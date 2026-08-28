#!/bin/sh
# Cross-build recipe for Kobo (ARMv7 hard-float ABI).  Deliberately mirrors
# build-kindle-armv7.sh so a single QuickJS update rebuilds both targets.
# Kobo firmware is eglibc/hard-float and rejects the softfp link; this
# script forces -mfloat-abi=hard -mfpu=neon which is the configuration
# shipped on every current Kobo device.  The output filename embeds the
# ABI so packaging scripts can distinguish it from the Kindle .so.
set -eu

BRIDGE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$BRIDGE_ROOT/../.." && pwd)
QJS_ROOT=${QJS_ROOT:-"$REPO_ROOT/third_party/quickjs-2026-06-04"}
OUT=${OUT:-"$REPO_ROOT/build/kobo-armv7"}
CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabihf-}
CC=${CC:-"${CROSS_COMPILE}gcc"}
SYSROOT=${SYSROOT:-}

if ! command -v "$CC" >/dev/null 2>&1; then
  echo "BUILD_BLOCKED: compiler not found: $CC" >&2
  exit 3
fi
if [ ! -f "$QJS_ROOT/quickjs.c" ]; then
  echo "BUILD_BLOCKED: missing QuickJS source: $QJS_ROOT" >&2
  exit 3
fi

mkdir -p "$OUT"
FLAGS="-std=c11 -Os -fPIC -fvisibility=hidden -fwrapv -D_GNU_SOURCE \
  -DCONFIG_VERSION=\"2026-06-04\" -I$QJS_ROOT \
  -mfloat-abi=hard -mfpu=neon"
if [ -n "$SYSROOT" ]; then FLAGS="$FLAGS --sysroot=$SYSROOT"; fi
LDFLAGS=${LDFLAGS:--Wl,--hash-style=both -Wl,-z,lazy -Wl,-z,relro -Wl,-z,max-page-size=0x1000}
# Same hardening / no std-lib binding rules as the Kindle script.
# shellcheck disable=SC2086
$CC $FLAGS $LDFLAGS -shared \
  "$BRIDGE_ROOT/lqjs_bridge.c" "$QJS_ROOT/quickjs.c" "$QJS_ROOT/dtoa.c" \
  "$QJS_ROOT/libregexp.c" "$QJS_ROOT/libunicode.c" "$QJS_ROOT/cutils.c" \
  -o "$OUT/liblekoqjs.so" -lm -ldl -pthread
echo "built $OUT/liblekoqjs.so"
