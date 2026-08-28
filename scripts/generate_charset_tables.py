#!/usr/bin/env python3
"""Reproduce Leko's compact GBK and GB18030 lookup tables.

The generator uses Python's standard-library codecs as the mapping oracle.
Python is a build-time tool and is not included in the plugin package.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_DIR = ROOT / "leko.koplugin" / "Leko"
GBK_PATH = MODULE_DIR / "gbk-unicode.bin"
GB18030_PATH = MODULE_DIR / "GB18030Ranges.lua"


def build_gbk() -> bytes:
    output = bytearray()
    trails = [*range(0x40, 0x7F), *range(0x80, 0xFF)]
    for lead in range(0x81, 0xFF):
        for trail in trails:
            try:
                decoded = bytes((lead, trail)).decode("gbk")
                codepoint = ord(decoded) if len(decoded) == 1 else 0
            except UnicodeDecodeError:
                codepoint = 0
            output.extend(codepoint.to_bytes(3, "big"))
    return bytes(output)


def pointer_bytes(pointer: int) -> bytes:
    value = pointer
    fourth = 0x30 + value % 10
    value //= 10
    third = 0x81 + value % 126
    value //= 126
    second = 0x30 + value % 10
    value //= 10
    first = 0x81 + value
    return bytes((first, second, third, fourth))


def build_gb18030_ranges() -> list[tuple[int, int, int]]:
    ranges: list[tuple[int, int, int]] = []
    start = end = base = None
    for pointer in range(126 * 10 * 126 * 10):
        try:
            decoded = pointer_bytes(pointer).decode("gb18030")
            codepoint = ord(decoded) if len(decoded) == 1 else None
        except UnicodeDecodeError:
            codepoint = None

        contiguous = (
            codepoint is not None
            and start is not None
            and pointer == end + 1
            and codepoint == base + (pointer - start)
        )
        if codepoint is not None and (start is None or contiguous):
            if start is None:
                start = end = pointer
                base = codepoint
            else:
                end = pointer
            continue

        if start is not None:
            ranges.append((start, end, base))
            start = end = base = None
        if codepoint is not None:
            start = end = pointer
            base = codepoint

    if start is not None:
        ranges.append((start, end, base))
    return ranges


def render_ranges(ranges: list[tuple[int, int, int]]) -> str:
    rows = ["-- Generated compact GB18030 4-byte index -> Unicode ranges.", "return {"]
    rows.extend(f"    {{{start},{end},{base}}}," for start, end, base in ranges)
    rows.append("}")
    return "\n".join(rows) + "\n"


def existing_ranges() -> list[tuple[int, int, int]]:
    text = GB18030_PATH.read_text(encoding="utf-8")
    return [tuple(map(int, values)) for values in re.findall(r"\{(\d+),(\d+),(\d+)\}", text)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="compare generated data with the repository")
    args = parser.parse_args()

    gbk = build_gbk()
    ranges = build_gb18030_ranges()
    if args.check:
        if GBK_PATH.read_bytes() != gbk:
            raise SystemExit("gbk-unicode.bin differs from the generated mapping")
        if existing_ranges() != ranges:
            raise SystemExit("GB18030Ranges.lua differs from the generated mapping")
        print(f"charset tables verified: {len(gbk)} bytes, {len(ranges)} ranges")
        return 0

    GBK_PATH.write_bytes(gbk)
    GB18030_PATH.write_text(render_ranges(ranges), encoding="utf-8", newline="\n")
    print(f"charset tables generated: {len(gbk)} bytes, {len(ranges)} ranges")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

