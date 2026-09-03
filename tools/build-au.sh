#!/usr/bin/env bash
# build-au.sh — generate the Xcode project and build UPIInstrument.appex.
#
# Run standalone, or from Tauri's beforeBundleCommand (see docs/upi-app-spec.md
# "Build & Packaging Pipeline"). Output: build/UPIInstrument.appex
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-Release}"
OUT="$ROOT/build"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found (brew install xcodegen)" >&2
  exit 1
fi

# libpd (Phase 0.5 backend) — static, multi-instance. Cached after first build.
if [[ -d "$ROOT/third_party/libpd/pure-data/src" ]]; then
  bash "$ROOT/tools/build-libpd.sh"
else
  echo "note: third_party/libpd submodule not initialised — libpd backend unavailable" >&2
fi

cd "$ROOT/native"

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild ($CONFIG) UPIInstrument"
DERIVED="$ROOT/native/.build/DerivedData"
ARCHS="${ARCHS:-$(uname -m)}"
xcodebuild \
  -project UPI.xcodeproj \
  -scheme UPIInstrument \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  build

APPEX="$DERIVED/Build/Products/$CONFIG/UPIInstrument.appex"
[[ -d "$APPEX" ]] || APPEX="$DERIVED/Build/Products/$CONFIG/PlugIns/UPIInstrument.appex"
[[ -d "$APPEX" ]] || { echo "error: built .appex not found under $DERIVED/Build/Products/$CONFIG" >&2; exit 1; }

mkdir -p "$OUT"
rm -rf "$OUT/UPIInstrument.appex"
cp -R "$APPEX" "$OUT/UPIInstrument.appex"
echo "==> $OUT/UPIInstrument.appex"
