#!/bin/bash
# Build InputConfig and include LightHelper in the app bundle.
# Usage: ./build_and_archive.sh [debug|release|archive]

set -e
cd "$(dirname "$0")"

MODE="${1:-debug}"
XCODE_OVERRIDES=()
if [ -n "${INPUTCONFIG_TEAM_ID:-}" ]; then
    XCODE_OVERRIDES+=("DEVELOPMENT_TEAM=${INPUTCONFIG_TEAM_ID}")
fi
if [ -n "${INPUTCONFIG_BUNDLE_ID:-}" ]; then
    XCODE_OVERRIDES+=("PRODUCT_BUNDLE_IDENTIFIER=${INPUTCONFIG_BUNDLE_ID}")
fi
HELPER_SRC="LightHelper/main.swift"
HELPER_ENTITLEMENTS="LightHelper/LightHelper.entitlements"
TOUCHPAD_HELPER_SRC="TouchpadHelper/main.swift"
TOUCHPAD_HELPER_ENTITLEMENTS="TouchpadHelper/TouchpadHelper.entitlements"
STEAM_HELPER_SRC="SteamControllerHelper/main.swift"
STEAM_HELPER_ENTITLEMENTS="SteamControllerHelper/SteamControllerHelper.entitlements"

# Do not kill xcodebuild/XCBBuildService here. That discards incremental
# build state and forces a full rebuild. Only kill them if you hit a
# CreateBuildOperation hang.

# Only rebuild a helper if its source is newer than the binary.
build_helper_if_needed() {
    local src="$1"
    local out="$2"
    local name="$3"
    if [ ! -f "$out" ] || [ "$src" -nt "$out" ]; then
        echo "=== Building $name ==="
        swiftc -O -framework Foundation -framework IOKit "$src" -o "$out"
    fi
}
build_helper_if_needed "$HELPER_SRC" "LightHelper/LightHelper" "LightHelper"
build_helper_if_needed "$TOUCHPAD_HELPER_SRC" "TouchpadHelper/TouchpadHelper" "TouchpadHelper"
build_helper_if_needed "$STEAM_HELPER_SRC" "SteamControllerHelper/SteamControllerHelper" "SteamControllerHelper"

# Pick a real signing identity. Restricted entitlements like
# com.apple.security.device.usb are only honored when the binary is signed by a
# genuine Apple Development/Distribution certificate, not ad-hoc. That is the
# whole reason an ad-hoc helper cannot open the controller from inside the
# sandbox. Prefer an Apple cert; fall back to whatever is available.
SIGN_ID=$(security find-identity -v -p codesigning | grep -oE '"Apple (Development|Distribution)[^"]*"' | head -1 | tr -d '"')
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning | head -1 | grep -oE '"[^"]*"' | tr -d '"')
fi
echo "Signing identity: $SIGN_ID"

# Sign all three helpers in the given Contents/MacOS directory with their own
# entitlements. Each helper is a separate process that opens the controller's
# HID device directly, so under the App Sandbox it needs its own device.usb /
# device.bluetooth entitlement. The main app's entitlement does not extend to a
# child process. This is the step the Debug path used to skip, which left the
# light dead in development builds even though the archive worked.
sign_helpers_in() {
    local dir="$1"
    codesign --force --sign "$SIGN_ID" --entitlements "$HELPER_ENTITLEMENTS" --options runtime "$dir/LightHelper"
    codesign --force --sign "$SIGN_ID" --entitlements "$TOUCHPAD_HELPER_ENTITLEMENTS" --options runtime "$dir/TouchpadHelper"
    codesign --force --sign "$SIGN_ID" --entitlements "$STEAM_HELPER_ENTITLEMENTS" --options runtime "$dir/SteamControllerHelper"
}

