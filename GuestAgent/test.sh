#!/bin/sh
# Test the guest agents on this Mac: build all three — which is also what holds the Windows
# structures to their sizes, checked at compile time — then run every test that can run here
# (src/tests.zig), the macOS screen's through the agent just built, as a child of it.
# CI runs this; so can anyone, from anywhere.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Formatting first, the way swift-format gates the app: zig fmt's own, nothing to configure.
zig fmt --check "$HERE/src"
sh "$ROOT/Vendor/build-guest-agents.sh" "$WORK/agents"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
cd "$HERE/src"
xcrun clang -c -O2 -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 macos/screen.m -o "$WORK/screen.o"
HUKAN_AGENT="$WORK/agents/hukan-guest-agent" zig test tests.zig "$WORK/screen.o" -lc \
  --sysroot "$SDK" -F/System/Library/Frameworks \
  -framework AppKit -framework ApplicationServices -framework Carbon
