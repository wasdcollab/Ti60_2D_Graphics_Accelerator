#!/usr/bin/env python
"""Check linked bucket encoding, lowest-free allocation and aim direction."""
import argparse
import hashlib
import json
from pathlib import Path

from profile_stress_frame import ROOT, T, symbols
from bucket_demand import aim_index


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, default=ROOT / "sw/build/firmware.bin")
    ap.add_argument("--report", type=Path)
    args = ap.parse_args()
    code = T.load_code_from_source(args.source)
    sym = symbols(args.source.with_suffix(".elf"))
    # These leaf kernels need only the linked image and zeroed RAM, no boot.
    from rv32i_soc_vm import SapphireSoCVM
    vm = SapphireSoCVM(code)

    def invoke(name, values):
        vm.pc = sym[name]
        vm.r[1], vm.r[2] = 0xFFFFFFFC, 0xF9010000
        for i, value in enumerate(values):
            vm.r[10 + i] = value & 0xFFFFFFFF
        start = vm.steps
        while vm.pc != 0xFFFFFFFC and vm.steps - start < 100000:
            vm.step()
        assert vm.pc == 0xFFFFFFFC, (name, vm.pc)
        return vm.r[10], vm.steps - start

    rows, slots = T.mm_value("MM_BUCKET_ROWS"), T.mm_value("MM_BUCKET_SLOTS")
    group = T.mm_value("MM_BUCKET_GROUP_ROWS")
    table = T.mm_value("MM_BUCKET_TABLE")
    stride = T.mm_value("MM_BUCKET_STRIDE")
    vm.store(sym["bt_base"], table, 4)
    count_offset = sym["bt_count"] - T.RAM_BASE
    widths = [26] * 16 + [7, 16, 13]
    bucket_cases, bucket_steps = 0, 0
    writes = []
    store = vm.store

    def capture(addr, value, size):
        if table <= addr < table + rows * stride:
            writes.append((addr, value & 0xFFFFFFFF, size))
        return store(addr, value, size)

    vm.store = capture
    for slot, width in enumerate(widths):
        packed = vm.load(sym["bt_tile_rows"] + slot * 2, 2)
        first, end = packed & 31, packed >> 5
        assert 0 <= first < end <= 26
        cases = [(y, 0) for y in range(-32, T.SCREEN_H + 33)]
        cases += [(y, depth) for y in (-32768, -26, -13, -1, 0, 7, 400, 767, 768, 32767)
                  for depth in (0, 127, 128)]
        for y, depth in cases:
            vm.ram[count_offset:count_offset + rows] = bytes([depth]) * rows
            vm.store(sym["bt_dropped"], 0, 4)
            vm.store(sym["bt_first"], rows, 2)
            vm.store(sym["bt_end"], 0, 2)
            writes.clear()
            bx, hue = (y * 19) & 2047, slot & 7
            _, cost = invoke("bucket_put_run", (y, bx, slot, width, hue))
            bucket_steps += cost
            start, stop = max(0, y + first), min(T.SCREEN_H, y + end)
            groups = list(range(start // group, (stop - 1) // group + 1)) if start < stop else []
            expected_writes = []
            counts = [depth] * rows
            for g in groups:
                raw = g * group - y + 8
                assert 1 <= raw <= 33, (slot, y, g, raw)
                if depth < slots:
                    word = (hue << 29) | (width << 24) | (slot << 17) | (max(0, min(63, raw)) << 11) | bx
                    expected_writes.append((table + g * stride + depth * 4, word, 4))
                    counts[g] += 1
            assert writes == expected_writes, (slot, y, depth, writes, expected_writes)
            assert list(vm.ram[count_offset:count_offset + rows]) == counts
            assert vm.load(sym["bt_dropped"], 4) == (len(groups) if depth == slots else 0)
            assert vm.load(sym["bt_first"], 2) == (groups[0] if groups else rows)
            assert vm.load(sym["bt_end"], 2) == (groups[-1] + 1 if groups else 0)
            bucket_cases += 1
    vm.store = store

    alloc_cases, alloc_steps = 0, 0
    for name, base, hi in (("alloc_pbullet", T.PBULLET_BASE, T.PBULLET_COUNT),
                           ("alloc_ebullet", T.EBULLET_BASE, T.EBULLET_COUNT - 128)):
        off = base - T.SCRATCH_BASE
        for i in range(hi):
            vm.scratch[off + i * 8 + 6] = 1
        # Every possible first free slot, then full (the orb tail stays empty).
        for hole in range(hi + 1):
            if hole < hi:
                vm.scratch[off + hole * 8 + 6] = 0xFE
            got, cost = invoke(name, ())
            assert got == (base + hole * 8 if hole < hi else 0), (name, hole, got)
            if hole < hi:
                vm.scratch[off + hole * 8 + 6] = 1
            alloc_cases += 1
            alloc_steps += cost

    aim_cases, aim_steps = 0, 0
    pairs = [(x, y) for x in range(-128, 128) for y in range(-128, 128)]
    pairs += [(x, y) for x in range(-1400, 1401, 37) for y in range(-800, 801, 29)]
    for dx, dy in pairs:
        got, cost = invoke("aim_index", (dx, dy))
        assert got == aim_index(dx, dy), (dx, dy, got)
        aim_cases += 1
        aim_steps += cost
    report = dict(bin_sha256=hashlib.sha256(args.source.read_bytes()).hexdigest(),
                  bucket_cases=bucket_cases, bucket_steps=bucket_steps,
                  allocator_cases=alloc_cases, allocator_steps=alloc_steps,
                  aim_cases=aim_cases, aim_steps=aim_steps)
    print("PASS:", report, flush=True)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
