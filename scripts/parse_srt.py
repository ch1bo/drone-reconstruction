#!/usr/bin/env python3
"""
Parse DJI SRT files to extract GPS and altitude telemetry data.

This script extracts GPS coordinates, altitude, and timestamp information from
DJI drone SRT subtitle files and outputs them in a JSON format suitable for
COLMAP alignment.
"""

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import List, Dict, Optional
import srt


def extract_telemetry_modern(text: str) -> Optional[Dict]:
    """
    Extract telemetry from modern DJI SRT format.

    Format: [latitude: 59.302335] [longitude: 18.203059] [rel_alt: 1.300 abs_alt: 132.860]
    """
    patterns = {
        'latitude': r'\[latitude:\s*([-\d.]+)\]',
        'longitude': r'\[longitude:\s*([-\d.]+)\]',
        'rel_alt': r'\[rel_alt:\s*([-\d.]+)',
        'abs_alt': r'abs_alt:\s*([-\d.]+)\]'
    }

    data = {}
    for key, pattern in patterns.items():
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            data[key] = float(match.group(1))
        else:
            return None  # Missing required field

    return data


def extract_telemetry_old(text: str) -> Optional[Dict]:
    """
    Extract telemetry from older DJI SRT format.

    Format: GPS(59.302335,18.203059,132.860)
    """
    pattern = r'GPS\(([-\d.]+),([-\d.]+),([-\d.]+)\)'
    match = re.search(pattern, text)

    if match:
        return {
            'latitude': float(match.group(1)),
            'longitude': float(match.group(2)),
            'abs_alt': float(match.group(3)),
            'rel_alt': None  # Not available in old format
        }

    return None


def parse_srt_file(srt_path: Path) -> List[Dict]:
    """Parse SRT file and extract all telemetry entries."""
    with open(srt_path, 'r', encoding='utf-8', errors='ignore') as f:
        subtitle_generator = srt.parse(f)
        subtitles = list(subtitle_generator)

    telemetry_data = []

    for sub in subtitles:
        # Try modern format first
        data = extract_telemetry_modern(sub.content)

        # Fall back to old format
        if data is None:
            data = extract_telemetry_old(sub.content)

        if data:
            telemetry_data.append({
                'index': sub.index,
                'start_time': sub.start.total_seconds(),
                'end_time': sub.end.total_seconds(),
                **data
            })

    return telemetry_data


def get_video_fps(video_path: Path) -> float:
    """Get video frame rate using ffprobe."""
    try:
        result = subprocess.run([
            'ffprobe', '-v', 'error',
            '-select_streams', 'v:0',
            '-show_entries', 'stream=r_frame_rate',
            '-of', 'default=noprint_wrappers=1:nokey=1',
            str(video_path)
        ], capture_output=True, text=True, check=True)

        # Parse fraction (e.g., "30000/1001" for 29.97 fps)
        num, den = result.stdout.strip().split('/')
        return float(num) / float(den)
    except Exception as e:
        print(f"Warning: Could not determine FPS: {e}")
        print("Assuming 30 fps")
        return 30.0


def get_video_duration(video_path: Path) -> float:
    """Get video duration in seconds using ffprobe."""
    try:
        result = subprocess.run([
            'ffprobe', '-v', 'error',
            '-show_entries', 'format=duration',
            '-of', 'default=noprint_wrappers=1:nokey=1',
            str(video_path)
        ], capture_output=True, text=True, check=True)

        return float(result.stdout.strip())
    except Exception as e:
        print(f"Warning: Could not determine duration: {e}")
        return None


