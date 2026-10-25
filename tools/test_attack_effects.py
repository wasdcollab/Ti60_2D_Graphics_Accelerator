"""Linked-firmware movement, campaign and cached-alpha regression (not FPS)."""
import os
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
sys.path.insert(0, str(ROOT / "tools"))
os.environ.setdefault("SIM_PURE_PYTHON", "1")
import test_runner as T
from profile_stress_frame import symbols, call_func


def main():
    binary = ROOT / "sw/build/firmware.bin"
    sym = symbols(binary.with_suffix(".elf"))
    code = T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)

    # Check every cached frame, not just the geometric radius formula.
    base = T.mm_value("MM_BURST_FRAME")
    stride = T.mm_value("MM_BURST_FRAME_BYTES")
    tiles = []
    for age in range(24):
        radius = max(16, 8 + age * 2)
        pixels = [vm.load(base + age * stride + p * 4) for p in range(112 * 112)]
        visible = 0
        for p, value in enumerate(pixels):
            if value == 0x00FF00FF:
                continue
            x, y = p % 112, p // 112
            assert 56-radius <= x < 56+radius and 56-radius <= y < 56+radius, (age, x, y)
            assert value >> 24 == (255 if age < 16 else 255 - (age - 16) * 18), (age, hex(value))
            visible += 1
        assert visible > 100
        tiles.append(pixels)
    # Preview actual cached art on a contrasting checkerboard, using straight alpha.
    out = ROOT / "work_sim/attack_effects_preview.ppm"
    rgb = bytearray()
    for y in range(224):
        for x in range(448):
            age = (y // 112 * 4 + x // 112) * 3
            s = tiles[age][(y % 112)*112 + x % 112]
            d = (28, 43, 57) if (x//16 + y//16) % 2 else (70, 79, 88)
            a = 0 if s == 0x00FF00FF else s >> 24
            rgb.extend((((s >> shift) & 255)*a + bg*(255-a) + 127)//255
                       for shift, bg in zip((16, 8, 0), d))
    out.write_bytes(b"P6\n448 224\n255\n" + rgb)
    print("PASS cached FX: all 24 frames fit cropped ROI, alpha fades, key border preserved", flush=True)

    T._enter_pressure_stage(vm)
    assert T.wait_frames(vm, 1)
    eb = T.mm_value("MM_EBULLET_BASE")
    capacity = T.mm_value("MM_EBULLET_COUNT")
    for i in range(capacity):
        vm.store(eb+i*8+6, 0, 1)
    vm.store(eb, 500 | (300 << 16))
    vm.store(eb+4, 2 | (1 << 8) | (1 << 16))
    tail = eb+(capacity-32)*8
    vm.store(tail, 700 | (300 << 16))
    vm.store(tail+4, 1 | (2 << 8) | (65 << 16))
    lance = eb+4000*8
    vm.store(lance, 700 | (400 << 16))
    vm.store(lance+4, 2 | (1 << 8) | (9 << 16))
    vm.store(T.mm_value("MM_LANCE_INDEX"), 4000, 2)
    for name, value, size in (("eb_hi", 4001, 4), ("eb_lance_count", 1, 4),
                              ("stress_target", 0, 2), ("active_ebullets_count", 3, 4),
                              ("active_count", 3, 2), ("spawn_timer", 1000, 2),
                              ("boss_fire_timer", 255, 1), ("boss_pat_timer", 255, 1)):
        vm.store(sym[name], value, size)
    tick = vm.load(sym["frame_tick"])
    for _ in range(5):
        assert T.wait_frames(vm, 1)
    dt = vm.load(sym["frame_tick"]) - tick
    assert vm.load(eb, 2) == 500+2*dt
    assert vm.load(eb+2, 2) == 300+dt
    assert vm.load(tail, 2) == 700+dt
    assert vm.load(tail+2, 2) == 300+2*dt
    assert vm.load(lance, 2) == 700+2*dt
    assert vm.load(lance+2, 2) == 400+dt
    assert vm.load(sym["eb_lance_count"]) == 1
    # A render without a logic update must not move either pool.
    before = bytes(vm.scratch[eb-T.SCRATCH_BASE:eb-T.SCRATCH_BASE+capacity*8])
    call_func(vm, sym["bucket_build_start"], (0,))
    call_func(vm, sym["bucket_build_finish"])
    assert before == bytes(vm.scratch[eb-T.SCRATCH_BASE:eb-T.SCRATCH_BASE+capacity*8])
    print("PASS movement: CPU tail and DMA front advance exactly once per tick; idle render freezes", flush=True)

    # Saturate the hardware candidate FIFO with graze-only records. The hit
    # lies beyond entry 511, so it can only be found by the CPU fallback.
    for i in range(capacity):
        vm.store(eb+i*8+6, 0, 1)
    px, py = vm.load(sym["player_x"], 2), vm.load(sym["player_y"], 2)
    for i in range(513):
        vm.store(eb+i*8, (px+(15 if i<512 else 0)) | (py << 16))
        vm.store(eb+i*8+4, 1 << 16)
    for name, value, size in (("eb_hi", 513, 4), ("eb_lance_count", 0, 4),
                              ("eb_motion_pending", 1, 1), ("invuln", 0, 2)):
        vm.store(sym[name], value, size)
    call_func(vm, sym["bucket_build_start"], (0,))
    call_func(vm, sym["bucket_build_finish"])
    assert vm.load(eb+512*8+6, 1) == 0, "overflow fallback missed hit"
    assert vm.load(sym["active_count"], 2) == 512
    for i in range(513):
        vm.store(eb+i*8+6, 0, 1)
    vm.store(sym["eb_hi"], 0)
    vm.store(sym["eb_motion_pending"], 1, 1)
    call_func(vm, sym["bucket_build_start"], (1,))
    call_func(vm, sym["bucket_build_finish"])
    assert vm.load(sym["active_count"], 2) == 0
    print("PASS candidates: overflow hit beyond FIFO capacity found; empty job clears live count", flush=True)

    vm = T.new_vm(code)
    T.start_game(vm)
    peak, types, hues, orb_seen = 0, set(), set(), False
    for frame in range(450):
        vm.store(sym["invuln"], 255, 2)
        assert T.wait_frames(vm, 1)
        live = 0
        for i in range(T.ENEMY_COUNT):
            addr = T.ENEMY_BASE + i*T.ENEMY_STRIDE
            if vm.load(addr+13, 1) & 1:
                live += 1
                types.add(vm.load(addr+10, 1))
        peak = max(peak, live)
        for i in range(capacity):
            flags = vm.load(eb+i*8+6, 1)
            if flags & 1:
                hues.add(vm.load(eb+i*8+7, 1) & 7)
                orb_seen |= bool(flags & 64)
    assert peak >= 9, peak
    assert len(hues) >= 4 and orb_seen, (hues, orb_seen)
    print("PASS campaign: peak=%d enemies, types=%s, hues=%s, orb=%s" %
          (peak, sorted(types), sorted(hues), orb_seen), flush=True)


if __name__ == "__main__":
    main()
