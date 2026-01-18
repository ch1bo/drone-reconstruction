#!/usr/bin/env python3
"""
Align COLMAP reconstruction to GPS coordinates using model_aligner.

This script wraps COLMAP's model_aligner tool to align a sparse reconstruction
to GPS reference positions.
"""

import argparse
import subprocess
import sys
from pathlib import Path


def run_colmap_aligner(
    input_path: Path,
    output_path: Path,
    reference_path: Path,
    alignment_type: str = "enu",
    max_error: float = 10.0,
    robust_alignment_max_error: float = None
) -> bool:
    """
    Run COLMAP model_aligner.

    Args:
        input_path: Path to input sparse reconstruction
        output_path: Path for aligned output reconstruction
        reference_path: Path to reference poses file
        alignment_type: Type of alignment (enu, ecef, custom)
        max_error: Maximum reprojection error threshold in meters
        robust_alignment_max_error: RANSAC threshold (defaults to max_error if None)

    Returns:
        True if successful, False otherwise
    """
    if robust_alignment_max_error is None:
        robust_alignment_max_error = max_error

    # Ensure output directory exists
    output_path.mkdir(parents=True, exist_ok=True)

    # Build COLMAP command
    cmd = [
        "colmap", "model_aligner",
        "--input_path", str(input_path),
        "--output_path", str(output_path),
        "--ref_images_path", str(reference_path),
        "--ref_is_gps", "1",
        "--alignment_type", alignment_type,
        "--alignment_max_error", str(max_error),
        "--robust_alignment_max_error", str(robust_alignment_max_error),
    ]

    print("Running COLMAP model_aligner...")
    print(f"Command: {' '.join(cmd)}")
    print()

    # Run command
    try:
        result = subprocess.run(
            cmd,
            check=True,
            capture_output=True,
            text=True
        )

        # Print output
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)

        print(f"\n✓ Alignment successful!")
        print(f"  Aligned model saved to: {output_path}")

        return True

    except subprocess.CalledProcessError as e:
        print(f"\n✗ COLMAP model_aligner failed with exit code {e.returncode}")
        print(f"\nStdout:\n{e.stdout}")
        print(f"\nStderr:\n{e.stderr}")
        return False

    except FileNotFoundError:
        print("Error: COLMAP not found in PATH")
        print("Make sure COLMAP is installed and accessible")
        return False


def verify_inputs(input_path: Path, reference_path: Path) -> bool:
    """Verify that input files exist."""
    if not input_path.exists():
        print(f"Error: Input reconstruction not found: {input_path}")
        print("Expected COLMAP sparse reconstruction directory")
        return False

    # Check for required COLMAP files
    required_files = ['cameras.bin', 'images.bin', 'points3D.bin']
    missing_files = []

    for filename in required_files:
        if not (input_path / filename).exists():
            # Try .txt format
            if not (input_path / filename.replace('.bin', '.txt')).exists():
                missing_files.append(filename)

    if missing_files:
        print(f"Error: Missing COLMAP reconstruction files in {input_path}:")
        for f in missing_files:
            print(f"  - {f} (or .txt version)")
        return False

    if not reference_path.exists():
        print(f"Error: Reference poses file not found: {reference_path}")
        return False

    return True


def main():
    parser = argparse.ArgumentParser(
        description="Align COLMAP reconstruction to GPS coordinates",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Alignment Types:
  enu     - East-North-Up local tangent plane (recommended)
            Origin at first camera position
  ecef    - Earth-Centered-Earth-Fixed global coordinates
  custom  - Custom cartesian coordinates

Examples:
  # Basic alignment with ENU coordinates
  python align_to_gps.py \\
    --input ./data/colmap/sparse/0 \\
    --output ./data/colmap/aligned \\
    --reference ./data/reference_poses.txt

  # Use ECEF for global coordinates
  python align_to_gps.py \\
    --input ./data/colmap/sparse/0 \\
    --output ./data/colmap/aligned \\
    --reference ./data/reference_poses.txt \\
    --alignment-type ecef

  # Adjust error threshold for noisy GPS
  python align_to_gps.py \\
    --input ./data/colmap/sparse/0 \\
    --output ./data/colmap/aligned \\
    --reference ./data/reference_poses.txt \\
    --max-error 15.0
        """
    )

    parser.add_argument('--input', type=Path, required=True,
                        help='Input COLMAP sparse reconstruction directory')
    parser.add_argument('--output', type=Path, required=True,
                        help='Output directory for aligned reconstruction')
    parser.add_argument('--reference', type=Path, required=True,
                        help='Reference GPS poses file')
    parser.add_argument('--alignment-type', choices=['enu', 'ecef', 'custom'],
                        default='enu',
                        help='Alignment coordinate system (default: enu)')
    parser.add_argument('--max-error', type=float, default=10.0,
                        help='Maximum alignment error in meters (default: 10.0)')
    parser.add_argument('--robust-error', type=float,
                        help='RANSAC threshold in meters (default: same as --max-error)')

    args = parser.parse_args()

    # Verify inputs
    print("Verifying inputs...")
    if not verify_inputs(args.input, args.reference):
        return 1

    # Run alignment
    success = run_colmap_aligner(
        input_path=args.input,
        output_path=args.output,
        reference_path=args.reference,
        alignment_type=args.alignment_type,
        max_error=args.max_error,
        robust_alignment_max_error=args.robust_error
    )

    if success:
        print("\nNext steps:")
        print("  1. Inspect alignment quality in COLMAP GUI:")
        print(f"     colmap gui --import_path {args.output}")
        print("  2. Update transforms.json with aligned poses:")
        print(f"     python scripts/update_transforms.py \\")
        print(f"       --aligned-colmap {args.output} \\")
        print(f"       --transforms ./data/transforms.json")
        return 0
    else:
        print("\nTroubleshooting:")
        print("  - Check GPS quality (needs at least 3 good positions)")
        print("  - Increase --max-error for noisier GPS")
        print("  - Try different --alignment-type")
        print("  - Verify reference_poses.txt format")
        return 1


if __name__ == '__main__':
    exit(main())
