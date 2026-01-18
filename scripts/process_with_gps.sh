#!/usr/bin/env bash
#
# End-to-end workflow for processing drone video with GPS alignment
#
# This script automates:
#   1. GPS extraction from SRT files
#   2. COLMAP reconstruction (or use existing)
#   3. GPS alignment
#   4. Transform matrix updates
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set Qt platform for headless COLMAP (if not already set)
if [ -z "$QT_QPA_PLATFORM" ]; then
    export QT_QPA_PLATFORM=offscreen
    echo -e "${YELLOW}[INFO]${NC} Setting QT_QPA_PLATFORM=offscreen for headless mode"
fi

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Process drone video with GPS-aligned COLMAP reconstruction.

Options:
    -v, --video FILE        Input video file (MP4)
    -s, --srt FILE         Input SRT file (DJI telemetry)
    -o, --output DIR       Output directory (default: ./data/processed_scene)
    -h, --help             Show this help message

Workflow:
    1. Extract GPS from SRT → gps_data.json
    2. Run COLMAP reconstruction (or skip if exists)
    3. Create reference poses → reference_poses.txt
    4. Align COLMAP to GPS → aligned/
    5. Update transforms.json with aligned poses

Examples:
    # Process video with GPS alignment
    $0 --video input/flight.mp4 --srt input/flight.SRT --output data/scene1

    # Use existing COLMAP reconstruction
    $0 --video input/flight.mp4 --srt input/flight.SRT --output data/scene1

EOF
}

# Default values
VIDEO=""
SRT=""
OUTPUT_DIR="./data/processed_scene"
SKIP_COLMAP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--video)
            VIDEO="$2"
            shift 2
            ;;
        -s|--srt)
            SRT="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate inputs
if [ -z "$VIDEO" ] || [ -z "$SRT" ]; then
    log_error "Video and SRT files are required"
    usage
    exit 1
fi

if [ ! -f "$VIDEO" ]; then
    log_error "Video file not found: $VIDEO"
    exit 1
fi

if [ ! -f "$SRT" ]; then
    log_error "SRT file not found: $SRT"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

log_info "Starting GPS-aligned COLMAP processing"
log_info "Video: $VIDEO"
log_info "SRT: $SRT"
log_info "Output: $OUTPUT_DIR"
echo

# ============================================================================
# Step 1: Extract GPS from SRT
# ============================================================================
log_info "Step 1/5: Extracting GPS from SRT..."

GPS_DATA="$OUTPUT_DIR/gps_data.json"
python scripts/parse_srt.py \
    --srt "$SRT" \
    --video "$VIDEO" \
    --output "$GPS_DATA"

if [ ! -f "$GPS_DATA" ]; then
    log_error "GPS extraction failed"
    exit 1
fi

echo
log_info "✓ GPS data extracted to $GPS_DATA"
echo

# ============================================================================
# Step 2: Run COLMAP reconstruction
# ============================================================================
COLMAP_DIR="$OUTPUT_DIR/colmap"
IMAGES_DIR="$OUTPUT_DIR/images"

if [ -d "$COLMAP_DIR/sparse/0" ]; then
    log_warn "COLMAP reconstruction already exists, skipping..."
    SKIP_COLMAP=true
else
    log_info "Step 2/5: Running COLMAP reconstruction..."

    # Extract frames if needed
    if [ ! -d "$IMAGES_DIR" ]; then
        log_info "Extracting video frames..."
        mkdir -p "$IMAGES_DIR"

        ffmpeg -i "$VIDEO" \
            -vf "fps=1" \
            -q:v 2 \
            "$IMAGES_DIR/frame_%06d.png" \
            -hide_banner -loglevel error

        NUM_FRAMES=$(ls -1 "$IMAGES_DIR" | wc -l)
        log_info "Extracted $NUM_FRAMES frames"
    fi

    # COLMAP feature extraction
    log_info "COLMAP: Feature extraction..."
    mkdir -p "$COLMAP_DIR"

    colmap feature_extractor \
        --database_path "$COLMAP_DIR/database.db" \
        --image_path "$IMAGES_DIR" \
        --ImageReader.camera_model OPENCV \
        --ImageReader.single_camera 1

    # COLMAP feature matching
    log_info "COLMAP: Feature matching..."
    colmap exhaustive_matcher \
        --database_path "$COLMAP_DIR/database.db"

    # COLMAP sparse reconstruction
    log_info "COLMAP: Sparse reconstruction..."
    mkdir -p "$COLMAP_DIR/sparse"

    colmap mapper \
        --database_path "$COLMAP_DIR/database.db" \
        --image_path "$IMAGES_DIR" \
        --output_path "$COLMAP_DIR/sparse"

    if [ ! -d "$COLMAP_DIR/sparse/0" ]; then
        log_error "COLMAP reconstruction failed"
        exit 1
    fi

    log_info "✓ COLMAP reconstruction complete"
