#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
PPM (P6) -> PNG, so the composited frame can be looked at.

Usage:  python tools/ppm_to_png.py <file.ppm>

Writes <file>.png next to the input.  The Verilator benches dump raw PPM because
that is what a C++ testbench can write without a library; every image viewer
worth using wants a PNG.

Requires Pillow.  If it is missing the script exits non-zero rather than
pretending to have converted something, because the benches check the exit code.
"""
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.stderr.write("ppm_to_png: Pillow is required (pip install pillow)\n")
    raise SystemExit(1)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__.strip() + "\n")
        return 2

    src = Path(argv[1])
    if not src.exists():
        sys.stderr.write("ppm_to_png: no such file: %s\n" % src)
        return 1

    raw = src.read_bytes()
    if not raw.startswith(b"P6"):
        sys.stderr.write("ppm_to_png: not a binary PPM (P6): %s\n" % src)
        return 1

    # Header: magic, width, height, maxval.  Whitespace separated, and any
    # amount of it is legal, so tokens are read one at a time instead of
    # splitting the whole file - the pixel data is binary and may contain bytes
    # that look like whitespace.
    pos = 2
    fields = []
    while len(fields) < 3:
        while pos < len(raw) and raw[pos:pos + 1].isspace():
            pos += 1
        if pos < len(raw) and raw[pos:pos + 1] == b"#":        # comment line
            while pos < len(raw) and raw[pos:pos + 1] != b"\n":
                pos += 1
            continue
        start = pos
        while pos < len(raw) and not raw[pos:pos + 1].isspace():
            pos += 1
        if start == pos:
            break
        fields.append(int(raw[start:pos]))
    if len(fields) != 3:
        sys.stderr.write("ppm_to_png: truncated PPM header: %s\n" % src)
        return 1
    width, height, maxval = fields
    pos += 1                                                   # one whitespace
    if maxval != 255:
        sys.stderr.write("ppm_to_png: only 8-bit samples supported (maxval=%d)\n"
                         % maxval)
        return 1

    need = width * height * 3
    body = raw[pos:pos + need]
    if len(body) != need:
        sys.stderr.write("ppm_to_png: short pixel data: %d of %d bytes\n"
                         % (len(body), need))
        return 1

    out = src.with_suffix(".png")
    Image.frombytes("RGB", (width, height), body).save(out)
    print("ppm_to_png: %s -> %s (%dx%d)" % (src.name, out.name, width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
