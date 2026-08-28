#!/bin/sh
# Run manually on the target Kindle before choosing CROSS_COMPILE or packaging.
set -eu
echo "uname: $(uname -a)"
echo "machine: $(uname -m)"
getconf LONG_BIT 2>/dev/null || true
getconf GNU_LIBC_VERSION 2>/dev/null || true
command -v luajit >/dev/null 2>&1 && luajit -e 'print(jit.version, jit.arch, jit.os)' || true
command -v readelf >/dev/null 2>&1 && readelf -h "${1:-./liblekoqjs.so}" || true
