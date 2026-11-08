#!/bin/sh
# Build Resources/hukan-guest-agent from GuestAgent/main.swift.
#
# The agent runs inside a macOS guest, not in hukan, so it is not part of the app target: it is
# compiled here into a committed static asset, the way rg is, and hukan copies it into a template
# while making it. arm64 only, like everything hukan ships, and for the oldest macOS a template is
# made from (the guest provisioning hukan relies on needs 27, so nothing older reaches it).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
OUT="$ROOT/Resources/hukan-guest-agent"

xcrun swiftc -O -target arm64-apple-macos27.0 -o "$OUT" "$ROOT/GuestAgent/main.swift"
strip -x "$OUT"
# Ad-hoc, which is all a binary launchd runs in a throwaway guest needs.
codesign -f -s - "$OUT"
ls -la "$OUT"
