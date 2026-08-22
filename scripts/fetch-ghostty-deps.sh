#!/bin/zsh
# Fetch all Ghostty zig dependencies and insert them into the local zig
# cache (vendor/zig-cache) with `zig fetch <local path>`.
#
# Why not plain `zig build`: zig's own HTTP client does not work through
# this machine's local proxy (127.0.0.1:7890), so we download with
# curl/git (which do) and hand zig the local files. Content hashes in
# build.zig.zon still verify everything we feed in.
set -e

# Local proxy (only on the dev machine; export PIGEON_USE_PROXY=1 there).
if [ "${PIGEON_USE_PROXY:-0}" = "1" ]; then
  export http_proxy=http://127.0.0.1:7890
  export https_proxy=http://127.0.0.1:7890
  export no_proxy=localhost,127.0.0.1,::1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG=/opt/homebrew/opt/zig@0.14/bin/zig
GHOSTTY="$ROOT/vendor/ghostty"
export ZIG_GLOBAL_CACHE_DIR="$ROOT/vendor/zig-cache"
DL="$ROOT/vendor/downloads"
mkdir -p "$DL" "$ZIG_GLOBAL_CACHE_DIR"

while IFS= read -r url; do
  case "$url" in
    git+*)
      # git+https://host/repo#commit -> shallow clone at the commit, then
      # fetch the checked-out tree. The zon hash is content-based so it
      # verifies the same as a tarball.
      repo="${url#git+}"
      commit="${repo##*#}"
      repo="${repo%%#*}"
      name="$(basename "$repo")-$commit"
      dir="$DL/$name"
      if [ ! -d "$dir" ]; then
        git init -q "$dir"
        git -C "$dir" remote add origin "$repo"
        git -C "$dir" fetch -q --depth 1 origin "$commit"
        git -C "$dir" checkout -q FETCH_HEAD
        rm -rf "$dir/.git"
      fi
      echo "fetch(dir): $name"
      "$ZIG" fetch "$dir" >/dev/null
      ;;
    *iTerm2-Color-Schemes*)
      # Upstream deleted this release asset (404 as of 2025-08). Lazy
      # dependency, only needed when bundling themes; we build with
      # -Demit-themes=false instead.
      echo "skip: $url"
      ;;
    *)
      file="$DL/$(basename "$url")"
      if [ ! -s "$file" ]; then
        echo "download: $url"
        curl -fsSL --retry 3 --max-time 300 -o "$file" "$url"
      fi
      echo "fetch(file): $(basename "$file")"
      "$ZIG" fetch "$file" >/dev/null
      ;;
  esac
done < "$GHOSTTY/build.zig.zon.txt"

echo "ALL DEPS FETCHED OK"
