#!/bin/sh
# Rebuild Vendor/Mesa from a pinned Mesa commit: the OpenGL a Linux machine's GPU is played on.
#
# virglrenderer replays a guest's OpenGL on an OpenGL of this Mac's, and macOS's own stops at 4.1
# with no compute shaders. Mesa's Zink turns OpenGL into Vulkan and KosmicKrisp turns Vulkan into
# Metal, and together they offer 4.6 (docs/virtual-machines.md says what that rests on). What
# comes out is four libraries the app carries in Contents/Frameworks, all loaded by the renderer
# process alone and nothing but the system's beneath them:
#
#   libEGL.1.dylib                the API the renderer makes its contexts with (surfaceless)
#   libgallium-<version>.dylib    Zink, and the rest of Mesa's GL
#   libvulkan_kosmickrisp.dylib   the Vulkan driver
#   libvulkan.1.dylib             a few lines in place of the Vulkan loader (mesa-vulkan-shim.c)
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

# Zink is Objective-C in part on macOS, and nothing in this configuration brings libobjc in.
COMMON="--buildtype release -Db_ndebug=true -Dplatforms= -Degl=enabled -Dglx=disabled \
  -Dgallium-drivers=zink -Dvulkan-drivers=kosmickrisp -Dgallium-rusticl=false -Dvideo-codecs= \
  -Dtools= -Dvulkan-layers= -Dc_link_args=-lobjc -Dcpp_link_args=-lobjc"

echo "==> The build-time compilers (with LLVM)"
# shellcheck disable=SC2086
meson setup "$WORK/tools-build" "$WORK/mesa" $COMMON -Dllvm=enabled >/dev/null
ninja -C "$WORK/tools-build" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 \
  src/kosmickrisp/clc/kk_clc >/dev/null
mkdir -p "$WORK/tools"
cp "$WORK/tools-build/src/compiler/clc/mesa_clc" "$WORK/tools-build/src/compiler/spirv/vtn_bindgen2" \
  "$WORK/tools-build/src/kosmickrisp/clc/kk_clc" "$WORK/tools/"

echo "==> Zink, KosmicKrisp and EGL (without LLVM)"
# The prefix is never installed to: it is only where Mesa would look for a drirc, which it does not
# need, and the libraries are copied out of DESTDIR.
# shellcheck disable=SC2086
PATH="$WORK/tools:$PATH" meson setup "$WORK/build" "$WORK/mesa" $COMMON --prefix /opt/hukan-mesa \
  -Dopengl=true -Dgles1=disabled -Dgles2=disabled -Dllvm=disabled -Dmesa-clc=system \
  -Dprecomp-compiler=system -Dspirv-tools=disabled -Dzstd=disabled -Dstrip=true >/dev/null
PATH="$WORK/tools:$PATH" ninja -C "$WORK/build" >/dev/null
DESTDIR="$WORK/install" ninja -C "$WORK/build" install >/dev/null
INSTALLED="$WORK/install/opt/hukan-mesa"

echo "==> The Vulkan loader's stand-in"
clang -dynamiclib -O2 -arch arm64 -o "$WORK/libvulkan.1.dylib" "$HERE/mesa-vulkan-shim.c" \
  -install_name @rpath/libvulkan.1.dylib -L"$INSTALLED/lib" -lvulkan_kosmickrisp

echo "==> Assembling Vendor/Mesa"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
GALLIUM="$(basename "$(ls "$INSTALLED"/lib/libgallium-*.dylib)")"
cp "$INSTALLED/lib/libEGL.1.dylib" "$INSTALLED/lib/$GALLIUM" \
  "$INSTALLED/lib/libvulkan_kosmickrisp.dylib" "$WORK/libvulkan.1.dylib" "$OUT/lib/"
# Each finds the others beside it, wherever the bundle is: their install names and references
# become @rpath ones, and @loader_path is on each one's run path. Zink dlopens
# @rpath/libvulkan.1.dylib, which that run path answers too.
for lib in "$OUT"/lib/*.dylib; do
  name="$(basename "$lib")"
  args="-id @rpath/$name -add_rpath @loader_path"
  # Zink's build puts the Vulkan loader's usual directory on its run path (/usr/local/lib), where
  # some other libvulkan.1.dylib may well be found before the one beside it.
  for path in $(otool -l "$lib" | awk '/LC_RPATH/ { getline; getline; print $2 }'); do
    args="$args -delete_rpath $path"
  done
  for dep in $(otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep -E "^(/opt/hukan-mesa|$WORK)/" || true); do
    args="$args -change $dep @rpath/$(basename "$dep")"
  done
  # shellcheck disable=SC2086
  install_name_tool $args "$lib" 2>/dev/null
  codesign -f -s - "$lib" 2>/dev/null
  if otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep -v -E '^(@rpath/|/usr/lib/|/System/)'; then
    echo "$name still depends on something outside the system and itself" >&2
    exit 1
  fi
done
# libepoxy, inside virglrenderer, is built against these (Vendor/build-virglrenderer.sh).
cp -R "$INSTALLED/include/EGL" "$INSTALLED/include/KHR" "$OUT/include/"

. "$HERE/licenses.sh"
# Most of Mesa is MIT; the Khronos headers compiled into it are Apache-2.0.
cat "$WORK/mesa/licenses/MIT" "$WORK/mesa/licenses/Apache-2.0" > "$WORK/LICENSE"
write_license mesa "$MESA_COMMIT" https://gitlab.freedesktop.org/mesa/mesa "$WORK/LICENSE"

echo "==> Done: $OUT ($(du -sh "$OUT/lib" | cut -f1))"
