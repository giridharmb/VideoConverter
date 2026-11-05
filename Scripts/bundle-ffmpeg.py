#!/usr/bin/env python3
"""Copy installed FFmpeg tools and their non-system dylib closure into Resources/Tools.

No downloads. The output is local-architecture and ad-hoc signed for development.
Distribution requires your own license review and Developer ID signing/notarization.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True)


def dependencies(path):
    return [line.strip().split(" (compatibility", 1)[0] for line in run("otool", "-L", path).splitlines()[1:] if line.strip()]


def rpaths(path):
    lines = run("otool", "-l", path).splitlines()
    result = []
    for i, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for next_line in lines[i + 1:i + 4]:
                if next_line.strip().startswith("path "):
                    result.append(next_line.strip()[5:].split(" (offset", 1)[0])
    return result


def resolve(dependency, owner, executable, search):
    def expand(value):
        return value.replace("@loader_path", str(owner.parent)).replace("@executable_path", str(executable.parent))
    if dependency.startswith("@rpath/"):
        for directory in rpaths(owner) + search:
            candidate = Path(expand(directory)) / dependency.removeprefix("@rpath/")
            if candidate.is_file():
                return candidate.resolve()
        raise RuntimeError(f"Cannot resolve {dependency} from {owner}")
    candidate = Path(expand(dependency))
    if not candidate.is_file():
        raise RuntimeError(f"Missing dependency {dependency} from {owner}")
    return candidate.resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    parser.add_argument("--ffprobe", default=shutil.which("ffprobe"))
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "Resources/Tools")
    args = parser.parse_args()
    if not args.ffmpeg or not args.ffprobe:
        parser.error("Install FFmpeg or provide --ffmpeg and --ffprobe paths.")
    output = args.output.resolve()
    if output.exists() and any(path.name != ".gitkeep" for path in output.iterdir()):
        parser.error(f"{output} already contains files. Move it aside before rebuilding the bundle.")
    (output / "lib").mkdir(parents=True, exist_ok=True)
    binaries = [Path(args.ffmpeg).resolve(), Path(args.ffprobe).resolve()]
    pending = [(source, output / name, source) for source, name in zip(binaries, ["ffmpeg", "ffprobe"])]
    visited = {}
    manifest = []
    while pending:
        source, target, executable = pending.pop(0)
        if source in visited:
            continue
        if target.exists():
            raise RuntimeError(f"Different libraries share a filename: {target.name}")
        visited[source] = target
        shutil.copy2(source, target)
        os.chmod(target, 0o755)
        subprocess.run(["codesign", "--remove-signature", str(target)], capture_output=True, check=False)
        if target.parent.name == "lib":
            subprocess.run(["install_name_tool", "-id", f"@rpath/{target.name}", str(target)], check=True)
        for dependency in dependencies(source):
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            resolved = resolve(dependency, source, executable, ["/opt/homebrew/lib", "/usr/local/lib"])
            if resolved == source:
                continue
            destination = output / "lib" / resolved.name
            pending.append((resolved, destination, executable))
            replacement = f"@loader_path/{'lib/' if target.parent == output else ''}{destination.name}"
            subprocess.run(["install_name_tool", "-change", dependency, replacement, str(target)], check=True)
        manifest.append({"source": str(source), "bundled": str(target.relative_to(output)), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest()})
    for target in sorted(visited.values(), key=lambda path: path.parent != output / "lib"):
        subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True, capture_output=True)
    version = run(output / "ffmpeg", "-version")
    run(output / "ffprobe", "-version")
    (output / "ffmpeg-build.txt").write_text(version)
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Bundled {len(visited)} Mach-O files in {output}")
    print("Verified ffmpeg and ffprobe. Review all binary licenses before distributing.")


if __name__ == "__main__":
    main()
