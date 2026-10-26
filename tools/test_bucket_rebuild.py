#!/usr/bin/env python
"""Exercise the linked RV32 game renderer against independent bucket vectors.

Runs real firmware instructions, including alternate-buffer shrink/empty cases.
Instruction counts are an A/B software metric, NOT a prediction of board FPS.
Use --source path/to/firmware.bin (with matching .sym and .elf) for a baseline.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
os.environ.setdefault("SIM_PURE_PYTHON", "1")
import test_runner as T


def symbols(elf):
    gcc = Path(os.environ.get("RISCV_GCC_DIR", r"E:\FPGA\toolchain\riscv-gcc"))
    nm = gcc / "bin" / "riscv-none-elf-nm.exe"
    if not nm.exists():
        plain = gcc / "bin" / "riscv-none-elf-nm"
        nm = plain if plain.exists() else Path(shutil.which("riscv-none-elf-nm") or "")
    if not nm or not Path(nm).exists():
        raise FileNotFoundError("riscv-none-elf-nm")
    result = subprocess.check_output([str(nm), str(elf)], text=True)
    return {line.split()[2]: int(line.split()[0], 16)
            for line in result.splitlines() if len(line.split()) == 3}


def check_stress_hud(vm, sym):
    """Check population against pools and the whole HUD band against font pixels."""
    seen, peak, drops, loads = set(), 0, 0, []
    bg = T.mm_value("MM_VISUAL_BACKGROUND")
    pitch = T.SCREEN_PITCH

    def word(addr):
        off = addr - T.SCRATCH_BASE
        return int.from_bytes(vm.scratch[off:off + 4], "little")

    presses = tuple(range(12, 153, 10)) + (232,)
    for frame in range(244):
        held_y = any(start <= frame < start + 4 for start in presses)
        vm.btn = T.raw_btn("x", "y") if held_y else T.raw_btn("x")
        assert T.wait_frames(vm, 1), "stress stage stopped publishing"
        target = vm.load(sym["stress_target"], 2)
        if not loads or loads[-1] != target:
            loads.append(target)
        population = 0
        for base, count, stride, flag in (
                (T.EBULLET_BASE, T.EBULLET_COUNT, 8, 6),
                (T.PBULLET_BASE, T.PBULLET_COUNT, 8, 6),
                (T.ENEMY_BASE, T.ENEMY_COUNT, T.ENEMY_STRIDE, 13),
                (T.ITEM_BASE, T.ITEM_COUNT, 8, 6)):
            population += sum(bool(vm.scratch[base - T.SCRATCH_BASE + i * stride + flag] & 1)
                              for i in range(count))
        population += T.peek(vm, "lives", 1) != 0
        population += T.peek(vm, "boss_state", 1) != 0 and T.peek(vm, "boss_hp", 2) > 0
        assert T.tlm(vm, "sprites") == population, "population telemetry differs from pools"
        peak = max(peak, population)
        drops = max(drops, T.tlm(vm, "bucket_drops"))
        # HUD_SIG_STRESS is the ninth watcher; decode the actual sampled value,
        # not this frame's population (the display refreshes every 16 ticks).
        sample = vm.load(sym["hud_sig"] + 8 * 4)
        seen.add(vm.right_request)
        expected = [word(bg + (y * pitch + x) * 4)
                    for y in range(592, 704) for x in range(177)]
        for x0, y0, text, scale in ((8, 600, "SPRITES", 2),
                                   (8, 620, "%04d" % (sample & 4095), 3),
                                   (8, 652, "LOAD", 2),
                                   (89, 648, "%04d" % target, 3),
                                   (8, 684, "DROP", 2),
                                   (68, 680, "%05d" % (sample >> 16), 3)):
            atlas = word(T.mm_value("MM_FONT_TABLE") + (scale - 1) * 4)
            for i, ch in enumerate(text):
                glyph = ord(ch) - 32
                gx, gy = (glyph % 16) * 8 * scale, (glyph // 16) * 8 * scale
                for dy in range(8 * scale):
                    for dx in range(6 * scale):
                        color = word(atlas + (gy + dy) * 512 * scale + (gx + dx) * 4)
                        if color != T.ALPHA_KEY:
                            expected[(y0 + dy - 592) * 177 + x0 + i * 7 * scale + dx] = color
        actual = vm.fb[vm.right_request]
        got = [actual[y * pitch + x] for y in range(592, 704) for x in range(177)]
        if got != expected:
            bad = [(i % 177, i // 177 + 592, hex(a), hex(b))
                   for i, (a, b) in enumerate(zip(got, expected)) if a != b]
            raise AssertionError("stress HUD sample=%#x frame=%d: %d mismatches, first=%r" %
                                 (sample, T.tlm(vm, "frames"), len(bad), bad[:8]))
    assert len(seen) == 2, "both framebuffers were not exercised"
    assert loads == list(range(192, 2113, 128)) + [192], ("Y edge/cycle", loads)
    assert peak >= 2000, ("stress population did not reach 2000", peak)
    print("PASS: 244 frames, exact HUD pixels on both buffers; peak population=%d, row drops=%d"
          % (peak, drops), flush=True)
    print("PASS: held Y advances once per press; load cycle %s" % loads, flush=True)
    T.save_frame(vm, vm.right_request, ROOT / "simulator/output/stress_counters.bmp",
                 ROOT / "simulator/output/stress_counters.png")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, default=ROOT / "sw/build/firmware.bin")
    ap.add_argument("--report", type=Path)
    ap.add_argument("--check-hud", action="store_true")
    args = ap.parse_args()
    code = T.load_code_from_source(args.source)
    sym = symbols(args.source.with_suffix(".elf"))
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    T._enter_pressure_stage(vm)
    assert T.wait_frames(vm, 3), "pressure stage did not publish"
    assert T.peek(vm, "wave", 2) == 1
    # Same workload for both binaries, excluding the newly added HUD. The
    # interactive stage and its HUD are checked by the stresslab scenario.
    T.poke(vm, sym["is_stress_stage"], 0)
    table = T.mm_value("MM_BUCKET_TABLE")
    # MM_BUCKET_ROWS counts GROUPS now, not scanlines: the firmware appends one
    # entry per group a bullet crosses and stores the tile row of the group's
    # first scanline.  This file re-derives the whole table independently, so the
    # grouping has to be re-derived here too.
    rows, slots = T.mm_value("MM_BUCKET_ROWS"), T.mm_value("MM_BUCKET_SLOTS")
    group_rows = T.mm_value("MM_BUCKET_GROUP_ROWS")
    screen_rows = T.SCREEN_H
    stride = T.mm_value("MM_BUCKET_STRIDE")
    table_bytes = rows * stride
    used_base = T.mm_value("MM_BUCKET_USED")
    # Derive occupied rows from actual boot-built tile bytes, independently
    # of the renderer's compact bounds. No nontransparent pixel may be culled.
    occupied = []
    for slot in range(19):
        if slot < 16:
            base, pitch, width, height = T.mm_value("MM_EBULLET_DIRTILE") + slot * 832, 32, 26, 26
        else:
            key, pitch, width, height = (("MM_PBULLET_TILE", 8, 7, 26),
                                        ("MM_ORB_TILE", 16, 16, 16),
                                        ("MM_MISSILE_TILE", 16, 13, 26))[slot - 16]
            base = T.mm_value(key)
        live_rows = [y for y in range(height) if any(vm.scratch[
            base - T.SCRATCH_BASE + y * pitch:base - T.SCRATCH_BASE + y * pitch + width])]
        if "bt_tile_rows" in sym:
            bounds = vm.load(sym["bt_tile_rows"] + slot * 2, 2)
            assert (bounds & 31, bounds >> 5) == (min(live_rows), max(live_rows) + 1), slot
            occupied.append(range(min(live_rows), max(live_rows) + 1))
        else:
            occupied.append(range(height))
    expected_other = [None, None]
    results = []
    header = (ROOT / "sw/driver/gpu2d.h").read_text(encoding="utf-8")
    framebuffers = [int(re.search(r"#define\s+" + key + r"\s+(0x[0-9A-Fa-f]+)",
                                 header)[1], 16)
                    for key in ("FB_LEFT_FRONT", "FB_LEFT_BACK")]

    # Dense steady frames, asymmetric shrink, empty, full pools, overflow,
    # top/bottom clipping, and recovery on BOTH tables.
    cases = [("steady192", 192, 96)] * 6 + [("steady320", 320, 128)] * 6
    cases += [("shrink", 37, 3), ("empty", 0, 0), ("empty", 0, 0)]
    cases += [("full", T.EBULLET_COUNT, T.PBULLET_COUNT)] * 2 + [("overflow", slots + 20, 0)] * 2
    cases += [("edges", 4, 4)] * 2 + [("empty", 0, 0)] * 2
    for index, (name, enemies, players) in enumerate(cases):
        T.clear_pool(vm, T.EBULLET_BASE, T.EBULLET_COUNT, 8, 6)
        T.clear_pool(vm, T.PBULLET_BASE, T.PBULLET_COUNT, 8, 6)
        expected = [[] for _ in range(rows)]
        drops = 0
        for player, n in ((True, players), (False, enemies)):
            base = T.PBULLET_BASE if player else T.EBULLET_BASE
            for i in range(n):
                x = 240 + (i * 37) % 800
                y = 30 + (i * 53) % 700
                if name == "overflow":
                    y = 200
                if name == "edges":
                    y = (-30, -1, 767, 800)[i]
                hue = i & 7
                off = base - T.SCRATCH_BASE + i * 8
                vm.scratch[off:off + 8] = struct.pack("<hhbbBB", x, y, 3, 0, 1, hue)
                top, left = (y, x) if player else (y - 13, x - 13)
                width, slot = (7, 16) if player else (26, 0)  # east-pointing rice
                # One entry per bucket the tile crosses, carrying the tile row of
                # that bucket's FIRST scanline, biased +8 so the negative values a
                # group boundary produces (the group starts above the tile) stay
                # unsigned.  Same expression as bucket_put_run() in main.c.
                r0, r1 = occupied[slot].start, occupied[slot].stop
                scr0 = max(top + r0, 0)
                scr1 = min(top + r1, screen_rows)
                if scr0 >= scr1:
                    continue
                for g in range(scr0 // group_rows, (scr1 - 1) // group_rows + 1):
                    tb = g * group_rows - top + 8
                    tb = 0 if tb < 0 else (63 if tb > 63 else tb)
                    entry = ((hue << 29) | (width << 24) | (slot << 17)
                             | (tb << 11) | left)
                    if len(expected[g]) < slots:
                        expected[g].append(entry)
                    else:
                        drops += 1
        # Allocators normally maintain these bounds; injection names them
        # explicitly, including the reserved 32-entry orb tail.
        T.poke(vm, sym["pb_hi"], players)
        T.poke(vm, sym["eb_hi"], min(enemies, T.EBULLET_COUNT - 32))
        buf = index & 1
        fb = framebuffers[buf]
        vm.active = vm.request = vm.right_active = vm.right_request = framebuffers[buf ^ 1]
        regs = list(vm.r)
        regs[1], regs[2], regs[10] = 0xFFFFFFFC, 0xF9010000, fb
        vm.r = regs
        vm.pc = sym["game_render"]
        start = vm.steps
        observed = {"table_stores": 0}
        original_store = vm.store

        def track_store(addr, value, size):
            if addr == sym["damage_track"] and "bucket_instructions" not in observed:
                observed["bucket_instructions"] = vm.steps - start + 1
            if table <= addr < table + 2 * table_bytes:
                observed["table_stores"] += 1
            return original_store(addr, value, size)

        vm.store = track_store
        while vm.pc != 0xFFFFFFFC and vm.steps - start < 4_000_000:
            vm.step()
        vm.store = original_store
        assert vm.pc == 0xFFFFFFFC, "renderer did not return"
        vm.drain()
        packed = b"".join(struct.pack("<%dI" % slots, *(r + [0] * (slots - len(r))))
                          for r in expected)
        expected_other[buf] = packed
        for b, want in enumerate(expected_other):
            if want is not None:
                off = table - T.SCRATCH_BASE + b * table_bytes
                assert vm.scratch[off:off + table_bytes] == want, (name, index, b)
        off = used_base - T.SCRATCH_BASE + buf * rows
        assert vm.scratch[off:off + rows] == bytes(map(len, expected)), (name, "ledger")
        if "bt_dropped" in sym:
            got = vm.load(sym["bt_dropped"], 4)
            assert got == drops, (name, "drops", got, drops)
        results.append(dict(case=name, buffer=buf, instructions=vm.steps - start,
                            entries=sum(map(len, expected)), drops=drops, **observed))
        print(results[-1], flush=True)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print("PASS: linked renderer, both table contents, depth ledgers, clipping and overflow")
    if args.check_hud:
        vm = T.new_vm(code)
        T._enter_pressure_stage(vm)
        assert T.wait_frames(vm, 3)
        check_stress_hud(vm, sym)


if __name__ == "__main__":
    main()
