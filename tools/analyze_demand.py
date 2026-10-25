#!/usr/bin/env python
"""Exact published-frame demand by hue, not by unproven spawn origin."""
import argparse
import hashlib
import json
from pathlib import Path

from profile_stress_frame import ROOT, T, symbols
from bucket_demand import snapshot


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, default=ROOT / "sw/build/firmware.bin")
    ap.add_argument("--load", type=int, default=2112)
    ap.add_argument("--report", type=Path)
    args = ap.parse_args()
    if not 192 <= args.load <= 2112:
        ap.error("load must be 192..2112")
    code = T.load_code_from_source(args.source)
    sym = symbols(args.source.with_suffix(".elf"))
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    T._enter_pressure_stage(vm)
    assert T.wait_frames(vm, 3)
    T.poke(vm, sym["stress_target"], args.load, 2)
    for _ in range(400):
        if T.tlm(vm, "sprites") >= args.load:
            break
        assert T.wait_frames(vm, 1)
    assert T.tlm(vm, "sprites") >= args.load, "target population was not reached"
    assert T.wait_frames(vm, 4)
    report = snapshot(vm, sym, T)
    report["bin_sha256"] = hashlib.sha256(args.source.read_bytes()).hexdigest()
    report["sprites"] = T.tlm(vm, "sprites")
    print("population=%d peak=%d DROP=%d (verified against firmware)" %
          (report["sprites"], report["peak"], report["predicted_drops"]))
    print("Hues are NOT unique storm origins; other boss patterns reuse them.")
    for g, d in enumerate(report["demand"]):
        if d >= 64:
            print("group=%2d demand=%3d hues=%s" % (g, d, dict(report["by_hue"][g])))
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
