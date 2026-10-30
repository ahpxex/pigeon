#!/bin/zsh
# One-shot environment setup for a fresh checkout of Pigeon:
# clones Ghostty, fetches its zig dependencies, builds GhosttyKit,
# and generates the Xcode project.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Local proxy (only on the dev machine; export PIGEON_USE_PROXY=1 there).
if [ "${PIGEON_USE_PROXY:-0}" = "1" ]; then
  export http_proxy=http://127.0.0.1:7890
  export https_proxy=http://127.0.0.1:7890
  export no_proxy=localhost,127.0.0.1,::1
fi

# Toolchain checks
ZIG=/opt/homebrew/opt/zig/bin/zig
if [ ! -x "$ZIG" ] || [ "$("$ZIG" version | cut -d. -f1-2)" != "0.17" ]; then
  echo "zig 0.17.x missing: brew install zig (ghostty v1.4.0 requires 0.17)" >&2
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
GHOSTTY_TAG=v1.4.0
if [ ! -d "$ROOT/vendor/ghostty" ]; then
  git clone --depth 1 --branch "$GHOSTTY_TAG" \
    https://github.com/ghostty-org/ghostty.git "$ROOT/vendor/ghostty"
fi

# Pigeon-local patches (config isolation, see patches/*.patch).
for patch in "$ROOT"/patches/*.patch; do
  [ -e "$patch" ] || continue
  if ! git -C "$ROOT/vendor/ghostty" apply --check "$patch" 2>/dev/null; then
    if git -C "$ROOT/vendor/ghostty" apply --reverse --check "$patch" 2>/dev/null; then
      continue  # already applied
    fi
    echo "patch does not apply cleanly: $patch" >&2
    exit 1
  fi
  git -C "$ROOT/vendor/ghostty" apply "$patch"
  echo "applied: $patch"
done

"$ROOT/scripts/fetch-ghostty-deps.sh"
"$ROOT/scripts/build-ghostty.sh"

cd "$ROOT" && xcodegen generate

echo ""
echo "Setup complete. Build with:"
echo "  xcodebuild -project Pigeon.xcodeproj -scheme Pigeon build"
