#!/bin/bash
# Repacks the self-built linux-aarch64 Kotlin/Native 2.4.21 distribution with JetBrains' official standard library
# and rebuilds the linux_arm64 system caches against it, with the distribution's own compiler. Runs on Linux aarch64.
#
# JetBrains' distributions ship a stdlib klib compiled by the bootstrap compiler, while the self-built distribution
# has one compiled by the 2.4.21 build itself, with different IR. Static caches that are built against JetBrains'
# prebuilt system caches, e.g. on macOS, then fail with "No inline function reference for FUN name:alloc".
# The official linux-x86_64 and macos-aarch64 stdlibs differ in a single metadata file and work together, so the
# official linux-x86_64 stdlib is used.
#
# The non-Apple platform klibs are replaced by the official ones only if the official linux-x86_64 and macos-aarch64
# distributions agree on them byte for byte. Otherwise the self-built ones stay.
#
# The caches are built with the arguments of KonanCacheTask at v2.4.21, in the same directories and with the same
# flavors as the Gradle build: per-file debug stdlib cache, monolithic opt stdlib cache (stored in the
# `stdlib-per-file-cache` directory, as NativeDistribution.stdlibCache names it), and one cache per platform klib,
# built in dependency order.
#
# Usage: repack_with_official_stdlib.sh <dist dir> <official linux-x86_64 tar.gz> <official macos-aarch64 tar.gz> <out dir>
#   <dist dir> contains the self-built bundles, their SBOMs, and the LLVM essentials and libffi archives.
# Requires: java (JDK 11+), python3, GNU tar, and network access for the target sysroot downloads.

set -euo pipefail

VERSION=2.4.21
OFFICIAL_LINUX_SHA256=4935d8c8da90a2d2a8ff51da7d2c264c0d6026e1d35a8f169e218d9209965678
OFFICIAL_MACOS_SHA256=bf4edb526d91e17d0862102f69250525d788e79011f86c2c64362749adf260ae
TARGET=linux_arm64
PREBUILT=kotlin-native-prebuilt-linux-aarch64-$VERSION
REGULAR=kotlin-native-linux-aarch64-$VERSION
LLVM=llvm-21-aarch64-linux-essentials-1
LIBFFI=libffi-3.4.6-1-linux-aarch64

DIST=${1:?"Usage: $0 <dist dir> <official linux-x86_64 tar.gz> <official macos-aarch64 tar.gz> <out dir>"}
OFFICIAL_LINUX=${2:?}
OFFICIAL_MACOS=${3:?}
OUT=${4:?}
HELPER="$(cd "$(dirname "$0")" && pwd)/repack_dist.py"

[ "$(uname -sm)" = "Linux aarch64" ] || { echo "Must run on Linux aarch64, not $(uname -sm)"; exit 1; }
check_sha256() { echo "$2  $1" | sha256sum -c --quiet - || { echo "Unexpected sha256 of $1"; exit 1; }; }
check_sha256 "$OFFICIAL_LINUX" "$OFFICIAL_LINUX_SHA256"
check_sha256 "$OFFICIAL_MACOS" "$OFFICIAL_MACOS_SHA256"

WORK=$(mktemp -d)
mkdir -p "$OUT" "$WORK/official" "$WORK/new"
echo "== Unpacking into $WORK"
tar -xzf "$DIST/$PREBUILT.tar.gz" -C "$WORK/new"
tar -xzf "$DIST/$REGULAR.tar.gz" -C "$WORK/new"
tar -xzf "$OFFICIAL_LINUX" -C "$WORK/official"
OFFICIAL_ROOT="$WORK/official/kotlin-native-prebuilt-linux-x86_64-$VERSION"
P="$WORK/new/$PREBUILT"
R="$WORK/new/$REGULAR"

echo "== Standard library: official linux-x86_64 klib/common"
for root in "$P" "$R"; do
  rm -rf "$root/klib/common"
  cp -a "$OFFICIAL_ROOT/klib/common" "$root/klib/common"
done

echo "== Non-Apple platform klibs: official linux-x86_64 vs official macos-aarch64"
NON_APPLE=$(ls "$OFFICIAL_ROOT/klib/platform" | grep -E '^(android|linux|mingw)_')
CHANGED=(klib/common klib/cache)
# shellcheck disable=SC2086
if python3 "$HELPER" platform-diff "$OFFICIAL_LINUX" "$OFFICIAL_MACOS" $NON_APPLE; then
  echo "Identical: using the official non-Apple platform klibs"
  for t in $NON_APPLE; do
    rm -rf "$P/klib/platform/$t"
    cp -a "$OFFICIAL_ROOT/klib/platform/$t" "$P/klib/platform/$t"
    CHANGED+=("klib/platform/$t")
  done
else
  echo "Not identical: keeping the self-built non-Apple platform klibs"
fi

echo "== Caches"
export KONAN_DATA_DIR="$WORK/konan-data"
mkdir -p "$KONAN_DATA_DIR/dependencies"
for dep in $LLVM $LIBFFI; do
  tar -xzf "$DIST/$dep.tar.gz" -C "$KONAN_DATA_DIR/dependencies"
  echo "$dep" >> "$KONAN_DATA_DIR/dependencies/.extracted"
