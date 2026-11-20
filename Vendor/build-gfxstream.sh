#!/bin/sh
# Rebuild Vendor/Cgfxstream.xcframework from a pinned gfxstream commit: the renderer a Linux
# machine's GPU runs on. The guest's own Mesa turns its OpenGL into Vulkan (Zink) and sends the
# Vulkan through virtio-gpu; gfxstream replays it here on KosmicKrisp, Mesa's Vulkan on Metal
# (Vendor/build-mesa.sh), and its snapshots are what lets such a machine be suspended
# (docs/virtual-machines.md says what that rests on).
#
# What comes out is one library, libgfxstream_backend.dylib, with nothing but the system's beneath
# it: its snapshots are protobufs, so protobuf and abseil are built here from source and linked in
# statically — Homebrew's are dylibs named for their exact version, which a `brew upgrade` takes
# away from under an app that links them. The xcframework carries the C API's headers and a module
# map, for the renderer process to import.
#
# Like the other archives here this is committed; run it by hand to move a pin. Needs network,
# cmake, meson and ninja.
set -eu

GFXSTREAM_COMMIT="cf47bd2660e7217f5729c91664d36d81c1b3282a"
GFXSTREAM_SHA256="cb3e512211701fb55dfcb94685945203db56656cee096981ca4ad66e1d463189"
ABSEIL_VERSION="20260817.0"
ABSEIL_SHA256="f7e05179df39c45434cad433f5783840bb3788ef322976f9138bc6b72b3a107d"
PROTOBUF_VERSION="36.2"
PROTOBUF_SHA256="3d9642a662d10e68ebae5e53f14dcce5105684212d5078f8e0d47d1ab3ae6b64"
# arm64 alone, as for the other archives here.
export MACOSX_DEPLOYMENT_TARGET="15.0"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/Cgfxstream.xcframework"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PREFIX="$WORK/prefix"
SDKROOT="$(xcrun --show-sdk-path)"
export SDKROOT

fetch() { # fetch URL SHA256 DIR
  curl -fsSL "$1" -o "$WORK/archive.tar.gz"
  echo "$2  $WORK/archive.tar.gz" | shasum -a 256 -c - >/dev/null
  mkdir -p "$3"
  tar -xzf "$WORK/archive.tar.gz" -C "$3" --strip-components 1
  rm "$WORK/archive.tar.gz"
}

# Static, position-independent (they end up inside a dylib), C++17 as gfxstream is.
CMAKE_COMMON="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF"

echo "==> abseil $ABSEIL_VERSION"
fetch "https://github.com/abseil/abseil-cpp/archive/refs/tags/$ABSEIL_VERSION.tar.gz" \
  "$ABSEIL_SHA256" "$WORK/abseil"
# shellcheck disable=SC2086
cmake -S "$WORK/abseil" -B "$WORK/abseil-build" $CMAKE_COMMON -DABSL_PROPAGATE_CXX_STD=ON >/dev/null
cmake --build "$WORK/abseil-build" >/dev/null
cmake --install "$WORK/abseil-build" >/dev/null

echo "==> protobuf $PROTOBUF_VERSION"
fetch "https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOBUF_VERSION/protobuf-$PROTOBUF_VERSION.tar.gz" \
  "$PROTOBUF_SHA256" "$WORK/protobuf"
# protoc too, from the same source as the library its generated code is compiled against.
# shellcheck disable=SC2086
cmake -S "$WORK/protobuf" -B "$WORK/protobuf-build" $CMAKE_COMMON -Dprotobuf_BUILD_TESTS=OFF \
  -Dprotobuf_ABSL_PROVIDER=package -Dprotobuf_BUILD_SHARED_LIBS=OFF >/dev/null
cmake --build "$WORK/protobuf-build" >/dev/null
cmake --install "$WORK/protobuf-build" >/dev/null

echo "==> PyYAML, for gfxstream's generators"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet pyyaml

echo "==> gfxstream $GFXSTREAM_COMMIT"
fetch "https://github.com/google/gfxstream/archive/$GFXSTREAM_COMMIT.tar.gz" "$GFXSTREAM_SHA256" \
  "$WORK/gfxstream"
patch -d "$WORK/gfxstream" -p1 --quiet < "$HERE/gfxstream-hukan.patch"
PATH="$PREFIX/bin:$WORK/venv/bin:$PATH" PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
  meson setup "$WORK/build" "$WORK/gfxstream" --buildtype release -Db_ndebug=true \
  -Dgfxstream-build=host -Ddefault_library=shared -Dstrip=true >/dev/null
PATH="$PREFIX/bin:$WORK/venv/bin:$PATH" ninja -C "$WORK/build" >/dev/null

echo "==> Assembling Vendor/Cgfxstream.xcframework"
LIB="$WORK/lib/libgfxstream_backend.dylib"
mkdir -p "$WORK/lib" "$WORK/headers"
cp "$(readlink -f "$WORK/build/host/libgfxstream_backend.dylib")" "$LIB"
install_name_tool -id @rpath/libgfxstream_backend.dylib "$LIB"
codesign -f -s - "$LIB" 2>/dev/null
if otool -L "$LIB" | tail -n +2 | awk '{print $1}' | grep -v -E '^(@rpath/libgfxstream_backend|/usr/lib/|/System/)'; then
  echo "libgfxstream_backend.dylib depends on something outside the system and itself" >&2
  exit 1
fi
# One directory down, as the other xcframeworks here have theirs (docs/build.md), and the API's
# two headers one further, since one includes the other as "gfxstream/...".
mkdir -p "$WORK/headers/Cgfxstream/gfxstream"
cp "$WORK/gfxstream/host/include/gfxstream/virtio-gpu-gfxstream-renderer.h" \
  "$WORK/gfxstream/host/include/gfxstream/virtio-gpu-gfxstream-renderer-unstable.h" \
  "$WORK/headers/Cgfxstream/gfxstream/"
cat > "$WORK/headers/Cgfxstream/Cgfxstream.h" <<'EOF'
#include "gfxstream/virtio-gpu-gfxstream-renderer.h"
#include "gfxstream/virtio-gpu-gfxstream-renderer-unstable.h"
EOF
cat > "$WORK/headers/Cgfxstream/module.modulemap" <<'EOF'
module Cgfxstream {
  header "Cgfxstream.h"
  export *
}
EOF
rm -rf "$OUT"
xcodebuild -create-xcframework -library "$LIB" -headers "$WORK/headers" -output "$OUT" >/dev/null

. "$HERE/licenses.sh"
write_license gfxstream "$GFXSTREAM_COMMIT" https://github.com/google/gfxstream "$WORK/gfxstream/LICENSE"
write_license protobuf "$PROTOBUF_VERSION" https://github.com/protocolbuffers/protobuf "$WORK/protobuf/LICENSE"
write_license abseil "$ABSEIL_VERSION" https://github.com/abseil/abseil-cpp "$WORK/abseil/LICENSE"

echo "==> Done: $OUT ($(du -sh "$OUT" | cut -f1))"
