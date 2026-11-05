#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
if ! command -v xcodegen >/dev/null; then
  print -u2 'XcodeGen is required to regenerate the project: brew install xcodegen'
  exit 1
fi
xcodegen generate
xcodebuild -project VideoConverter.xcodeproj -scheme VideoConverter -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
print 'Built: build/Build/Products/Debug/VideoConverter.app'
