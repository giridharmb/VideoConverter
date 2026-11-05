# Local packaging and release boundaries

## Local build

The source tree builds in Xcode without linked Homebrew headers/libraries. At runtime the app uses bundled FFmpeg/ffprobe if present, otherwise it discovers local installations. Engine settings can override the directory.

`Scripts/bundle-ffmpeg.py` copies installed `ffmpeg`, `ffprobe` and recursively discovered non-system dylibs into `Resources/Tools`. It resolves absolute, loader-relative and rpath dependencies, rewrites them to the copied dependency names, and signs copies ad hoc. System libraries in `/System/Library` and `/usr/lib` remain OS-provided. Name collisions and missing dependencies fail explicitly. The script does not change the installed originals.

The generated `manifest.json` is a dependency provenance inventory, not an SBOM or license manifest. Verify the exact source packages, versions, licenses and corresponding source for redistribution. The script verifies executable startup; it does not exercise every codec plugin or optional runtime resource. A relocation test is part of release validation.

The repository tracks an empty `.gitkeep` placeholder in Tools so the included Xcode project has a valid folder resource even without bundled binaries. A fresh clone can open and build directly in Xcode, using installed FFmpeg tools at runtime. The bundler accepts that placeholder and fills the folder; the next build copies its contents automatically. Regenerate with XcodeGen when changing project configuration, not for each binary refresh.

## A self-contained local copy

```sh
python3 Scripts/bundle-ffmpeg.py
xcodegen generate
zsh Scripts/build.sh
```

This produces `build/Build/Products/Debug/VideoConverter.app`. For local debugging `CODE_SIGNING_ALLOWED=NO` skips app signing. Copied worker binaries and dylibs are signed ad hoc. For another Mac, code signing and Gatekeeper handling need a proper release build rather than instructions to disable platform protections.

## Before distributing

- Choose the app identifier and Developer ID team. Build Release with appropriate architecture slices and deployment target.
- Build FFmpeg and every bundled library for each supported CPU architecture, or produce separate arm64/x86_64 distributions. Copying Homebrew binaries from an Apple Silicon Mac does not make a universal app.
- Audit `ffmpeg -buildconf`, `ffmpeg -L`, all dependency license texts, source availability, notices, patent considerations where applicable, and the intended application license. The local Homebrew build is GPL-enabled and includes many independently licensed dependencies. This project does not grant a license to redistribute those components.
- Supply required notices and corresponding source/build instructions according to the actual component licenses. The app source license must be selected by the repository owner before public release; this scaffold does not assume one.
- Sign nested dylibs/helpers/frameworks from the inside out with the intended identity and appropriate entitlements. Sign the app, validate it with strict code-signing verification, notarize, and staple the result. Ad hoc signatures are for local development.
- Test the relocated app without Homebrew in its discovery path on a clean Mac. Verify codec startup, hardware encode, dependency relocation, media reading/writing, pause/cancel/retry, and normal quit.
- Decide how to update/vet FFmpeg builds and respond to codec security updates. Input media can exercise complex native parsers. Child-process isolation limits crashes but is not a security sandbox.
- The application currently disables App Sandbox. A Mac App Store build requires an explicit security-scoped bookmark/file access model, restored bookmark permissions, bundled helper entitlements and a compatible process/library design. Do not simply toggle the sandbox setting and assume saved queues still have access.

The app itself configures no analytics upload or update service. Expert FFmpeg protocols/filters may initiate network activity if explicitly configured or referenced by a media manifest.
