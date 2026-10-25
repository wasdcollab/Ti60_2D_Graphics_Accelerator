#!/usr/bin/env python
"""Check real linked storm births at the inlined update's final step store."""
from collections import Counter
import hashlib
import json
import struct

from profile_stress_frame import ROOT, T, call_func, symbols
from bucket_demand import aim_index


def main():
    source = ROOT / "sw/build/firmware.bin"
    code = T.load_code_from_source(source)
    sym = symbols(source.with_suffix(".elf"))
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    T._enter_pressure_stage(vm)
    assert T.wait_frames(vm, 3)
    results = []
    for start, target in [(s, 2112) for s in range(48)] + [(65520, 2112), (7, 5), (9, 0)]:
        T.clear_pool(vm, T.EBULLET_BASE, T.EBULLET_COUNT, 8, 6)
        T.clear_pool(vm, T.PBULLET_BASE, T.PBULLET_COUNT, 8, 6)
        T.clear_pool(vm, T.ENEMY_BASE, T.ENEMY_COUNT, T.ENEMY_STRIDE, 13)
        for name, value, size in (("stress_storm_step", start, 2),
                                  ("stress_target", target, 2),
                                  ("boss_fire_timer", 100, 1),
                                  ("boss_pat_timer", 100, 1),
                                  ("lockon_arm", 0, 1),
                                  ("boss_x", 650, 2), ("boss_y", 300, 2)):
            vm.store(sym[name], value, size)
        observed = []
        store = vm.store

        def capture(addr, value, size):
            result = store(addr, value, size)
            if addr == sym["stress_storm_step"]:
                records = [struct.unpack_from("<hhbbBB", vm.scratch,
                           T.EBULLET_BASE - T.SCRATCH_BASE + i * 8)
                           for i in range(T.EBULLET_COUNT)]
                live = [r for r in records if r[4] & 1]
                cx, cy = vm.load(sym["boss_x"], 2) + 32, vm.load(sym["boss_y"], 2) + 28
                px, py = vm.load(sym["player_x"], 2), vm.load(sym["player_y"], 2)
                observed.append((vm.load(addr, 2), live, cx, cy, px, py))
            return result

        vm.store = capture
        try:
            call_func(vm, sym["game_update"], pad_on_stack=True)
        finally:
            vm.store = store
        n = min(48, target)
        if not n:
            assert not observed and vm.load(sym["stress_storm_step"], 2) == start
            results.append(dict(start=start, births=0))
            continue
        assert len(observed) == 1, observed
        end, live, cx, cy, px, py = observed[0]
        assert end == (start + n) & 65535 and len(live) == n, (start, end, len(live))
        hues, edges = Counter(), Counter()
        for i, (x, y, vx, vy, flags, hue) in enumerate(live):
            step = start + i
            expected = 5 if step % 3 == 0 else 3 if step % 6 == 1 else 4
            assert hue == expected and flags == 1, (step, hue, expected, flags)
            hues[hue] += 1
            if hue in (3, 5):
                factor = 11 if hue == 5 else 5
                assert (x, y) == (cx, cy + (step * factor % 16) * 9 - 67)
                a = ((step * 2) & 15) if hue == 5 else (
                    aim_index(px - cx, py - cy) + ((step >> 2) & 3) - 1) & 15
                dx = vm.load(sym["dir16_x"] + a, 1, signed=True)
                dy = vm.load(sym["dir16_y"] + a, 1, signed=True)
                assert (vx, vy) == (dx * 3 >> 4, dy * 3 >> 4)
            else:
                left = bool(step & 2)
                # Right births are clamped by spawn_ebullet to GAME_RIGHT-16.
                assert (x, vx, vy) == ((183, 3, 0) if left else (1169, -3, 0))
                assert 48 <= y < 720
                edges["left" if left else "right"] += 1
        if n == 48:
            assert hues == {5: 16, 3: 8, 4: 24} and edges == {"left": 12, "right": 12}
        results.append(dict(start=start, births=n, hues=hues, edges=edges))
    report = dict(bin_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), cases=results)
    (ROOT / "work_sim/storm_round2_mix.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: 51 linked-firmware cases: 48 phases, uint16 wrap, short fill, zero room")
    print("Every full cycle: ring=16 cone=8 wall=24; walls left/right=12/12")


if __name__ == "__main__":
    main()
