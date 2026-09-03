#!/usr/bin/env bash
# unregister.sh — remove every stale registration of the UPI Audio Unit so
# pluginkit / auval resolve to exactly the copy you just built. Safe to run
# when nothing is registered.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> removing UPI AU registrations"
paths="$(pluginkit -mAv -p com.apple.AudioUnit-UI 2>/dev/null \
          | grep -oE '/[^[:space:]]+UPIInstrument\.appex' | sort -u || true)"
if [[ -n "$paths" ]]; then
  while read -r p; do
    [[ -n "$p" ]] || continue
    pluginkit -r "$p" 2>/dev/null && echo "   - $p" || true
  done <<< "$paths"
else
  echo "   (none)"
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
find "$HOME/Library/Developer/Xcode/DerivedData"/UPI-* \
     "$ROOT/src-tauri/target" "$ROOT/native/.build" \
     -maxdepth 8 -name "UPI*.app" 2>/dev/null \
  | while read -r a; do "$LSREGISTER" -u "$a" 2>/dev/null || true; done

echo "==> done"
exit 0
