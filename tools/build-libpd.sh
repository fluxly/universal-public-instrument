#!/usr/bin/env bash
# build-libpd.sh — build the vendored libpd (third_party/libpd submodule) as a
# static, multi-instance library for the current macOS arch. Output:
#   third_party/libpd/build/libpd.a  (+ headers used in place)
#
# Multi-instance (PD_MULTI) lets more than one Pd-backed Instrument Pack run in
# the same extension process. Static so it links straight into UPIInstrument.appex.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBPD="$ROOT/third_party/libpd"
BUILD="$LIBPD/build"
ARCH="${ARCH:-$(uname -m)}"

[[ -f "$LIBPD/CMakeLists.txt" ]] || {
  echo "error: third_party/libpd is empty — run: git submodule update --init --recursive" >&2
  exit 1
}
[[ -d "$LIBPD/pure-data/src" ]] || {
  echo "error: third_party/libpd/pure-data missing — run: git submodule update --init --recursive" >&2
  exit 1
}

if [[ -f "$BUILD/libpd.a" && "${FORCE:-0}" != "1" ]]; then
  echo "==> libpd.a present (FORCE=1 to rebuild): $BUILD/libpd.a"
  exit 0
fi

echo "==> cmake configure (PD_MULTI=ON, static only, $ARCH)"
cmake -S "$LIBPD" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DPD_MULTI=ON \
  -DPD_UTILS=ON \
  -DPD_EXTRA=ON \
  -DLIBPD_SHARED=OFF \
  -DLIBPD_STATIC=ON \
  -DPD_BUILD_C_EXAMPLES=OFF

echo "==> cmake build"
cmake --build "$BUILD"

# normalise the output location (PD_MULTI build produces libpd-multi.a)
A="$(find "$BUILD" -name 'libpd-multi.a' | head -1)"
[[ -n "$A" ]] || A="$(find "$BUILD" -name 'libpds.a' -o -name 'libpd.a' | grep -v "$BUILD/libpd.a" | head -1)"
[[ -n "$A" ]] || { echo "error: libpd static lib not produced" >&2; exit 1; }
cp "$A" "$BUILD/libpd.a"

echo "==> $BUILD/libpd.a"
lipo -info "$BUILD/libpd.a" 2>/dev/null || true
