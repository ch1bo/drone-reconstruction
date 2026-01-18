# Drone 3D Reconstruction

A modern pipeline for creating high-quality 3D reconstructions of neighborhoods and outdoor environments from monocular drone video footage using Neural Radiance Fields (NeRF) and 3D Gaussian Splatting.

## Overview

This project provides a streamlined workflow for offline 3D reconstruction from DJI drone 4K video feeds. It combines classical structure-from-motion (COLMAP) with GPS telemetry data from DJI SRT files to create metric-scale, georeferenced 3D models using state-of-the-art neural rendering (NeRF and 3D Gaussian Splatting).

**Key Features:**
- Automatic GPS/altitude extraction from DJI SRT subtitle files
- COLMAP-based reconstruction with GPS alignment
- Metric scale (real-world measurements in meters)
- Georeferenced output (East-North-Up coordinate system)
- High-precision altitude using drone's infrared sensor

## Workflow

### Processing Pipeline

```bash
# 1. Setup environment
nix develop

# 2. Process video with GPS alignment (one command does everything)
./scripts/process_with_gps.sh \
  --video ./input/DJI_20260117094312_0018_D.MP4 \
  --srt ./input/DJI_20260117094312_0018_D.SRT \
  --output ./data/processed_scene

# This automatically:
#   - Extracts GPS/altitude from SRT
#   - Runs COLMAP reconstruction
#   - Aligns to GPS coordinates
#   - Produces metric-scale, georeferenced model

# 3. Inspect alignment (optional)
colmap gui \
  --database_path ./data/processed_scene/colmap/database.db \
  --import_path ./data/processed_scene/colmap/sparse/1 \
  --image_path ./data/processed_scene/images

# 4. Train 3D Gaussian Splatting on GPU machine
ns-train splatfacto \
  --data ./data/processed_scene \
  --output-dir ./outputs/scene_01

# 5. View results interactively
ns-viewer --load-config ./outputs/scene_01/config.yml

# 6. Export georeferenced point cloud
ns-export pointcloud \
  --load-config ./outputs/scene_01/config.yml \
  --output-dir ./exports/scene_01
```

### Manual Step-by-Step

For more control or troubleshooting, run individual scripts:

```bash
# 1. Extract GPS from SRT
python scripts/parse_srt.py \
  --srt input/DJI_flight.SRT \
  --video input/DJI_flight.MP4 \
  --output data/gps_data.json

# 2. Run COLMAP reconstruction (or use ns-process-data)
# ... (see docs/gps_workflow.md)

# 3. Create GPS reference poses
python scripts/create_reference_poses.py \
  --gps-data data/gps_data.json \
  --output data/reference_poses.txt

# 4. Align to GPS
python scripts/align_to_gps.py \
  --input data/colmap/sparse/0 \
  --output data/colmap/aligned \
  --reference data/reference_poses.txt

# 5. Update transforms.json
python scripts/update_transforms.py \
  --aligned-colmap data/colmap/aligned \
  --transforms data/transforms.json
```

See [docs/gps_workflow.md](docs/gps_workflow.md) for detailed documentation and troubleshooting.

### Hardware Requirements

- **GPU**: NVIDIA GPU with 12GB+ VRAM (tested on RTX 4070Ti)
- **CPU**: Multi-core processor (32 cores recommended for COLMAP)
- **RAM**: 64GB recommended for large scenes
- **Storage**: ~10-50GB per scene depending on video length and resolution

### Expected Processing Times (on RTX 4070Ti)

- Video preprocessing + COLMAP: 30-60 minutes (CPU-bound)
- Gaussian Splatting training: 30-60 minutes
- NeRF training: 2-8 hours
- Real-time viewing: 30-60 FPS

## How It Works

### Pipeline Architecture

```
DJI Drone Video (4K) + SRT Telemetry
    ├── GPS/Altitude Extraction (parse_srt.py)
    └── Frame Extraction (ffmpeg)
          ↓
    COLMAP (Structure-from-Motion)
    ├── Feature Detection & Matching
    ├── Sparse Reconstruction
    └── Camera Pose Estimation
          ↓
    GPS Alignment (model_aligner)
    ├── Sim3 transform estimation (rotation + translation + scale)
    ├── Metric scale from GPS
    └── Georeferencing to ENU coordinates
          ↓
    Neural Reconstruction
    ├── 3D Gaussian Splatting (fast, recommended)
    └── NeRF variants (high quality, slower)
          ↓
    Metric-scale, Georeferenced 3D Model
```

### Key Components

#### 1. Structure-from-Motion (COLMAP)

