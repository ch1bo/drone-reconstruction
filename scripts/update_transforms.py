#!/usr/bin/env python3
"""
Update transforms.json with aligned camera poses from COLMAP.

This script reads aligned COLMAP reconstruction and updates the transforms.json
file with georeferenced camera poses while preserving intrinsics.
"""

import argparse
import json
import struct
from pathlib import Path
from typing import Dict, List, Tuple
import numpy as np


def read_colmap_binary_images(images_bin_path: Path) -> Dict:
    """
    Read COLMAP images.bin file.

    Returns dict mapping image_id to {name, qvec, tvec, camera_id}
    """
    images = {}

    with open(images_bin_path, 'rb') as f:
        num_images = struct.unpack('Q', f.read(8))[0]

        for _ in range(num_images):
            image_id = struct.unpack('I', f.read(4))[0]

            # Quaternion (w, x, y, z) - rotation from world to camera
            qw, qx, qy, qz = struct.unpack('dddd', f.read(32))

            # Translation (x, y, z) - camera position in world
            tx, ty, tz = struct.unpack('ddd', f.read(24))

            camera_id = struct.unpack('I', f.read(4))[0]

            # Image name
            name_bytes = b''
            while True:
                char = f.read(1)
                if char == b'\x00':
                    break
                name_bytes += char
            name = name_bytes.decode('utf-8')

            # Skip 2D points (not needed)
            num_points2D = struct.unpack('Q', f.read(8))[0]
            f.read(24 * num_points2D)  # Skip point2D data

            images[image_id] = {
                'name': name,
                'qvec': np.array([qw, qx, qy, qz]),
                'tvec': np.array([tx, ty, tz]),
                'camera_id': camera_id
            }

    return images


def read_colmap_text_images(images_txt_path: Path) -> Dict:
    """
    Read COLMAP images.txt file.

    Format:
    # IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
    """
    images = {}

    with open(images_txt_path, 'r') as f:
        for line in f:
            line = line.strip()

            # Skip comments and empty lines
            if line.startswith('#') or not line:
                continue

            # Parse image line
            parts = line.split()
            if len(parts) < 10:
                continue

            image_id = int(parts[0])
            qw, qx, qy, qz = map(float, parts[1:5])
            tx, ty, tz = map(float, parts[5:8])
            camera_id = int(parts[8])
            name = parts[9]

            images[image_id] = {
                'name': name,
                'qvec': np.array([qw, qx, qy, qz]),
                'tvec': np.array([tx, ty, tz]),
                'camera_id': camera_id
            }

            # Skip next line (points2D)
            f.readline()

    return images


def qvec_to_rotmat(qvec: np.ndarray) -> np.ndarray:
    """
    Convert quaternion to 3x3 rotation matrix.

    COLMAP quaternion format: (w, x, y, z)
    Represents rotation from world to camera.
    """
    w, x, y, z = qvec
    R = np.array([
        [1 - 2*y*y - 2*z*z, 2*x*y - 2*z*w, 2*x*z + 2*y*w],
        [2*x*y + 2*z*w, 1 - 2*x*x - 2*z*z, 2*y*z - 2*x*w],
        [2*x*z - 2*y*w, 2*y*z + 2*x*w, 1 - 2*x*x - 2*y*y]
    ])
    return R


def colmap_to_transform_matrix(qvec: np.ndarray, tvec: np.ndarray) -> np.ndarray:
    """
    Convert COLMAP camera pose to 4x4 transform matrix.

    COLMAP stores:
    - qvec: rotation from world to camera (camera orientation)
    - tvec: camera center in world coordinates

    Transforms.json needs:
    - 4x4 matrix representing camera-to-world transformation
    """
    # Get rotation matrix (world to camera)
    R_world_to_cam = qvec_to_rotmat(qvec)

    # Invert to get camera to world
    R_cam_to_world = R_world_to_cam.T

    # Camera position in world (already in world coords)
    cam_center = tvec

    # Build 4x4 matrix
    transform = np.eye(4)
    transform[:3, :3] = R_cam_to_world
    transform[:3, 3] = cam_center

    return transform


