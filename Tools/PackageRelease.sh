#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="output/Harbor Vault.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DESTINATION="output/releases"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/HarborVault-package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/codesign --verify --deep --strict "$APP"
mkdir -p "$DESTINATION"
# Avoid Finder metadata, extended attributes, resource forks, or runtime files.
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP" "$STAGING/Harbor Vault.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Install.txt" <<'NOTE'
Harbor Vault

Drag Harbor Vault.app into Applications, eject this disk image, then open the app.
Requires an Apple silicon Mac running macOS 14 or newer.
This preview is ad-hoc signed and is not Apple-notarized.
If macOS blocks the app, see https://support.apple.com/102445.

Create your own vault on first launch. No vaults or sample personal files are included.
Documentation and updates: https://github.com/arjun1223/HarborVault
NOTE
DMG="$DESTINATION/HarborVault-$VERSION-macOS-arm64.dmg"
/usr/bin/hdiutil create -volname 'Harbor Vault' -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
/usr/bin/hdiutil verify "$DMG"
(cd "$DESTINATION" && /usr/bin/shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)
printf '%s\n' "Created $DMG"
