# GPS-Aligned 3D Reconstruction Workflow

This guide explains how to create metric-scale, georeferenced 3D reconstructions from DJI drone footage using GPS/altitude data from SRT subtitle files.

## Overview

The workflow integrates DJI telemetry (GPS coordinates, altitude) into the COLMAP-based reconstruction pipeline to achieve:

1. **Metric scale**: Measurements in real-world units (meters) instead of arbitrary scale
2. **Georeferencing**: 3D model positioned in GPS coordinate system

### Why GPS Integration Matters

Standard COLMAP reconstruction produces accurate camera poses but with arbitrary scale and orientation. Adding GPS data provides:

- Real-world measurements (e.g., "building is 15m tall" instead of "15 units")
- Geographic context (GPS coordinates for overlaying on maps)
- Better vertical scale accuracy using drone's infrared altimeter (~0.1m precision)

## Prerequisites

- DJI drone video (.MP4)
- Corresponding SRT subtitle file (contains GPS/telemetry data)
- Nix development environment (run `nix develop`)

## Quick Start

### Option A: Automated Workflow

Use the provided script for end-to-end processing:

```bash
./scripts/process_with_gps.sh \
    --video input/DJI_20260117094312_0018_D.MP4 \
    --srt input/DJI_20260117094312_0018_D.SRT \
    --output data/processed_scene
```

This runs all steps automatically:
1. GPS extraction
2. COLMAP reconstruction
3. GPS alignment
4. Transform update

### Option B: Step-by-Step

For more control or troubleshooting, run each step manually:

#### 1. Extract GPS from SRT

```bash
python scripts/parse_srt.py \
    --srt input/DJI_20260117094312_0018_D.SRT \
    --video input/DJI_20260117094312_0018_D.MP4 \
    --output data/gps_data.json
```

**Output:** `gps_data.json` with GPS coordinates and altitude for each frame.

#### 2. Run COLMAP Reconstruction

Extract video frames:

```bash
mkdir -p data/images
ffmpeg -i input/DJI_20260117094312_0018_D.MP4 \
    -vf "fps=1" \
    -q:v 2 \
    data/images/frame_%06d.png
```

Run COLMAP:

```bash
mkdir -p data/colmap

# Feature extraction
colmap feature_extractor \
    --database_path data/colmap/database.db \
    --image_path data/images \
    --ImageReader.camera_model OPENCV \
    --ImageReader.single_camera 1

# Feature matching
colmap exhaustive_matcher \
    --database_path data/colmap/database.db

# Sparse reconstruction
colmap mapper \
    --database_path data/colmap/database.db \
    --image_path data/images \
    --output_path data/colmap/sparse
```

#### 3. Create Reference Poses

Convert GPS data to COLMAP format:

```bash
python scripts/create_reference_poses.py \
    --gps-data data/gps_data.json \
    --output data/reference_poses.txt
```

**Output:** `reference_poses.txt` in COLMAP's format (longitude, latitude, altitude).

#### 4. Align to GPS

Run COLMAP model_aligner:

```bash
python scripts/align_to_gps.py \
    --input data/colmap/sparse/0 \
    --output data/colmap/aligned \
    --reference data/reference_poses.txt \
    --alignment-type enu \
    --max-error 10.0
```

**Parameters:**
- `alignment-type enu`: East-North-Up local coordinates (recommended)
- `max-error 10.0`: 10 meter threshold (suitable for consumer GPS)

**Output:** Aligned COLMAP reconstruction in `data/colmap/aligned/`

#### 5. Update transforms.json

If you have `transforms.json` from Nerfstudio:

```bash
python scripts/update_transforms.py \
    --aligned-colmap data/colmap/aligned \
    --transforms data/transforms.json
```

This updates camera poses while preserving intrinsics (focal length, distortion).

## Understanding the Pipeline

### GPS Data Format

DJI SRT files contain per-frame telemetry:

```
[latitude: 47.327540] [longitude: 9.603926] [rel_alt: 4.000 abs_alt: 377.161]
```

- **Latitude/Longitude**: WGS84 GPS coordinates (~5m horizontal accuracy)
- **Relative altitude**: Height above takeoff point (infrared sensor, ~0.1m accuracy)
- **Absolute altitude**: MSL altitude from GPS (~10-20m vertical accuracy)

The parser uses **relative altitude** by default because it's more precise for consumer drones.

### Coordinate Systems

1. **COLMAP Output (Unaligned)**
   - Arbitrary origin and scale
   - Accurate relative poses but unknown real-world position

2. **GPS Coordinates**
   - WGS84 latitude/longitude
   - Coarse accuracy (~5m) but provides scale and geographic context

