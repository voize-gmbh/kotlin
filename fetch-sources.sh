#!/bin/sh
# Fetches every project in sources.txt at its pinned commit into $1 (default: ./src).
# Git checks each commit's hash, so the sources are exactly the ones listed.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dest=${1:-src}
mkdir -p "$dest"
dest=$(cd "$dest" && pwd)

grep -v '^#' "$here/sources.txt" | grep -v '^[[:space:]]*$' | while read -r path url commit sparse; do
  dir="$dest/$path"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
    echo "up to date: $path"
    continue
  fi
  echo "fetching:   $path @ $commit"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  if [ -n "$sparse" ]; then
    git -C "$dir" sparse-checkout set --no-cone $(for p in $sparse; do printf '/%s ' "$p"; done)
    git -C "$dir" fetch -q --depth=1 --filter=blob:none origin "$commit"
  else
    git -C "$dir" fetch -q --depth=1 origin "$commit"
  fi
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  test "$(git -C "$dir" rev-parse HEAD)" = "$commit"
done
