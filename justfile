# Drone 3D Reconstruction Pipeline
# Use `just` to see all commands
# Default parameters - override with: just <command> <param>=<value>

video := "input/DJI_20260117094312_0018_D.MP4"
srt := "input/DJI_20260117094312_0018_D.SRT"
data := "data/processed_scene"
output := "outputs/scene_01"

# Show this help
@default:
    just --list --unsorted

# ============================================================================
# Pipeline - Main workflows
# ============================================================================

# Process video from scratch with GPS alignment
[group('pipeline')]
process video=video srt=srt data=data:
    ./scripts/process_with_gps.sh --video {{ video }} --srt {{ srt }} --output {{ data }}

# Align existing reconstruction to GPS
[group('pipeline')]
align srt=srt data=data:
    ./scripts/align_existing_reconstruction.sh --srt {{ srt }} --data {{ data }}

# Train Gaussian Splatting model
[group('pipeline')]
train data=data output=output steps="30000":
    ns-train splatfacto --data {{ data }} --output-dir {{ output }} --max-num-iterations {{ steps }}

# View trained model
[group('pipeline')]
view config:
    ns-viewer --load-config {{ config }}

# ============================================================================
# Steps - Individual pipeline steps
# ============================================================================

# Extract GPS data from SRT file
[group('steps')]
gps-extract srt=srt video=video output=(data + "/gps_data.json"):
    python scripts/parse_srt.py --srt {{ srt }} --video {{ video }} --output {{ output }}

# Create reference poses for GPS alignment
[group('steps')]
gps-reference gps=(data + "/gps_data.json") transforms=(data + "/transforms.json") output=(data + "/reference_poses.txt"):
    python scripts/create_reference_poses.py --gps-data {{ gps }} --transforms {{ transforms }} --output {{ output }}

# Align COLMAP to GPS coordinates
[group('steps')]
gps-align input=(data + "/colmap/sparse/0") reference=(data + "/reference_poses.txt") output=(data + "/colmap/aligned") error="10.0":
    python scripts/align_to_gps.py --input {{ input }} --output {{ output }} --reference {{ reference }} --alignment-type enu --max-error {{ error }}

# Run nerfstudio preprocessing (COLMAP)
[group('steps')]
colmap-process video=video data=data:
    ns-process-data video --data {{ video }} --output-dir {{ data }}

# Open COLMAP GUI to inspect model
[group('steps')]
colmap-gui model=(data + "/colmap/sparse/0"):
    colmap gui --import_path {{ model }}

# ============================================================================
# Export - Rendering and export
# ============================================================================

# Export point cloud
[group('export')]
export-points config output="exports":
    mkdir -p {{ output }}
    ns-export pointcloud --load-config {{ config }} --output-dir {{ output }}

# Export mesh
[group('export')]
export-mesh config output="exports":
    mkdir -p {{ output }}
    ns-export poisson --load-config {{ config }} --output-dir {{ output }}

# Render camera path
[group('export')]
render config camera_path output="renders/output.mp4":
    mkdir -p renders
    ns-render camera-path --load-config {{ config }} --camera-path-filename {{ camera_path }} --output-path {{ output }}

# ============================================================================
# Utilities
# ============================================================================

# Check dependencies are installed
[group('util')]
check:
    #!/usr/bin/env bash
    echo "Checking dependencies..."
    command -v python >/dev/null 2>&1 && echo "✓ Python" || echo "✗ Python"
    command -v ffmpeg >/dev/null 2>&1 && echo "✓ FFmpeg" || echo "✗ FFmpeg"
    command -v colmap >/dev/null 2>&1 && echo "✓ COLMAP" || echo "✗ COLMAP"
    command -v ns-train >/dev/null 2>&1 && echo "✓ Nerfstudio" || echo "✗ Nerfstudio"
    command -v nvidia-smi >/dev/null 2>&1 && echo "✓ CUDA" || echo "✗ CUDA"

# Show GPU status
[group('util')]
gpu:
    @nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv

# Show disk usage
[group('util')]
disk:
    @du -sh input/ data/ outputs/ renders/ 2>/dev/null || true
