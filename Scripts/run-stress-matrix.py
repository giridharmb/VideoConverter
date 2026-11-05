#!/usr/bin/env python3
"""Run release ConverterStress scenarios sequentially; conversions inside each run are parallel."""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--database", type=Path, default=Path.home() / "Library/Application Support/VideoConverter/telemetry.sqlite")
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--tag", default="stress")
    parser.add_argument("--parallel", nargs="+", type=int, default=[1, 2, 4, 8])
    parser.add_argument("--threads", type=int, nargs="+", default=[0])
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--mode", choices=["matrix", "log-flood", "single-video"], default="matrix")
    parser.add_argument("--chunk-workers", nargs="+", type=int, default=[1], help="single-video only; 1 uses standard mode")
    parser.add_argument("--chunk-seconds", type=float, default=120)
    parser.add_argument("--codec", choices=["libx264", "libx265"], default="libx264")
    parser.add_argument("--encoder-preset", default="medium")
    parser.add_argument("--no-negative", action="store_true", help="Omit invalid/truncated controls for isolated throughput measurements")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.repeat < 1 or any(t < 0 for t in args.threads) or any(c < 1 or c > 8 for c in args.parallel):
        parser.error("Use positive repeats, nonnegative threads, and 1–8 parallel workers.")
    if any(c < 1 or c > 8 for c in args.chunk_workers) or not 1 <= args.chunk_seconds <= 3600:
        parser.error("Use 1–8 chunk workers and 1–3600 chunk seconds.")
    if args.mode != "single-video" and args.chunk_workers != [1]:
        parser.error("Chunk comparisons require --mode single-video.")
    if args.binary is None:
        subprocess.run(["swift", "build", "-c", "release"], cwd=root, check=True)
        binary_dir = subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True).strip()
        args.binary = Path(binary_dir) / "ConverterStress"
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = []
    for repetition in range(1, args.repeat + 1):
        for parallel in args.parallel:
            for threads in args.threads:
                for chunk_workers in args.chunk_workers:
                    label = f"{args.tag}-c{parallel}-t{threads}-r{repetition}"
                    if args.mode == "single-video":
                        label += f"-chunks{chunk_workers}"
                    output = args.output / label
                    if output.exists():
                        parser.error(f"Use a new tag or directory; {output} already exists.")
                    output.mkdir()
                    command = [str(args.binary.resolve()), "--fixtures", str(args.fixtures.resolve()), "--output", str(output.resolve()),
                               "--database", str(args.database.resolve()), "--parallel", str(parallel), "--threads", str(threads),
                               "--label", label, "--mode", args.mode, "--negative", str(not args.no_negative).lower(),
                               "--chunk-workers", str(chunk_workers), "--chunk-seconds", str(args.chunk_seconds),
                               "--codec", args.codec, "--encoder-preset", args.encoder_preset]
                    print(f"Starting {label}…", flush=True)
                    with (output / "runner.log").open("w") as log:
                        subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
                    summary = json.loads((output / "summary.json").read_text())
                    manifest.append(summary)
                    (args.output / f"{args.tag}-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
                    print(f"{label}: {summary['completed']} complete, {summary['failed']} expected-negative failures, "
                          f"{summary['wall_seconds']:.2f}s, {summary['telemetry_dropped']} telemetry events dropped", flush=True)



if __name__ == "__main__":
    main()
