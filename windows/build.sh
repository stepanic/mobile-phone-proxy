#!/usr/bin/env bash
# Cross-compile the Windows proxy from any OS (macOS/Linux). No Windows machine
# needed — Go links a fully static .exe with no runtime dependency.
#
# Usage: ./build.sh            # builds dist/proxy.exe (windows/amd64)
#        ./build.sh arm64      # builds dist/proxy-arm64.exe (windows/arm64)
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${1:-amd64}"
OUT="dist/proxy.exe"
[[ "$ARCH" == "arm64" ]] && OUT="dist/proxy-arm64.exe"

mkdir -p dist
GOOS=windows GOARCH="$ARCH" go build -trimpath -ldflags "-s -w" -o "$OUT" ./
echo "built $OUT"
file "$OUT" 2>/dev/null || true
