#!/usr/bin/env bash
# ddsp-fetch-models.sh — fetch the DDSP-VST trumpet/clarinet models and convert
# them to the flat weight blobs the DdspBackend loads.
#
# The .ddspw / .ref artifacts are git-ignored (7.5 MB each, derived from a
# third-party release). This script reproduces them for every DDSP pack:
#
#   1. download DDSP-VST-Models.zip  (Apache-2.0, storage.googleapis.com/ddsp-vst)
#   2. extract Trumpet.tflite + Clarinet.tflite
#   3. run tools/ddsp-convert.py (in an ephemeral uv env) once per model
#   4. copy trumpet/clarinet.{ddspw,ref} into each pack's backend/ dir
#
# Idempotent: exits early if every pack already has its four files. FORCE=1
# re-converts. The conversion is deterministic — blobs are bit-identical.
#
#   bash tools/ddsp-fetch-models.sh
#
# Needs: curl, unzip, and `uv` (https://docs.astral.sh/uv/) for the Python side.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# packs that load com.upi.backend.ddsp
PACKS=( hello-ddsp chocolate-trumpet )
CACHE="build/ddsp-cache"

ZIP_URL="https://storage.googleapis.com/ddsp-vst/releases/DDSP-VST-Models.zip"
ZIP_SHA256="bbb0f4a61be86d8b52460b21210016945899d78f031b99a844a3771e9a2a5308"

# model name in the zip  ->  output basename in each pack
MODELS=( "Trumpet:trumpet" "Clarinet:clarinet" )

pack_dir()  { echo "instrument-packs/$1/backend"; }

have_all=1
for p in "${PACKS[@]}"; do
  d="$(pack_dir "$p")"
  for m in "${MODELS[@]}"; do
    base="${m#*:}"
    [[ -s "$d/$base.ddspw" && -s "$d/$base.ref" ]] || have_all=0
  done
done
if [[ "$have_all" == 1 && "${FORCE:-0}" != "1" ]]; then
  echo "==> DDSP models present for all packs (FORCE=1 to re-convert)"
  exit 0
fi

command -v uv >/dev/null || {
  echo "error: 'uv' not found — install from https://docs.astral.sh/uv/ (brew install uv)" >&2
  exit 1
}

mkdir -p "$CACHE"
ZIP="$CACHE/DDSP-VST-Models.zip"

check_sha() { [[ "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]]; }

if [[ -f "$ZIP" ]] && check_sha "$ZIP" "$ZIP_SHA256"; then
  echo "==> using cached $ZIP"
else
  echo "==> downloading DDSP-VST-Models.zip (~77 MB)"
  curl -fSL --retry 3 -o "$ZIP" "$ZIP_URL"
  check_sha "$ZIP" "$ZIP_SHA256" || {
    echo "error: $ZIP sha256 mismatch (expected $ZIP_SHA256)" >&2
    exit 1
  }
fi

TFDIR="$CACHE/tflite"
OUTDIR="$CACHE/converted"
mkdir -p "$TFDIR" "$OUTDIR"

for m in "${MODELS[@]}"; do
  name="${m%%:*}"; base="${m#*:}"
  unzip -o -q -j "$ZIP" "DDSP-VST-Models/$name.tflite" -d "$TFDIR"
  if [[ -s "$OUTDIR/$base.ddspw" && -s "$OUTDIR/$base.ref" && "${FORCE:-0}" != "1" ]]; then
    echo "==> $base: cached conversion"
  else
    echo "==> converting $name (uv run, ephemeral Python 3.11 env)"
    uv run --quiet --python 3.11 \
      --with 'numpy<2' --with tflite --with ai-edge-litert \
      python tools/ddsp-convert.py "$TFDIR/$name.tflite" "$OUTDIR/$base"
  fi
done

for p in "${PACKS[@]}"; do
  d="$(pack_dir "$p")"
  mkdir -p "$d"
  for m in "${MODELS[@]}"; do
    base="${m#*:}"
    cp "$OUTDIR/$base.ddspw" "$OUTDIR/$base.ref" "$d/"
  done
  echo "==> $p: $(ls "$d"/*.ddspw | wc -l | tr -d ' ') weight blobs in $d"
done
