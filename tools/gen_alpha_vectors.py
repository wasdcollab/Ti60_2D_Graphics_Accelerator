#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/gen_alpha_vectors.py
==========================
Generates the OP_ALPHA (hardware alpha blending) stimulus shared by both
verification layers:

    tests/bitblt_alpha_vectors.txt    read by tests/tb_step3_bitblt_copy.sv
                                      read by simulator/alpha_ref.py

Format, one vector per line (NO comment lines: the SystemVerilog bench reads it
with $fscanf, which cannot skip them):

    profile src_off dst_off width height src_stride dst_stride global_alpha ck_en ck_val

    profile 0 : pseudo random alpha and colour
    profile 1 : alpha swept over {0,255,1,127,128,254}, random colour
    profile 2 : alpha swept, colour channels swept over {0,255,1,254}
    profile 3 : every third pixel is exactly the colour key

src_off / dst_off are byte offsets from SRC_BASE (0x0160_0000) and
DST_BASE (0x0130_0000).  Both offsets are multiples of 4: blending and colour
keying build a per-pixel byte-strobe mask, so the hardware rejects addresses
that are not on a 32-bit pixel boundary (that is covered by the bench's guard
rails, not by a data vector).
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "tests", "bitblt_alpha_vectors.txt")

SS = 4096                       # default stride (16-byte aligned)
MEMSZ = 65536                   # both DDR models are 64 KiB
KEY = 0x00FF00FF                # pure magenta, same key the firmware uses
FULL = 255                      # GLOBAL_ALPHA identity


def vectors():
    v = []

    # 1. pixel aligned src/dst offset matrix (sigma = soff - doff in -12..12)
    for so in (0, 4, 8, 12):
        for do in (0, 4, 8, 12):
            v.append((0, so, do, 37, 3, SS, SS, FULL, 0, KEY))

    # 2. alpha boundary sweep: A = 0, 255, 1, 127, 128, 254
    for so, do in ((0, 0), (0, 4), (4, 0), (12, 8), (8, 12)):
        v.append((1, so, do, 64, 4, SS, SS, FULL, 0, KEY))

    # 3. channel boundary sweep: R/G/B over {0, 255, 1, 254}
    for so, do in ((0, 0), (4, 12), (12, 4)):
        v.append((2, so, do, 48, 3, SS, SS, FULL, 0, KEY))

    # 4. colour key + alpha together: a keyed pixel must never be blended
    for so, do in ((0, 0), (4, 12), (12, 4), (8, 8)):
        v.append((3, so, do, 37, 3, SS, SS, FULL, 1, KEY))
    v.append((0, 0, 0, 37, 3, SS, SS, FULL, 1, KEY))

    # 5. global alpha scaling (0xFF is the identity, 0 = fully transparent)
    for ga in (255, 200, 128, 64, 1, 0):
        v.append((0, 4, 8, 33, 3, SS, SS, ga, 0, KEY))
    for ga in (128, 64):
        v.append((3, 0, 12, 33, 3, SS, SS, ga, 1, KEY))

    # 6. width sweep, single row and multi row
    for w in (1, 2, 3, 4, 5, 15, 16, 17, 63, 64, 65, 127, 128, 129,
              255, 256, 257, 511, 512, 1024):
        v.append((0, 0, 0, w, 1, SS, SS, FULL, 0, KEY))
    for w in (17, 64, 129, 257):
        v.append((1, 4, 12, w, 2, SS, SS, FULL, 0, KEY))

    # 7. height sweep with a tighter stride
    for h in (1, 2, 3, 17):
        v.append((0, 0, 12, 64, h, 1024, 1024, FULL, 0, KEY))

    # 8. independent source / destination strides
    for ss, ds in ((4096, 4096), (2048, 2048), (512, 512), (512, 4096),
                   (4096, 512), (1024, 2048)):
        v.append((2, 8, 4, 64, 4, ss, ds, FULL, 0, KEY))

    # 9. bursts that must be split at a 4 KiB page boundary
    for do in (0, 16, 4064, 4080, 4096 - 16):
        v.append((0, 0, do, 64, 3, SS, SS, FULL, 0, KEY))
        v.append((3, 4, do, 64, 3, SS, SS, 160, 1, KEY))

    # 10. single beat and one-pixel rows
    v.append((0, 0, 0, 4, 1, SS, SS, FULL, 0, KEY))
    v.append((0, 12, 0, 1, 1, SS, SS, FULL, 0, KEY))
    v.append((0, 0, 12, 1, 1, SS, SS, 128, 1, KEY))

    # 11. wide multi-row stress
    v.append((0, 0, 0, 512, 4, SS, SS, FULL, 0, KEY))
    v.append((2, 4, 4, 1024, 2, SS, SS, FULL, 0, KEY))

    return v


def check(vs):
    """Every vector must stay inside the 64 KiB source and destination models,
    including the one extra look-ahead read beat each row issues, and the
    destination head/tail beats the bench inspects."""
    for i, (p, so, do, w, h, ss, ds, ga, ck, key) in enumerate(vs):
        if ss % 16 or ds % 16:
            raise AssertionError("vector %d: stride is not a multiple of 16" % i)
        if so % 4 or do % 4:
            raise AssertionError("vector %d: offset is not pixel aligned" % i)
        if not 0 <= ga <= 255:
            raise AssertionError("vector %d: global alpha out of range" % i)
        if not 0 <= key <= 0xFFFFFFFF:
            raise AssertionError("vector %d: colour key out of range" % i)
        src_hi = so + (h - 1) * ss + 4 * w + 16
        dst_hi = do + (h - 1) * ds + 4 * w + 16
        if src_hi > MEMSZ:
            raise AssertionError("vector %d: source reaches %d > %d" % (i, src_hi, MEMSZ))
        if dst_hi > MEMSZ:
            raise AssertionError("vector %d: destination reaches %d > %d" % (i, dst_hi, MEMSZ))
    return vs


def main():
    vs = check(vectors())
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="ascii", newline="\n") as fh:
        for row in vs:
            fh.write("%d %d %d %d %d %d %d %d %d %08X\n" % row)
    print("wrote %d alpha vectors -> %s" % (len(vs), OUT))


if __name__ == "__main__":
    main()
