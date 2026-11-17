#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"
SDK="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
mkdir -p output .module-cache
"$(/usr/bin/xcrun --find clang)" -target arm64-apple-macos14.0 -fobjc-arc -fblocks -isysroot "$SDK" -c Tests/NativeException.m -o output/native-exception.o
SOURCE_FILES=()
for source in Sources/*.swift; do
    if [ "$source" != "Sources/Main.swift" ]; then SOURCE_FILES+=("$source"); fi
done
"$SWIFTC" -swift-version 5 -O -sdk "$SDK" -target arm64-apple-macos14.0 -module-cache-path .module-cache -import-objc-header Tests/NativeException.h "${SOURCE_FILES[@]}" Tests/StorageTests.swift output/native-exception.o -o output/storage-tests
output/storage-tests "$@"
