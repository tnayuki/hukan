#!/bin/sh
# Build Resources/rg from a pinned ripgrep source release.
#
# ripgrep produces the file set the panel's filter and its content search read: one process per
# gesture, streamed and killed when the gesture is superseded, holding nothing between them. It
# is bundled rather than depended on, because the cask is only one of the ways hukan arrives —
# the Release zip and a local build are the others — and a formula the user could remove, at a
# prefix that moves with the architecture, is a dependency that fails silently. The bundled copy
# is named by absolute path inside the bundle, the same way the `hukan` CLI beside it is.
#
# Built here rather than downloaded, which is the same call the two xcframeworks make: ripgrep
# publishes a macOS binary and taking it would have been one curl, but then the bytes hukan ships
# are bytes nobody here compiled. The source archive is pinned by tag and by sha256, cargo builds
# it against ripgrep's own lockfile, and the result is a committed static asset — the build is not
# part of xcodebuild, so Rust is a dependency of bumping the version and of nothing else. 31s on
# this machine.
#
# Redistribution needs no notice: ripgrep is dual-licensed MIT / Unlicense, and the Unlicense
# half asks for nothing.
set -eu

VERSION="15.2.0"
SHA256="7605249d3eb0d5f170e3414498e3344e26b1e7a147aec518b57090b80036a562"

HERE="$(cd "$(dirname "$0")" && pwd)"
RESOURCES="$HERE/../Resources"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

url="https://github.com/BurntSushi/ripgrep/archive/refs/tags/$VERSION.tar.gz"
echo "fetching ripgrep $VERSION"
curl -fsSL "$url" -o "$WORK/src.tar.gz"
echo "$SHA256  $WORK/src.tar.gz" | shasum -a 256 -c - >/dev/null
tar xzf "$WORK/src.tar.gz" -C "$WORK"

# `--locked` so the dependency versions are the ones this release was cut against rather than
# whatever crates.io holds today; the default feature set is all hukan asks of it (the walk, the
# ignore rules and a literal search — PCRE2 is an optional feature and stays out).
#
# Whole-program LTO and a single codegen unit, which are worth exactly one thing and it is not
# speed: measured here, they take the stripped binary from 4,239,088 bytes to 3,466,512 and leave
# both jobs hukan asks of it where they were (a whole-home walk 14.5s against 14.4, a literal
# search over a 60,000-file checkout 0.03s either way). Both of those are bound by syscalls and
# the disk, so there is nothing for code generation to win. The build goes from 31s to 1m13s,
# which nobody waits for: this script is run by hand to bump a version. `panic = "abort"` would
# take off another 364KB and is left alone, being a change to the behaviour upstream tests.
echo "building"
(cd "$WORK/ripgrep-$VERSION" \
  && CARGO_PROFILE_RELEASE_LTO=fat \
     CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
     CARGO_PROFILE_RELEASE_DEBUG=false \
     cargo build --release --locked --quiet)

cp "$WORK/ripgrep-$VERSION/target/release/rg" "$RESOURCES/rg"
# Debug symbols are a third of the binary and nothing here reads them.
strip -x "$RESOURCES/rg"
chmod +x "$RESOURCES/rg"
# Ad-hoc, like the app around it: cargo signs with nothing, and an unsigned Mach-O inside a
# signed bundle is what the kernel refuses to exec.
codesign --force --sign - "$RESOURCES/rg"

echo "Resources/rg is $("$RESOURCES/rg" --version | head -1) ($(lipo -archs "$RESOURCES/rg"), $(wc -c < "$RESOURCES/rg") bytes)"
