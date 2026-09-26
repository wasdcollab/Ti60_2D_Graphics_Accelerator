"""Exercise the linked RV32I game's three-stage state machine in the VM.

Long kill/grind sections are fixture-controlled through named BSS symbols;
all transitions, attacks, rendering, and telemetry still run in real firmware.
This is a functional test, not a board-FPS measurement.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
import test_runner as t
from rv32i_soc_vm import RAM_BASE, SCRATCH_BASE


def symbols():
    nm = ROOT.parent / "toolchain/riscv-gcc/bin/riscv-none-elf-nm.exe"
    output = subprocess.check_output([str(nm), str(ROOT / "sw/build/firmware.elf")], text=True)
    return {cols[2]: int(cols[0], 16) for line in output.splitlines()
            if len(cols := line.split()) >= 3}


def put(vm, syms, name, value, size=2):
    off = syms[name] - RAM_BASE
    vm.ram[off:off + size] = value.to_bytes(size, "little", signed=value < 0)


def frame(vm, budget=5_000_000):
    before = t.tlm(vm, "frames")
    for _ in range(budget):
        vm.step()
        if t.tlm(vm, "frames") != before:
            return
    raise AssertionError("firmware did not finish the next game frame")


def until(vm, predicate, frames=4):
    for _ in range(frames):
        if predicate():
            return
        frame(vm)
    assert predicate(), "expected stage state was not reached"


def dialogue(vm, syms):
    assert t.tlm(vm, "dialog") == 1
    x, y = t.player_pos(vm)
    vm.joy = (255 << 8) | 255
    for line in (2, 3, 0):
        put(vm, syms, "dialog_timer", 1)
        until(vm, lambda: t.tlm(vm, "dialog") == line)
        assert t.player_pos(vm) == (x, y), "dialogue did not freeze the battle"
    vm.joy = (128 << 8) | 128


def main():
    code = t.load_code_from_source(t.DEFAULT_SOURCE)
    syms = symbols()
    vm = t.new_vm(code)
    t.menu_enter(vm, 1)
    assert t.tlm(vm, "stage") == 1
    beam = 0x01629000 - SCRATCH_BASE
    assert int.from_bytes(vm.scratch[beam:beam + 4], "little") == 0x00FF00FF
    assert any(vm.scratch[beam + x * 4 + 3] == 255 for x in range(16)), \
        "laser strip lacks non-key alpha pixels"
    print("booted stage 1", flush=True)

    # A good drop and two visibly labelled curse types must have real effects.
    for kind, field in ((0, "lives"), (5, "slow"), (6, "jam")):
        x, y = t.player_pos(vm)
        off = t.ITEM_BASE - SCRATCH_BASE
        vm.scratch[off:off + 8] = (x.to_bytes(2, "little") + y.to_bytes(2, "little") +
                                   bytes((0, kind, 1, 0)))
        prev = t.tlm(vm, field)
        for _ in range(3):
            frame(vm)
            if t.tlm(vm, field) > prev:
                break
        assert t.tlm(vm, field) > prev, (kind, field)
    vm.joy = (128 << 8) | 180
    frame(vm)
    old_x = t.tlm(vm, "player_x")
    frame(vm)
    assert t.tlm(vm, "player_x") - old_x == 2, "SLOW did not reduce speed"
    vm.joy = (128 << 8) | 128
    print("pickup and debuff checks passed", flush=True)

    visited = []
    out = ROOT / "simulator/output/story"
    out.mkdir(parents=True, exist_ok=True)
    for stage in (1, 2, 3):
        assert t.tlm(vm, "stage") == stage
        print("entering stage", stage, flush=True)
        put(vm, syms, "spawn_timer", 0)
        until(vm, lambda: t.tlm(vm, "enemies") > 0)
        types = [vm.scratch[t.ENEMY_BASE - SCRATCH_BASE + i * t.ENEMY_STRIDE + 10]
                 for i in range(t.ENEMY_COUNT)
                 if vm.scratch[t.ENEMY_BASE - SCRATCH_BASE + i * t.ENEMY_STRIDE + 13]]
        assert all(kind in ({0, 2} if stage == 1 else
                            {1, 3} if stage == 2 else {0, 1, 2, 3})
                   for kind in types), types
        put(vm, syms, "kills", t.tlm(vm, "kills") + 100)
        put(vm, syms, "spawn_timer", 0)
        # Clear the fixture field so the quota deterministically brings in the boss.
        for i in range(t.ENEMY_COUNT):
            vm.scratch[t.ENEMY_BASE - SCRATCH_BASE + i * t.ENEMY_STRIDE + 13] = 0
        until(vm, lambda: t.tlm(vm, "dialog") == 1)
        t.save_frame(vm, vm.right_request, out / ("dialog_%d.bmp" % stage),
                     out / ("dialog_%d.png" % stage))
        dialogue(vm, syms)
        print("dialogue passed", stage, flush=True)
        put(vm, syms, "boss_y", 44)
        until(vm, lambda: t.tlm(vm, "boss_st") == 2)
        x0, y0 = t.tlm(vm, "boss_x"), t.tlm(vm, "boss_y")
        for _ in range(12):
            frame(vm)
        x1, y1 = t.tlm(vm, "boss_x"), t.tlm(vm, "boss_y")
        assert x0 != x1 and y0 != y1, "boss did not move on both axes"
        assert t.GAME_LEFT + 8 <= x1 <= t.GAME_RIGHT - 72
        assert 44 <= y1 <= 468
        visited.append((x1, y1))
        t.save_frame(vm, vm.right_request, out / ("boss_%d.bmp" % stage),
                     out / ("boss_%d.png" % stage))
        print("boss roamed", stage, (x1, y1), flush=True)

        if stage == 1:
            put(vm, syms, "weapon", 2, 1)
            put(vm, syms, "boss_x", t.tlm(vm, "player_x") - 32)
            put(vm, syms, "boss_y", 180)
            put(vm, syms, "boss_target_x", t.tlm(vm, "player_x") - 32)
            put(vm, syms, "boss_target_y", 180)
            put(vm, syms, "boss_move_timer", 30, 1)
            hits = t.tlm(vm, "laser_hits")
            blends = vm.blit_alpha_calls
            vm.btn = t.raw_btn("x")
            until(vm, lambda: t.tlm(vm, "laser_hits") > hits)
            frame(vm)
            t.save_frame(vm, vm.right_request, out / "laser.bmp", out / "laser.png")
            vm.btn = t.raw_btn()
            assert vm.blit_alpha_calls - blends >= 2, "beam + aura did not both blend"
            frame(vm)
            still = t.tlm(vm, "laser_hits")
            frame(vm)
            assert t.tlm(vm, "laser_hits") == still, "released laser still caused damage"
            put(vm, syms, "weapon", 0, 1)
            print("laser passed", flush=True)

        put(vm, syms, "boss_hp", 0)
        until(vm, lambda: t.tlm(vm, "boss_st") == 3)
        put(vm, syms, "boss_dead_timer", 0, 1)
        until(vm, lambda: t.tlm(vm, "stage") == stage + 1 if stage < 3 else t.tlm(vm, "boss_st") == 0)

    assert t.tlm(vm, "stage") == 3
    assert t.tlm(vm, "boss_st") == 0
    assert vm.ram[syms["game_clear"] - RAM_BASE] == 1
    frame(vm)
    t.save_frame(vm, vm.right_request, out / "all_clear.bmp", out / "all_clear.png")
    vm.btn = t.raw_btn("ok")
    until(vm, lambda: t.tlm(vm, "stage") == 1)
    vm.btn = t.raw_btn()
    assert vm.blit_alpha_calls > 0
    assert vm.min_sp >= 0xF900FC00
    print("PASS 3 stages, dialogues, 2D boss motion, debuffs, held laser, alpha+key;", visited)


if __name__ == "__main__":
    main()
