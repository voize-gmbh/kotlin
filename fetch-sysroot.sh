#!/bin/sh
# Builds the sysroot in $1 from the packages in sysroot.txt.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dest=$1
debs=$(mktemp -d)
mkdir -p "$dest"

grep -v '^#' "$here/sysroot.txt" | grep -v '^[[:space:]]*$' | while read -r url sha256; do
  deb="$debs/$(basename "$url")"
  curl -fsSL -o "$deb" "$url"
  echo "$sha256  $deb" | sha256sum -c -
  dpkg-deb -x "$deb" "$dest"
done

# Absolute symlinks (libm.so -> /lib/aarch64-linux-gnu/libm.so.6) would point out of the sysroot.
find "$dest" -type l | while read -r link; do
  target=$(readlink "$link")
  case $target in
    /*) ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$dest$target")" "$link" ;;
  esac
done
rm -rf "$debs"
