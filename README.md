# aapt2 2.20-13193326 for Linux aarch64 (unofficial build)

Google ships the Android SDK build tools for Linux x86_64 only. This builds the `aapt2` of
build-tools 36.0.0 (`Android Asset Packaging Tool (aapt) 2.20-13193326`) for Linux aarch64 from
the Android Open Source Project, so that Android resource processing runs natively on arm64 hosts
such as AWS Graviton build executors. Its outputs are byte-identical to Google's `aapt2`.

Releases: https://github.com/voize-gmbh/kotlin/releases (tags `aapt2-<version>-linux-arm64`).

## Build

On a host that runs linux/arm64 containers (an arm64 machine, or Docker with emulation):

```sh
docker buildx build --platform linux/arm64 --target release --output out .
```

`out/` then holds `aapt2-2.20-13193326-linux-aarch64.tar.gz` (`aapt2` and `NOTICE`) and its SPDX
SBOM. `--target dist` produces just the binary. The build is reproducible: building twice gives the
same tarball.

Everything is pinned:

| What | Pinned by |
|---|---|
| AOSP sources (`sources.txt`) | git commit; `fetch-sources.sh` checks out exactly these |
| Toolchain: clang/lld 20.1.2, CMake, Ninja | Ubuntu 24.04 image digest and an Ubuntu archive snapshot |
| libc++ and libc++abi 20.1.8 | sha256 of the LLVM source tarball |
| glibc to link against (Debian 10) | sha256 of each `.deb` (`sysroot.txt`) |

## Which sources

The build number 13193326 lies between two daily snapshots of the Android 16 release branch
(`25Q2-release`, published as `android16-release`): 13190096 (2025-03-10) and 13197820
(2025-03-11). `sources.txt` pins every project at that branch's state after snapshot 13190096.
Nothing aapt2 is built from changed between snapshots 13182071 (2025-03-07) and 13197820, so the
choice among them does not matter. aapt2 reports minor version 20 only on that branch (AOSP `main`
and `sdk-release` were still at 2.19 then), and the help text of Google's binary matches the source:
it still has the "stylesables" typo fixed on 2025-03-19, and predates the sparse encoding change of
2025-03-12.

## How it is built

- `CMakeLists.txt` compiles aapt2 and the libraries it links (libandroidfw, libutils, libcutils,
  liblog, libbase, libziparchive, libincfs-utils, libbuildversion, protobuf 3.21.12, expat, libpng,
  zlib, fmtlib) with the source lists of their `Android.bp` files for a Linux host, and the flags
  Soong uses for host code (`build/soong/cc/config`). Among them `-ffp-contract=off`, without which
  arm64 would fuse floating-point multiply-adds that x86_64 does not. protoc is built from the same
  protobuf and generates aapt2's protobuf code, with paths relative to the source root as Soong does.
- Like Google's Linux build, everything but glibc is linked statically. libc++ is built against the
  glibc of Debian 10, and the binary only needs the `GLIBC_2.17` symbol version, the first glibc for
  aarch64. So it runs on any aarch64 Linux with glibc.
- aapt2 writes its version into proto outputs (compiled values, static libraries, `--proto-format`
  APKs). Soong writes the build number into the `soong_build_number` symbol after linking;
  `inject_build_number.py` does the same with 13193326, so outputs match Google's byte for byte.
- `CursorWindow.cpp`, which `Android.bp` adds to libandroidfw on Linux hosts, is left out: it needs
  libbinder, and aapt2 does not use it.

## Verification

Two tests compared every output file of this build against Google's macOS (arm64) and Linux
(x86_64) binaries of the same version. Both use real resources: those of an Android app and the
317 AARs it depends on (3241 resource files).

1. Replay of real invocations (`test/aapt2-capture-wrapper.py`, `test/replay.py`). A local Bazel
   build of the app ran with a wrapper in place of aapt2 that recorded each invocation (arguments,
   inputs and the outputs of Google's binary). Each one was then replayed at the same paths with the
   other binaries: 7256 invocations (7230 `compile` with crunching and pseudo-localisation, 25 `link`
   including the app's `--proto-format` link of 1273 inputs, 1 `convert`), 7310 output files.
2. `test/direct-test.sh` runs a fixed set of commands over the same resource directories: `compile`
   with and without crunching, pseudo-localised and to a zip; `link` as binary (min SDK 21, 26, 33,
   sparse and compact entries, debug with `-c` and preferred density), as proto, as static library,
   with non-final ids; `convert` both ways; `optimize`; `dump`; and the help text: 8350 files,
   compared with `test/compare-trees.py`.

All output files of this build are identical to those of Google's macOS binary. Google's Linux
binary agrees with both, except on one deliberately out-of-range value in `direct-test.sh`: a
dimension of `3.4028235e38dp` overflows a float to integer conversion in libandroidfw
(`ResourceTypes.cpp`, `stringToFloat`), which arm64 and x86_64 resolve differently. There this build
and Google's macOS arm64 binary agree.

A Bazel build of an Android library and app (compile, static library link, resource packaging and
the APK) on Linux arm64 with this aapt2 gave the same outputs, byte for byte, as the same build on a
Mac with Google's. The binary also ran on CentOS 7 (glibc 2.17), Debian 10, Amazon Linux 2023 and
Ubuntu 24.04.

## Licence

The build scripts here are under the Apache License 2.0 (`LICENSE`). The binary contains code under
the licences listed in its `NOTICE`.
