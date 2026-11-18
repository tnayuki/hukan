#!/bin/sh
# Rebuild Vendor/Cvirglrenderer.xcframework from pinned virglrenderer and libepoxy releases.
#
# virglrenderer is the host half of virgl: it takes the OpenGL a Linux guest's Mesa sends down a
# virtio-gpu and replays it on an OpenGL of this Mac's — Mesa's Zink on KosmicKrisp
# (Vendor/build-mesa.sh), in EGL contexts hukan makes and hands it, since it has no winsys of its
# own for one. Only its GL renderer (vrend) is built: no Venus, no render server, no EGL or GLX
# winsys. libepoxy is the one library it needs, built static beside it with EGL — patched to find
# Mesa's (libepoxy-macos-egl.patch) — so what comes out is one archive, which reaches Mesa only
# through the libraries the app carries. Its headers, epoxy's GL and EGL ones included, are what
# the renderer's own GL calls go through too.
#
# The release is patched (virglrenderer-hukan.patch, which says why hunk by hunk), and GL errors
# are logged rather than fatal (check-gl-errors=false): with them fatal, a stray error left by one
# call — Xorg's glamor leaves one — kills the guest's whole GL context.
#
# Like Clibgit2.xcframework this is a committed static asset; run it by hand to bump a version,
# after Vendor/build-mesa.sh, whose EGL headers epoxy is built against. Needs meson, ninja and
# pkgconf (Homebrew), and network for the two archives and PyYAML, which virglrenderer's build
# reads its format table with.
set -eu

VIRGLRENDERER_VERSION="1.3.0"
VIRGLRENDERER_SHA256="088040d130eaa0458a978fe7867fbfb1fcf1fdff52bf3b27a00658828bc4189f"
EPOXY_VERSION="1.5.10"
EPOXY_SHA256="a7ced37f4102b745ac86d6a70a9da399cc139ff168ba6b8002b4d8d43c900c15"
# arm64 alone, as for the other archives here: the app is built for nothing else.
ARCH="arm64"
export MACOSX_DEPLOYMENT_TARGET="15.0"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PREFIX="$WORK/prefix"
export CFLAGS="-arch $ARCH -I$HERE/Mesa/include" LDFLAGS="-arch $ARCH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

fetch() { # url sha256 dir
  curl -fsSL "$1" -o "$WORK/archive"
  echo "$2  $WORK/archive" | shasum -a 256 -c - >/dev/null
  mkdir -p "$3"
  tar -xf "$WORK/archive" -C "$3" --strip-components 1
}

echo "==> PyYAML, for virglrenderer's build"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet pyyaml
export PATH="$WORK/venv/bin:$PATH"

echo "==> libepoxy $EPOXY_VERSION (static, EGL, no GLX/X11)"
fetch "https://github.com/anholt/libepoxy/archive/refs/tags/$EPOXY_VERSION.tar.gz" \
  "$EPOXY_SHA256" "$WORK/epoxy"
patch -d "$WORK/epoxy" -p1 --quiet < "$HERE/libepoxy-macos-egl.patch"
meson setup "$WORK/epoxy/build" "$WORK/epoxy" --prefix "$PREFIX" --buildtype release \
  -Ddefault_library=static -Dglx=no -Degl=yes -Dx11=false -Dtests=false >/dev/null
ninja -C "$WORK/epoxy/build" install >/dev/null

echo "==> virglrenderer $VIRGLRENDERER_VERSION (vrend only, patched)"
fetch "https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/$VIRGLRENDERER_VERSION/virglrenderer-$VIRGLRENDERER_VERSION.tar.bz2" \
  "$VIRGLRENDERER_SHA256" "$WORK/virgl"
patch -d "$WORK/virgl" -p1 --quiet < "$HERE/virglrenderer-hukan.patch"
meson setup "$WORK/virgl/build" "$WORK/virgl" --prefix "$PREFIX" --buildtype release \
  -Ddefault_library=static -Dvenus=false -Dcheck-gl-errors=false -Dtests=false >/dev/null
ninja -C "$WORK/virgl/build" install >/dev/null

. "$HERE/licenses.sh"
write_license libepoxy "$EPOXY_VERSION" https://github.com/anholt/libepoxy "$WORK/epoxy/COPYING"
write_license virglrenderer "$VIRGLRENDERER_VERSION" https://gitlab.freedesktop.org/virgl/virglrenderer \
  "$WORK/virgl/COPYING"

echo "==> Merging into one archive"
# The static libvirglrenderer.a carries its own objects only; the internal libraries it was linked
# from (Mesa's util, gallium's auxiliary) are archives of their own in the build tree.
ARCHIVES="$(find "$WORK/virgl/build/src" -name '*.a') $PREFIX/lib/libepoxy.a"
libtool -static -o "$WORK/libvirglrenderer-hukan.a" $ARCHIVES 2>"$WORK/libtool.log" \
  || { cat "$WORK/libtool.log" >&2; exit 1; }

echo "==> Assembling headers + module map"
HEADERS="$WORK/headers/Cvirglrenderer"
mkdir -p "$HEADERS"
cp "$PREFIX"/include/virgl/*.h "$HEADERS/"
cp -R "$PREFIX/include/epoxy" "$HERE/Mesa/include/EGL" "$HERE/Mesa/include/KHR" "$HEADERS/"
cat > "$HEADERS/Cvirglrenderer.h" <<'HEADER'
#include <stdint.h>
#include <sys/uio.h>
#include "virglrenderer.h"
/* The renderer's own GL and EGL calls go through epoxy too, so they reach Mesa's. */
#include <epoxy/gl.h>
#include <epoxy/egl.h>
/* Opaque in the public header, but the transfer calls take one; this is src/virgl_hw.h's layout. */
struct virgl_box {
  uint32_t x, y, z;
  uint32_t w, h, d;
};
HEADER
cat > "$HEADERS/module.modulemap" <<'MODULEMAP'
module Cvirglrenderer {
    header "Cvirglrenderer.h"
    export *
}
MODULEMAP

echo "==> Packaging Cvirglrenderer.xcframework"
rm -rf "$HERE/Cvirglrenderer.xcframework"
xcodebuild -create-xcframework \
  -library "$WORK/libvirglrenderer-hukan.a" -headers "$WORK/headers" \
  -output "$HERE/Cvirglrenderer.xcframework" >/dev/null

echo "==> Done: $HERE/Cvirglrenderer.xcframework (virglrenderer $VIRGLRENDERER_VERSION, libepoxy $EPOXY_VERSION)"