if [ "$MODE" = "archive" ]; then
    echo "=== Archiving InputConfig ==="
    xcodebuild -scheme InputConfig \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -skipPackagePluginValidation \
        archive \
        -archivePath build/InputConfig.xcarchive \
        "${XCODE_OVERRIDES[@]}"

    # Copy helpers into the archive and sign them
    MACOS_DIR="build/InputConfig.xcarchive/Products/Applications/InputConfig.app/Contents/MacOS"
    cp LightHelper/LightHelper "$MACOS_DIR/"
    cp TouchpadHelper/TouchpadHelper "$MACOS_DIR/"
    cp SteamControllerHelper/SteamControllerHelper "$MACOS_DIR/"

    echo "=== Signing helpers ==="
    sign_helpers_in "$MACOS_DIR"

    echo "=== Verifying signatures ==="
    codesign -dvv "$MACOS_DIR/LightHelper" 2>&1 | grep -E "Identifier|Authority|Entitlements"
    codesign -dvv "$MACOS_DIR/TouchpadHelper" 2>&1 | grep -E "Identifier|Authority|Entitlements"
    codesign -dvv "$MACOS_DIR/SteamControllerHelper" 2>&1 | grep -E "Identifier|Authority|Entitlements"

    echo "=== Archive ready at build/InputConfig.xcarchive ==="
    echo "Open in Xcode: open build/InputConfig.xcarchive"
elif [ "$MODE" = "install" ]; then
    # Build a Release copy, bundle the signed helpers, and install it to
    # /Applications/InputConfig.app, a stable and properly-signed location.
    # macOS keys Accessibility / Input Monitoring grants to the app's code
    # signature (bundle id + Apple Development cert), which is identical across
    # rebuilds, so the user grants once and it sticks instead of re-prompting
    # for a fresh DerivedData build every time.
    echo "=== Building InputConfig (Release) for install ==="
    xcodebuild -scheme InputConfig \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -skipPackagePluginValidation \
        "${XCODE_OVERRIDES[@]}" \
        build

    SRC=$(find ~/Library/Developer/Xcode/DerivedData/InputConfig-*/Build/Products/Release -name "InputConfig.app" -maxdepth 1 2>/dev/null | head -1)
    if [ -z "$SRC" ]; then echo "Release build not found"; exit 1; fi
    DEST="/Applications/InputConfig.app"
    echo "=== Installing $SRC -> $DEST ==="
    rm -rf "$DEST"
    cp -R "$SRC" "$DEST"

    cp LightHelper/LightHelper "$DEST/Contents/MacOS/"
    cp TouchpadHelper/TouchpadHelper "$DEST/Contents/MacOS/"
    cp SteamControllerHelper/SteamControllerHelper "$DEST/Contents/MacOS/"
    echo "=== Signing helpers ==="
    sign_helpers_in "$DEST/Contents/MacOS"

    # Re-seal the app so its own signature covers the helpers we just added.
    echo "=== Re-signing app bundle ==="
    codesign --force --sign "$SIGN_ID" \
        --entitlements InputConfig/InputConfig.entitlements \
        --options runtime \
        "$DEST"

    echo "=== Verifying ==="
    codesign --verify --strict "$DEST" 2>&1 && echo "  app signature VALID" || echo "  app signature check reported issues"
    codesign -dvv "$DEST/Contents/MacOS/LightHelper" 2>&1 | grep -E "Identifier|flags|Authority=Apple"

    echo "=== Installed: $DEST ==="
    echo "Open: open \"$DEST\""
else
    CONFIG="Debug"
    [ "$MODE" = "release" ] && CONFIG="Release"

    echo "=== Building InputConfig ($CONFIG) ==="
    # Let xcodebuild use all cores. -jobs 1 is only needed for the Xcode GUI,
    # which can hang at CreateBuildOperation; the command-line build does not.
    xcodebuild -scheme InputConfig \
        -configuration "$CONFIG" \
        -destination 'generic/platform=macOS' \
        -skipPackagePluginValidation \
        "${XCODE_OVERRIDES[@]}" \
        build

    # Find and copy helpers into the built app, then sign them so the sandboxed
    # app can spawn them with HID access. The Debug path previously copied
    # unsigned helpers, which the sandbox blocked from opening the controller,
    # so the light went dead in development builds.
    APP=$(find ~/Library/Developer/Xcode/DerivedData/InputConfig-*/Build/Products/$CONFIG -name "InputConfig.app" -maxdepth 1 2>/dev/null | head -1)
    if [ -n "$APP" ]; then
        cp LightHelper/LightHelper "$APP/Contents/MacOS/"
        cp TouchpadHelper/TouchpadHelper "$APP/Contents/MacOS/"
        cp SteamControllerHelper/SteamControllerHelper "$APP/Contents/MacOS/"
        echo "=== Signing helpers ==="
        sign_helpers_in "$APP/Contents/MacOS"
        echo "=== Build complete: $APP ==="
        echo "Run: open \"$APP\""
    fi
fi
