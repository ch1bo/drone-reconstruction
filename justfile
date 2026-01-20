# Drone 3D Reconstruction Pipeline
# Use `just` to see all commands
# Default parameters - override with: just <command> <param>=<value>

video := "input/DJI_20260117094312_0018_D.MP4"
srt := "input/DJI_20260117094312_0018_D.SRT"
data := "data/processed"
output := "outputs/scene_01"

# Show this help
@default:
    just --list --unsorted

# ============================================================================
# Pipeline - Integrated workflows
# ============================================================================

# Process video from scratch with GPS alignment
[group('pipeline')]
process-with-gps video=video srt=srt data=data:
    ./scripts/process_with_gps.sh --video {{ video }} --srt {{ srt }} --output {{ data }}

# Align existing reconstruction to GPS
[group('pipeline')]
align srt=srt data=data:
    ./scripts/align_existing_reconstruction.sh --srt {{ srt }} --data {{ data }}

# ============================================================================
# Steps - Individual pipeline steps
# ============================================================================

# Run nerfstudio preprocessing (COLMAP)
[group('steps')]
process video=video out="processed":
    ns-process-data video --data {{ video }} --output-dir data/{{ out }} \
      --num-downscales 0 \
      --matching-method sequential \
      --num-frames-target 1000

# Open COLMAP GUI to inspect model
[group('steps')]
colmap-gui model="sparse/0":
    colmap gui --import_path {{ data + "/" + model }} --database_path {{ data + "/database.db" }} --image_path {{ data + "/images" }}

# Train Gaussian Splatting model
[group('steps')]
train data=data steps="30000":
    ns-train splatfacto --data {{ data }} --output-dir outputs/ --max-num-iterations {{ steps }}

# View trained model
[group('steps')]
view config:
    ns-viewer --load-config {{ config }}

# ============================================================================
# Export - Rendering and export
# ============================================================================

# Export point cloud
[group('export')]
export-points config:
    mkdir -p {{ output }}
    ns-export pointcloud --load-config {{ config }} --output-dir exports/

# Export mesh
[group('export')]
export-mesh config:
    mkdir -p {{ output }}
    ns-export poisson --load-config {{ config }} --output-dir exports/

# Render camera path
[group('export')]
render config camera_path name="output.mp4":
    ns-render camera-path --load-config {{ config }} --camera-path-filename {{ camera_path }} --output-path renders/{{ name }}

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