def load_colmap_images(colmap_path: Path) -> Dict:
    """Load COLMAP images from binary or text format."""
    images_bin = colmap_path / 'images.bin'
    images_txt = colmap_path / 'images.txt'

    if images_bin.exists():
        print(f"Reading COLMAP binary format: {images_bin}")
        return read_colmap_binary_images(images_bin)
    elif images_txt.exists():
        print(f"Reading COLMAP text format: {images_txt}")
        return read_colmap_text_images(images_txt)
    else:
        raise FileNotFoundError(f"No images.bin or images.txt found in {colmap_path}")


def update_transforms_json(
    transforms_path: Path,
    colmap_images: Dict,
    output_path: Path,
    coordinate_system: str = "enu"
) -> Dict:
    """
    Update transforms.json with aligned camera poses.

    Preserves intrinsics and other metadata.
    Updates only the transform_matrix for each frame.
    """
    # Load existing transforms
    with open(transforms_path, 'r') as f:
        transforms = json.load(f)

    # Create mapping from image name to COLMAP data
    colmap_by_name = {img['name']: img for img in colmap_images.values()}

    # Update each frame
    updated_count = 0
    for frame in transforms['frames']:
        file_path = frame['file_path']
        # Extract filename (e.g., "images/frame_000000.png" -> "frame_000000.png")
        filename = Path(file_path).name

        if filename in colmap_by_name:
            colmap_img = colmap_by_name[filename]

            # Convert COLMAP pose to transform matrix
            transform_matrix = colmap_to_transform_matrix(
                colmap_img['qvec'],
                colmap_img['tvec']
            )

            # Update frame
            frame['transform_matrix'] = transform_matrix.tolist()
            updated_count += 1
        else:
            print(f"Warning: No COLMAP pose found for {filename}")

    # Add metadata about georeferencing
    if 'metadata' not in transforms:
        transforms['metadata'] = {}

    transforms['metadata']['coordinate_system'] = coordinate_system
    transforms['metadata']['aligned_to_gps'] = True

    # Save updated transforms
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'w') as f:
        json.dump(transforms, f, indent=2)

    print(f"\nUpdated {updated_count}/{len(transforms['frames'])} frames")
    return transforms


def main():
    parser = argparse.ArgumentParser(
        description="Update transforms.json with aligned COLMAP poses",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Update transforms.json with aligned poses
  python update_transforms.py \\
    --aligned-colmap ./data/colmap/aligned \\
    --transforms ./data/transforms.json \\
    --output ./data/transforms_georef.json

  # Update in place
  python update_transforms.py \\
    --aligned-colmap ./data/colmap/aligned \\
    --transforms ./data/transforms.json
        """
    )

    parser.add_argument('--aligned-colmap', type=Path, required=True,
                        help='Path to aligned COLMAP reconstruction directory')
    parser.add_argument('--transforms', type=Path, required=True,
                        help='Path to original transforms.json')
    parser.add_argument('--output', type=Path,
                        help='Output path for updated transforms.json (default: update in place)')
    parser.add_argument('--coordinate-system', default='enu',
                        help='Coordinate system used for alignment (default: enu)')

    args = parser.parse_args()

    # Default: update in place
    if args.output is None:
        args.output = args.transforms

    # Verify inputs
    if not args.aligned_colmap.exists():
        print(f"Error: Aligned COLMAP directory not found: {args.aligned_colmap}")
        return 1

    if not args.transforms.exists():
        print(f"Error: transforms.json not found: {args.transforms}")
        return 1

    # Load COLMAP poses
    try:
        colmap_images = load_colmap_images(args.aligned_colmap)
        print(f"Loaded {len(colmap_images)} camera poses from COLMAP")
    except Exception as e:
        print(f"Error loading COLMAP data: {e}")
        return 1

    # Update transforms
    try:
        updated_transforms = update_transforms_json(
            transforms_path=args.transforms,
            colmap_images=colmap_images,
            output_path=args.output,
            coordinate_system=args.coordinate_system
        )

        print(f"\n✓ Updated transforms saved to: {args.output}")
        print(f"  Coordinate system: {args.coordinate_system}")
        print(f"  Georeferenced: Yes")

        return 0

    except Exception as e:
        print(f"Error updating transforms: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    exit(main())
