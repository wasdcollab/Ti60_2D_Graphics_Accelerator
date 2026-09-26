# -*- coding: utf-8 -*-
"""Diag: laser columns must vanish cleanly (background restored) on stages 0/1/2."""
import sys
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SIM_DIR))

import test_runner as tr
from test_runner import (new_vm, load_code_from_source, DEFAULT_SOURCE, start_game,
                         poke, sym_addr, tlm, wait_frames, clear_pool,
                         ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, SCRATCH_BASE,
                         BACKGROUND_PLANE, BACKGROUND_PLATE, SCREEN_H, SCREEN_W,
                         SCREEN_PITCH, SCREEN_STRIDE, BOSS_FIGHT)

LASER_BAR_H = 480
COL_BLOCKS = [256, 512, 768, 1024]   # x64 blocks used by the restore pass


def pixel_mismatch(vm, stage_idx, x_lo, x_hi):
    fb = vm.fb[vm.right_request]
    off = BACKGROUND_PLANE - SCRATCH_BASE + stage_idx * BACKGROUND_PLATE
    y0 = (SCREEN_H - LASER_BAR_H) // 2
    bad = total = 0
    for y in range(y0, y0 + LASER_BAR_H, 2):
        srow = off + y * SCREEN_STRIDE
        frow = y * SCREEN_PITCH
        for x in range(x_lo, x_hi, 1):
            exp = int.from_bytes(vm.scratch[srow + x * 4:srow + x * 4 + 4], "little")
            if fb[frow + x] != exp:
                bad += 1
            total += 1
    return bad, total


def run_stage(code, stage_idx):
    vm = new_vm(code)
    start_game(vm)
    clear_pool(vm, ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, 13)
    poke(vm, sym_addr('wave'), stage_idx, 2)
    poke(vm, sym_addr('stage_bg_active'), stage_idx, 4)
    poke(vm, sym_addr('boss_hp_max'), 400, 2)
    poke(vm, sym_addr('boss_hp'), 400, 2)
    poke(vm, sym_addr('boss_x'), 384, 2)
    poke(vm, sym_addr('boss_y'), 200, 2)
    poke(vm, 0xF900F9CA, 0, 1)   # boss_shake (firmware.map .sbss)
    poke(vm, 0xF900F9CB, 0, 1)   # boss_pending_opener (firmware.map)
    poke(vm, sym_addr('boss_state'), BOSS_FIGHT, 1)
    poke(vm, 0xF900F9AC, 0, 2)   # stage_banner (firmware.map)
    poke(vm, sym_addr('boss_pat_timer'), 127, 1)
    poke(vm, sym_addr('boss_fire_timer'), 127, 1)
    assert wait_frames(vm, 2), "fight never produced a frame"

    poke(vm, sym_addr('boss_laser'), 90, 1)
    poke(vm, 0xF900F967, 0, 1)   # laser_was_active (firmware.map)
    assert wait_frames(vm, 2), "laser never came up"
    on = tlm(vm, 'laser')
    print("  stage %d: laser up (%d frames)" % (stage_idx, on))
    assert on > 0

    while tlm(vm, 'laser') > 0:
        assert wait_frames(vm, 1), "game stopped before the laser expired"

    # first frame after laser==0: the restore pass should run and clear the flag
    assert wait_frames(vm, 1), "game stopped after the laser expired"
    flag_after = vm.ram[0xF900F967 - 0xF9000000]
    print("  stage %d: laser_was_active after the expiry frame = %d" % (stage_idx, flag_after))
    assert wait_frames(vm, 2), "game stopped after the restore"

    total_bad = total_px = 0
    bar_bad = bar_px = 0
    for x0 in COL_BLOCKS:
        bad, total = pixel_mismatch(vm, stage_idx, x0, x0 + 64)
        total_bad += bad
        total_px += total
        bbad, btotal = pixel_mismatch(vm, stage_idx, x0, x0 + 16)
        bar_bad += bbad
        bar_px += btotal
    print("  stage %d: after expiry, whole blocks %d/%d (%.1f%%), first 16px strips %d/%d (%.1f%%)"
          % (stage_idx, total_bad, total_px, 100.0 * total_bad / total_px,
             bar_bad, bar_px, 100.0 * bar_bad / bar_px))
    return total_bad, total_px


if __name__ == "__main__":
    code = load_code_from_source(DEFAULT_SOURCE)
    for s in (0, 1, 2):
        run_stage(code, s)
