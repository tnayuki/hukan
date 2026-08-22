#!/bin/sh
# Rebuild Vendor/Clibgit2.xcframework from a pinned libgit2 release.
#
# hukan only *reads* local worktrees — it never clones or fetches — so libgit2 is built with
# every network backend off (USE_HTTPS=OFF, USE_SSH=OFF). That drops the OpenSSL and libssh2
# dependencies entirely, leaving one self-contained static archive with no external libraries
# to ship. The result, Clibgit2.xcframework, is a committed static asset (like Resources/
# hukan.icns): the build is not part of xcodebuild — run this by hand to bump the version.
set -eu

LIBGIT2_VERSION="1.9.7"
ARCHS="arm64;x86_64"
DEPLOYMENT_TARGET="15.0"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Fetching libgit2 v$LIBGIT2_VERSION"
curl -fsSL "https://github.com/libgit2/libgit2/archive/refs/tags/v${LIBGIT2_VERSION}.tar.gz" \
  | tar xz -C "$WORK"
SRC="$WORK/libgit2-${LIBGIT2_VERSION}"

echo "==> Configuring (static, no https/ssh, bundled zlib + builtin regex)"
cmake -S "$SRC" -B "$WORK/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_CLI=OFF \
  -DBUILD_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DUSE_HTTPS=OFF \
  -DUSE_SSH=OFF \
  -DUSE_BUNDLED_ZLIB=ON \
  -DREGEX_BACKEND=builtin

echo "==> Building"
cmake --build "$WORK/build" --config Release -j"$(sysctl -n hw.ncpu)"

LIB="$(find "$WORK/build" -name 'libgit2.a' | head -1)"
[ -n "$LIB" ] || { echo "libgit2.a not found" >&2; exit 1; }

echo "==> Assembling headers + module map"
HEADERS="$WORK/headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp -R "$SRC/include/." "$HEADERS/"
cat > "$HEADERS/module.modulemap" <<'MODULEMAP'
module Clibgit2 {
    header "git2.h"
    export *
}
MODULEMAP

echo "==> Packaging Clibgit2.xcframework"
rm -rf "$HERE/Clibgit2.xcframework"
xcodebuild -create-xcframework \
  -library "$LIB" -headers "$HEADERS" \
  -output "$HERE/Clibgit2.xcframework"

echo "==> Done: $HERE/Clibgit2.xcframework (libgit2 $LIBGIT2_VERSION)"
