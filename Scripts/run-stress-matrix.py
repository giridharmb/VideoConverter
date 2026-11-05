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
    parser.add_argument("--mode", choices=["matrix", "log-flood"], default="matrix")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.repeat < 1 or any(t < 0 for t in args.threads) or any(c < 1 or c > 8 for c in args.parallel):
        parser.error("Use positive repeats, nonnegative threads, and 1–8 parallel workers.")
    if args.binary is None:
        subprocess.run(["swift", "build", "-c", "release"], cwd=root, check=True)
        binary_dir = subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True).strip()
        args.binary = Path(binary_dir) / "ConverterStress"
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = []
    for repetition in range(1, args.repeat + 1):
        for parallel in args.parallel:
            for threads in args.threads:
                label = f"{args.tag}-c{parallel}-t{threads}-r{repetition}"
                output = args.output / label
                if output.exists():
                    parser.error(f"Use a new tag or directory; {output} already exists.")
                output.mkdir()
                command = [str(args.binary.resolve()), "--fixtures", str(args.fixtures.resolve()), "--output", str(output.resolve()),
                           "--database", str(args.database.resolve()), "--parallel", str(parallel), "--threads", str(threads),
                           "--label", label, "--mode", args.mode, "--negative", "true"]
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