3. **Aligned Output (ENU)**
   - East-North-Up local coordinate system
   - Origin at first camera position
   - Metric scale (meters)
   - Real-world orientation

### Alignment Process

The `model_aligner` estimates a **similarity transformation (Sim3)** between COLMAP and GPS:

1. Matches camera positions from COLMAP to GPS coordinates
2. Uses RANSAC to robustly estimate 7-DOF transform:
   - 3 DOF rotation
   - 3 DOF translation
   - 1 DOF scale
3. Applies transform to align entire reconstruction

**Result:** COLMAP's precise poses + GPS scale/position = metric georeferenced reconstruction

## Verification

### 1. Inspect Alignment in COLMAP GUI

```bash
colmap gui --import_path data/colmap/aligned
```

Check:
- Camera positions form smooth trajectory
- GPS error statistics (shown in model_aligner output)
- Sparse point cloud looks reasonable

### 2. Measure Known Distances

In the final reconstruction:
1. Identify objects with known dimensions (e.g., car length ~4-5m)
2. Measure in 3D viewer
3. Verify measurements match reality (±10% acceptable)

### 3. Compare Trajectories

Visualize GPS track vs. aligned camera positions:

```python
import json
import matplotlib.pyplot as plt

# Load GPS data
with open('data/gps_data.json') as f:
    gps = json.load(f)

# Load aligned transforms
with open('data/transforms.json') as f:
    transforms = json.load(f)

# Extract positions
gps_lons = [f['longitude'] for f in gps['frames']]
gps_lats = [f['latitude'] for f in gps['frames']]

cam_xs = [f['transform_matrix'][0][3] for f in transforms['frames']]
cam_ys = [f['transform_matrix'][1][3] for f in transforms['frames']]

# Plot
plt.figure(figsize=(10, 5))

plt.subplot(1, 2, 1)
plt.plot(gps_lons, gps_lats, 'o-', label='GPS')
plt.title('GPS Trajectory')
plt.xlabel('Longitude')
plt.ylabel('Latitude')

plt.subplot(1, 2, 2)
plt.plot(cam_xs, cam_ys, 'o-', label='Aligned Cameras', color='orange')
plt.title('Aligned Camera Trajectory (ENU)')
plt.xlabel('East (m)')
plt.ylabel('North (m)')
plt.axis('equal')

plt.tight_layout()
plt.show()
```

## Troubleshooting

### Alignment Fails with "Not enough inliers"

**Cause:** GPS positions don't match COLMAP trajectory (too noisy or wrong)

**Solutions:**
1. Increase error threshold: `--max-error 15.0` or `20.0`
2. Check if GPS data is corrupted (inspect `gps_data.json`)
3. Verify SRT file corresponds to correct video
4. Try different alignment type: `--alignment-type ecef`

### Very Large Scale Errors

**Symptom:** Buildings appear 100m tall when they should be 10m

**Cause:** Scale factor incorrectly estimated

**Solutions:**
1. Check relative altitude data quality
2. Try using absolute altitude: `--use-abs-altitude` in create_reference_poses.py
3. Manually verify scale using known object dimensions

### Poor Vertical Accuracy

**Cause:** GPS altitude is less accurate than horizontal position

**Solution:** Use relative altitude (default behavior):

```bash
python scripts/create_reference_poses.py \
    --gps-data data/gps_data.json \
    --output data/reference_poses.txt
    # Uses relative altitude by default
```

### Missing transforms.json

**Cause:** Haven't run Nerfstudio's `ns-process-data` yet

**Solutions:**
1. Run on GPU machine: `ns-process-data video --data video.mp4 --output-dir data/`
2. Or manually create transforms.json from aligned COLMAP using:
   ```bash
   colmap model_converter \
       --input_path data/colmap/aligned \
       --output_path data/transforms.txt \
       --output_type TXT
   ```

### Qt/X11 Error on Headless Server

**Symptom:**
```
qt.qpa.xcb: could not connect to display
This application failed to start because no Qt platform plugin could be initialized
```

**Cause:** COLMAP has Qt dependencies and tries to initialize a display even for CLI operations

**Solutions:**

1. **Using Nix (Automatic):** The flake.nix already sets this for you
   ```bash
   nix develop  # QT_QPA_PLATFORM=offscreen is set automatically
   ./scripts/process_with_gps.sh ...
   ```

2. **Manual Setup:** Set environment variable before running
   ```bash
   export QT_QPA_PLATFORM=offscreen
   ./scripts/process_with_gps.sh ...
   ```

3. **Alternative:** Use xvfb (virtual framebuffer)
   ```bash
   xvfb-run ./scripts/process_with_gps.sh ...
   ```

