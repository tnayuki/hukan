#!/bin/sh
# Build Resources/hukan-guest-agent.exe from GuestAgent/Windows.
#
# C# on .NET Framework 4.8.1, which Windows 11 on Arm has built in, so the guest needs nothing
# installed for it, and the compiler's output is the same wherever it runs: this builds on the Mac
# with the .NET SDK and no Windows anywhere. PlatformTarget is ARM64 in the project, because AnyCPU
# runs under x64 emulation there.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

dotnet build "$ROOT/GuestAgent/Windows/hukan-guest-agent.csproj" -c Release -o "$WORK/out" \
  -p:BaseIntermediateOutputPath="$WORK/obj/" --nologo -v quiet
cp "$WORK/out/hukan-guest-agent.exe" "$ROOT/Resources/hukan-guest-agent.exe"
rm -rf "$ROOT/GuestAgent/Windows/obj" "$ROOT/GuestAgent/Windows/bin"
ls -la "$ROOT/Resources/hukan-guest-agent.exe"
