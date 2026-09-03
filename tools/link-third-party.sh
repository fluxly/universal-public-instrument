#!/usr/bin/env bash
# link-third-party.sh — (re)create the symlinks declared in tools/third-party.config
# (or tools/third-party.config.local, which wins and is git-ignored).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="tools/third-party.config"
[[ -f "tools/third-party.config.local" ]] && CONFIG="tools/third-party.config.local"

echo "==> using $CONFIG"
missing=0

while read -r link target _rest; do
  [[ -z "${link:-}" || "${link:0:1}" == "#" ]] && continue
  target="${target/#\~/$HOME}"

  mkdir -p "$(dirname "$link")"
  rm -f "$link"

  if [[ ! -e "$target" ]]; then
    echo "  ✗ $link -> $target   (source missing)"
    missing=1
    continue
  fi
  ln -s "$target" "$link"
  echo "  ✓ $link -> $target"
done < "$CONFIG"

if [[ "$missing" -ne 0 ]]; then
  cat >&2 <<'EOF'

Some sources are missing. Edit tools/third-party.config (or copy it to
tools/third-party.config.local and edit that) to point at your local checkouts,
then re-run. The web build needs third_party/ravel/core-dist; the libpd backend
(Phase 0.5+) needs third_party/libpd.
EOF
  exit 1
fi
