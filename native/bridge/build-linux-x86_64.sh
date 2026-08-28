#!/bin/sh
# Native build recipe for desktop Linux x86_64 (desktop fallback so users
# without KOReader can still exercise the bridge from qjs).  Mirrors the
# Kindle / Kobo scripts in flag set and dependency list so the same
# QuickJS tree rebuilds cleanly across all three targets.
set -eu

BRIDGE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$BRIDGE_ROOT/../.." && pwd)
QJS_ROOT=${QJS_ROOT:-"$REPO_ROOT/third_party/quickjs-2026-06-04"}
OUT=${OUT:-"$REPO_ROOT/build/linux-x86_64"}
CC=${CC:-gcc}

if ! command -v "$CC" >/dev/null 2>&1; then
  echo "BUILD_BLOCKED: compiler not found: $CC" >&2
  exit 3
fi
if [ ! -f "$QJS_ROOT/quickjs.c" ]; then
  echo "BUILD_BLOCKED: missing QuickJS source: $QJS_ROOT" >&2
  exit 3
fi

mkdir -p "$OUT"
FLAGS="-std=c11 -O2 -fPIC -fvisibility=hidden -fwrapv -D_GNU_SOURCE \
  -DCONFIG_VERSION=\"2026-06-04\" -I$QJS_ROOT"
LDFLAGS=${LDFLAGS:--Wl,--hash-style=both -Wl,-z,lazy -Wl,-z,relro}

$CC $FLAGS $LDFLAGS -shared \
  "$BRIDGE_ROOT/lqjs_bridge.c" "$QJS_ROOT/quickjs.c" "$QJS_ROOT/dtoa.c" \
  "$QJS_ROOT/libregexp.c" "$QJS_ROOT/libunicode.c" "$QJS_ROOT/cutils.c" \
  -o "$OUT/liblekoqjs.so" -lm -ldl -pthread
echo "built $OUT/liblekoqjs.so"
