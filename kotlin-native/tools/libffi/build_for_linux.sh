#!/bin/bash

# Builds the libffi archive that Kotlin/Native uses on a Linux host (see libffiDir.<host> in konan.properties).
# The archive contains `include/` and `lib/libffi.a`.

set -eou pipefail

OUTPUT_PATH=${1?"Usage: $0 <output path>"}
if [ ! -d "$OUTPUT_PATH" ]; then
  echo "$OUTPUT_PATH does not exist"
  exit 1
fi
OUTPUT_PATH="$(realpath "$OUTPUT_PATH")"

case "$(uname -m)" in
  aarch64|arm64) ARCH=aarch64 ;;
  x86_64|amd64) ARCH=x86-64 ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

LIBFFI_VERSION=3.4.6
LIBFFI_SHA256=b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e
VERSION=1
NAME=libffi-$LIBFFI_VERSION-$VERSION-linux-$ARCH

pushd "$(mktemp -d -t libffi.XXXXXX)"
curl -LO "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz"
echo "$LIBFFI_SHA256  libffi-$LIBFFI_VERSION.tar.gz" | sha256sum -c -
tar -xf "libffi-$LIBFFI_VERSION.tar.gz"
pushd "libffi-$LIBFFI_VERSION"

# --libdir: some distributions default to lib64, but Kotlin/Native expects lib/libffi.a.
./configure --prefix="$(pwd)/$NAME" --libdir="$(pwd)/$NAME/lib" --disable-docs --enable-shared=no --with-pic
make -j"$(nproc)" install
test -f "$NAME/lib/libffi.a"
test -f "$NAME/include/ffi.h"
tar -czf "$OUTPUT_PATH/$NAME.tar.gz" "$NAME"
popd
popd

echo "Created $OUTPUT_PATH/$NAME.tar.gz"
