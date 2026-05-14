#!/bin/bash
# Build JoystickConfig and include LightHelper in the app bundle.
# Usage: ./build_and_archive.sh [debug|release|archive]

set -e
cd "$(dirname "$0")"

MODE="${1:-debug}"
HELPER_SRC="LightHelper/main.swift"
HELPER_ENTITLEMENTS="LightHelper/LightHelper.entitlements"

# Kill any stuck build processes first
killall xcodebuild 2>/dev/null || true
killall XCBBuildService 2>/dev/null || true
sleep 1

echo "=== Building LightHelper ==="
swiftc -O -framework Foundation -framework IOKit "$HELPER_SRC" -o LightHelper/LightHelper

# Get the team ID from the main app's signing
TEAM_ID=$(security find-identity -v -p codesigning | grep "Apple Distribution\|Developer ID\|3rd Party Mac Developer" | head -1 | grep -o '"[^"]*"' | tr -d '"' | head -1)
if [ -z "$TEAM_ID" ]; then
    TEAM_ID=$(security find-identity -v -p codesigning | head -1 | grep -o '"[^"]*"' | tr -d '"')
fi
echo "Signing identity: $TEAM_ID"

if [ "$MODE" = "archive" ]; then
    echo "=== Archiving JoystickConfig ==="
    xcodebuild -scheme JoystickConfig \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        -jobs 1 \
        -skipPackagePluginValidation \
        archive \
        -archivePath build/JoystickConfig.xcarchive

    # Copy LightHelper into the archive and sign it
    MACOS_DIR="build/JoystickConfig.xcarchive/Products/Applications/JoystickConfig.app/Contents/MacOS"
    cp LightHelper/LightHelper "$MACOS_DIR/"

    echo "=== Signing LightHelper ==="
    codesign --force --sign "$TEAM_ID" \
        --entitlements "$HELPER_ENTITLEMENTS" \
        --options runtime \
        "$MACOS_DIR/LightHelper"

    echo "=== Verifying signatures ==="
    codesign -dvv "$MACOS_DIR/LightHelper" 2>&1 | grep -E "Identifier|Authority|Entitlements"

    echo "=== Archive ready at build/JoystickConfig.xcarchive ==="
    echo "Open in Xcode: open build/JoystickConfig.xcarchive"
else
    CONFIG="Debug"
    [ "$MODE" = "release" ] && CONFIG="Release"

    echo "=== Building JoystickConfig ($CONFIG) ==="
    xcodebuild -scheme JoystickConfig \
        -configuration "$CONFIG" \
        -destination 'platform=macOS,arch=arm64' \
        -jobs 1 \
        -skipPackagePluginValidation \
        build

    # Find and copy LightHelper into the built app
    APP=$(find ~/Library/Developer/Xcode/DerivedData/JoystickConfig-*/Build/Products/$CONFIG -name "JoystickConfig.app" -maxdepth 1 2>/dev/null | head -1)
    if [ -n "$APP" ]; then
        cp LightHelper/LightHelper "$APP/Contents/MacOS/"
        echo "=== Build complete: $APP ==="
        echo "Run: open \"$APP\""
    fi
fi
