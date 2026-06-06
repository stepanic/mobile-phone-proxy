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

# Version from git tag (fallback to short SHA) unless overridden via VERSION=...
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"

mkdir -p dist
GOOS=windows GOARCH="$ARCH" go build -trimpath \
  -ldflags "-s -w -X main.version=$VERSION" -o "$OUT" ./
echo "built $OUT ($VERSION)"
file "$OUT" 2>/dev/null || true
