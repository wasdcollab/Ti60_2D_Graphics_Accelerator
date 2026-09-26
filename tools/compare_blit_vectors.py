#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/compare_blit_vectors.py
=============================
Cross-checks the per-vector result hashes produced by

    work_sim/step3_rtl/bitblt_copy_mb<N>.vec    (Vivado XSim, real RTL)  tag VEC
    work_sim/step3_rtl/bitblt_copy_py.vec       (simulator/blit_ref.py)

    work_sim/step3_rtl/bitblt_alpha_mb<N>.vec   (Vivado XSim, real RTL)  tag AVEC
    work_sim/step3_rtl/bitblt_alpha_py.vec      (simulator/alpha_ref.py)

Same stimulus, same FNV-1a 64 hash definition -> the two lists must agree
element by element.  This is the L2 cross-validation of the BitBlt engine: it
proves the RTL is not merely self-consistent but matches an independent
byte-exact model of the specification.  --tag selects which vector family is
compared (VEC = fill/copy/colour key, AVEC = alpha blending).
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DIR = os.path.join(ROOT, "work_sim", "step3_rtl")


def patterns(tag):
    return (re.compile(r"^%s (\d+) ok .*hash=([0-9a-fA-F]{16})" % tag),
            re.compile(r"^%s (\d+) hash=([0-9a-fA-F]{16})" % tag))


def parse(path, pattern):
    out = {}
    if not os.path.exists(path):
        raise SystemExit("missing file: %s" % path)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = pattern.match(line.strip())
            if m:
                out[int(m.group(1))] = m.group(2).lower()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--tag", default="VEC", help="VEC (fill/copy) or AVEC (alpha)")
    ap.add_argument("--rtl", default=None)
    ap.add_argument("--py", default=None)
    a = ap.parse_args()

    tag = a.tag
    rtl_re, py_re = patterns(tag)
    stem = "bitblt_copy" if tag == "VEC" else "bitblt_alpha"
    rtl_path = a.rtl or os.path.join(a.dir, "%s_mb64.vec" % stem)
    py_path = a.py or os.path.join(a.dir, "%s_py.vec" % stem)

    rtl = parse(rtl_path, rtl_re)
    py = parse(py_path, py_re)

    print("RTL vectors: %d (%s)" % (len(rtl), os.path.basename(rtl_path)))
    print("PY  vectors: %d (%s)" % (len(py), os.path.basename(py_path)))

    if not rtl or not py:
        raise SystemExit("one of the hash lists is empty")

    bad = [i for i in sorted(set(rtl) & set(py)) if rtl[i] != py[i]]
    missing = sorted(set(py) - set(rtl))

    for i in bad[:20]:
        print("  MISMATCH vector %d: rtl=%s py=%s" % (i, rtl[i], py[i]))
    if missing:
        print("  missing in RTL: %s" % missing[:20])
    if bad or missing:
        raise SystemExit("CROSS-CHECK FAILED (%d mismatches, %d missing)"
                         % (len(bad), len(missing)))

    print("PASS cross-check [%s]: %d/%d vectors byte-identical between RTL and the "
          "Python reference model" % (tag, len(py), len(py)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
