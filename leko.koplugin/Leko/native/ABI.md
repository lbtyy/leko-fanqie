# QuickJS native bridge ABI

This shared library is the production QuickJS bridge for the 0.15.47 package.

- Engine: official QuickJS `2026-06-04` source.
- Bridge ABI: `2`, bridge version `2.0.0`.
- Target: 32-bit ARMv7-A, Cortex-A8-compatible, EABI5, softfp; position-independent shared object.
- ELF flags: `EF_ARM_EABI_VER5 | EF_ARM_ABI_FLOAT_SOFT` (`0x05000200`).
- SONAME: `liblekoqjs.so`.
- Minimum recorded glibc symbol requirement: `GLIBC_2.4` (the build is capped at glibc 2.11).
- Dynamic dependencies: `libm.so.6`, `libpthread.so.0`, `libc.so.6`, `librt.so.1`.
- Load segments use 4 KiB alignment and the dynamic table does not request
  `DF_BIND_NOW`; both are required for the old Kindle dynamic loader used by
  the KindleBasic/softfp target.
- The object has no `PT_INTERP`; the KOReader/Kindle loader resolves the listed shared libraries.

The bridge exposes only the opaque C ABI in `lqjs_bridge.h`: runtime/context
lifecycle, bounded evaluation, exception/stack reporting, memory and stack
limits, interrupt deadlines, host callback installation, version queries,
sampled current/peak QuickJS memory usage, and explicit result-buffer release.
QuickJS internal value layouts are not part of the LuaJIT FFI surface.
