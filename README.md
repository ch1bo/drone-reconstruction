# Drone 3D Reconstruction

A pipeline for creating 3D reconstructions from DJI drone video footage,
using Structure-from-Motion (COLMAP) for camera pose estimation and 3D
Gaussian Splatting (via Nerfstudio) for the final neural reconstruction.

## Goal

The aim is to fly a drone over a site, feed the video into this pipeline,
and get back a walkable 3D model with real-world scale and geographic
positioning. "Real-world scale" means measurements in meters; "geographic
positioning" means the model is oriented and placed according to GPS
coordinates, so it could be overlaid on a map.

The immediate use case is neighborhood-scale outdoor scenes — a few hundred
meters across, flown at moderate altitude. Indoor scenes and close-range
detail work are out of scope.

## Setup

The environment is managed with [Nix flakes](https://nixos.wiki/wiki/Flakes).
There are two shells:

```
nix develop          # lightweight: colmap, ffmpeg
nix develop .#full   # full pipeline including CUDA + nerfstudio
```

The split exists because the full shell takes a long time to build the
first time (it compiles CUDA kernels) and requires an NVIDIA GPU. Day-to-day
exploration of COLMAP outputs, tweaking scripts, or reading this document
does not need the full shell.

[`direnv`](https://direnv.net/) is configured via `.envrc` to auto-activate
the default shell when you `cd` into the project.

### Why Nix

Nerfstudio and its dependencies (PyTorch, tiny-cuda-nn, etc.) are
notoriously painful to install consistently. Nix pins exact versions and
makes the environment reproducible across machines. The tradeoff is a slower
first-time setup, but subsequent `nix develop` calls are instant (assuming
the binary cache is available).

The Nix binary cache `cache.nixos-cuda.org` (configured in `flake.nix`) is
used to avoid recompiling CUDA packages from source on every machine.

### tiny-cuda-nn cache

`tiny-cuda-nn` compiles CUDA kernels at runtime using JIT compilation. By
default it writes these to a path inside the Python package directory, which
is read-only in the Nix store. The patch in
`patches/tiny-cuda-nn-cache-env.patch` makes it respect a
`TCNN_CACHE_PATH` environment variable instead. The `full` devshell sets
this to `./cache/tinycudann` so compiled kernels land in the project
directory and persist across shell sessions.

### Nerfstudio as a submodule

Nerfstudio itself is installed via `pip install -e .` from a git submodule
at `nerfstudio/`. This happens automatically the first time the `full` shell
is created (`postVenvCreation` in `flake.nix`). The submodule approach
allows pinning to a specific commit and applying local patches if needed.

## Pipeline

Frame extraction, sparse reconstruction, and GPS alignment run in the
default shell (`nix develop`) — they only need ffmpeg and COLMAP. The
optional dense point cloud step is split: `image_undistorter` and
`stereo_fusion` are CPU-only (default shell); `patch_match_stereo` needs
CUDA (full shell). Training and viewing need the full shell for nerfstudio.

```
DJI video (.MP4) + telemetry (.SRT)
        │
        ▼
  ffmpeg                    ← extract frames
  colmap                    ← feature extraction, matching, sparse SfM
        │
        ▼
  GPS alignment             ← align_existing_reconstruction.sh
        │  reads GPS from .SRT, aligns COLMAP model using
        │  COLMAP model_aligner (Sim3 fit to GPS positions)
        │
        ▼
  colmap (optional)         ← dense point cloud via MVS
        │
        ▼
  ns-train splatfacto       ← 3D Gaussian Splatting training
        │
        ▼
  ns-viewer / ns-export     ← interactive viewing or mesh/point cloud export
```

### Frame extraction

```sh
mkdir -p data/flight1/images

ffmpeg -i input/DJI_20260117094704_0020_D.MP4 \
  -vf fps=2 \
  -q:v 2 \
  data/flight1/images/frame_%06d.jpg
```

`fps=2` extracts 2 frames per second. For a 5-minute flight at normal
drone speed that gives ~600 frames, which is enough overlap for COLMAP.
More frames means better reconstruction but slower COLMAP matching.

`-q:v 2` is near-lossless JPEG quality. COLMAP's feature extractor works
on the images directly, so quality matters more here than disk space.

### Sparse reconstruction with COLMAP

```sh
mkdir -p data/flight1/sparse

# Feature extraction — SIFT keypoints for each image
colmap feature_extractor \
  --database_path data/flight1/database.db \
  --image_path data/flight1/images \
  --ImageReader.camera_model OPENCV \
  --ImageReader.single_camera 1 \
  --FeatureExtraction.use_gpu 1

# Sequential matching — matches each frame to its neighbours only
colmap sequential_matcher \
  --database_path data/flight1/database.db \
  --FeatureMatching.use_gpu 1

# Sparse reconstruction — estimates camera poses and 3D point cloud
colmap mapper \
  --database_path data/flight1/database.db \
  --image_path data/flight1/images \
  --output_path data/flight1/sparse
```

`single_camera 1` tells COLMAP all images share the same intrinsics (one
physical lens), which is correct for a single drone video and reduces the
degrees of freedom during bundle adjustment.

`OPENCV` camera model supports radial and tangential distortion
coefficients (k1, k2, p1, p2), appropriate for drone camera lenses.

**Sequential matching** is used rather than exhaustive matching because
drone video is a continuous flyover — consecutive frames share the most
features. Exhaustive matching is O(n²) in frame count and unnecessary here.

The mapper outputs one or more reconstructions under
`colmap/sparse/0/`, `colmap/sparse/1/`, etc., ordered by the number of
registered images. `0` is usually the largest and the one to use.

Inspect the result:

```sh
colmap gui \
  --import_path data/flight1/sparse/0 \
  --database_path data/flight1/database.db \
  --image_path data/flight1/images
```

### GPS alignment

```sh
# Parse SRT and write a reference poses file for colmap model_aligner
python scripts/srt_to_reference_poses.py \
  --srt input/DJI_20260117094312_0018_D.SRT \
  --video input/DJI_20260117094312_0018_D.MP4 \
  --fps 2 \
  --output data/flight1/reference_poses.txt

# Fit a Sim3 transform between the COLMAP reconstruction and the GPS positions
colmap model_aligner \
  --input_path data/flight1/sparse/0 \
  --output_path data/flight1/aligned \
  --ref_images_path data/flight1/reference_poses.txt \
  --ref_is_gps 1 \
  --alignment_type enu \
  --alignment_max_error 10
```

The aligned model lands in `colmap/aligned/`, in the same binary format as
`colmap/sparse/0` — it can be inspected in the COLMAP GUI or passed to any
subsequent step in place of the unaligned model.

**Why Sim3 and not just translation?** COLMAP from monocular video produces
poses that are correct up to an unknown scale. GPS provides the real-world
scale. The Sim3 fit recovers rotation (to align orientation), translation
(to place the model geographically), and scale (to make distances real-world
meters) all at once.

**Coordinate system: ENU.** The aligned model uses an East-North-Up local
coordinate system: X=East, Y=North, Z=Up, origin at the first camera
position, units in metres. ENU is right-handed and standard in surveying
and robotics. ECEF (Earth-Centered-Earth-Fixed) is the alternative but
less intuitive for a local scene.

**Altitude: relative, not absolute.** DJI SRT files contain both
`rel_alt` (height above the takeoff point, from the drone's infrared
altimeter, ~0.1 m precision) and `abs_alt` (MSL altitude from GPS,
~10–20 m precision). The pipeline uses `rel_alt` by default because its
much higher precision gives a better scale estimate. The vertical axis in
the final model is therefore height above takeoff, not sea level.

**GPS accuracy.** Consumer GPS horizontal accuracy is ~5 m. That is the
dominant source of error in the final model's geographic positioning.
Relative distances within the model (measured from COLMAP, not GPS) are
sub-meter accurate.

### Dense point cloud (optional)

After the sparse reconstruction, COLMAP can compute per-pixel depth maps
and fuse them into a dense point cloud via Multi-View Stereo. This gives
real geometry — not a learned representation — directly usable in
MeshLab, CloudCompare, or a GIS tool.

The MVS pipeline needs its own workspace layout (undistorted images +
sparse model as siblings). `image_undistorter` sets that up from the
GPS-aligned model:

```sh
# Prepare undistorted workspace for MVS
colmap image_undistorter \
  --image_path data/flight1/images \
  --input_path data/flight1/aligned \
  --output_path data/flight1/dense \
  --output_type COLMAP

# Compute depth maps (requires CUDA, run in nix develop .#full)
colmap patch_match_stereo \
  --workspace_path data/flight1/dense \
  --PatchMatchStereo.geom_consistency true

# Fuse depth maps into a single point cloud
colmap stereo_fusion \
  --workspace_path data/flight1/dense \
  --input_type geometric \
  --output_path data/flight1/dense/fused.ply
```

The output `fused.ply` is a coloured point cloud in the same coordinate
system as the sparse model — so if you have run GPS alignment, it is
already georeferenced in ENU metres.

`patch_match_stereo` is GPU-only (CUDA required). `image_undistorter` and
`stereo_fusion` run on CPU and can be done in the default shell.
`stereo_fusion` is also the step most sensitive to RAM: for 1000 full-res
frames expect several GB of working set.

### Training

```sh
ns-train splatfacto \
  --data data/flight1 \
  --output-dir outputs/ \
  colmap-data-parser-config \
    --colmap-path colmap/aligned \
    --assume-colmap-world-coordinate-convention False
```

This trains a 3D Gaussian Splatting model. Training takes 30–60 minutes on an RTX 4070 Ti.

Nerfstudio's `colmap` dataparser reads the sparse model directly from
`data/<scene>/colmap/<model>/` and images from `data/<scene>/images/` —
no intermediate `transforms.json` conversion needed. The `--colmap-path`
argument selects the GPS-aligned model rather than the raw `sparse/0`.

`--assume-colmap-world-coordinate-convention False` is required when using
a GPS-aligned model. By default the dataparser assumes unaligned COLMAP
output, where gravity points along -Y, and applies a transform to remap it
to nerfstudio's +Z-up convention (swapping Y/Z and negating). A GPS-aligned
ENU model already has X=East, Y=North, Z=Up, so that remapping must be
skipped or it inverts the Z axis and misplaces North.

**Why Gaussian Splatting over NeRF?** For large outdoor scenes, Gaussian
Splatting trains faster (~30 min vs. 2–8 hours for a full NeRF), renders in
real time (suitable for interactive exploration), and produces comparable
visual quality. NeRF variants like Zip-NeRF may give better results for
scenes with fine detail, but the speed tradeoff is steep. `splatfacto` is
Nerfstudio's implementation and well-maintained.

### Viewing and exporting

```sh
# Interactive viewer (serves in browser)
ns-viewer --load-config outputs/flight1/splatfacto/<timestamp>/config.yml

# Render a saved camera path
ns-render camera-path \
  --load-config outputs/flight1/splatfacto/<timestamp>/config.yml \
  --camera-path-filename cameras/path.json \
  --output-path renders/flight1.mp4

# Export point cloud from the Gaussian model
ns-export pointcloud \
  --load-config outputs/flight1/splatfacto/<timestamp>/config.yml \
  --output-dir exports/flight1

# Export mesh
ns-export poisson \
  --load-config outputs/flight1/splatfacto/<timestamp>/config.yml \
  --output-dir exports/flight1
```

The nerfstudio viewer (`ns-viewer`) serves an interactive 3D view in the
browser. Camera paths for rendering can be defined in the viewer and saved
as JSON files.

## DJI SRT telemetry format

DJI drones embed per-frame GPS and sensor data in `.SRT` subtitle files
alongside the video. Modern firmware uses the format:

```
[latitude: 47.327540] [longitude: 9.603926] [rel_alt: 4.000 abs_alt: 377.161]
```

Older firmware used:

```
GPS(47.327540,9.603926,377.161)
```

`scripts/srt_to_reference_poses.py` handles both formats. It interpolates
telemetry to match each extracted video frame's timestamp (the SRT entries
are one-per-second; the extracted frames may be at sub-second intervals).
The Python `srt` library handles subtitle parsing; the telemetry values are
extracted with regexes.

## Common issues

**COLMAP fails on a headless server (no display)**

COLMAP links against Qt and tries to initialise a display even in CLI mode.
Set `QT_QPA_PLATFORM=offscreen` before running any COLMAP command.

**COLMAP fails on a headless server (OpenGL)**

Feature extraction uses OpenGL by default for GPU acceleration. On a
headless server without a display or proper GPU passthrough this fails. Add
`--FeatureExtraction.use_gpu 0` and `--FeatureMatching.use_gpu 0` to the
relevant COLMAP commands, or pass `--cpu` to `align_existing_reconstruction.sh`.
CPU mode is 2–3× slower but works everywhere.

**Alignment fails: "not enough inliers"**

The GPS track and COLMAP trajectory don't match well enough for RANSAC to
find an inlier set. First check that the SRT file corresponds to the correct
video. If it does, try increasing `--max-error` from 10 to 15 or 20 metres
to accommodate noisier GPS.

**Out of GPU memory during training**

Reduce `--pipeline.datamanager.train-num-rays-per-batch`, or re-extract
frames at a lower resolution with ffmpeg's `-vf scale=` filter.

## References

- [Nerfstudio](https://docs.nerf.studio/) — the framework used for training
  and export
- [COLMAP](https://colmap.github.io/) — structure-from-motion library
- [3D Gaussian Splatting](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/)
  — the reconstruction method (Kerbl et al., SIGGRAPH 2023)
- [NeRF](https://www.matthewtancik.com/nerf) — the earlier neural rendering
  approach this builds on (Mildenhall et al., ECCV 2020)
- [DJI SRT format](https://github.com/JuanIrache/DJI_SRT_Parser) — community
  documentation of the telemetry format
