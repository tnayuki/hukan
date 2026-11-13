#!/bin/sh
# Build Resources/hukan-guest-agent-linux from GuestAgent/Go.
#
# Go, cross-compiled here for an arm64 Linux guest: static (no cgo), so it runs on whatever
# distribution a template is made from with nothing installed for it. Like the other two agents it
# is a committed asset rather than part of the app target, and hukan puts it into a template while
# making it. The protocol lives in GuestAgent/Go/agent, apart from how Linux is reached, so an
# agent for another system written in Go starts from the same package.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
OUT="$ROOT/Resources/hukan-guest-agent-linux"

cd "$ROOT/GuestAgent/Go"
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -buildvcs=false -ldflags="-s -w" \
  -o "$OUT" ./cmd/hukan-guest-agent
ls -la "$OUT"
