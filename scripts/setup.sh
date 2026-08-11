#!/bin/zsh
# One-shot environment setup for a fresh checkout of Pigeon:
# clones Ghostty, fetches its zig dependencies, builds GhosttyKit,
# and generates the Xcode project.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export no_proxy=localhost,127.0.0.1,::1

# Toolchain checks
if [ ! -x /opt/homebrew/opt/zig@0.14/bin/zig ]; then
  echo "zig 0.14 missing: brew install zig@0.14" >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null; then
  echo "xcodegen missing: brew install xcodegen" >&2
  exit 1
fi
if ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
  echo "Metal toolchain missing: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

# Ghostty source, pinned to the release Pigeon builds against.
GHOSTTY_TAG=v1.2.3
if [ ! -d "$ROOT/vendor/ghostty" ]; then
  git clone --depth 1 --branch "$GHOSTTY_TAG" \
    https://github.com/ghostty-org/ghostty.git "$ROOT/vendor/ghostty"
fi

"$ROOT/scripts/fetch-ghostty-deps.sh"
"$ROOT/scripts/build-ghostty.sh"

cd "$ROOT" && xcodegen generate

echo ""
echo "Setup complete. Build with:"
echo "  xcodebuild -project Pigeon.xcodeproj -scheme Pigeon build"
