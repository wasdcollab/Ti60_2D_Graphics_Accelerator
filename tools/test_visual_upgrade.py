"""Validate linked-firmware effect lifetimes, priority and fixed spell origin.

No FPS is inferred from the instruction-level VM. Pixel-level RTL checks live
in tests/tb_fx_ring.sv; this test checks the actual C->APB interface contract.
"""
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "simulator"), str(ROOT / "tools")]
os.environ.setdefault("SIM_PURE_PYTHON", "1")
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func


def check_effect_descriptors(vm, syms):
    fx = T.mm_value("MM_VISUAL_FX")
    for i in range(16):
        vm.store(fx + i * 8, 0)
        vm.store(fx + i * 8 + 4, 0)
    for name in ("hit_ring_timer", "bomb_flash"):
        vm.store(syms[name], 0, 1)
    vm.r[2] = 0xF9010000

    def upload():
        call_func(vm, syms["fx_rings_upload"])
        return [tuple(vm.load(0xF8100200 + 16 * k + 4 * j) for j in range(3)) for k in range(4)]

    def active(rows):
        return [(a, b, c) for a, b, c in rows if a & 0x80000000]

    assert not active(upload()), "expired effects must disable all four slots"
    radii, alphas = [], []
    for age in range(24):
        vm.store(fx, 683 | (340 << 16))
        vm.store(fx + 4, age | 0x100)
        rows = active(upload())
        assert len(rows) == 1
        a, b, c = rows[0]
        assert (a & 2047, (a >> 11) & 1023) == (683, 340)
        if age < 4:
            assert a & 0x40000000 and c & 0x1000000, "hot core must use soft ADD"
        else:
            assert not a & 0x40000000 and (b >> 16) > 0
            radii.append((a >> 21) & 511)
            alphas.append(b & 255)
    assert radii == sorted(radii) and alphas == sorted(alphas, reverse=True)
    assert alphas[-1] <= 3, "wave must fade close to zero before expiry"
    vm.store(fx + 4, 24 | 0x100)
    assert not active(upload()), "age 24 cannot leave a stale core"
    vm.store(fx + 4, 0)
    print("PASS impact: all 24 ages, soft core, expanding hollow wave, fade and expiry", flush=True)

    vm.store(syms["bomb_x"], 683, 2); vm.store(syms["bomb_y"], 500, 2)
    waves, energies = [], []
    for age in range(36):
        vm.store(syms["bomb_flash"], 36 - age, 1)
        # Moving the player after activation must not drag the wave's centre.
        vm.store(syms["player_x"], 800 + age, 2)
        vm.store(syms["player_y"], 600, 2)
        rows = active(upload())
        assert len(rows) == 3
        assert all(a & 0x40000000 and c & 0x1000000 for a, _, c in rows[:2])
        assert sum(a & 2047 for a, _, _ in rows[:2]) in (1365, 1366)
        assert sum((a >> 11) & 1023 for a, _, _ in rows[:2]) in (999, 1000)
        a, b, _ = rows[2]
        assert (a & 2047, (a >> 11) & 1023) == (683, 500)
        assert not a & 0x40000000 and 0 < b & 255 <= 180
        waves.append((a >> 21) & 511)
        energies.append(rows[0][2] & 0xFFFFFF)
    assert waves == sorted(waves) and 300 < waves[-1] < 511
    assert energies[-1] < energies[26], "orb light must fade, not only its ignored ADD alpha"

    # Player damage takes slot zero; the three spell layers still fit exactly.
    vm.store(syms["hit_ring_timer"], 8, 1)
    rows = active(upload())
    assert len(rows) == 4 and not rows[0][0] & 0x40000000
    vm.store(syms["hit_ring_timer"], 0, 1)
    vm.store(syms["bomb_flash"], 0, 1)
    assert not active(upload())
    print("PASS spell: 36 ages, opposite orbiting orbs, anchored wave, RGB fade, four-slot priority", flush=True)


def main():
    binary = ROOT / "sw/build/firmware.bin"
    syms = _symtab(binary.with_suffix(".elf"))
    code = T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    check_effect_descriptors(vm, syms)
    assert vm.min_sp >= 0xF900FD00, "effect upload exceeded the reserved stack"
    print("PASS descriptor stack: min SP=%#x" % vm.min_sp)


if __name__ == "__main__":
    main()
