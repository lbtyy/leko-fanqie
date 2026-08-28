#!/bin/sh
# Multi-platform ABI verification runner.  Iterates every produced
# liblekoqjs.so (or .dll) and runs test_lqjs_bridge to confirm the ABI
# symbols line up with the LuaJIT expectations.  Exits non-zero when
# any platform fails, which prevents the package.ps1 automation from
# bundling a broken .so.
set -eu

BRIDGE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$BRIDGE_ROOT/../.." && pwd)
BUILD_ROOT=${BUILD_ROOT:-"$REPO_ROOT/build"}
TEST_BIN=${TEST_BIN:-./test_lqjs_bridge}

if [ ! -x "$TEST_BIN" ]; then
  echo "VERIFY_BLOCKED: test runner not built: $TEST_BIN" >&2
  exit 2
fi

overall_rc=0
for artifact in "$BUILD_ROOT"/*/liblekoqjs.so "$BUILD_ROOT"/*/liblekoqjs.dll; do
  [ -e "$artifact" ] || continue
  platform=$(basename "$(dirname "$artifact")")
  echo "verify $platform <- $artifact"
  if LD_LIBRARY_PATH="$(dirname "$artifact")" "$TEST_BIN" "$artifact"; then
    echo "  ok"
  else
    echo "  FAILED" >&2
    overall_rc=1
  fi
done

if [ $overall_rc -ne 0 ]; then
  echo "VERIFY_FAILED: at least one platform failed" >&2
fi
exit $overall_rc
