#!/bin/sh
# Build the three guest agents from GuestAgent/src into DIR (default .build/GuestAgents):
#
#   hukan-guest-agent        macOS, linked against the frameworks the screen is reached through,
#                            for the oldest macOS a template is made from (the guest provisioning
#                            hukan relies on needs 27)
#   hukan-guest-agent.exe    Windows 11 on Arm; a GUI-subsystem binary, so the user half the Task
#                            Scheduler starts at logon opens no console
#   hukan-guest-agent-linux  Linux, static and with no libc, so it runs on whatever distribution a
#                            template is made from with nothing installed for it
#
# One Zig program, cross-compiled here for all three. The app target runs this as a build phase and
# writes straight into the bundle's Resources, so the binaries are never committed — which is only
# safe because the build is reproducible: a guest's agent is replaced at boot whenever it differs
# from the one the app ships, so a build that drifted would replace every guest's agent on every
# rebuild. A file whose bytes would not change is left alone, so a build with nothing new touches
# nothing. ReleaseSafe: a mistake in an agent ends it, and launchd, systemd or the service manager
# brings it back, where the faster modes would carry on past one with whatever memory it left.
# arm64 only, like everything hukan ships.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIR="${1:-$ROOT/.build/GuestAgents}"
mkdir -p "$DIR"

# Xcode runs a build phase with a PATH that has no Homebrew on it. What the environment already
# found comes first — CI installs its own.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
if ! command -v zig >/dev/null 2>&1; then
  echo "error: the guest agents need Zig (brew install zig)" >&2
  exit 1
fi
# Another Zig is other bytes, and other bytes are a new agent in every guest at its next boot, so
# the version is pinned (GuestAgent/zig-version, which CI installs too) and a different one says so.
wanted="$(cat "$ROOT/GuestAgent/zig-version")"
if [ "$(zig version)" != "$wanted" ]; then
  echo "warning: the guest agents are pinned to Zig $wanted but this is $(zig version); every guest's agent will be replaced" >&2
fi
# Xcode exports the app's own deployment target and SDK, which would be read in place of the
# agent's.
unset MACOSX_DEPLOYMENT_TARGET SDKROOT

SRC="$ROOT/GuestAgent/src"
cd "$SRC"

# `zig build-exe` compiles from scratch every time — its cache is the build system's, which this
# does without — so the three builds are skipped when nothing they are made from has moved: the
# source, this script, Zig and the SDK. The stamp sits outside DIR, which is the app's Resources.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
inputs="$( (zig version; echo "$SDK"; cat "$HERE/$(basename "$0")"; find . -type f | LC_ALL=C sort | xargs shasum) | shasum | cut -d' ' -f1)"
stamps="$ROOT/.build/GuestAgents-stamps"
stamp="$stamps/$(printf '%s' "$DIR" | shasum | cut -d' ' -f1)"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$inputs" ] &&
  [ -f "$DIR/hukan-guest-agent" ] && [ -f "$DIR/hukan-guest-agent.exe" ] && [ -f "$DIR/hukan-guest-agent-linux" ]; then
  exit 0
fi

# place moves a freshly built binary over OUT, unless OUT already holds those bytes.
place() {
  if cmp -s "$1" "$2"; then rm -f "$1"; else mv -f "$1" "$2"; fi
}

build() {
  zig build-exe main.zig -O ReleaseSafe -fstrip --name hukan-guest-agent "$@"
}

# The Objective-C half is Xcode's clang's to compile: Zig's carries its own libc headers, which the
# SDK's frameworks do not build against. Zig links it, against the SDK's frameworks.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
xcrun clang -c -O2 -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 macos/screen.m -o "$WORK/screen.o"
out="$DIR/hukan-guest-agent"
build "$WORK/screen.o" -target aarch64-macos.27.0 -lc --sysroot "$SDK" -F/System/Library/Frameworks \
  -framework AppKit -framework ApplicationServices -framework Carbon \
  -femit-bin="$out.new"
# Ad-hoc, which is all a binary launchd runs in a throwaway guest needs.
codesign -f -s - "$out.new" 2>/dev/null
place "$out.new" "$out"

out="$DIR/hukan-guest-agent.exe"
build -target aarch64-windows --subsystem windows -femit-bin="$out.new"
place "$out.new" "$out"

out="$DIR/hukan-guest-agent-linux"
build -target aarch64-linux -femit-bin="$out.new"
place "$out.new" "$out"

mkdir -p "$stamps"
printf '%s' "$inputs" > "$stamp"
