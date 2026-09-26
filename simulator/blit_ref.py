#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
simulator/blit_ref.py
=====================
Byte-exact architectural reference model of the Ti60 BitBlt engine v2
(rtl/bitblt/*).  It is *not* a timing model: it implements the same memory
semantics as the RTL and is driven by the same stimulus file
(tests/bitblt_copy_vectors.txt) that tests/tb_step3_bitblt_copy.sv consumes.

Both sides hash the resulting destination bytes with FNV-1a 64, so comparing
the two hash lists proves that the RTL and this model agree byte for byte.

Usage:
    python simulator/blit_ref.py --vectors tests/bitblt_copy_vectors.txt \
                                 --out work_sim/step3_rtl/bitblt_copy_py.vec
"""
import argparse
import os
import sys

SRC_BASE = 0x01600000
DST_BASE = 0x01300000
MEMSZ = 65536

FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x00000100000001B3
MASK64 = (1 << 64) - 1


# --------------------------------------------------------------------------
# memory helpers
# --------------------------------------------------------------------------
def make_source(memsz=MEMSZ):
    """Same deterministic stimulus pattern as the SystemVerilog testbench."""
    return bytearray(((i * 37) ^ (i >> 5) ^ 0xA5) & 0xFF for i in range(memsz))


def fnv1a(data, h=FNV_OFFSET):
    for b in data:
        h = ((h ^ b) * FNV_PRIME) & MASK64
    return h


# --------------------------------------------------------------------------
# engine operations (must mirror rtl/bitblt/bitblt_stride_gen.v row geometry)
# --------------------------------------------------------------------------
def parse_op_type(cmd_op_type):
    return "fill" if (cmd_op_type & 0x3) == 0 else "copy"


def blit_fill(dst, dst_off, width, height, dst_stride, color):
    """Solid fill: every byte of [dst_off, dst_off+4*width) on each row."""
    nbytes = width * 4
    pixel = bytes(((color >> 0) & 0xFF, (color >> 8) & 0xFF,
                   (color >> 16) & 0xFF, (color >> 24) & 0xFF))
    row = pixel * width
    for y in range(height):
        base = dst_off + y * dst_stride
        dst[base:base + nbytes] = row
    return nbytes * height


def blit_copy(src, dst, src_off, dst_off, width, height, src_stride, dst_stride):
    """Block copy: 4*width bytes per row taken from the source snapshot."""
    nbytes = width * 4
    for y in range(height):
        s = src_off + y * src_stride
        d = dst_off + y * dst_stride
        dst[d:d + nbytes] = src[s:s + nbytes]
    return nbytes * height


# --------------------------------------------------------------------------
# vector driver
# --------------------------------------------------------------------------
def load_vectors(path):
    out = []
    with open(path, "r", encoding="ascii") as fh:
        for line in fh:
            line = line.split("#")[0].strip()
            if not line:
                continue
            f = line.split()
            if len(f) != 8:
                raise ValueError("bad vector line: %r" % line)
            op, so, do, w, h, ss, ds, col = (int(x, 16) if i == 7 else int(x)
                                             for i, x in enumerate(f))
            out.append((op, so, do, w, h, ss, ds, col))
    return out


def run(path, out_path=None, verbose=True):
    vecs = load_vectors(path)
    src = make_source()
    hashes = []
    for idx, (op, so, do, w, h, ss, ds, col) in enumerate(vecs):
        snap = bytes(src)                       # source snapshot before the op
        dst = bytearray(MEMSZ)
        if op == 0:
            written = blit_fill(dst, do, w, h, ds, col)
        else:
            written = blit_copy(snap, dst, so, do, w, h, ss, ds)

        h64 = FNV_OFFSET
        for y in range(h):
            base = do + y * ds
            h64 = fnv1a(dst[base:base + 4 * w], h64)

        if written != 4 * w * h:
            raise AssertionError("vector %d: wrote %d bytes, expected %d"
                                 % (idx, written, 4 * w * h))
        hashes.append((idx, h64))
        if verbose:
            print("VEC %d ok op=%d soff=%d doff=%d w=%d h=%d ss=%d ds=%d hash=%016x"
                  % (idx, op, so, do, w, h, ss, ds, h64))

    if out_path:
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="ascii", newline="\n") as fh:
            for idx, h64 in hashes:
                fh.write("VEC %d hash=%016x\n" % (idx, h64))
    print("PASS Python BitBlt model: %d vectors" % len(vecs))
    return hashes


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", default=os.path.join(root, "tests", "bitblt_copy_vectors.txt"))
    ap.add_argument("--out", default=None)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    run(a.vectors, a.out, verbose=not a.quiet)
    return 0


if __name__ == "__main__":
    sys.exit(main())