**Note:** The `process_with_gps.sh` script automatically sets `QT_QPA_PLATFORM=offscreen` if not already set.

### OpenGL Context Error on Headless Server

**Symptom:**
```
E20260118 20:40:02.303983 140640883779904 opengl_utils.cc:56] Check failed: context_.create()
terminate called after throwing an instance of 'std::invalid_argument'
```

**Cause:** COLMAP tries to use GPU/OpenGL for feature extraction but can't create OpenGL context on headless server

**Solution:** Use CPU-only mode

```bash
./scripts/process_with_gps.sh \
  --video input/flight.mp4 \
  --srt input/flight.SRT \
  --output data/scene \
  --cpu
```

**Note:** CPU mode is slower than GPU mode (2-3x) but works on all systems. Use GPU mode on machines with display or proper GPU passthrough.

## Advanced Usage

### RTK GPS (High Precision)

If you have RTK GPS (~2cm accuracy):

1. Use tighter error threshold: `--max-error 0.5`
2. Consider using GPS positions directly without COLMAP refinement
3. Alignment will be much more accurate

### Multi-Video Fusion

To combine multiple drone flights:

1. Process each video separately with GPS alignment
2. Merge COLMAP models:
   ```bash
   colmap model_merger \
       --input_path1 data/flight1/colmap/aligned \
       --input_path2 data/flight2/colmap/aligned \
       --output_path data/merged
   ```
3. Both models share GPS coordinate system, so merging is straightforward

### Export Georeferenced Outputs

Export point cloud with GPS coordinates:

```bash
# On GPU machine after training
ns-export pointcloud \
    --load-config outputs/scene_01/config.yml \
    --output-dir exports/georeferenced \
    --num-points 1000000
```

The output point cloud will have coordinates in the aligned coordinate system (ENU or ECEF).

For GIS integration:
1. Convert to LAS format with GPS coordinates
2. Import into QGIS or other GIS software
3. Overlay on satellite imagery or maps

## File Reference

### gps_data.json

```json
{
  "source_srt": "input/video.SRT",
  "source_video": "input/video.mp4",
  "num_entries": 1234,
  "has_rel_altitude": true,
  "frames": [
    {
      "frame_number": 0,
      "timestamp": 0.0,
      "latitude": 47.327540,
      "longitude": 9.603926,
      "abs_altitude": 377.161,
      "rel_altitude": 4.000
    }
  ]
}
```

### reference_poses.txt

```
frame_000000.png 9.603926 47.327540 4.000
frame_000001.png 9.603934 47.327542 4.050
frame_000002.png 9.603941 47.327544 4.100
```

Format: `image_name longitude latitude altitude`

### transforms.json (georeferenced)

Standard Nerfstudio format with added metadata:

```json
{
  "camera_model": "OPENCV",
  "fl_x": 1234.5,
  "fl_y": 1234.5,
  "cx": 960.0,
  "cy": 540.0,
  "frames": [
    {
      "file_path": "images/frame_000000.png",
      "transform_matrix": [
        [/* 4x4 camera-to-world matrix in ENU coordinates */]
      ]
    }
  ],
  "metadata": {
    "coordinate_system": "enu",
    "aligned_to_gps": true
  }
}
```

## Performance Notes

### Computation Time (4-core CPU, no GPU)

- GPS extraction: ~10 seconds
- COLMAP feature extraction: ~5-15 minutes (depends on frame count)
- COLMAP matching: ~5-30 minutes
- COLMAP reconstruction: ~10-60 minutes
- GPS alignment: ~5-30 seconds
- Transform update: ~1 second

**Total:** ~30-120 minutes for initial processing (one-time cost)

### Accuracy Expectations

| Metric | Consumer GPS | RTK GPS |
|--------|--------------|---------|
| Horizontal position | ±5m | ±2cm |
| Vertical (GPS alt) | ±10-20m | ±4cm |
| Vertical (relative alt) | ±0.1m | N/A |
| Final scale accuracy | ±5-10% | ±1% |
| Orientation | ±few degrees | ±0.1° |

## References

- [COLMAP Documentation](https://colmap.github.io/)
- [Nerfstudio Docs](https://docs.nerf.studio/)
- [DJI SRT Format Specification](https://github.com/JuanIrache/DJI_SRT_Parser)
- [GPS Coordinate Systems](https://en.wikipedia.org/wiki/Geographic_coordinate_system)

## Support

For issues or questions:
1. Check this documentation
2. Inspect intermediate outputs (GPS data, COLMAP reconstruction)
3. Open GitHub issue with:
   - SRT file sample
   - COLMAP output logs
   - Alignment error messages
