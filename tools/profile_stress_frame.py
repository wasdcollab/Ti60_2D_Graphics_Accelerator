#!/usr/bin/env python
"""Per-component instruction-cost breakdown of the pressure stage at high load.

Runs the real linked firmware in the RV32 SoC VM, ramps the pressure stage to
a chosen load, then profiles a short natural display-pass window three ways:

  1. PC sampling over whole passes, attributed to functions via addr2line
     (the firmware is built -g, so inline chains are recovered);
  2. marker stores inside the pass: bt_count[] reset = bucket_build() start,
     damage_track store = bucket_build() end, tlm[TLM_FRAMES] store =
     telemetry frame marker (not function end), GPU2D RIGHT_NEXT = publish;
  3. isolated direct calls for the non-inlined symbols that exist
     (game_update, telemetry_write, game_render) and allocator worst cases.

Plus a bucket depth ledger / per-group demand histogram to show WHERE the
DROPs come from spatially.

Instruction counts are an A/B software metric, NOT a board FPS prediction:
the VM retires 1 instruction per step; CPI, DDR stalls and engine waits of
the board are not modelled.
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
sys.path.insert(0, str(ROOT / "tools"))
os.environ.setdefault("SIM_PURE_PYTHON", "1")
import test_runner as T
from bucket_demand import snapshot

GCC = Path(os.environ.get("RISCV_GCC_DIR", r"D:\FPGAqiansai\toolchain"))
TLM_FRAMES_ADDR = 0x01605B00 + 4          # tlm[TLM_FRAMES], telemetry marker


def symbols(elf):
    nm = GCC / "bin" / "riscv-none-elf-nm.exe"
    result = subprocess.check_output([str(nm), str(elf)], text=True)
    return {line.split()[2]: int(line.split()[0], 16)
            for line in result.splitlines() if len(line.split()) == 3}


def tlm_raw(vm, index):
    return int(vm.scratch32[(T.TLM_BASE - T.SCRATCH_BASE) // 4 + index])


def right_next_addr():
    header = (ROOT / "sw/driver/gpu2d.h").read_text(encoding="utf-8")
    m = re.search(r"#define\s+GPU2D_REG_RIGHT_NEXT\s+(.*)", header)
    return m[1].strip()


def call_func(vm, addr, args=(), budget=12_000_000, pad_on_stack=False):
    """Call addr(args) with a sentinel ra, nested on the suspended stack;
    restore pc and all registers afterwards. Memory mutations are NOT undone."""
    saved_r = list(vm.r)
    saved_pc = vm.pc
    r = list(vm.r)
    if pad_on_stack:
        sp = (r[2] - 96) & ~15
        for i in range(96 // 4):
            vm.store(sp + i * 4, 0, 4)
        r[2] = sp
        r[10] = sp
    r[1] = 0xFFFFFFFC
    for i, a in enumerate(args):
        r[10 + i] = a & 0xFFFFFFFF
    vm.r = r
    vm.pc = addr
    s0 = vm.steps
    while vm.pc != 0xFFFFFFFC and vm.steps - s0 < budget:
        vm.step()
    assert vm.pc == 0xFFFFFFFC, "call at %#x did not return (pc=%#x)" % (addr, vm.pc)
    cost = vm.steps - s0
    vm.r = saved_r
    vm.pc = saved_pc
    return cost


def addr2line_map(elf, addrs):
    """Batch addr2line queries, using address markers to delimit inline chains."""
    tool = GCC / "bin" / "riscv-none-elf-addr2line.exe"
    res = {}
    batch = list(dict.fromkeys(addrs))
    CH = 256
    for i in range(0, len(batch), CH):
        chunk = batch[i:i + CH]
        out = subprocess.check_output(
            [str(tool), "-e", str(elf), "-a", "-f", "-i"] +
            ["%#x" % a for a in chunk], text=True)
        blocks = re.split(r"(?m)^(0x[0-9a-fA-F]+)\s*$", out)
        for j in range(1, len(blocks), 2):
            a = int(blocks[j], 16)
            ls = blocks[j + 1].strip().splitlines()
            frames = list(zip(ls[::2], ls[1::2]))
            inner = frames[0] if frames else ("??", "??")
            outer = frames[-1] if frames else ("??", "??")
            res[a] = (inner, outer)
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, default=ROOT / "sw/build/firmware.bin")
    ap.add_argument("--load", type=int, default=2112)
    ap.add_argument("--frames", type=int, default=6)
    ap.add_argument("--attack", action="store_true", help="hold X after ramp")
    ap.add_argument("--sample", type=int, default=4, help="sample every N steps")
    ap.add_argument("--report", type=Path)
    args = ap.parse_args()
    if args.sample < 1 or args.frames < 1 or not 192 <= args.load <= 8000:
        ap.error("sample/frames must be positive; load must be 192..8000")

    elf = args.source.with_suffix(".elf")
    code = T.load_code_from_source(args.source)
    sym = symbols(elf)
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    T._enter_pressure_stage(vm)
    assert T.wait_frames(vm, 3), "pressure stage did not publish"

    T.poke(vm, sym["stress_target"], args.load, 2)
    frames_waited = 0
    while T.tlm(vm, "sprites") < args.load and frames_waited < 400:
        assert T.wait_frames(vm, 1), "stage stopped publishing during ramp"
        frames_waited += 1
    pop = T.tlm(vm, "sprites")
    print("ramp: %d passes, population=%d (target %d)" % (frames_waited, pop, args.load),
          flush=True)
    assert pop >= args.load, "target population was not reached"
    if args.attack:
        vm.btn = T.raw_btn("x")
    for _ in range(30 if args.attack else 4):
        assert T.wait_frames(vm, 1)

    report = {"load": args.load, "attack": args.attack, "population": pop, "passes": [], "calls": {},
              "alloc": {}, "buckets": {}, "pc_profile": {}}
    report["provenance"] = {
        "source": str(args.source.resolve()),
        "bin_sha256": hashlib.sha256(args.source.read_bytes()).hexdigest(),
        "elf_sha256": hashlib.sha256(elf.read_bytes()).hexdigest(),
        "sample_interval": args.sample,
        "scenario": "Fixed player, direct load injection, four warm-up passes after ramp; not proven steady state or worst case",
        "markers": "Bucket store window excludes prologue; tel_end is a legacy name for the telemetry frame store, not function end",
    }

    damage_track = sym["damage_track"]
    bt_count = sym["bt_count"]
    rows = T.mm_value("MM_BUCKET_ROWS")

    # ---- 1+2. natural passes with PC sampling and store markers --------
    all_pcs = []
    for k in range(args.frames):
        samples = []
        marks = {"bucket_start": None, "bucket_end": None, "tel_end": None}
        s0 = vm.steps

        original_store = vm.store

        def track_store(addr, value, size, _m=marks, _s0=s0):
            t = vm.steps - _s0
            if addr == damage_track and _m["bucket_end"] is None \
                    and _m["bucket_start"] is not None:
                _m["bucket_end"] = t
            elif bt_count <= addr < bt_count + rows and _m["bucket_start"] is None:
                _m["bucket_start"] = t
            elif addr == TLM_FRAMES_ADDR:
                _m["tel_end"] = t
            return original_store(addr, value, size)

        vm.store = track_store
        f0 = tlm_raw(vm, 1)
        r0 = vm.right_request
        step = vm.step
        while tlm_raw(vm, 1) == f0 or vm.right_request == r0:
            step()
            if vm.steps % args.sample == 0:
                samples.append(vm.pc)
            if vm.steps - s0 > 20_000_000:
                raise AssertionError("pass did not complete")
        vm.store = original_store
        steps = vm.steps - s0
        all_pcs.extend(samples)
        entry = {
            "steps": steps,
            "sprites": T.tlm(vm, "sprites"),
            "drops_frame": tlm_raw(vm, 58),
            "bucket_start": marks["bucket_start"],
            "bucket_end": marks["bucket_end"],
            "tel_end": marks["tel_end"],
            "pc_samples": len(samples),
            "buckets": snapshot(vm, sym, T),
        }
        assert entry["buckets"]["predicted_drops"] == entry["drops_frame"]
        report["passes"].append(entry)
        print("pass %d: steps=%d bucket=[%s..%s] tel_end=%s drops=%d"
              % (k, steps, marks["bucket_start"], marks["bucket_end"],
                 marks["tel_end"], entry["drops_frame"]), flush=True)

    report["buckets"] = report["passes"][-1]["buckets"]

    # attribute sampled PCs
    print("attributing %d samples (%d unique PCs) via addr2line..."
          % (len(all_pcs), len(set(all_pcs))), flush=True)
    amap = addr2line_map(elf, sorted(set(all_pcs)))
    outer = Counter()
    inner = Counter()
    for pc in all_pcs:
        (f_in, _), (f_out, _) = amap[pc]
        outer[f_out] += 1
        inner[f_in] += 1
    report["pc_profile"] = {
        "outer": outer.most_common(30),
        "inner": inner.most_common(40),
        "samples": len(all_pcs),
    }
    print("outer frames:")
    for name, n in outer.most_common(15):
        print("  %8d  %s" % (n, name), flush=True)
    print("inner frames:")
    for name, n in inner.most_common(20):
        print("  %8d  %s" % (n, name), flush=True)

    # ---- 3. isolated calls on the live state ----------------------------
    for name, fargs, pad in (("game_update", (), True),
                             ("telemetry_write", (), False)):
        if name not in sym:
            continue
        costs = [call_func(vm, sym[name], fargs, pad_on_stack=pad)
                 for _ in range(2)]
        T.wait_frames(vm, 1)
        report["calls"][name] = costs
        print("call %-20s %s steps" % (name, costs), flush=True)

    # ---- allocator worst cases ------------------------------------------
    off = T.EBULLET_BASE - T.SCRATCH_BASE
    eb_flags = [vm.scratch[off + i * 8 + 6] for i in range(T.EBULLET_COUNT)]
    saved_hi = vm.load(sym["eb_hi"], 4)
    if "alloc_ebullet" in sym:
        c = call_func(vm, sym["alloc_ebullet"])
        report["alloc"]["alloc_ebullet_live"] = c
        for i in range(T.EBULLET_COUNT):
            vm.scratch[off + i * 8 + 6] = eb_flags[i]
        T.poke(vm, sym["eb_hi"], saved_hi, 4)
        for i in range(T.EBULLET_COUNT):
            vm.scratch[off + i * 8 + 6] = 1
        report["alloc"]["alloc_ebullet_full"] = call_func(vm, sym["alloc_ebullet"])
        if "alloc_orb" in sym:
            report["alloc"]["alloc_orb_full"] = call_func(vm, sym["alloc_orb"])
        for i in range(T.EBULLET_COUNT):
            vm.scratch[off + i * 8 + 6] = eb_flags[i]
        T.poke(vm, sym["eb_hi"], saved_hi, 4)
        print("alloc:", report["alloc"], flush=True)
    T.wait_frames(vm, 2)

    # Demand was captured BEFORE isolated calls mutated the live state.
    print("last natural pass: peak demand=%d, predicted/actual DROP=%d" %
          (report["buckets"]["peak"], report["buckets"]["predicted_drops"]), flush=True)

    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("report ->", args.report, flush=True)


if __name__ == "__main__":
    main()
