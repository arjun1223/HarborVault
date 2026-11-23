#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
identity="$(bash Tools/SigningIdentity.sh)"
if [ "$identity" = "-" ]; then
    echo "SKIP: certificate-backed signing is required for the cross-build Keychain regression test."
    exit 0
fi
sdk="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
swiftc="$(/usr/bin/xcrun --find swiftc)"
fixture="$(mktemp -d "${TMPDIR:-/private/tmp/}harbor-signing-test.XXXXXX")"
local_id="$(uuidgen)"
portable_id="$(uuidgen)"
cleanup() {
    if [ -x "$fixture/reader-one" ]; then "$fixture/reader-one" cleanup "$local_id" "$portable_id"; fi
    rm -rf "$fixture"
}
trap cleanup EXIT
for version in one two; do
    printf 'let fixtureBuildMarker = "%s"\n' "$version" > "$fixture/BuildMarker.swift"
    "$swiftc" -swift-version 5 -O -sdk "$sdk" -target arm64-apple-macos14.0 -module-cache-path .module-cache \
        Sources/LocalVaultHistory.swift Sources/PortableHistory.swift Tests/SigningHistoryProbe.swift \
        "$fixture/BuildMarker.swift" -o "$fixture/reader-$version"
    codesign --force --sign "$identity" --identifier com.harborvault.history-regression --options runtime "$fixture/reader-$version"
done
first_hash="$(codesign -d --verbose=4 "$fixture/reader-one" 2>&1 | awk -F= '/^CDHash=/ { print $2 }')"
second_hash="$(codesign -d --verbose=4 "$fixture/reader-two" 2>&1 | awk -F= '/^CDHash=/ { print $2 }')"
if [ -z "$first_hash" ] || [ "$first_hash" = "$second_hash" ]; then
    echo "FAIL: the fixture builds must have different code hashes."
    exit 1
fi
echo "PASS: fixture builds have different code hashes."
"$fixture/reader-one" write "$local_id" "$portable_id"
"$fixture/reader-two" read "$local_id" "$portable_id"
"$fixture/reader-one" read "$local_id" "$portable_id"