fi

echo

# ============================================================================
# Step 3: Create reference poses
# ============================================================================
log_info "Step 3/5: Creating reference poses for alignment..."

# Check if transforms.json exists (from ns-process-data)
TRANSFORMS_JSON="$OUTPUT_DIR/transforms.json"
if [ -f "$TRANSFORMS_JSON" ]; then
    log_info "Using existing transforms.json for frame names"
    TRANSFORMS_ARG="--transforms $TRANSFORMS_JSON"
else
    log_warn "No transforms.json found, using default frame names"
    TRANSFORMS_ARG=""
fi

REFERENCE_POSES="$OUTPUT_DIR/reference_poses.txt"
python scripts/create_reference_poses.py \
    --gps-data "$GPS_DATA" \
    $TRANSFORMS_ARG \
    --output "$REFERENCE_POSES"

if [ ! -f "$REFERENCE_POSES" ]; then
    log_error "Reference poses creation failed"
    exit 1
fi

log_info "✓ Reference poses created: $REFERENCE_POSES"
echo

# ============================================================================
# Step 4: Align COLMAP to GPS
# ============================================================================
log_info "Step 4/5: Aligning COLMAP reconstruction to GPS..."

ALIGNED_DIR="$COLMAP_DIR/aligned"
python scripts/align_to_gps.py \
    --input "$COLMAP_DIR/sparse/0" \
    --output "$ALIGNED_DIR" \
    --reference "$REFERENCE_POSES" \
    --alignment-type enu \
    --max-error 10.0

if [ ! -d "$ALIGNED_DIR" ]; then
    log_error "GPS alignment failed"
    exit 1
fi

log_info "✓ Alignment complete: $ALIGNED_DIR"
echo

# ============================================================================
# Step 5: Update transforms.json (or create if needed)
# ============================================================================
log_info "Step 5/5: Updating transforms.json with aligned poses..."

# If transforms.json doesn't exist, we need to create it from COLMAP
if [ ! -f "$TRANSFORMS_JSON" ]; then
    log_warn "transforms.json not found"
    log_info "Creating transforms.json from COLMAP..."

    # Use COLMAP's model_converter to create Nerfstudio format
    colmap model_converter \
        --input_path "$ALIGNED_DIR" \
        --output_path "$OUTPUT_DIR/colmap_export" \
        --output_type TXT

    # TODO: Create transforms.json from COLMAP text format
    # For now, user should use ns-process-data to create initial transforms.json
    log_warn "Please run ns-process-data first to create transforms.json"
    log_warn "Or manually create transforms.json from COLMAP output"
else
    # Update existing transforms.json
    python scripts/update_transforms.py \
        --aligned-colmap "$ALIGNED_DIR" \
        --transforms "$TRANSFORMS_JSON" \
        --coordinate-system enu

    log_info "✓ transforms.json updated with georeferenced poses"
fi

echo
log_info "============================================================"
log_info "Processing complete!"
log_info "============================================================"
log_info ""
log_info "Output files:"
log_info "  GPS data:         $GPS_DATA"
log_info "  COLMAP sparse:    $COLMAP_DIR/sparse/0"
log_info "  Aligned sparse:   $ALIGNED_DIR"
log_info "  Reference poses:  $REFERENCE_POSES"
if [ -f "$TRANSFORMS_JSON" ]; then
    log_info "  Transforms:       $TRANSFORMS_JSON (georeferenced)"
fi
log_info ""
log_info "Next steps:"
log_info "  1. Inspect alignment in COLMAP GUI:"
log_info "     colmap gui --import_path $ALIGNED_DIR"
log_info ""
log_info "  2. Train 3D Gaussian Splatting (on GPU machine):"
log_info "     ns-train splatfacto --data $OUTPUT_DIR"
log_info ""
