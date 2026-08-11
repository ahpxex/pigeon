#!/bin/zsh
# Build GhosttyKit.xcframework (libghostty) from vendor/ghostty.
#
# Prerequisites:
#   - zig 0.14.x:            brew install zig@0.14
#   - Metal toolchain:       xcodebuild -downloadComponent MetalToolchain
#   - Ghostty source:        scripts/setup.sh (clone + deps)
#
# Usage:
#   scripts/build-ghostty.sh            # native arch (fast, day-to-day dev)
#   scripts/build-ghostty.sh universal  # arm64 + x86_64 (release)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG=/opt/homebrew/opt/zig@0.14/bin/zig
export ZIG_GLOBAL_CACHE_DIR="$ROOT/vendor/zig-cache"

TARGET="${1:-native}"

cd "$ROOT/vendor/ghostty"
"$ZIG" build \
  -Doptimize=ReleaseFast \
  -Demit-themes=false \
  -Demit-macos-app=false \
  -Dxcframework-target="$TARGET"

echo "OK: vendor/ghostty/macos/GhosttyKit.xcframework"
echo "OK: vendor/ghostty/zig-out/share (bundled resources)"
