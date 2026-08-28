#!/bin/sh
# Cross-build recipe for Windows x86_64 via mingw-w64 — EXPERIMENTAL.
# Per Q1 in DESIGN-leko-plus.md §8, KOReader's Windows build is MSYS2 /
# mingw; cross-compiling the bridge from Linux uses x86_64-w64-mingw32-gcc.
# pthread → win32 is the only non-trivial adaptation (see
# lqjs_bridge.c for the _WIN32 branch), and this script adds the
# library flags the bridge relies on.  Output file extension is .dll;
# package.ps1 only bundles it when MINW_PATH is provided (operators
# must opt in).
set -eu

BRIDGE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$BRIDGE_ROOT/../.." && pwd)
QJS_ROOT=${QJS_ROOT:-"$REPO_ROOT/third_party/quickjs-2026-06-04"}
OUT=${OUT:-"$REPO_ROOT/build/windows-x86_64"}
CROSS_COMPILE=${CROSS_COMPILE:-x86_64-w64-mingw32-}
CC=${CC:-"${CROSS_COMPILE}gcc"}

if ! command -v "$CC" >/dev/null 2>&1; then
  echo "BUILD_BLOCKED: mingw compiler not found: $CC" >&2
  echo "            install mingw-w64 or set CC to an available compiler" >&2
  exit 3
fi
if [ ! -f "$QJS_ROOT/quickjs.c" ]; then
  echo "BUILD_BLOCKED: missing QuickJS source: $QJS_ROOT" >&2
  exit 3
fi

mkdir -p "$OUT"
FLAGS="-std=c11 -O2 -fPIC -fvisibility=hidden -fwrapv \
  -D_GNU_SOURCE -DCONFIG_VERSION=\"2026-06-04\" -I$QJS_ROOT \
  -DLQJS_NO_PTHREAD=1"
# win32:   ws2_32 for sockets (used by leko's bridge today), bcrypt for
#          optional sha helpers; user32 stays optional.  No -lm.
LDFLAGS="-Wl,--enable-stdcall-fixup -shared"

$CC $FLAGS $LDFLAGS \
  "$BRIDGE_ROOT/lqjs_bridge.c" "$QJS_ROOT/quickjs.c" "$QJS_ROOT/dtoa.c" \
  "$QJS_ROOT/libregexp.c" "$QJS_ROOT/libunicode.c" "$QJS_ROOT/cutils.c" \
  -o "$OUT/liblekoqjs.dll" -lws2_32 -lbcrypt
echo "built $OUT/liblekoqjs.dll (experimental)"
