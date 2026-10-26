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
                                  ("boss_x", 650, 2), ("boss_y", 300, 2),
                                  # The pool clear above does not touch the CPU
                                  # occupancy counter. On the hardware-motion
                                  # path bullets_update() does not rescan the
                                  # front run, so a stale count would shrink
                                  # `room` after the first case.
                                  ("active_ebullets_count", 0, 4),
                                  ("active_count", 0, 2),
                                  ("eb_free_hint", 0, 4),
                                  ("eb_hi", 0, 4),
                                  ("eb_lance_count", 0, 4)):
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
        # Budget 224, and a target >= 4000 also asks for the 64-shot reserve.
        room = target + (64 if target >= 4000 else 0)
        n = min(room, 224)
        if not n:
            assert not observed and vm.load(sym["stress_storm_step"], 2) == start
            results.append(dict(start=start, births=0))
            continue
        assert len(observed) == 1, observed
        end, live, cx, cy, px, py = observed[0]
        assert end == (start + n) & 65535 and len(live) == n, (start, end, len(live))
        sched = [0, 128, 64, 198, 1, 129, 65, 199, 2, 130, 66, 200,
                 3, 131, 67, 201, 4, 132, 68, 202, 5, 133, 69, 203]
        hues, edges = Counter(), Counter()
        for i, (x, y, vx, vy, flags, hue) in enumerate(live):
            step = start + i
            kind = sched[step % 24] >> 6
            sub = sched[step % 24] & 0x3F
            expected = 5 if kind == 0 else 3 if kind == 1 else 4
            assert hue == expected and flags == 1, (step, hue, expected, flags)
            hues[hue] += 1
            lat_y = ((step * 5) % 96) * 8 + 4
            if kind in (0, 1):
                birth_x = 189 + ((step * 17 + (400 if kind == 1 else 0)) % 960)
                assert (x, y) == (birth_x, lat_y), (step, x, y, birth_x, lat_y)
                if kind == 0:
                    a = (step * 2) & 15
                else:
                    a = (aim_index(px - cx, py - cy) + ((step & 12) >> 2) - 1
                         + (8 if sub & 1 else 0)) & 15
                dx = vm.load(sym["dir16_x"] + a, 1, signed=True)
                dy = vm.load(sym["dir16_y"] + a, 1, signed=True)
                assert (vx, vy) == (dx * 3 >> 4, dy * 3 >> 4)
            else:
                drift = -1 if (step & 1) == 0 else 1
                if not (1 <= lat_y + drift <= 767):
                    drift = -drift
                left = kind == 2
                assert (x, y, vx, vy) == ((182, lat_y, 3, drift) if left else (1169, lat_y, -3, drift))
                edges["left" if left else "right"] += 1
        if n == 224 and start == 0:
            assert hues == {5: 56, 3: 56, 4: 112} and edges == {"left": 56, "right": 56}
        results.append(dict(start=start, births=n, hues=dict(hues), edges=dict(edges)))
    report = dict(bin_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), cases=results)
    (ROOT / "work_sim/storm_round2_mix.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: 51 linked-firmware cases: lattice births, uint16 wrap, short fill, zero room")
    print("Budget 224 from step 0: ring=56 cone=56 wall=112; walls left/right=56/56")


if __name__ == "__main__":
    main()
