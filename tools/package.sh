#!/usr/bin/env bash
# package.sh — assemble the final Apple product.
#
# Mental model (docs/upi-app-spec.md "Build & Packaging Pipeline"):
#   Tauri builds the host .app (and signs it once).  This script then:
#     1. embeds build/UPIInstrument.appex into the .app's PlugIns/
#     2. signs the .appex with its OWN entitlements (never --deep)
#     3. re-signs the .app over the final contents (nested code signed first)
#     4. builds a .pkg (App Store) and/or .dmg (direct), then notarizes
#
# Phase 0 status: Tauri is not wired yet, so this also accepts the XcodeGen
# host (UPIHost.app) as the container and does an ad-hoc sign by default.
#
# Env:
#   APP_PATH         path to the host .app          (default: build/UPIHost.app)
#   APPEX_PATH       path to the built .appex        (default: build/UPIInstrument.appex)
#   SIGN_IDENTITY    codesign identity               (default: "-"  = ad-hoc)
#   APP_ENTITLEMENTS host entitlements plist         (default: native/UPIHost/UPIHost.entitlements)
#   APPEX_ENTITLEMENTS extension entitlements plist  (default: native/UPIInstrument/UPIInstrument.entitlements)
#   MAKE_DMG=1       also produce build/UPI.dmg
#   MAKE_PKG=1       also produce build/UPI.pkg (needs a "3rd Party Mac Developer Installer" identity)
#   NOTARYTOOL_PROFILE  keychain profile name for `xcrun notarytool` (direct dist)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Prefer the Tauri-built app; fall back to the XcodeGen dev host.
DEFAULT_APP="src-tauri/target/release/bundle/macos/UPI.app"
[[ -d "$DEFAULT_APP" ]] || DEFAULT_APP="build/UPIHost.app"

APP_PATH="${APP_PATH:-$DEFAULT_APP}"
APPEX_PATH="${APPEX_PATH:-build/UPIInstrument.appex}"

# Signing identity, in priority order:
#   1. SIGN_IDENTITY env (explicit, e.g. a Developer ID for release)
#   2. native/.signing-identity  (git-ignored; set by tools/set-signing-identity.sh)
#   3. ad-hoc "-"
# A stable identity (2) keeps macOS from re-prompting to approve the rebuilt
# AUv3 extension every build.
LOCAL_DEV_IDENTITY=""
if [[ -z "${SIGN_IDENTITY:-}" && -s "$ROOT/native/.signing-identity" ]]; then
  LOCAL_DEV_IDENTITY="$(tr -d '\n' < "$ROOT/native/.signing-identity")"
  SIGN_IDENTITY="$LOCAL_DEV_IDENTITY"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "==> signing identity: $SIGN_IDENTITY"
if [[ "$APP_PATH" == *"/UPI.app" ]]; then
  APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-src-tauri/Entitlements.plist}"
else
  APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-native/UPIHost/UPIHost.entitlements}"
fi
APPEX_ENTITLEMENTS="${APPEX_ENTITLEMENTS:-native/UPIInstrument/UPIInstrument.entitlements}"

[[ -d "$APP_PATH" ]]   || { echo "error: $APP_PATH not found (build the host first)" >&2; exit 1; }
[[ -d "$APPEX_PATH" ]] || { echo "error: $APPEX_PATH not found (run tools/build-au.sh)" >&2; exit 1; }

echo "==> 1. embed extension"
mkdir -p "$APP_PATH/Contents/PlugIns"
rm -rf "$APP_PATH/Contents/PlugIns/UPIInstrument.appex"
cp -R "$APPEX_PATH" "$APP_PATH/Contents/PlugIns/UPIInstrument.appex"

SIGN_FLAGS=(--force --timestamp --options runtime --generate-entitlement-der)
if [[ "$SIGN_IDENTITY" == "-" || "$SIGN_IDENTITY" == "$LOCAL_DEV_IDENTITY" ]]; then
  # local dev: no timestamp / hardened runtime (self-signed can't notarize anyway)
  SIGN_FLAGS=(--force --generate-entitlement-der)
fi

echo "==> 2. sign nested code (inside-out), explicit entitlements, no --deep"
APPEX="$APP_PATH/Contents/PlugIns/UPIInstrument.appex"

# every framework, deepest first (the .appex carries its own UPIRuntime.framework)
while IFS= read -r fw; do
  codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$fw"
done < <(find "$APP_PATH" -type d -name "*.framework" 2>/dev/null | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)

# the extension, with its own entitlements
codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" \
  --entitlements "$APPEX_ENTITLEMENTS" \
  "$APPEX"

echo "==> 3. sign the app over final contents"
codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP_PATH"

echo "==> verify"
codesign --verify --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH/Contents/PlugIns/UPIInstrument.appex"

if [[ "${MAKE_DMG:-0}" == "1" ]]; then
  echo "==> dmg"
  rm -f build/UPI.dmg
  hdiutil create -volname "Universal Public Instrument" -srcfolder "$APP_PATH" \
    -ov -format UDZO build/UPI.dmg
  [[ -n "${NOTARYTOOL_PROFILE:-}" ]] && {
    xcrun notarytool submit build/UPI.dmg --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    xcrun stapler staple build/UPI.dmg
  }
fi

if [[ "${MAKE_PKG:-0}" == "1" ]]; then
  echo "==> pkg"
  rm -f build/UPI.pkg
  productbuild --component "$APP_PATH" /Applications \
    ${PKG_SIGN_IDENTITY:+--sign "$PKG_SIGN_IDENTITY"} build/UPI.pkg
fi

echo "==> done: $APP_PATH"
