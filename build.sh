#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain MAJOR.MINOR.PATCH" >&2
    exit 2
fi
APP="${GATEWAY_APP_OUTPUT:-$PWD/dist/Gemini Gateway.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macosx13.0 Sources/Core.swift Sources/Relay.swift Sources/Launcher.swift Sources/Session.swift Sources/VPN.swift Sources/App.swift -o "$APP/Contents/MacOS/GeminiGateway"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GeminiGateway</string>
<key>CFBundleIdentifier</key><string>local.geminigateway.mac</string>
<key>CFBundleName</key><string>Gemini Gateway</string>
<key>CFBundleDisplayName</key><string>Gemini Gateway</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Antigravity Gateway Login</string><key>CFBundleTypeRole</key><string>Viewer</string><key>CFBundleURLSchemes</key><array><string>antigravity</string><string>antigravity-ide</string></array></dict></array>
<key>NSHumanReadableCopyright</key><string>Local, source-available build. No third-party gateway code.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "$APP"