def interpolate_telemetry(telemetry_data: List[Dict], timestamps: List[float]) -> List[Dict]:
    """
    Interpolate telemetry data to match video frame timestamps.

    Uses linear interpolation between SRT entries.
    """
    import numpy as np

    # Extract SRT timestamps and coordinates
    srt_times = np.array([d['start_time'] for d in telemetry_data])
    lats = np.array([d['latitude'] for d in telemetry_data])
    lons = np.array([d['longitude'] for d in telemetry_data])
    abs_alts = np.array([d['abs_alt'] for d in telemetry_data])

    # Handle relative altitude (may be None for older format)
    has_rel_alt = telemetry_data[0].get('rel_alt') is not None
    if has_rel_alt:
        rel_alts = np.array([d['rel_alt'] for d in telemetry_data])

    frame_timestamps = np.array(timestamps)

    # Interpolate
    interp_lats = np.interp(frame_timestamps, srt_times, lats)
    interp_lons = np.interp(frame_timestamps, srt_times, lons)
    interp_abs_alts = np.interp(frame_timestamps, srt_times, abs_alts)

    if has_rel_alt:
        interp_rel_alts = np.interp(frame_timestamps, srt_times, rel_alts)

    # Build output
    interpolated = []
    for i, ts in enumerate(frame_timestamps):
        entry = {
            'frame_number': i,
            'timestamp': float(ts),
            'latitude': float(interp_lats[i]),
            'longitude': float(interp_lons[i]),
            'abs_altitude': float(interp_abs_alts[i]),
        }

        if has_rel_alt:
            entry['rel_altitude'] = float(interp_rel_alts[i])

        interpolated.append(entry)

    return interpolated


def main():
    parser = argparse.ArgumentParser(
        description="Extract GPS/altitude data from DJI SRT files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Parse SRT and match to video frames
  python parse_srt.py --srt video.SRT --video video.mp4 --output gps_data.json

  # Parse SRT only (no frame matching)
  python parse_srt.py --srt video.SRT --output gps_data.json
        """
    )

    parser.add_argument('--srt', type=Path, required=True,
                        help='Path to DJI SRT file')
    parser.add_argument('--video', type=Path,
                        help='Path to video file (for frame matching)')
    parser.add_argument('--output', type=Path, required=True,
                        help='Output JSON file path')
    parser.add_argument('--fps', type=float,
                        help='Video FPS (auto-detected if not specified)')

    args = parser.parse_args()

    # Parse SRT file
    print(f"Parsing SRT file: {args.srt}")
    telemetry_data = parse_srt_file(args.srt)

    if not telemetry_data:
        print("Error: No telemetry data found in SRT file")
        return 1

    print(f"Found {len(telemetry_data)} telemetry entries")
    print(f"Time range: {telemetry_data[0]['start_time']:.2f}s - {telemetry_data[-1]['end_time']:.2f}s")

    # If video is provided, interpolate to frame timestamps
    if args.video:
        if not args.video.exists():
            print(f"Error: Video file not found: {args.video}")
            return 1

        # Get video properties
        fps = args.fps if args.fps else get_video_fps(args.video)
        duration = get_video_duration(args.video)

        print(f"Video FPS: {fps:.2f}")
        if duration:
            print(f"Video duration: {duration:.2f}s")

        # Generate frame timestamps
        if duration:
            num_frames = int(duration * fps)
        else:
            # Use SRT duration as fallback
            num_frames = int(telemetry_data[-1]['end_time'] * fps)

        frame_timestamps = [i / fps for i in range(num_frames)]

        print(f"Interpolating telemetry for {num_frames} frames...")
        output_data = interpolate_telemetry(telemetry_data, frame_timestamps)
    else:
        # Just output raw SRT data
        output_data = telemetry_data

    # Write output
    output = {
        'source_srt': str(args.srt),
        'source_video': str(args.video) if args.video else None,
        'num_entries': len(output_data),
        'has_rel_altitude': output_data[0].get('rel_altitude') is not None,
        'frames': output_data
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, 'w') as f:
        json.dump(output, f, indent=2)

    print(f"Wrote GPS data to: {args.output}")
    print(f"Sample entry: {json.dumps(output_data[0], indent=2)}")

    return 0


if __name__ == '__main__':
    exit(main())