COLMAP estimates camera poses and sparse 3D structure from video frames:
- Extracts and matches SIFT features across frames
- Performs incremental bundle adjustment
- Outputs camera intrinsics, extrinsics, and sparse point cloud
- Handles scale ambiguity better than pure monocular SLAM

#### 2. Neural Radiance Fields (NeRF)

NeRF represents scenes as continuous 5D functions (3D position + 2D viewing direction → RGB + density):
- **Pros**: Photorealistic novel view synthesis, continuous representation
- **Cons**: Slow rendering (requires many neural network queries per pixel)
- **Training**: 2-8 hours for neighborhood-scale scenes
- **Use case**: When rendering quality is paramount and speed is secondary

#### 3. 3D Gaussian Splatting

Represents scenes as collections of 3D Gaussian primitives with learned parameters:
- **Pros**: Real-time rendering (100-1000x faster than NeRF), faster training
- **Cons**: Discrete representation (millions of Gaussians)
- **Training**: 30-60 minutes for large outdoor scenes
- **Use case**: Large-scale outdoor reconstructions, interactive viewing

### Technical Background

**Why Neural Methods Work Well for Drone Footage**

- Handle large-scale outdoor scenes with varying lighting
- Robust to sparse view sampling (drone doesn't capture every angle)
- Deal with sky, foliage, and other challenging materials
- Produce complete, watertight reconstructions without explicit meshing

## Libraries and Tools

### Core Dependencies

- **[Nerfstudio](https://github.com/nerfstudio-project/nerfstudio)** - Unified framework for NeRF and Gaussian Splatting
  - Modular architecture supporting multiple methods
  - Built-in viewer and export tools
  - Active development and community

- **[COLMAP](https://colmap.github.io/)** - Structure-from-Motion and Multi-View Stereo
  - Industry standard for camera pose estimation
  - Integrated into Nerfstudio preprocessing pipeline

### Alternative Implementations

- **[gaussian-splatting](https://github.com/graphdeco-inria/gaussian-splatting)** - Original Gaussian Splatting implementation
- **[Instant-NGP](https://github.com/NVlabs/instant-ngp)** - NVIDIA's fast NeRF implementation
- **[ORB-SLAM3](https://github.com/UZ-SLAMLab/ORB_SLAM3)** - If you need real-time SLAM
- **[DROID-SLAM](https://github.com/princeton-vl/DROID-SLAM)** - Deep learning-based SLAM

## Key Papers and References

### Neural Rendering Foundations

1. **NeRF: Representing Scenes as Neural Radiance Fields for View Synthesis**  
   Mildenhall et al., ECCV 2020  
   [Paper](https://arxiv.org/abs/2003.08934) | [Project Page](https://www.matthewtancik.com/nerf)  
   *The foundational work that started the neural rendering revolution*

2. **3D Gaussian Splatting for Real-Time Radiance Field Rendering**  
   Kerbl et al., SIGGRAPH 2023  
   [Paper](https://arxiv.org/abs/2308.04079) | [Project Page](https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/)  
   *Current state-of-the-art for fast, high-quality reconstruction*

### Large-Scale Scene Reconstruction

3. **Mip-NeRF 360: Unbounded Anti-Aliased Neural Radiance Fields**  
   Barron et al., CVPR 2022  
   [Paper](https://arxiv.org/abs/2111.12077)  
   *Specifically designed for large outdoor unbounded scenes*

4. **Zip-NeRF: Anti-Aliased Grid-Based Neural Radiance Fields**  
   Barron et al., ICCV 2023  
   [Paper](https://arxiv.org/abs/2304.06706)  
   *Improved quality for detailed outdoor scenes*

### Structure-from-Motion

5. **Structure-from-Motion Revisited**  
   Schönberger & Frahm, CVPR 2016  
   [Paper](https://demuc.de/papers/schoenberger2016sfm.pdf)  
   *The paper behind COLMAP*

### Hybrid SLAM + Neural Approaches

6. **NICE-SLAM: Neural Implicit Scalable Encoding for SLAM**  
   Zhu et al., CVPR 2022  
   [Paper](https://arxiv.org/abs/2112.12130)  
   *If you need real-time tracking with neural reconstruction*

7. **Point-SLAM: Dense Neural Point Cloud-based SLAM**  
   Sandström et al., ICCV 2023  
   [Paper](https://arxiv.org/abs/2304.04278)  
   *Recent work combining classical SLAM robustness with neural quality*

## GPS-Aligned Reconstruction

DJI drones embed GPS, IMU, and altitude telemetry in SRT subtitle files alongside the video. This project leverages this data to create metric-scale, georeferenced 3D models.

### What You Get

- **Metric Scale**: Real-world measurements in meters (not arbitrary units)
- **Georeferencing**: Model positioned in GPS coordinate system (ENU)
- **Precise Altitude**: Uses drone's infrared altimeter (~0.1m precision) for vertical scale
- **GIS-Compatible**: Export models with geographic coordinates for mapping applications

### How It Works

1. **GPS Extraction** (`scripts/parse_srt.py`): Parses DJI SRT files to extract latitude, longitude, and altitude per frame
2. **COLMAP Reconstruction**: Standard structure-from-motion for precise relative camera poses
3. **GPS Alignment** (`scripts/align_to_gps.py`): Uses COLMAP's `model_aligner` to estimate similarity transform (Sim3) between COLMAP and GPS
4. **Transform Update** (`scripts/update_transforms.py`): Updates camera poses with metric, georeferenced coordinates

**Accuracy:** Consumer GPS provides ~5m horizontal, but combined with COLMAP's precision and accurate altitude data, the final model has:
- Horizontal positioning: ±5m (GPS limited)
- Vertical scale: ±0.1-0.5m (infrared altimeter + COLMAP)
- Relative measurements: Sub-meter accuracy (COLMAP quality)

### Processing Scripts

All scripts are in `scripts/`:

- `process_with_gps.sh` - End-to-end automated workflow
- `parse_srt.py` - Extract GPS/altitude from DJI SRT files
- `create_reference_poses.py` - Convert GPS to COLMAP format
- `align_to_gps.py` - Align reconstruction to GPS coordinates
- `update_transforms.py` - Update transforms.json with aligned poses

See [GPS Workflow Guide](docs/gps_workflow.md) for detailed usage and troubleshooting.

## Project Structure

```
├── README.md
├── flake.nix                      # Nix environment configuration
├── input/                         # Raw drone videos + SRT files
│   ├── DJI_*.mp4                  # DJI drone videos
│   └── DJI_*.SRT                  # DJI telemetry (GPS/altitude)
├── data/                          # Processed datasets
│   └── processed_scene/
│       ├── images/                # Extracted video frames
│       ├── colmap/                # COLMAP outputs
│       │   ├── sparse/0/          # Original reconstruction
│       │   └── aligned/           # GPS-aligned reconstruction
│       ├── gps_data.json          # Parsed GPS telemetry
│       ├── reference_poses.txt    # GPS poses for alignment
│       └── transforms.json        # Camera poses (georeferenced)
├── outputs/                       # Trained NeRF/Gaussian Splatting models
│   └── scene_01/
│       ├── config.yml
│       └── nerfstudio_models/
├── exports/                       # Exported meshes, point clouds
├── scripts/                       # GPS processing pipeline
│   ├── process_with_gps.sh        # End-to-end workflow
│   ├── parse_srt.py               # Extract GPS from SRT
│   ├── create_reference_poses.py  # Convert to COLMAP format
│   ├── align_to_gps.py            # Run GPS alignment
│   └── update_transforms.py       # Update with aligned poses
└── docs/
    └── gps_workflow.md            # Detailed GPS workflow guide
```

## Features

- [x] GPS-aligned reconstruction with metric scale
- [x] Automatic DJI SRT telemetry parsing
- [x] Georeferenced 3D models (ENU coordinate system)
- [x] Infrared altimeter integration for precise vertical scale

## Future Enhancements

- [ ] GPU-accelerated COLMAP for faster preprocessing
- [ ] Multi-video fusion for complete neighborhood coverage
- [ ] RTK GPS support for centimeter-level accuracy
- [ ] Automated flight path planning for optimal coverage
- [ ] Web-based 3D viewer for sharing results
- [ ] GIS export formats (GeoTIFF, LAS with coordinates)
- [ ] Change detection across different flight dates

## Troubleshooting

### Common Issues

**Out of Memory Errors**
- Reduce `--max-num-iterations` for training
- Lower resolution with `--pipeline.datamanager.train-num-rays-per-batch`
- Use `--pipeline.model.predict-normals False` to save memory

**Poor Reconstruction Quality**
- Ensure sufficient overlap between video frames (70%+ recommended)
- Check COLMAP results - if sparse reconstruction fails, the video quality may be insufficient
- Increase video bitrate for future flights
- Fly slower with more stable camera motion

**COLMAP Fails**
- Video may have motion blur - fly slower or increase shutter speed
- Insufficient texture in scene (e.g., blank walls)
- Try adjusting COLMAP feature extraction parameters

## Contributing

This is a personal project, but suggestions and improvements are welcome through issues and pull requests.

## License

Apache-2.0

## Acknowledgments

Built on the excellent work of the Nerfstudio team and the broader neural rendering community. Special thanks to the authors of the referenced papers for making their code available.
