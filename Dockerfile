# syntax=docker/dockerfile:1
# Builds aapt2 for Linux aarch64. See README.md:
#   docker buildx build --platform linux/arm64 --output out .

ARG LLVM_VERSION=20.1.8
ARG LLVM_SHA256=6898f963c8e938981e6c4a302e83ec5beb4630147c7311183cf61069af16333d
ARG UBUNTU_IMAGE=ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c
ARG UBUNTU_SNAPSHOT=20251015T000000Z

# Ubuntu 24.04 with packages pinned by an Ubuntu archive snapshot.
FROM ${UBUNTU_IMAGE} AS toolchain
ARG UBUNTU_SNAPSHOT
RUN apt-get update --snapshot "$UBUNTU_SNAPSHOT" \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils git cmake ninja-build python3 clang-20 lld-20 llvm-20 \
 && rm -rf /var/lib/apt/lists/*
ENV CC=clang-20 CXX=clang++-20

# glibc from Debian 10 to link against, so that aapt2 needs no newer glibc than that.
FROM toolchain AS sysroot
COPY sysroot.txt fetch-sysroot.sh /build/
RUN sh /build/fetch-sysroot.sh /sysroot

# libc++ and libc++abi, built against that sysroot and linked statically.
FROM sysroot AS libcxx
ARG LLVM_VERSION
ARG LLVM_SHA256
RUN curl -fsSL -o /tmp/llvm.tar.xz \
      "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-project-${LLVM_VERSION}.src.tar.xz" \
 && echo "${LLVM_SHA256}  /tmp/llvm.tar.xz" | sha256sum -c - \
 && mkdir /llvm && cd /llvm \
 && tar -xJf /tmp/llvm.tar.xz --strip-components=1 \
      $(for d in runtimes libcxx libcxxabi libc cmake llvm/cmake llvm/utils/llvm-lit; do echo "llvm-project-${LLVM_VERSION}.src/$d"; done) \
 && rm /tmp/llvm.tar.xz
RUN cmake -S /llvm/runtimes -B /libcxx-build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSROOT=/sysroot \
      -DCMAKE_INSTALL_PREFIX=/libcxx \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld -nostdlib++" \
      -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
      -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
      -DLIBCXX_ENABLE_SHARED=OFF \
      -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
      -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
      -DLIBCXX_INCLUDE_TESTS=OFF \
      -DLIBCXXABI_ENABLE_SHARED=OFF \
      -DLIBCXXABI_INCLUDE_TESTS=OFF \
      -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
 && ninja -C /libcxx-build install-cxx install-cxxabi

FROM libcxx AS sources
COPY sources.txt fetch-sources.sh /build/
RUN sh /build/fetch-sources.sh /aosp

FROM sources AS build
COPY CMakeLists.txt inject_build_number.py /build/
RUN cmake -S /build -B /out -G Ninja -DAOSP=/aosp -DSYSROOT=/sysroot -DLIBCXX=/libcxx -DCMAKE_BUILD_TYPE= \
 && ninja -C /out aapt2 \
 && llvm-strip-20 -o /out/aapt2.stripped /out/aapt2

# The release tarball (aapt2 and the licence texts of everything in it) and its SBOM.
FROM build AS package
ARG LLVM_VERSION
ARG LLVM_SHA256
ARG UBUNTU_IMAGE
ARG UBUNTU_SNAPSHOT
# The commit time of the frameworks/base revision, as every file's mtime.
ARG SOURCE_DATE_EPOCH=1741648657
ARG SBOM_CREATED=1970-01-01T00:00:00Z
ARG RELEASE_URL=NOASSERTION
COPY collect-notices.sh make-sbom.py /build/
RUN set -eu; name=aapt2-2.20-13193326-linux-aarch64; \
    mkdir -p "/pkg/$name" /release; \
    install -m 0755 /out/aapt2.stripped "/pkg/$name/aapt2"; \
    sh /build/collect-notices.sh /aosp /llvm /sysroot > "/pkg/$name/NOTICE"; \
    chmod 0644 "/pkg/$name/NOTICE"; \
    tar -C /pkg --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" -cf - "$name" \
      | gzip -9n > "/release/$name.tar.gz"; \
    { echo "ubuntu 24.04 docker://$UBUNTU_IMAGE"; \
      for p in clang-20 lld-20 llvm-20 cmake ninja-build; do \
        echo "$p $(dpkg-query -W -f='${Version}' "$p") https://snapshot.ubuntu.com/ubuntu-ports/$UBUNTU_SNAPSHOT"; \
      done; } > /tmp/toolchain.txt; \
    SBOM_CREATED="$SBOM_CREATED" RELEASE_URL="$RELEASE_URL" python3 /build/make-sbom.py "/release/$name.tar.gz" \
      /build/sources.txt /build/sysroot.txt "$LLVM_VERSION" "$LLVM_SHA256" /tmp/toolchain.txt > "/release/$name.spdx.json"

FROM scratch AS release
COPY --from=package /release/ /