done

# `additionalCacheFlags` from konan.properties, looked up like Configurables.targetList: for the target, then plain.
ADDITIONAL_CACHE_FLAGS=()
for key in "additionalCacheFlags.$TARGET" additionalCacheFlags; do
  line=$(grep -E "^$key *=" "$P/konan/konan.properties" || true)
  if [ -n "$line" ]; then
    case "$line" in *\\) echo "Multi-line $key is not supported"; exit 1 ;; esac
    read -r -a ADDITIONAL_CACHE_FLAGS <<< "${line#*=}"
    break
  fi
done

# Arguments of KonanCacheTask at v2.4.21.
build_cache() { # <g|opt> <klib> <cache directory> <per-file|monolithic>
  local args
  if [ "$1" = opt ]; then args=(-opt -Xbinary=enableReleaseBinaryCache=true); else args=(-g); fi
  args+=(-target "$TARGET" -produce static_cache "-Xadd-cache=$2" "-Xcache-directory=$3")
  args+=("${ADDITIONAL_CACHE_FLAGS[@]}" "-Xdebug-prefix-map=$3=out")
  if [ "$4" = per-file ]; then args+=(-Xmake-per-file-cache); fi
  echo "konanc ${args[*]}"
  "$P/bin/konanc" "${args[@]}"
}

for flavor in g opt; do
  rm -rf "$P/klib/cache/$TARGET-${flavor}STATIC-system/"* "$R/klib/cache/$TARGET-${flavor}STATIC-system/"*
done

for flavor in g opt; do
  stdlib_cache_dir="$WORK/stdlib-cache/$TARGET-${flavor}STATIC-system"
  mkdir -p "$stdlib_cache_dir"
  if [ $flavor = g ]; then
    build_cache g "$P/klib/common/stdlib" "$stdlib_cache_dir" per-file
    built="$stdlib_cache_dir/stdlib-per-file-cache"
  else
    build_cache opt "$P/klib/common/stdlib" "$stdlib_cache_dir" monolithic
    built="$stdlib_cache_dir/stdlib-cache"
  fi
  for root in "$P" "$R"; do
    cp -a "$built" "$root/klib/cache/$TARGET-${flavor}STATIC-system/stdlib-per-file-cache"
  done
done

# Platform klibs in dependency order. The Gradle build orders the cache tasks by the `depends` of the def files
# (shipped in konan/platformDef), which can be stricter than the klib manifests, e.g. builtin.def depends on posix.
PLATFORM_ORDER=$(python3 - "$P/klib/platform/$TARGET" "$P/konan/platformDef/$TARGET" <<'PY'
import os, sys
root, defs = sys.argv[1], sys.argv[2]
prefix = "org.jetbrains.kotlin.native.platform."
def properties(path):
    with open(path) as f:
        return dict((k.strip(), v.strip()) for k, v in (l.split("=", 1) for l in f.read().split("\n---\n")[0].splitlines() if "=" in l))
deps = {}
for lib in sorted(os.listdir(root)):
    names = properties(os.path.join(root, lib, "default", "manifest")).get("depends", "").split()
    def_file = os.path.join(defs, lib[len(prefix):] + ".def")
    if os.path.exists(def_file):
        names += [prefix + d for d in properties(def_file).get("depends", "").split()]
    deps[lib] = sorted({d for d in names if d in os.listdir(root)})
done = []
while len(done) < len(deps):
    ready = [l for l in sorted(deps) if l not in done and all(d in done for d in deps[l])]
    if not ready: sys.exit(f"cyclic platform klib dependencies: {deps}")
    done += ready
print("\n".join(done))
PY
)
for flavor in g opt; do
  for lib in $PLATFORM_ORDER; do
    build_cache $flavor "$P/klib/platform/$TARGET/$lib" "$P/klib/cache/$TARGET-${flavor}STATIC-system" monolithic
  done
done

echo "== Repacking"
for bundle in $PREBUILT $REGULAR; do
  python3 "$HELPER" repack "$DIST/$bundle.tar.gz" "$WORK/new" "$OUT/$bundle.tar.gz" "${CHANGED[@]}"
  python3 "$HELPER" verify "$DIST/$bundle.tar.gz" "$OUT/$bundle.tar.gz" "$OFFICIAL_LINUX" "${CHANGED[@]}"
done

echo "== Checksums"
for f in $LLVM.tar.gz $LIBFFI.tar.gz $PREBUILT.spdx.json $REGULAR.spdx.json; do cp "$DIST/$f" "$OUT/$f"; done
(
  cd "$OUT"
  for f in $PREBUILT.tar.gz $REGULAR.tar.gz $LLVM.tar.gz $LIBFFI.tar.gz; do sha256sum "$f" | cut -d' ' -f1 > "$f.sha256"; done
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
)
rm -rf "$WORK"
echo "== Done: $OUT"
