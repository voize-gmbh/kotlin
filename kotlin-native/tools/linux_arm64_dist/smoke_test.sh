#!/bin/bash
# Smoke-tests a linux-aarch64 Kotlin/Native 2.4.21 distribution produced by repack_with_official_stdlib.sh, from a
# fresh KONAN_DATA_DIR. Runs on Linux aarch64 and needs strace, file and readelf.
#
# Usage: smoke_test.sh <out dir of repack_with_official_stdlib.sh> <official linux-x86_64 tar.gz> <report file>

set -uo pipefail

VERSION=2.4.21
OUT=${1:?"Usage: $0 <dist dir> <official linux-x86_64 tar.gz> <report file>"}
OFFICIAL_LINUX=${2:?}
REPORT=${3:?}
HELPER="$(cd "$(dirname "$0")" && pwd)/repack_dist.py"
PREBUILT=kotlin-native-prebuilt-linux-aarch64-$VERSION
REGULAR=kotlin-native-linux-aarch64-$VERSION

W=$(mktemp -d)
exec > >(tee "$REPORT") 2>&1
PASSED=0; FAILED=0
pass() { echo "PASS: $*"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $*"; FAILED=$((FAILED + 1)); }

export KONAN_DATA_DIR="$W/konan-data"
mkdir -p "$KONAN_DATA_DIR/dependencies"
for dep in llvm-21-aarch64-linux-essentials-1 libffi-3.4.6-1-linux-aarch64; do
  tar -xzf "$OUT/$dep.tar.gz" -C "$KONAN_DATA_DIR/dependencies"
  echo "$dep" >> "$KONAN_DATA_DIR/dependencies/.extracted"
done
tar -xzf "$OUT/$PREBUILT.tar.gz" -C "$W"
KN="$W/$PREBUILT"
K="$KN/bin/kotlinc-native"
cd "$W"

echo "== klib/common vs official linux-x86_64"
python3 "$HELPER" listing "$OFFICIAL_LINUX" klib/common > official-common.txt
for bundle in $PREBUILT $REGULAR; do
  python3 "$HELPER" listing "$OUT/$bundle.tar.gz" klib/common > "$bundle-common.txt"
  if diff -q official-common.txt "$bundle-common.txt" > /dev/null; then
    pass "$bundle klib/common sha256 listing == official ($(wc -l < official-common.txt) files)"
  else
    fail "$bundle klib/common differs from official"; diff official-common.txt "$bundle-common.txt" | head
  fi
done

echo "== Layout vs official linux-x86_64 (top-level directory and cache host normalised)"
python3 - "$OFFICIAL_LINUX" "$OUT/$PREBUILT.tar.gz" <<'PY' && pass "same paths as the official prebuilt bundle" || fail "layout differs from the official prebuilt bundle"
import re, sys, tarfile
def paths(p):
    with tarfile.open(p, "r:gz") as t:
        names = (m.name.rstrip("/").partition("/")[2] for m in t)
        return {re.sub(r"klib/cache/linux_(x64|arm64)-", "klib/cache/HOST-", n) for n in names}
a, b = paths(sys.argv[1]), paths(sys.argv[2])
print(f"official {len(a)} entries, ours {len(b)}; only official: {sorted(a - b)[:5]}; only ours: {sorted(b - a)[:5]}")
sys.exit(0 if a == b else 1)
PY

echo "== Versions"
grep -E "^compilerVersion" "$KN/konan/konan.properties"
echo "stdlib manifest: $(grep compiler_version "$KN/klib/common/stdlib/default/manifest")"
echo "linux_arm64 posix manifest: $(grep compiler_version "$KN/klib/platform/linux_arm64/org.jetbrains.kotlin.native.platform.posix/default/manifest")"
echo "ios_arm64 Foundation manifest: $(grep compiler_version "$KN/klib/platform/ios_arm64/org.jetbrains.kotlin.native.platform.Foundation/default/manifest")"
"$K" -version 2>&1 | tail -1

cat > hello.kt <<'KT'
fun main(args: Array<String>) {
    val sum = (1L..100_000L).sumOf { it * it }
    println("Hello, Kotlin/Native! sum=$sum args=${args.toList()}")
}
KT

echo "== Compile for every target"
for t in linux_arm64 linux_x64 linux_arm32_hfp mingw_x64 android_arm32 android_arm64 android_x86 android_x64; do
  start=$(date +%s)
  if "$K" hello.kt -target $t -o "hello-$t" > "compile-$t.log" 2>&1; then
    out=$(ls hello-$t.kexe hello-$t.exe 2>/dev/null | head -1)
    pass "[$t] compile OK in $(( $(date +%s) - start ))s: $(file -b "$out")"
    [ "${out##*.}" = kexe ] && echo "  NEEDED: $(readelf -d "$out" | grep NEEDED | grep -o '\[.*\]' | tr '\n' ' ')"
  else
    fail "[$t] compile"; tail -5 "compile-$t.log"
  fi
done
./hello-linux_arm64.kexe a b && pass "run linux_arm64" || fail "run linux_arm64"

echo "== Debug build with the system caches (-Xauto-cache-from, as KGP passes it)"
mkdir -p auto-cache-from
if strace -f -qq -e trace=openat -e signal=none -o debug-open.txt "$K" hello.kt -g -o hello-debug -Xauto-cache-from="$W/auto-cache-from" > debug.log 2>&1; then
  stdlib_archives=$(grep -c "klib/cache/linux_arm64-gSTATIC-system/stdlib-per-file-cache/.*\.a\"" debug-open.txt)
  posix_cache=$(grep -c "klib/cache/linux_arm64-gSTATIC-system/org.jetbrains.kotlin.native.platform.posix-cache" debug-open.txt)
  if [ "$stdlib_archives" -gt 0 ] && [ "$posix_cache" -gt 0 ] && ./hello-debug.kexe x; then
    pass "[-g] uses the system caches ($stdlib_archives stdlib cache archives opened) and runs: $(file -b hello-debug.kexe | cut -d, -f1-2,7-)"
  else
    fail "[-g] system caches not used or binary failed (stdlib archives opened: $stdlib_archives, posix cache: $posix_cache)"
  fi
else
  fail "[-g] compile"; tail -5 debug.log
fi
"$K" hello.kt -opt -o hello-opt > opt.log 2>&1 && ./hello-opt.kexe x && pass "[-opt] compile and run" || { fail "[-opt]"; tail -5 opt.log; }

echo "== cinterop against posix, with kotlinx.cinterop.alloc from the stdlib"
cat > kn.def <<'DEF'
headers = unistd.h string.h
package = kn
---
static inline int kn_add(int a, int b) { return a + b; }
static inline unsigned long kn_strlen(const char* s) { return strlen(s); }
DEF
cat > interop.kt <<'KT'
import kotlinx.cinterop.*
import platform.posix.*

@OptIn(ExperimentalForeignApi::class)
fun main() {
    val doubled = memScoped {
        val n = alloc<IntVar>()
        n.value = kn.kn_add(2, 3)
        n.value * 2
    }
    val pid = getpid()
    println("cinterop: kn_add(2,3)*2=$doubled kn_strlen=${kn.kn_strlen("posix")} pid>0=${pid > 0}")
}
KT
"$KN/bin/cinterop" -def kn.def -target linux_arm64 -o auto-cache-from/kn > cinterop.log 2>&1 \
  && pass "[cinterop linux_arm64] klib" || { fail "[cinterop linux_arm64]"; tail -5 cinterop.log; }
rm -rf auto-cache-dir; mkdir auto-cache-dir
if "$K" interop.kt -g -l auto-cache-from/kn.klib -o interop-debug -Xauto-cache-from="$W/auto-cache-from" -Xauto-cache-dir="$W/auto-cache-dir" > interop-debug.log 2>&1 && ./interop-debug.kexe; then
  pass "[cinterop -g] links against the system caches, builds a cache for the interop klib ($(find auto-cache-dir -name '*.a' | wc -l) archives) and runs"
else
  fail "[cinterop -g]"; tail -5 interop-debug.log
fi
"$K" interop.kt -opt -l auto-cache-from/kn.klib -o interop-opt > interop-opt.log 2>&1 && ./interop-opt.kexe \
  && pass "[cinterop -opt] compile and run" || { fail "[cinterop -opt]"; tail -5 interop-opt.log; }
"$KN/bin/cinterop" -def kn.def -target android_arm64 -o kn-android > cinterop-android.log 2>&1 \
  && "$K" interop.kt -target android_arm64 -l kn-android.klib -o interop-android > interop-android.log 2>&1 \
  && pass "[cinterop android_arm64] $(file -b interop-android.kexe | cut -d, -f1-2,5)" || { fail "[cinterop android_arm64]"; tail -5 interop-android.log; }

echo "== Apple platform libraries"
cat > apple.kt <<'KT'
import platform.Foundation.NSUUID
import platform.darwin.NSObject
class Tag : NSObject()
fun id(): String = NSUUID().UUIDString()
KT
for t in ios_arm64 ios_simulator_arm64 macos_arm64; do
  "$K" -p library -target $t -o "apple-$t" apple.kt > "apple-$t.log" 2>&1 \
    && pass "[apple $t] library: $(unzip -p "apple-$t.klib" default/manifest 2>/dev/null | grep native_targets || echo built)" \
    || { fail "[apple $t]"; tail -5 "apple-$t.log"; }
done

echo "== Dependencies downloaded into the fresh KONAN_DATA_DIR"
ls "$KONAN_DATA_DIR/dependencies"

echo "SUMMARY: $PASSED passed, $FAILED failed"
rm -rf "$W"
[ "$FAILED" = 0 ]
