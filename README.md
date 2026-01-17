# Drone 3D Reconstruction

A modern pipeline for creating high-quality 3D reconstructions of neighborhoods and outdoor environments from monocular drone video footage using Neural Radiance Fields (NeRF) and 3D Gaussian Splatting.

## Overview

This project provides a streamlined workflow for offline 3D reconstruction from DJI drone 4K video feeds. It leverages state-of-the-art neural rendering techniques that have emerged in the past few years, combining classical structure-from-motion (SfM) with modern neural implicit representations.

## Target Workflow

### Getting Started

```bash
# 1. Setup environment
nix develop  # or use your preferred environment setup

# 2. Process drone video
ns-process-data video \
  --data ./input/drone_flight.mp4 \
  --output-dir ./data/processed_scene

# 3. Train 3D Gaussian Splatting model (recommended for large outdoor scenes)
ns-train splatfacto \
  --data ./data/processed_scene \
  --output-dir ./outputs/scene_01

# Alternative: Train NeRF model (higher quality, slower)
# ns-train nerfacto --data ./data/processed_scene

# 4. View results interactively
ns-viewer --load-config ./outputs/scene_01/config.yml

# 5. Export mesh or point cloud
ns-export pointcloud \
  --load-config ./outputs/scene_01/config.yml \
  --output-dir ./exports/scene_01
```

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
Drone Video (4K) 
    ↓
Frame Extraction
    ↓
COLMAP (Structure-from-Motion)
    ├── Feature Detection & Matching
    ├── Sparse Reconstruction
    └── Camera Pose Estimation
    ↓
Neural Reconstruction
    ├── 3D Gaussian Splatting (fast, recommended)
    └── NeRF variants (high quality, slower)
    ↓
3D Model (viewable, exportable)
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

## DJI Drone Metadata

DJI drones typically embed GPS, IMU, and other telemetry data in:
- Video file metadata (MP4 metadata tracks)
- Separate SRT subtitle files
- Flight log files (DAT/TXT format)

While COLMAP provides better camera poses for reconstruction, GPS data can:
- Provide metric scale (instead of arbitrary units)
- Initialize camera positions for faster convergence
- Georeference the final 3D model

Tools for extraction:
- `exiftool` for video metadata
- DJI-specific parsers like `dji-srt-parser`
- Consider implementing GPS-constrained bundle adjustment

## Project Structure

```
├── README.md
├── flake.nix                 # Nix environment configuration
├── input/                    # Raw drone videos
├── data/                     # Processed datasets
│   └── processed_scene/
│       ├── images/           # Extracted frames
│       ├── colmap/           # COLMAP outputs
│       └── transforms.json   # Camera poses in NeRF format
├── outputs/                  # Trained models
│   └── scene_01/
│       ├── config.yml
│       └── nerfstudio_models/
├── exports/                  # Exported meshes, point clouds
└── scripts/                  # Helper scripts
    ├── extract_metadata.py
    └── batch_process.sh
```

## Future Enhancements

- [ ] GPU-accelerated COLMAP for faster preprocessing
- [ ] Multi-video fusion for complete neighborhood coverage
- [ ] GPS-constrained bundle adjustment
- [ ] Automated flight path planning for optimal coverage
- [ ] Web-based 3D viewer for sharing results
- [ ] Mesh post-processing and texturing
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
