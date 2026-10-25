#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/gen_copy_vectors.py
=========================
Generates the shared BitBlt stimulus file used by BOTH verification layers:

    tests/bitblt_copy_vectors.txt     (read by tests/tb_step3_bitblt_copy.sv)
                                      (read by simulator/blit_vectors.py)

Format, one vector per line:

    op src_off dst_off width height src_stride dst_stride color

     op = 0  OP_FILL  (src_off ignored, color used)
     op = 1  OP_COPY

Offsets are byte offsets from SRC_BASE (0x0160_0000) / DST_BASE (0x0130_0000).
Both the RTL testbench and the Python reference model start from the same
deterministic source pattern, so a per-vector FNV-1a hash of the result is
enough to prove the two implementations agree byte for byte.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "tests", "bitblt_copy_vectors.txt")

SS = 4096   # default stride
COLOR = 0x12A5F0C3


def vectors():
    v = []

    # ---- 1. 16-byte alignment matrix (src/dst low nibble combinations) ----
    for so in (0, 4, 8, 12):
        for do in (0, 4, 8, 12):
            v.append((1, so, do, 37, 3, SS, SS, 0))

    # ---- 2. byte-level alignment (the case v1 corrupted outright) ----
    for so, do in ((0, 1), (1, 0), (0, 2), (2, 0), (3, 7), (7, 3), (5, 11),
                   (11, 5), (13, 2), (2, 13), (15, 0), (0, 15), (9, 1), (1, 9)):
        v.append((1, so, do, 21, 2, SS, SS, 0))

    # ---- 3. width sweep, aligned and deliberately misaligned ----
    for w in (1, 2, 3, 4, 5, 15, 16, 17, 63, 64, 65, 127, 128, 129,
              255, 256, 257, 511, 512, 513, 1023, 1024):
        v.append((1, 0, 0, w, 2, SS, SS, 0))
        v.append((1, 4, 8, w, 2, SS, SS, 0))

    # ---- 4. height sweep (tighter stride so 17 rows still fit the 64 KiB model) ----
    for h in (1, 2, 3, 17):
        v.append((1, 0, 0, 64, h, 1024, 1024, 0))

    # ---- 5. independent source / destination strides ----
    for ss, ds in ((4096, 4096), (2048, 2048), (512, 512), (512, 4096),
                   (4096, 512), (1024, 2048)):
        v.append((1, 16, 32, 64, 4, ss, ds, 0))

    # ---- 6. bursts that must be split at a 4 KiB page boundary ----
    for do in (0, 16, 4064, 4080, 4096 - 16):
        v.append((1, 0, do, 64, 3, SS, SS, 0))

    # ---- 6b. degenerate rectangles must complete immediately, zero writes ----
    v.append((0, 0, 0, 32, 0, SS, SS, COLOR))
    v.append((0, 0, 0, 0, 3, SS, SS, COLOR))
    v.append((1, 0, 0, 32, 0, SS, SS, 0))
    v.append((1, 0, 0, 0, 3, SS, SS, 0))

    # ---- 7. wide / multi-row fills (regression for the legacy fill hang) ----
    v.append((0, 0, 2048, 512, 4, SS, SS, COLOR))
    v.append((0, 0, 0, 512, 4, SS, SS, COLOR))
    v.append((0, 0, 0, 1024, 2, SS, SS, COLOR))
    v.append((0, 0, 2048, 256, 6, SS, SS, COLOR))

    # ---- 8. fill regression (head/tail byte masking) ----
    for do in (0, 4, 8, 12, 1, 2, 3, 15):
        for w in (1, 4, 15, 16, 17, 64, 257):
            v.append((0, 0, do, w, 3, SS, SS, COLOR))

    return v


MEMSZ = 65536


def check(vs):
    """Every vector must stay inside the 64 KiB source and destination models,
    including the one extra look-ahead read beat each row issues."""
    for i, (op, so, do, w, h, ss, ds, _c) in enumerate(vs):
        if ss % 16 or ds % 16:
            raise AssertionError("vector %d: stride is not a multiple of 16" % i)
        if op == 1:
            hi = so + (h - 1) * ss + 4 * w + 16
            if hi > MEMSZ:
                raise AssertionError("vector %d: source reaches %d > %d" % (i, hi, MEMSZ))
        # The destination gets the same +16 as the source: the bench hands the
        # engine one extra beat at the head and one at the tail, so a vector
        # that ends exactly on MEMSZ still writes past the model.  This file
        # said so in its own comment and only added the 16 on the source side,
        # which is the half that would not have failed first.
        hi = do + (h - 1) * ds + 4 * w + 16
        if hi > MEMSZ:
            raise AssertionError("vector %d: destination reaches %d > %d" % (i, hi, MEMSZ))
    return vs


def main():
    vs = check(vectors())
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="ascii", newline="\n") as fh:
        for row in vs:
            fh.write("%d %d %d %d %d %d %d %08X\n" % row)
    print("wrote %d vectors -> %s" % (len(vs), OUT))


if __name__ == "__main__":
    main()
