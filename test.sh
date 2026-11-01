#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DEVELOPER_DIR_PATH="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFTC="$DEVELOPER_DIR_PATH/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
mkdir -p output .module-cache
"$DEVELOPER_DIR_PATH/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" -target arm64-apple-macos14.0 -fobjc-arc -fblocks -isysroot "$SDK" -c Tests/NativeException.m -o output/native-exception.o
SOURCE_FILES=()
for source in Sources/*.swift; do
    if [ "$source" != "Sources/Main.swift" ]; then SOURCE_FILES+=("$source"); fi
done
"$SWIFTC" -swift-version 5 -O -sdk "$SDK" -target arm64-apple-macos14.0 -module-cache-path .module-cache -import-objc-header Tests/NativeException.h "${SOURCE_FILES[@]}" Tests/StorageTests.swift output/native-exception.o -o output/storage-tests
output/storage-tests "$@"
