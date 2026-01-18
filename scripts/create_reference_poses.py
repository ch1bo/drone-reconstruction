#!/usr/bin/env python3
"""
Create COLMAP reference poses file from GPS data.

This script converts GPS data (from parse_srt.py) into COLMAP's reference
poses format for use with model_aligner.
"""

import argparse
import json
from pathlib import Path
from typing import Dict, List


def load_gps_data(gps_data_path: Path) -> Dict:
    """Load GPS data JSON file."""
    with open(gps_data_path, 'r') as f:
        return json.load(f)


def load_transforms(transforms_path: Path) -> Dict:
    """Load transforms.json to get frame names."""
    if not transforms_path.exists():
        return None

    with open(transforms_path, 'r') as f:
        return json.load(f)


def extract_frame_name(file_path: str) -> str:
    """Extract filename from transforms.json file_path."""
    # file_path is usually like "images/frame_000000.png"
    return Path(file_path).name


def create_reference_poses(
    gps_data: Dict,
    transforms: Dict = None,
    use_rel_altitude: bool = True,
    output_path: Path = None
) -> List[str]:
    """
    Create COLMAP reference poses.

    COLMAP format with --ref_is_gps 1:
        image_name.jpg X Y Z
    where X=longitude, Y=latitude, Z=altitude
    """
    frames = gps_data['frames']
    has_rel_alt = gps_data.get('has_rel_altitude', False)

    # If transforms.json is available, use its frame names
    if transforms and 'frames' in transforms:
        transform_frames = {
            i: extract_frame_name(f['file_path'])
            for i, f in enumerate(transforms['frames'])
        }
    else:
        # Generate default frame names
        transform_frames = {
            i: f"frame_{i:06d}.png"
            for i in range(len(frames))
        }

    reference_lines = []

    for frame in frames:
        frame_num = frame.get('frame_number')
        if frame_num is None:
            # For raw SRT data without frame matching
            continue

        # Get frame name
        if frame_num in transform_frames:
            frame_name = transform_frames[frame_num]
        else:
            frame_name = f"frame_{frame_num:06d}.png"

        lon = frame['longitude']
        lat = frame['latitude']

        # Choose altitude source
        if use_rel_altitude and has_rel_alt and 'rel_altitude' in frame:
            # Relative altitude is more precise for consumer drones
            alt = frame['rel_altitude']
        else:
            # Fall back to absolute altitude
            alt = frame['abs_altitude']

        # COLMAP format: image_name.jpg longitude latitude altitude
        reference_lines.append(f"{frame_name} {lon:.8f} {lat:.8f} {alt:.3f}")

    # Write to file if output_path specified
    if output_path:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, 'w') as f:
            f.write('\n'.join(reference_lines) + '\n')

    return reference_lines


def main():
    parser = argparse.ArgumentParser(
        description="Create COLMAP reference poses from GPS data",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Create reference poses for COLMAP alignment
  python create_reference_poses.py \\
    --gps-data gps_data.json \\
    --output reference_poses.txt

  # Use with transforms.json to match frame names
  python create_reference_poses.py \\
    --gps-data gps_data.json \\
    --transforms transforms.json \\
    --output reference_poses.txt

  # Use absolute altitude instead of relative
  python create_reference_poses.py \\
    --gps-data gps_data.json \\
    --use-abs-altitude \\
    --output reference_poses.txt
        """
    )

    parser.add_argument('--gps-data', type=Path, required=True,
                        help='GPS data JSON file (from parse_srt.py)')
    parser.add_argument('--transforms', type=Path,
                        help='transforms.json from COLMAP/Nerfstudio (optional)')
    parser.add_argument('--output', type=Path, required=True,
                        help='Output reference poses file')
    parser.add_argument('--use-abs-altitude', action='store_true',
                        help='Use absolute altitude instead of relative (default: use relative if available)')

    args = parser.parse_args()

    # Load data
    print(f"Loading GPS data from: {args.gps_data}")
    gps_data = load_gps_data(args.gps_data)

    transforms = None
    if args.transforms:
        if args.transforms.exists():
            print(f"Loading transforms from: {args.transforms}")
            transforms = load_transforms(args.transforms)
        else:
            print(f"Warning: transforms.json not found at {args.transforms}")
            print("Will use default frame names")

    # Create reference poses
    use_rel = not args.use_abs_altitude
    reference_lines = create_reference_poses(
        gps_data,
        transforms,
        use_rel_altitude=use_rel,
        output_path=args.output
    )

    # Summary
    print(f"\nCreated {len(reference_lines)} reference poses")
    print(f"Output: {args.output}")
    print(f"Altitude source: {'relative' if use_rel and gps_data.get('has_rel_altitude') else 'absolute'}")
    print(f"\nSample entries:")
    for line in reference_lines[:3]:
        print(f"  {line}")
    if len(reference_lines) > 3:
        print(f"  ...")

    print(f"\nUse with COLMAP model_aligner:")
    print(f"  colmap model_aligner \\")
    print(f"    --input_path ./sparse/0 \\")
    print(f"    --output_path ./aligned \\")
    print(f"    --ref_images_path {args.output} \\")
    print(f"    --ref_is_gps 1 \\")
    print(f"    --alignment_type enu \\")
    print(f"    --alignment_max_error 10.0")

    return 0


if __name__ == '__main__':
    exit(main())
