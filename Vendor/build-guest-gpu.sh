#!/bin/sh
# Rebuild GuestAgent/src/linux/gpu/libvulkan_gfxstream-{aarch64,x86_64}.so from a pinned Mesa
# commit: the Vulkan driver a Linux guest's GPU is reached through, for arm64 and for what Rosetta
# runs there (Unity's editor is x86_64 and loads Mesa, and so a driver, of its own architecture). Ubuntu's Mesa carries a gfxstream driver too, but
# one too old for Zink (it does not pass robustness2's nullDescriptor through before 26.3) and
# without what a dma-buf shared with the desktop needs (Vendor/mesa-gfxstream-guest.patch says
# what). The guest's own Zink, Ubuntu's, runs on it.
#
# Built in Ubuntu 24.04 containers (Apple's `container`; the amd64 one runs under Rosetta), the
# oldest release a template is made from, so the libraries it links are there on every newer one. The guest agent carries the
# result and puts it in place (GuestAgent/src/linux/gpu.zig), so a new driver needs no template.
#
# Like the other archives here this is committed; run it by hand to move the pin. Needs network and
# Apple's `container`.
set -eu

MESA_COMMIT="df1275b06a309052cc7425a37292b3c1df4c2fbc"
MESA_SHA256="73dc8b614ee8654a8dcf818c573b886890d94b0ddc1a8e7e403bee629741e68a"
IMAGE="ubuntu:24.04"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../GuestAgent/src/linux/gpu"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Mesa $MESA_COMMIT"
curl -fsSL "https://gitlab.freedesktop.org/mesa/mesa/-/archive/$MESA_COMMIT/mesa-$MESA_COMMIT.tar.gz" \
  -o "$WORK/mesa.tar.gz"
echo "$MESA_SHA256  $WORK/mesa.tar.gz" | shasum -a 256 -c - >/dev/null
cp "$HERE/mesa-gfxstream-guest.patch" "$WORK/"

cat > "$WORK/build.sh" <<'EOF'
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates python3-pip ninja-build pkg-config \
  python3-mako python3-yaml bison flex glslang-tools gcc g++ patch libdrm-dev libexpat1-dev \
  zlib1g-dev libzstd-dev libx11-dev libx11-xcb-dev libxcb1-dev libxcb-dri3-dev libxcb-present-dev \
  libxcb-sync-dev libxcb-shm0-dev libxcb-xfixes0-dev libxcb-randr0-dev \
  libxshmfence-dev libxrandr-dev libxext-dev libxfixes-dev libudev-dev libwayland-dev \
  wayland-protocols libwayland-bin >/dev/null
# No xcb-keysyms: Mesa takes it only if it is there, for a debugging hotkey, and a driver linked to
# it needs a library an amd64 guest does not have.
# Mesa main needs a newer meson than 24.04's.
pip3 install -q --break-system-packages 'meson>=1.4'
mkdir /build && cd /build
tar -xzf /work/mesa.tar.gz --strip-components 1
patch -p1 --quiet < /work/mesa-gfxstream-guest.patch
meson setup out -Dbuildtype=release -Dvulkan-drivers=gfxstream -Dgallium-drivers= \
  -Dplatforms=x11,wayland -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false \
  -Dgles1=disabled -Dgles2=disabled -Dllvm=disabled -Dvideo-codecs= -Dvalgrind=disabled \
  -Dlibunwind=disabled >/dev/null
ninja -C out >/dev/null
cp out/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so "/work/libvulkan_gfxstream-$(uname -m).so"
strip "/work/libvulkan_gfxstream-$(uname -m).so"
EOF

for arch in arm64 amd64; do
  echo "==> Building in $IMAGE ($arch)"
  # A container's 1 GB default starves Mesa's C++ compiles until the container stops answering.
  container run --rm --arch "$arch" --cpus 8 --memory 8g --volume "$WORK:/work" "$IMAGE" \
    sh /work/build.sh
done

mkdir -p "$OUT"
cp "$WORK/libvulkan_gfxstream-aarch64.so" "$WORK/libvulkan_gfxstream-x86_64.so" "$OUT/"

. "$HERE/licenses.sh"
tar -xzf "$WORK/mesa.tar.gz" -C "$WORK" "mesa-$MESA_COMMIT/licenses/MIT" "mesa-$MESA_COMMIT/licenses/Apache-2.0"
cat "$WORK/mesa-$MESA_COMMIT/licenses/MIT" "$WORK/mesa-$MESA_COMMIT/licenses/Apache-2.0" > "$WORK/LICENSE"
write_license mesa-guest "$MESA_COMMIT" https://gitlab.freedesktop.org/mesa/mesa "$WORK/LICENSE"

echo "==> Done:"
du -h "$OUT"/libvulkan_gfxstream-*.so
