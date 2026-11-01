#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DEVELOPER_DIR_PATH="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFTC="$DEVELOPER_DIR_PATH/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
DESTINATION="${HARBOR_APP_OUTPUT:-output/Harbor Vault.app}"
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
codesign --force --sign - --options runtime "$APP"
python3 Tools/PublishApp.py "$APP" "$DESTINATION"

