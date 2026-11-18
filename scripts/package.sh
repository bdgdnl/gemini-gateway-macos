#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${GATEWAY_APP_OUTPUT:-$PWD/dist/Gemini Gateway.app}"
DEST="${GATEWAY_PACKAGE_DIR:-$PWD/dist}"
test -x "$APP/Contents/MacOS/GeminiGateway"
codesign --verify --strict "$APP"
mkdir -p "$DEST"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DEST/Gemini-Gateway-macOS-arm64.zip"
cd "$DEST"
shasum -a 256 Gemini-Gateway-macOS-arm64.zip > SHA256SUMS
echo "$DEST/Gemini-Gateway-macOS-arm64.zip"
