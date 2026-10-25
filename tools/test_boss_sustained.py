"""Sustained BOSS workload/coverage test. VM steps are NOT board FPS.

Runs the linked game with attack held, records every published frame, and keeps
all collision, impact FX and pattern logic. Board acceptance still requires a
five-minute run with per-second FPS >= 60, no corruption and continuous music.
"""
import argparse
import hashlib
import json
import os
import struct
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
os.environ.setdefault("SIM_PURE_PYTHON", "1")
import test_runner as T
from profile_stress_frame import symbols
from bucket_demand import snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frames", type=int, default=2400)
    parser.add_argument("--load", type=int, default=4000)
    parser.add_argument("--idle", action="store_true", help="do not hold attack")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    binary = ROOT / "sw/build/firmware.bin"
    sym = symbols(binary.with_suffix(".elf"))
    code = T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    T._enter_pressure_stage(vm)
    vm.btn = T.raw_btn() if args.idle else T.raw_btn("x")
    T.poke(vm, sym["stress_target"], args.load, 2)
    for _ in range(400):
        assert T.wait_frames(vm, 1), "ramp stalled"
        if T.tlm(vm, "sprites") >= args.load:
            break
    else:
        raise AssertionError("requested population was not reached")
    frames, patterns, worst = [], set(), None
    max_drop = -1
    eb_base = T.mm_value("MM_EBULLET_BASE") - T.SCRATCH_BASE
    lance_base = T.mm_value("MM_LANCE_INDEX") - T.SCRATCH_BASE
    capacity = T.mm_value("MM_EBULLET_COUNT")
    for i in range(args.frames):
        before = vm.steps
        assert T.wait_frames(vm, 1), "publish stalled"
        pattern = vm.load(sym["boss_pattern"], 1)
        patterns.add(pattern)
        drop = vm.load(sym["bt_dropped"], 4)
        assert drop != 65535, "accelerator reported a fault"
        pool = vm.scratch[eb_base:eb_base+capacity*8]
        live = sum(bool(pool[k*8+6] & 1) for k in range(capacity))
        assert vm.load(sym["active_count"], 2) == live, "stale live count"
        n_lances = vm.load(sym["eb_lance_count"])
        assert n_lances <= capacity - 32
        indices = struct.unpack_from("<%dH" % n_lances, vm.scratch, lance_base)
        assert len(set(indices)) == len(indices), "duplicate lance index"
        expected_lances = {k for k in range(capacity - 32) if pool[k*8+6] & 9 == 9}
        actual_lances = {k for k in indices if pool[k*8+6] & 9 == 9}
        assert actual_lances == expected_lances, "missing live lance"
        frames.append(dict(frame=i, sprites=T.tlm(vm, "sprites"), pattern=pattern,
                           drops=drop, instructions=vm.steps-before,
                           lances=n_lances,
                           rows=vm.load(sym["blit_rows"]),
                           commands=vm.load(sym["blit_cmds"])))
        if drop > max_drop:
            max_drop = drop
            worst = snapshot(vm, sym, T)
        if i % 120 == 0:
            print("frame=%d sprites=%d pattern=%d drop=%d peak_drop=%d patterns=%s" %
                  (i, frames[-1]["sprites"], pattern, drop, max_drop, sorted(patterns)), flush=True)
    report = dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  load=args.load, attack=not args.idle, frames=frames, patterns=sorted(patterns),
                  min_sprites=min(f["sprites"] for f in frames),
                  max_drops=max_drop, worst_buckets=worst,
                  timing_note="Functional VM only. No DDR stalls or accelerator timing model; not FPS evidence.")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    print("RESULT patterns=%d min_sprites=%d max_drop=%d report=%s" %
          (len(patterns), report["min_sprites"], max_drop, args.report), flush=True)
    if args.frames >= 2400:
        assert len(patterns) == 17, "not all non-summon patterns were exercised"


if __name__ == "__main__":
    main()
