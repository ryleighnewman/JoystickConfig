#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED="$ROOT/build/DerivedData"
CONFIGURATION="${INPUTCONFIG_CONFIGURATION:-Debug}"
TEAM_ID="${INPUTCONFIG_TEAM_ID:-}"
EXPECTED_BUNDLE_ID="${INPUTCONFIG_BUNDLE_ID:-com.ryokojima.inputconfig.local}"
APP="$DERIVED/Build/Products/$CONFIGURATION/InputConfig.app"
ACTION="${1:-run}"

typeset -a XCODE_OVERRIDES
XCODE_OVERRIDES=()
if [[ -n "$TEAM_ID" ]]; then
  XCODE_OVERRIDES+=("DEVELOPMENT_TEAM=$TEAM_ID")
fi
if [[ -n "${INPUTCONFIG_BUNDLE_ID:-}" ]]; then
  XCODE_OVERRIDES+=("PRODUCT_BUNDLE_IDENTIFIER=$EXPECTED_BUNDLE_ID")
fi

build_helpers() {
  /usr/bin/xcrun swiftc -O -framework Foundation -framework IOKit "$ROOT/LightHelper/main.swift" -o "$ROOT/LightHelper/LightHelper"
  /usr/bin/xcrun swiftc -O -framework Foundation -framework IOKit "$ROOT/TouchpadHelper/main.swift" -o "$ROOT/TouchpadHelper/TouchpadHelper"
  /usr/bin/xcrun swiftc -O -framework Foundation -framework IOKit "$ROOT/SteamControllerHelper/main.swift" -o "$ROOT/SteamControllerHelper/SteamControllerHelper"
}

identity() {
  /usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/"Apple Development/{print $2; exit}'
}

sign_bundle() {
  local app="$1"
  local sign_id
  sign_id="$(identity)"
  if [[ -z "$sign_id" ]]; then
    print -u2 "No code-signing identity is available. Open Xcode > Settings > Accounts, or set INPUTCONFIG_TEAM_ID to your team."
    return 65
  fi
  /bin/cp "$ROOT/LightHelper/LightHelper" "$app/Contents/MacOS/LightHelper"
  /bin/cp "$ROOT/TouchpadHelper/TouchpadHelper" "$app/Contents/MacOS/TouchpadHelper"
  /bin/cp "$ROOT/SteamControllerHelper/SteamControllerHelper" "$app/Contents/MacOS/SteamControllerHelper"
  /usr/bin/codesign --force --sign "$sign_id" --options runtime --entitlements "$ROOT/LightHelper/LightHelper.entitlements" "$app/Contents/MacOS/LightHelper"
  /usr/bin/codesign --force --sign "$sign_id" --options runtime --entitlements "$ROOT/TouchpadHelper/TouchpadHelper.entitlements" "$app/Contents/MacOS/TouchpadHelper"
  /usr/bin/codesign --force --sign "$sign_id" --options runtime --entitlements "$ROOT/SteamControllerHelper/SteamControllerHelper.entitlements" "$app/Contents/MacOS/SteamControllerHelper"
  /usr/bin/codesign --force --sign "$sign_id" --options runtime --entitlements "$ROOT/InputConfig/InputConfig.entitlements" "$app"
}

build_app() {
  /bin/mkdir -p "$ROOT/build"
  build_helpers
  /usr/bin/xcodebuild -project "$ROOT/InputConfig.xcodeproj" -scheme InputConfig \
    -configuration "$CONFIGURATION" -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" CODE_SIGN_STYLE=Automatic "${XCODE_OVERRIDES[@]}" \
    -allowProvisioningUpdates build
  sign_bundle "$APP"
}

verify_app() {
  local app="${1:-$APP}"
  /usr/bin/codesign --verify --strict --deep "$app"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$EXPECTED_BUNDLE_ID" ]]
  if [[ -n "$TEAM_ID" ]]; then
    /usr/bin/codesign -dvvv "$app" 2>&1 | /usr/bin/grep "TeamIdentifier=$TEAM_ID" >/dev/null
  fi
  /usr/bin/codesign -d --entitlements - "$app" 2>&1 | /usr/bin/grep 'com.apple.security.device.usb' >/dev/null
  if /usr/bin/codesign -d --entitlements - "$app" 2>&1 | /usr/bin/grep 'com.apple.security.app-sandbox' >/dev/null; then
    print -u2 "main app must remain unsandboxed so inputconfigctl can share Application Support"
    return 66
  fi
  for helper in LightHelper TouchpadHelper SteamControllerHelper; do
    /usr/bin/codesign --verify --strict "$app/Contents/MacOS/$helper"
    /usr/bin/codesign -d --entitlements - "$app/Contents/MacOS/$helper" 2>&1 | /usr/bin/grep 'com.apple.security.app-sandbox' >/dev/null
    /usr/bin/codesign -d --entitlements - "$app/Contents/MacOS/$helper" 2>&1 | /usr/bin/grep 'com.apple.security.device.usb' >/dev/null
    /usr/bin/codesign -d --entitlements - "$app/Contents/MacOS/$helper" 2>&1 | /usr/bin/grep 'com.apple.security.device.bluetooth' >/dev/null
  done
  print "verified: $app"
}

case "$ACTION" in
  build)
    build_helpers
    /usr/bin/xcodebuild -project "$ROOT/InputConfig.xcodeproj" -scheme InputConfig \
      -configuration "$CONFIGURATION" -destination 'generic/platform=macOS' \
      -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=- \
      "${XCODE_OVERRIDES[@]}" build
    ;;
  run)
    build_app
    verify_app
    /usr/bin/open "$APP"
    ;;
  debug)
    build_app
    verify_app
    /usr/bin/lldb --one-line run "$APP/Contents/MacOS/InputConfig"
    ;;
  logs)
    /usr/bin/log stream --style compact --predicate 'process == "InputConfig" OR process == "TouchpadHelper" OR process == "LightHelper" OR process == "SteamControllerHelper"'
    ;;
  telemetry)
    /usr/bin/log show --last 30m --style compact --predicate 'process == "InputConfig"' | /usr/bin/tail -n 500
    ;;
  verify)
    verify_app "${2:-$APP}"
    ;;
  install)
    CONFIGURATION=Release
    APP="$DERIVED/Build/Products/Release/InputConfig.app"
    build_app
    verify_app
    /usr/bin/ditto "$APP" /Applications/InputConfig.app
    verify_app /Applications/InputConfig.app
    print "installed: /Applications/InputConfig.app"
    ;;
  *)
    print -u2 "usage: $0 {build|run|debug|logs|telemetry|verify|install}"
    exit 64
    ;;
esac
