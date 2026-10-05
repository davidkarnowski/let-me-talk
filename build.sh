#!/bin/zsh
# Build, sign and bundle LetMeTalk.app. Usage: ./build.sh [--install]
set -euo pipefail
cd "${0:A:h}"

APP=build/LetMeTalk.app
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -target arm64-apple-macos14 LetMeTalk.swift -o "$APP/Contents/MacOS/LetMeTalk"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x LetMeTalk || true
    rm -rf /Applications/LetMeTalk.app
    cp -R "$APP" /Applications/
    open /Applications/LetMeTalk.app
    echo "Installed and launched /Applications/LetMeTalk.app"
fi
