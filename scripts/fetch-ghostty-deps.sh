#!/bin/zsh
# Fetch all Ghostty zig dependencies and unpack them into the
# project-local package dir (vendor/ghostty/zig-pkg/<pkg-hash>).
#
# Why not `zig build --fetch`: zig's own HTTP client does not work
# through this machine's local proxy (127.0.0.1:7890), so we download
# with curl/git (which do).
#
# Zig 0.17 changed the package model: the global cache only accepts
# canonical tarballs zig repacked itself (a `zig fetch <file>` entry
# still wraps the archive's top-level dir and fails resolution), while
# the build reads dependencies already unpacked in <build root>/zig-pkg/
# <declared hash>. We populate that directory ourselves — unpack with
# the top-level directory stripped, keyed by the hash names listed in
# build.zig.zon.json — which is also exactly what upstream's zon2nix
# vendoring does.
set -e

# Local proxy (only on the dev machine; export PIGEON_USE_PROXY=1 there).
if [ "${PIGEON_USE_PROXY:-0}" = "1" ]; then
  export http_proxy=http://127.0.0.1:7890
  export https_proxy=http://127.0.0.1:7890
  export no_proxy=localhost,127.0.0.1,::1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
PKGDIR="$GHOSTTY/zig-pkg"
DL="$ROOT/vendor/downloads"
mkdir -p "$PKGDIR" "$DL"

# copy_tree <src dir holding package files> <dest>
copy_tree() {
  mkdir -p "$2"
  cp -R "$1/." "$2/"
}

# filter_paths <dest>: apply the package's own build.zig.zon .paths
# filter — a manifest listing explicit paths makes every unlisted
# top-level entry extra cargo the declared hash does not cover.
filter_paths() {
  local zon="$1/build.zig.zon"
  [ -f "$zon" ] || return 0
  # The .paths block usually spans multiple lines (.paths = .{\n "a",\n ...}).
  local paths_block
  paths_block=$(awk '/\.paths/{flag=1} flag{print; if(/}/) exit}' "$zon")
  # No .paths field, or it contains "" → everything is included.
  [ -n "$paths_block" ] || return 0
  echo "$paths_block" | grep -q '""' && return 0
  local keep
  keep=$(echo "$paths_block" | grep -o '"[^"]*"' | tr -d '"' | cut -d/ -f1 | sort -u)
  keep="build.zig.zon
$keep"
  local entry base
  for entry in "$1"/*(D); do
    base="${entry##*/}"
    echo "$keep" | grep -qxF "$base" || rm -rf "$entry"
  done
}

python3 - "$GHOSTTY/build.zig.zon.json" <<'EOF' | while IFS=$'\t' read -r key url; do
import json, sys
for k, v in json.load(open(sys.argv[1])).items():
    print(f"{k}\t{v['url']}")
EOF
  dest="$PKGDIR/$key"
  if [ -d "$dest" ]; then continue; fi

  case "$url" in
    git+*)
      # git+https://host/repo#commit -> shallow clone at the commit.
      # The checked-out tree (gitattributes applied) is exactly what the
      # declared hash covers.
      repo="${url#git+}"
      commit="${repo##*#}"
      repo="${repo%%#*}"
      name="$(basename "$repo")-$commit"
      src="$DL/$name"
      if [ ! -d "$src" ]; then
        git init -q "$src"
        git -C "$src" remote add origin "$repo"
        git -C "$src" fetch -q --depth 1 origin "$commit"
        git -C "$src" checkout -q FETCH_HEAD
        rm -rf "$src/.git"
      fi
      echo "dep(git): $key <- $name"
      copy_tree "$src" "$dest"
      ;;
    *)
      file="$DL/$(basename "$url")"
      if [ ! -s "$file" ]; then
        echo "download: $url"
        curl -fsSL --retry 3 --max-time 300 -o "$file" "$url"
      fi
      echo "dep(tar): $key"
      # Most tarballs wrap contents in a single top-level directory;
      # strip it when present (a few are already rooted at package level).
      tmp="$(mktemp -d)"
      tar -xf "$file" -C "$tmp"
      entries=("$tmp"/*(D))
      if [ ${#entries[@]} -eq 1 ] && [ -d "${entries[1]}" ]; then
        copy_tree "${entries[1]}" "$dest"
      else
        copy_tree "$tmp" "$dest"
      fi
      rm -rf "$tmp"
      ;;
  esac
  filter_paths "$dest"
done

echo "ALL DEPS FETCHED OK"
