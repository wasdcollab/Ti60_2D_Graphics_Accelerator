#!/usr/bin/env python
"""Verify cold/warm rice directions and dynamic held/zero-velocity aiming."""
import hashlib
import json
import struct

from profile_stress_frame import ROOT, T, symbols, call_func
from bucket_demand import aim_index


def main():
    source = ROOT / "sw/build/firmware.bin"
    code = T.load_code_from_source(source)
    sym = symbols(source.with_suffix(".elf"))
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    T._enter_pressure_stage(vm)
    assert T.wait_frames(vm, 3)
    T.poke(vm, sym["is_stress_stage"], 0, 1)
    T.clear_pool(vm, T.EBULLET_BASE, T.EBULLET_COUNT, 8, 6)
    T.clear_pool(vm, T.PBULLET_BASE, T.PBULLET_COUNT, 8, 6)
    T.poke(vm, sym["pb_hi"], 0)
    T.poke(vm, sym["eb_hi"], 1)
    base = T.EBULLET_BASE - T.SCRATCH_BASE
    table = T.mm_value("MM_BUCKET_TABLE")
    rows, stride = T.mm_value("MM_BUCKET_ROWS"), T.mm_value("MM_BUCKET_STRIDE")
    group = T.mm_value("MM_BUCKET_GROUP_ROWS")
    fb = vm.right_request
    costs = []

    def render(direction, label):
        other = next(addr for addr in vm.fb if addr != fb)
        vm.active = vm.request = vm.right_active = vm.right_request = other
        before = vm.steps
        call_func(vm, sym["game_render"], (fb,))
        vm.drain()
        buf = vm.load(sym["bt_buf"], 4)
        packed = vm.load(sym["bt_tile_rows"] + direction * 2, 2)
        first, end = packed & 31, packed >> 5
        x, y = 700 - 13, 400 - 13
        active = range((y + first) // group, (y + end - 1) // group + 1)
        for g in range(rows):
            depth = vm.load(T.mm_value("MM_BUCKET_USED") + buf * rows + g, 1)
            assert depth == int(g in active), (label, g, depth)
            if depth:
                expected = (3 << 29) | (26 << 24) | (direction << 17) | ((g * group - y + 8) << 11) | x
                assert vm.load(table + buf * rows * stride + g * stride, 4) == expected, (label, g)
        return vm.steps - before

    for a in range(16):
        vx = vm.load(sym["dir16_x"] + a, 1, signed=True) * 3 >> 4
        vy = vm.load(sym["dir16_y"] + a, 1, signed=True) * 3 >> 4
        direction = aim_index(vx, vy)
        vm.scratch[base:base + 8] = struct.pack("<hhbbBB", 700, 400, vx, vy, 1, 3)
        cold = render(direction, (a, "cold"))
        assert vm.scratch[base + 7] == (128 | direction << 3 | 3)
        warm = render(direction, (a, "warm"))
        costs.append(dict(direction=direction, cold=cold, warm=warm))
    # New spawns overwrite hue, so a reused slot must discard its old direction.
    for flags in (1, 5):
        vm.scratch[base:base + 8] = struct.pack("<hhbbBB", 700, 400, 0, 0, flags, 3)
        for px, py in ((400, 400), (1000, 600), (700, 100)):
            T.poke(vm, sym["player_x"], px, 2)
            T.poke(vm, sym["player_y"], py, 2)
            render(aim_index(px - 700, py - 400), (flags, px, py))
            assert vm.scratch[base + 7] == 3, "dynamic shot was incorrectly cached"
    # Same transition as lock-on release: remove HELD and set flight velocity.
    vm.scratch[base + 4:base + 7] = bytes((0, 3, 1))
    render(4, "released")
    assert vm.scratch[base + 7] == (128 | 4 << 3 | 3)
    render(4, "released warm")
    report = dict(bin_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), costs=costs)
    (ROOT / "work_sim/fps_cache_directions.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: 16 cold/warm directions, slot reuse, held/zero-velocity tracking and held release")


if __name__ == "__main__":
    main()
