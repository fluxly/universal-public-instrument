#!/usr/bin/env bash
# smoke.sh — Phase 0 gate. Builds the .appex, assembles UPI.app, registers,
# validates, and renders.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.cargo/bin:$PATH"

CONFIG="${CONFIG:-Release}"        # Release = what ships; set CONFIG=Debug for faster iteration
SRC_APP="src-tauri/target/release/bundle/macos/UPI.app"
APP="$HOME/Applications/UPI.app"   # pkd only trusts app extensions under /Applications or ~/Applications
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

echo "### 1/5  build .appex ($CONFIG)"
CONFIG="$CONFIG" bash tools/build-au.sh

echo "### 2/5  ensure a host bundle"
if [[ ! -d "$SRC_APP" ]]; then
  echo "    (no Tauri bundle yet — 'cargo tauri build')"
  ( cd src-tauri && cargo tauri build --bundles app )
fi
rm -rf "$APP"; cp -R "$SRC_APP" "$APP"

echo "### 3/5  embed + sign (package.sh)"
APP_PATH="$APP" bash tools/package.sh >/dev/null
codesign --verify --strict "$APP"

echo "### 4/5  register + auval"
bash tools/unregister.sh
"$LSREGISTER" -f -R -trusted "$APP"
pluginkit -a "$APP/Contents/PlugIns/UPIInstrument.appex"
sleep 2
auval -v aumu UPIi UPI_ | tail -3

echo "### 5/5  render / state / MPE / Pd / identity smoke tests"
swift tools/render-smoke.swift
swift tools/state-smoke.swift
swift tools/mpe-smoke.swift
swift tools/pd-smoke.swift
swift tools/identity-smoke.swift

echo
echo "PHASE 0 SMOKE: all green"
