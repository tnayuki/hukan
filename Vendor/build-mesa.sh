#!/bin/sh
# Rebuild Vendor/Mesa from a pinned Mesa commit: KosmicKrisp, the Vulkan driver a Linux machine's
# GPU is played on. gfxstream (Vendor/build-gfxstream.sh) replays the guest's Vulkan on it, and
# KosmicKrisp turns it into Metal; the guest's OpenGL is its own Zink on top of that Vulkan
# (docs/virtual-machines.md says what that rests on). What comes out is one library the app carries
# in Contents/Frameworks, which gfxstream loads by path in the renderer process, with nothing but
# the system's beneath it:
#
#   libvulkan_kosmickrisp.dylib   the Vulkan driver
#
# Built for the macOS platform, which is what has KosmicKrisp hand out the Metal heaps a guest's
# blobs are shared through, with two patches over the pin: transform feedback and RGB32 texel
# buffers, which the guest's Zink needs for GL 4.x.
#
# Built twice. KosmicKrisp compiles some of its internals from OpenCL C while it builds, which
# needs LLVM; nothing at run time does, so a first configuration with LLVM builds only those
# compilers, and the second, which is what ships, takes them from it and leaves LLVM out — along
# with SPIRV-Tools and zstd, debugging and cache compression the app has no use for.
#
# Like the other archives here this is committed; run it by hand to move the pin. Needs network,
# meson, ninja and, for the first build only, Homebrew's llvm, spirv-llvm-translator, libclc,
# spirv-tools, glslang and bison. MESA_DEPS, a space-separated list of prefixes, replaces the
# Homebrew ones where those are not installed.
set -eu

MESA_COMMIT="fda2a4b55540f77e9b0963500933da7343c58ecc"
MESA_SHA256="66cc9a8c039b33a3fb7f2b224d4581cf8e2e2cc4e0d3bf676fd2d1546832a337"
# arm64 alone, as for the other archives here.
export MACOSX_DEPLOYMENT_TARGET="15.0"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/Mesa"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DEPS="${MESA_DEPS:-}"
if [ -z "$DEPS" ]; then
  for formula in llvm spirv-llvm-translator libclc spirv-tools glslang bison; do
    DEPS="$DEPS $(brew --prefix "$formula")"
  done
fi
for prefix in $DEPS; do
  PATH="$prefix/bin:$PATH"
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/share/pkgconfig:${PKG_CONFIG_PATH:-}"
done
export PATH PKG_CONFIG_PATH
SDKROOT="$(xcrun --show-sdk-path)"
export SDKROOT

echo "==> Mako and PyYAML, for Mesa's generators"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet mako pyyaml packaging
export PATH="$WORK/venv/bin:$PATH"

echo "==> Mesa $MESA_COMMIT"
curl -fsSL "https://gitlab.freedesktop.org/mesa/mesa/-/archive/$MESA_COMMIT/mesa-$MESA_COMMIT.tar.gz" \
  -o "$WORK/mesa.tar.gz"
echo "$MESA_SHA256  $WORK/mesa.tar.gz" | shasum -a 256 -c - >/dev/null
mkdir -p "$WORK/mesa"
tar -xzf "$WORK/mesa.tar.gz" -C "$WORK/mesa" --strip-components 1
patch -d "$WORK/mesa" -p1 --quiet < "$HERE/mesa-kosmickrisp-transform-feedback.patch"
patch -d "$WORK/mesa" -p1 --quiet < "$HERE/mesa-kosmickrisp-rgb32-texel-buffer.patch"

COMMON="--buildtype release -Db_ndebug=true -Dplatforms=macos -Degl=disabled -Dglx=disabled \
  -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dgallium-drivers= \
  -Dvulkan-drivers=kosmickrisp -Dgallium-rusticl=false -Dvideo-codecs= -Dtools= -Dvulkan-layers="

echo "==> The build-time compilers (with LLVM)"
# shellcheck disable=SC2086
meson setup "$WORK/tools-build" "$WORK/mesa" $COMMON -Dllvm=enabled >/dev/null
ninja -C "$WORK/tools-build" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 \
  src/kosmickrisp/clc/kk_clc >/dev/null
mkdir -p "$WORK/tools"
cp "$WORK/tools-build/src/compiler/clc/mesa_clc" "$WORK/tools-build/src/compiler/spirv/vtn_bindgen2" \
  "$WORK/tools-build/src/kosmickrisp/clc/kk_clc" "$WORK/tools/"

echo "==> KosmicKrisp (without LLVM)"
# shellcheck disable=SC2086
PATH="$WORK/tools:$PATH" meson setup "$WORK/build" "$WORK/mesa" $COMMON -Dllvm=disabled \
  -Dmesa-clc=system -Dprecomp-compiler=system -Dspirv-tools=disabled -Dzstd=disabled \
  -Dstrip=true >/dev/null
PATH="$WORK/tools:$PATH" ninja -C "$WORK/build" src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib \
  >/dev/null

echo "==> Assembling Vendor/Mesa"
rm -rf "$OUT"
mkdir -p "$OUT/lib"
lib="$OUT/lib/libvulkan_kosmickrisp.dylib"
cp "$WORK/build/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib" "$lib"
args="-id @rpath/libvulkan_kosmickrisp.dylib"
for path in $(otool -l "$lib" | awk '/LC_RPATH/ { getline; getline; print $2 }'); do
  args="$args -delete_rpath $path"
done
# shellcheck disable=SC2086
install_name_tool $args "$lib" 2>/dev/null
codesign -f -s - "$lib" 2>/dev/null
if otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep -v -E '^(@rpath/libvulkan_kosmickrisp|/usr/lib/|/System/)'; then
  echo "libvulkan_kosmickrisp.dylib depends on something outside the system" >&2
  exit 1
fi

. "$HERE/licenses.sh"
# Most of Mesa is MIT; the Khronos headers compiled into it are Apache-2.0.
cat "$WORK/mesa/licenses/MIT" "$WORK/mesa/licenses/Apache-2.0" > "$WORK/LICENSE"
write_license mesa "$MESA_COMMIT" https://gitlab.freedesktop.org/mesa/mesa "$WORK/LICENSE"

echo "==> Done: $OUT ($(du -sh "$OUT/lib" | cut -f1))"
