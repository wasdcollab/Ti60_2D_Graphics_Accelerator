#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
simulator/alpha_ref.py
======================
Byte-exact architectural reference model of the OP_ALPHA datapath
(rtl/bitblt/bitblt_alpha_blend.v + bitblt_stride_gen.v v3).

It consumes exactly the same stimulus file as the RTL bench
(tests/bitblt_alpha_vectors.txt), reproduces the source sprite and the
destination background with the same deterministic generators, applies the
specification formula and hashes the whole destination rectangle with FNV-1a 64.
Comparing those hashes with the ones the RTL prints proves the two agree byte
for byte - including the colour-key skips and the alpha byte pass-through.

Specification implemented (identical to the RTL):

    ae  = (a * GLOBAL_ALPHA + 127) / 255
    out = (src * ae + dst * (255 - ae) + 127) / 255      for R, G and B
    the A byte of the framebuffer is passed through from the destination

Colour key has priority: a source pixel equal to the key is never written.

Usage:
    python simulator/alpha_ref.py --vectors tests/bitblt_alpha_vectors.txt \
                                  --out work_sim/step3_rtl/bitblt_alpha_py.vec
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

A_SEQ = (0, 255, 1, 127, 128, 254)
C_SEQ = (0, 255, 1, 254)


def fnv1a(data, h=FNV_OFFSET):
    for b in data:
        h = ((h ^ b) * FNV_PRIME) & MASK64
    return h


def background(memsz=MEMSZ):
    """Same deterministic destination background as the SystemVerilog bench."""
    return bytearray(((i * 29) ^ (i >> 4) ^ 0x5A) & 0xFF for i in range(memsz))


def src_pixel(profile, x, y, key):
    """Same sprite generator as the SystemVerilog bench (returns B,G,R,A)."""
    a = (17 * x + 29 * y + 71) & 0xFF
    r = (53 * x + 97 * y + 13) & 0xFF
    g = (11 * x + 41 * y + 199) & 0xFF
    b = (131 * x + 7 * y + 3) & 0xFF
    if profile == 1:
        a = A_SEQ[(x + y) % 6]
    elif profile == 2:
        a = A_SEQ[(x + y) % 6]
        r = C_SEQ[x % 4]
        g = C_SEQ[(x + y + 1) % 4]
        b = C_SEQ[(x + 2 * y + 2) % 4]
    elif profile == 3:
        a = A_SEQ[(x + y) % 6]
        if (x + y) % 3 == 0:
            a = (key >> 24) & 0xFF
            r = (key >> 16) & 0xFF
            g = (key >> 8) & 0xFF
            b = key & 0xFF
    return bytes((b, g, r, a))


def blend_channel(s, d, a):
    return (s * a + d * (255 - a) + 127) // 255


def scale_alpha(a, g):
    return (a * g + 127) // 255


def load_vectors(path):
    out = []
    with open(path, "r", encoding="ascii") as fh:
        for line in fh:
            line = line.split("#")[0].strip()
            if not line:
                continue
            f = line.split()
            if len(f) != 10:
                raise ValueError("bad alpha vector line: %r" % line)
            profile, so, do, w, h, ss, ds, ga, ck, key = (
                int(v, 16) if i == 9 else int(v) for i, v in enumerate(f))
            out.append((profile, so, do, w, h, ss, ds, ga, ck, key))
    return out


def run(path, out_path=None, verbose=True):
    vecs = load_vectors(path)
    hashes = []
    written_total = 0
    keyed_total = 0

    for idx, (profile, so, do, w, h, ss, ds, ga, ck, key) in enumerate(vecs):
        src = bytearray(MEMSZ)
        for y in range(h):
            for x in range(w):
                a = so + y * ss + x * 4
                src[a:a + 4] = src_pixel(profile, x, y, key)

        dst = background()
        snap = bytes(dst)

        written = 0
        keyed = 0
        for y in range(h):
            for x in range(w):
                sa = so + y * ss + x * 4
                da = do + y * ds + x * 4
                spix = src[sa:sa + 4]
                if ck and int.from_bytes(spix, "little") == key:
                    keyed += 1
                    continue                      # untouched, not even read
                ae = scale_alpha(spix[3], ga)
                for k in range(3):
                    dst[da + k] = blend_channel(src[sa + k], snap[da + k], ae)
                dst[da + 3] = snap[da + 3]        # alpha byte passes through
                written += 4

        if written != 4 * (w * h - keyed):
            raise AssertionError("vector %d: byte accounting broken" % idx)

        h64 = FNV_OFFSET
        for y in range(h):
            base = do + y * ds
            h64 = fnv1a(dst[base:base + 4 * w], h64)

        hashes.append((idx, h64))
        written_total += written
        keyed_total += keyed
        if verbose:
            print("AVEC %d ok p=%d soff=%d doff=%d w=%d h=%d ss=%d ds=%d ga=%d ck=%d key=%08x hash=%016x"
                  % (idx, profile, so, do, w, h, ss, ds, ga, ck, key, h64))

    if out_path:
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="ascii", newline="\n") as fh:
            for idx, h64 in hashes:
                fh.write("AVEC %d hash=%016x\n" % (idx, h64))

    print("PASS Python ALPHA model: %d vectors, %d bytes written, %d keyed pixels skipped"
          % (len(vecs), written_total, keyed_total))
    return hashes


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", default=os.path.join(root, "tests", "bitblt_alpha_vectors.txt"))
    ap.add_argument("--out", default=None)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    run(a.vectors, a.out, verbose=not a.quiet)
    return 0


if __name__ == "__main__":
    sys.exit(main())
