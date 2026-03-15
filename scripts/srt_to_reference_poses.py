#!/usr/bin/env python3
"""
Convert a DJI SRT telemetry file to a COLMAP reference poses file.

Parses GPS coordinates and altitude from a DJI SRT subtitle file, interpolates
them to match extracted video frame timestamps, and writes the result in the
format expected by `colmap model_aligner --ref_is_gps 1`:

    frame_000001.jpg  longitude  latitude  altitude
    frame_000002.jpg  longitude  latitude  altitude
    ...

The frame names in the output must match the image filenames in the COLMAP
database. These are the filenames produced by the ffmpeg extraction step.

Relative altitude (from the drone's infrared altimeter, ~0.1 m precision) is
used in preference to absolute GPS altitude (~10-20 m precision).
"""

import argparse
import re
import subprocess
from pathlib import Path
from typing import Optional
import numpy as np
import srt


def extract_telemetry_modern(text: str) -> Optional[dict]:
    """
    Parse modern DJI SRT format:
      [latitude: 59.302335] [longitude: 18.203059] [rel_alt: 1.300 abs_alt: 132.860]
    """
    patterns = {
        'latitude':  r'\[latitude:\s*([-\d.]+)\]',
        'longitude': r'\[longitude:\s*([-\d.]+)\]',
        'rel_alt':   r'\[rel_alt:\s*([-\d.]+)',
        'abs_alt':   r'abs_alt:\s*([-\d.]+)\]',
    }
    data = {}
    for key, pattern in patterns.items():
        m = re.search(pattern, text, re.IGNORECASE)
        if not m:
            return None
        data[key] = float(m.group(1))
    return data


def extract_telemetry_old(text: str) -> Optional[dict]:
    """
    Parse older DJI SRT format:
      GPS(59.302335,18.203059,132.860)
    Relative altitude is not available in this format.
    """
    m = re.search(r'GPS\(([-\d.]+),([-\d.]+),([-\d.]+)\)', text)
    if m:
        return {
            'latitude':  float(m.group(1)),
            'longitude': float(m.group(2)),
            'abs_alt':   float(m.group(3)),
            'rel_alt':   None,
        }
    return None


def parse_srt(srt_path: Path) -> list[dict]:
    """Return a list of telemetry dicts, one per SRT subtitle entry."""
    with open(srt_path, encoding='utf-8', errors='ignore') as f:
        subtitles = list(srt.parse(f))

    entries = []
    for sub in subtitles:
        data = extract_telemetry_modern(sub.content) or extract_telemetry_old(sub.content)
        if data:
            entries.append({'timestamp': sub.start.total_seconds(), **data})

    return entries


def video_fps(video_path: Path) -> float:
    """Read frame rate from video file using ffprobe."""
    result = subprocess.run(
        ['ffprobe', '-v', 'error',
         '-select_streams', 'v:0',
         '-show_entries', 'stream=r_frame_rate',
         '-of', 'default=noprint_wrappers=1:nokey=1',
         str(video_path)],
        capture_output=True, text=True, check=True,
    )
    num, den = result.stdout.strip().split('/')
    return float(num) / float(den)


def video_duration(video_path: Path) -> float:
    """Read duration in seconds from video file using ffprobe."""
    result = subprocess.run(
        ['ffprobe', '-v', 'error',
         '-show_entries', 'format=duration',
         '-of', 'default=noprint_wrappers=1:nokey=1',
         str(video_path)],
        capture_output=True, text=True, check=True,
    )
    return float(result.stdout.strip())


def main():
    parser = argparse.ArgumentParser(
        description="Convert DJI SRT telemetry to a COLMAP reference poses file",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
example:
  python scripts/srt_to_reference_poses.py \\
    --srt input/DJI_flight.SRT \\
    --video input/DJI_flight.MP4 \\
    --output data/flight1/reference_poses.txt \\
    --fps 2
""",
    )
    parser.add_argument('--srt',    type=Path, required=True, help='DJI SRT file')
    parser.add_argument('--video',  type=Path, required=True, help='Corresponding video file')
    parser.add_argument('--output', type=Path, required=True, help='Output reference poses file')
    parser.add_argument('--fps',    type=float,
                        help='Frame rate used during ffmpeg extraction (auto-detected if omitted)')
    parser.add_argument('--use-abs-altitude', action='store_true',
                        help='Use absolute GPS altitude instead of relative infrared altitude')
    args = parser.parse_args()

    # Parse SRT
    print(f"Parsing {args.srt}")
    entries = parse_srt(args.srt)
    if not entries:
        print("Error: no telemetry found in SRT file")
        return 1
    print(f"  {len(entries)} telemetry entries, "
          f"{entries[0]['timestamp']:.1f}s – {entries[-1]['timestamp']:.1f}s")

    has_rel_alt = entries[0].get('rel_alt') is not None
    use_rel = has_rel_alt and not args.use_abs_altitude
    alt_source = 'rel_alt (infrared)' if use_rel else 'abs_alt (GPS)'
    print(f"  altitude source: {alt_source}")

    # Build frame timestamps matching the ffmpeg extraction
    fps = args.fps or video_fps(args.video)
    duration = video_duration(args.video)
    # ffmpeg fps= filter produces frames at 0, 1/fps, 2/fps, ...
    frame_times = np.arange(0, duration, 1.0 / fps)
    print(f"  {len(frame_times)} frames at {fps} fps over {duration:.1f}s")

    # Interpolate telemetry onto frame timestamps
    srt_times = np.array([e['timestamp'] for e in entries])
    lats = np.interp(frame_times, srt_times, [e['latitude']  for e in entries])
    lons = np.interp(frame_times, srt_times, [e['longitude'] for e in entries])
    alts = np.interp(frame_times, srt_times,
                     [e['rel_alt'] if use_rel else e['abs_alt'] for e in entries])

    # Write reference poses file
    # COLMAP model_aligner --ref_is_gps 1 expects: image_name longitude latitude altitude
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, 'w') as f:
        for i, (lon, lat, alt) in enumerate(zip(lons, lats, alts)):
            name = f"frame_{i+1:06d}.jpg"
            f.write(f"{name} {lon:.8f} {lat:.8f} {alt:.3f}\n")

    print(f"Wrote {len(frame_times)} reference poses to {args.output}")
    return 0


if __name__ == '__main__':
    exit(main())
