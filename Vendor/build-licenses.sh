#!/bin/sh
# Write Resources/Licenses for what reaches the app without a Vendor script of its own fetching
# it: the Swift packages linked into the executable, at the commits Package.resolved pins, and
# Zig's standard library, which is compiled into the guest agents, at GuestAgent/zig-version.
# The vendored archives write their own (libgit2, gfxstream, Mesa, the tree-sitter grammars).
#
# Run by hand after a package or Zig bump, like the other scripts here. Needs network and jq.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/licenses.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RESOLVED="$ROOT/hukan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# The packages whose code is linked, by Package.resolved identity. swift-argument-parser is
# resolved too, but only for a SwiftTerm command-line tool the app does not build.
for identity in swiftterm swifttreesitter tree-sitter yoga; do
  pin="$(jq -e --arg id "$identity" '.pins[] | select(.identity == $id)' "$RESOLVED")" \
    || { echo "no pin for $identity in Package.resolved" >&2; exit 1; }
  location="$(echo "$pin" | jq -r .location | sed 's/\.git$//')"
  revision="$(echo "$pin" | jq -r .state.revision)"
  version="$(echo "$pin" | jq -r '.state.version // .state.revision')"
  repo="${location#https://github.com/}"
  echo "==> $repo $version"
  curl -fsSL "https://raw.githubusercontent.com/$repo/$revision/LICENSE" -o "$WORK/LICENSE"
  write_license "$(basename "$repo")" "$version" "$location" "$WORK/LICENSE"
done

ZIG_VERSION="$(cat "$ROOT/GuestAgent/zig-version")"
echo "==> zig $ZIG_VERSION"
curl -fsSL "https://codeberg.org/ziglang/zig/raw/tag/$ZIG_VERSION/LICENSE" -o "$WORK/LICENSE"
write_license zig "$ZIG_VERSION" https://codeberg.org/ziglang/zig "$WORK/LICENSE"
