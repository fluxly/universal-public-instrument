#!/usr/bin/env bash
# set-signing-identity.sh — choose a stable code-signing identity for the local
# dev loop, so macOS stops asking you to re-approve the AUv3 extension in
# System Settings after every rebuild.
#
# Ad-hoc signing (`codesign -s -`) gives the extension a designated requirement
# of just its cdhash, which changes on every build — macOS treats each rebuild
# as a new extension. Signing with a real, stable identity (e.g. an "Apple
# Development" cert) gives a stable requirement, so you approve it once.
#
# Writes the chosen name to `native/.signing-identity` (git-ignored).
# `tools/package.sh` / `tools/smoke.sh` read it; unset or empty -> ad-hoc.
#
#   bash tools/set-signing-identity.sh              # interactive picker
#   bash tools/set-signing-identity.sh "Apple Development: You (TEAMID)"
#   bash tools/set-signing-identity.sh -            # back to ad-hoc

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/native/.signing-identity"

if [[ $# -ge 1 ]]; then
  choice="$1"
else
  echo "Code-signing identities available:"
  mapfile -t IDS < <(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p')
  if [[ ${#IDS[@]} -eq 0 ]]; then
    echo "  (none found — staying on ad-hoc)"; printf '' > "$OUT"; exit 0
  fi
  i=1; for id in "${IDS[@]}"; do echo "  $i) $id"; i=$((i+1)); done
  echo "  0) ad-hoc (-)"
  read -rp "Pick [1]: " n; n="${n:-1}"
  if [[ "$n" == "0" ]]; then choice="-"; else choice="${IDS[$((n-1))]}"; fi
fi

if [[ "$choice" == "-" || -z "$choice" ]]; then
  printf '' > "$OUT"
  echo "==> ad-hoc signing (native/.signing-identity cleared)"
else
  printf '%s\n' "$choice" > "$OUT"
  echo "==> signing identity set: $choice"
  echo "    (native/.signing-identity)"
fi
echo
echo "Next: bash tools/smoke.sh, then approve the extension ONE more time in"
echo "System Settings > General > Login Items & Extensions. Future rebuilds: no prompt."
