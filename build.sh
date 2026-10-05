#!/bin/zsh
# Build, sign and bundle LetMeTalk.app. Usage: ./build.sh [--install]
set -euo pipefail
cd "${0:A:h}"

APP=build/LetMeTalk.app
# Sign with your Developer ID if you have one; otherwise ad-hoc ("-"), which is fine for your own Mac.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY="Developer ID Application"
else
    IDENTITY="-"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -target "$(uname -m)-apple-macos14" LetMeTalk.swift -o "$APP/Contents/MacOS/LetMeTalk"
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
