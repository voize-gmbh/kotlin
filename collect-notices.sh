#!/bin/sh
# Writes the licence texts of everything linked into aapt2 to stdout.
# usage: collect-notices.sh <aosp sources> <llvm sources> <sysroot>
set -eu
aosp=$1 llvm=$2 sysroot=$3

section() {
  printf '%s\n' "================================================================================"
  printf '%s\n' "$1"
  printf '%s\n\n' "================================================================================"
  cat "$2"
  printf '\n\n'
}

cat <<'EOF'
aapt2 for Linux aarch64 is built from the Android Open Source Project and links the libraries
below statically. Each section names the component, where it comes from and its licence text.
glibc is not included: aapt2 links it dynamically from the system it runs on.


EOF
section "aapt2, libandroidfw, libidmap2_policies (platform/frameworks/base), Apache-2.0" "$aosp/frameworks/base/NOTICE"
section "Android native headers (platform/frameworks/native), Apache-2.0" "$aosp/frameworks/native/NOTICE"
section "libutils (platform/system/core), Apache-2.0" "$aosp/system/core/libutils/NOTICE"
section "libcutils (platform/system/core), Apache-2.0" "$aosp/system/core/libcutils/NOTICE"
section "libbase (platform/system/libbase), Apache-2.0" "$aosp/system/libbase/NOTICE"
section "liblog (platform/system/logging), Apache-2.0" "$aosp/system/logging/liblog/NOTICE"
section "libziparchive (platform/system/libziparchive) and libbuildversion (platform/build/soong), Apache-2.0" "$aosp/build/soong/licenses/LICENSE"
section "libincfs-utils (platform/system/incremental_delivery), Apache-2.0" "$aosp/system/incremental_delivery/incfs/NOTICE"
section "JNI headers (platform/libnativehelper), Apache-2.0" "$aosp/libnativehelper/NOTICE"
section "Protocol Buffers 3.21.12 (platform/external/protobuf), BSD-3-Clause" "$aosp/external/protobuf/LICENSE"
section "Expat (platform/external/expat), MIT" "$aosp/external/expat/COPYING"
section "libpng 1.6.44 (platform/external/libpng), libpng-2.0" "$aosp/external/libpng/LICENSE"
section "zlib, Chromium's version (platform/external/zlib), Zlib" "$aosp/external/zlib/LICENSE"
section "{fmt} (platform/external/fmtlib), MIT" "$aosp/external/fmtlib/LICENSE"
section "libc++ (LLVM), Apache-2.0 WITH LLVM-exception" "$llvm/libcxx/LICENSE.TXT"
section "libc++abi (LLVM), Apache-2.0 WITH LLVM-exception" "$llvm/libcxxabi/LICENSE.TXT"
section "libgcc (GCC 8.3.0, Debian gcc-8 8.3.0-6), GPL-3.0-or-later WITH GCC-exception-3.1" "$sysroot/usr/share/doc/gcc-8-base/copyright"
