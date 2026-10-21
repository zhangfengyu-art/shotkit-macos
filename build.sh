#!/bin/zsh
set -eu
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  print -u2 'This release targets Apple Silicon Macs. Build on macOS with the macOS 27 SDK.'
  exit 1
fi
app="$PWD/build/ShotKit.app"
mkdir -p "$app/Contents/MacOS"
cp native/Info.plist "$app/Contents/Info.plist"
task_cache="$(mktemp -d "${TMPDIR:-/tmp}/shotkit-build.XXXXXX")"
trap 'rm -rf "$task_cache"' EXIT
cp native/ShotKit.swift "$task_cache/main.swift"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$task_cache" "$task_cache/main.swift" \
  native/NativeService.swift native/NativeLibrary.swift native/NativeTranslation.swift \
  -o "$app/Contents/MacOS/ShotKit" \
  -framework Cocoa -framework Vision -framework ApplicationServices \
  -framework SwiftUI -framework Translation
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
print "Built $app"
