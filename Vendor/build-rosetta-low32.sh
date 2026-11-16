#!/bin/sh
# Rebuild Resources/hukan-rosetta-low32-x86_64.so and its arm64 stand-in from
# Vendor/rosetta-low32/low32.c, cross-compiled here with zig (Homebrew) for Linux.
#
# The x86_64 library is what a Linux template preloads into every x86_64 process, so Rosetta's
# MAP_32BIT requests land below 2GB (low32.c says why). The preload names it by `$LIB`, which the
# loader spells per architecture, so an arm64 process looks for the same name in the arm64
# directory; the stand-in is an empty library there, without which every arm64 program would print
# that the preload could not be found. Committed assets, like the guest agents.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../Resources"

zig cc -target x86_64-linux-gnu.2.31 -shared -fPIC -O2 -Wall -Werror \
  -o "$OUT/hukan-rosetta-low32-x86_64.so" "$HERE/rosetta-low32/low32.c"
echo '' > "${TMPDIR:-/tmp}/hukan-empty.c"
zig cc -target aarch64-linux-gnu.2.31 -shared -fPIC -O2 \
  -o "$OUT/hukan-rosetta-low32-arm64.so" "${TMPDIR:-/tmp}/hukan-empty.c"
rm -f "${TMPDIR:-/tmp}/hukan-empty.c"
ls -la "$OUT"/hukan-rosetta-low32-*.so
