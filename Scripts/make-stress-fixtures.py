#!/usr/bin/env python3
"""Generate comparable ~1 MB local videos; no downloaded or personal media."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bytes", type=int, default=1_000_000)
    parser.add_argument("--duration", type=float, default=8)
    args = parser.parse_args()
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        parser.error("Install FFmpeg and ffprobe first.")
    if args.bytes < 100_000 or args.duration <= 0:
        parser.error("Use at least 100 KB and a positive duration.")
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        parser.error("Use a new empty fixture directory; existing fixtures are never overwritten.")
    formats = [
        ("fixture_h264.mp4", "libx264", "aac", ["-preset", "veryfast"]),
        ("fixture_hevc.mkv", "libx265", "aac", ["-preset", "fast", "-x265-params", "pools=2:frame-threads=2:log-level=error"]),
        ("fixture_h264.mov", "libx264", "aac", ["-preset", "veryfast"]),
        ("fixture_vp9.webm", "libvpx-vp9", "libopus", ["-deadline", "good", "-cpu-used", "4"]),
        ("fixture_mpeg4.avi", "mpeg4", "libmp3lame", []),
    ]
    manifest = {"target_bytes": args.bytes, "tolerance_fraction": 0.05, "duration_seconds": args.duration,
                "generator": "lavfi testsrc2 + 440 Hz sine, 640x360, 30 fps, 48 kHz mono", "fixtures": []}
    for filename, video, audio, extra in formats:
        bitrate = max(100_000, int(args.bytes * 8 / args.duration - 116_000))
        final = args.output / filename
        for attempt in range(5):
            candidate = args.output / f"candidate-{attempt}{final.suffix}"
            command = [ffmpeg, "-hide_banner", "-v", "error", "-nostdin", "-n", "-f", "lavfi", "-i",
                       "testsrc2=size=640x360:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                       "-t", str(args.duration), "-c:v", video, "-b:v", str(bitrate), "-pix_fmt", "yuv420p", "-threads", "2",
                       "-c:a", audio, "-b:a", "96k", *extra]
            if final.suffix in [".mp4", ".mov"]:
                command += ["-movflags", "+faststart"]
            subprocess.run([*command, str(candidate)], check=True, capture_output=True)
            size = candidate.stat().st_size
            if abs(size / args.bytes - 1) <= 0.05:
                candidate.rename(final)
                break
            candidate.unlink()
            bitrate = int(bitrate * args.bytes / size)
        else:
            raise RuntimeError(f"Could not reach ±5% of {args.bytes} bytes for {filename}")
        probe = json.loads(subprocess.check_output([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(final)]))
        assert any(s["codec_type"] == "video" for s in probe["streams"])
        assert any(s["codec_type"] == "audio" for s in probe["streams"])
        assert abs(float(probe["format"]["duration"]) - args.duration) < 0.3
        manifest["fixtures"].append({"file": filename, "bytes": final.stat().st_size, "video_encoder": video,
                                     "audio_encoder": audio, "duration": float(probe["format"]["duration"]),
                                     "sha256": hashlib.sha256(final.read_bytes()).hexdigest()})
        print(f"{filename}: {final.stat().st_size:,} bytes", flush=True)
    negative = args.output / "negative"
    negative.mkdir()
    (negative / "invalid.bin").write_bytes(b"Deliberately invalid synthetic media.\n" * 30)
    source = (args.output / "fixture_h264.mp4").read_bytes()
    (negative / "truncated.mp4").write_bytes(source[:len(source) // 2])
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
