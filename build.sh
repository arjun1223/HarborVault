#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"
SDK="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
DESTINATION="${HARBOR_APP_OUTPUT:-output/Harbor Vault.app}"
SIGNING_IDENTITY="$(bash Tools/SigningIdentity.sh)"
APP="output/.Harbor-build-$$-$RANDOM.app"
trap 'if [ -d "$APP" ]; then rm -rf "$APP"; fi' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .module-cache
"$SWIFTC" -sdk "$SDK" -module-cache-path .module-cache Tools/MakeIcon.swift -o output/make-icon
output/make-icon output/HarborVault.iconset
"$SWIFTC" -swift-version 5 -O -sdk "$SDK" -target arm64-apple-macos14.0 -module-cache-path .module-cache Sources/*.swift -o "$APP/Contents/MacOS/HarborVault"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/"
cp -R Resources/Licenses "$APP/Contents/Resources/"
if [ -f README.md ]; then cp README.md "$APP/Contents/Resources/README.md"; fi
if [ -f output/HarborVault.icns ]; then cp output/HarborVault.icns "$APP/Contents/Resources/HarborVault.icns"; fi
codesign --force --sign "$SIGNING_IDENTITY" --identifier com.harborvault.mac --options runtime "$APP"
python3 Tools/PublishApp.py "$APP" "$DESTINATION"

