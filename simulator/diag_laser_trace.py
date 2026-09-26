# -*- coding: utf-8 -*-
"""Diag v3: track the laser columns frame-by-frame across the expiry."""
import sys
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SIM_DIR))

import test_runner as tr
from test_runner import (new_vm, load_code_from_source, DEFAULT_SOURCE, start_game,
                         poke, sym_addr, tlm, wait_frames, wait_published, clear_pool,
                         ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, SCRATCH_BASE,
                         BACKGROUND_PLANE, BACKGROUND_PLATE, SCREEN_H,
                         SCREEN_PITCH, SCREEN_STRIDE, BOSS_FIGHT)

LASER_BAR_H = 480
COL_BLOCKS = [256, 512, 768, 1024]
LASER_LEFT = [301, 552, 803, 1054]     # BOSS_LASER_X(k) - 5
RESTORE_FLAG = 0xF900F9D0               # laser_was_active (firmware.map)
SHAKE_ADDR = 0xF900FA3A                 # boss_shake (firmware.map)
PEND_OPENER = 0xF900FA3B                # boss_pending_opener (firmware.map)
BANNER_ADDR = 0xF900FA1C                # stage_banner (firmware.map)


def mismatch_report(vm, stage_idx, tag):
    fb = vm.fb[vm.right_request]
    off = BACKGROUND_PLANE - SCRATCH_BASE + stage_idx * BACKGROUND_PLATE
    y0 = (SCREEN_H - LASER_BAR_H) // 2
    bad_x = {}
    totals = [0, 0]      # whole-block, bar-only
    bads = [0, 0]
    for x0, bx in zip(COL_BLOCKS, LASER_LEFT):
        for y in range(y0, y0 + LASER_BAR_H, 2):
            srow = off + y * SCREEN_STRIDE
            frow = y * SCREEN_PITCH
            for x in range(x0, x0 + 64):
                exp = int.from_bytes(vm.scratch[srow + x * 4:srow + x * 4 + 4], "little")
                if fb[frow + x] != exp:
                    bads[0] += 1
                    bad_x[x] = bad_x.get(x, 0) + 1
                    if bx <= x < bx + 16:
                        bads[1] += 1
                totals[0] += 1
                if bx <= x < bx + 16:
                    totals[1] += 1
    xs = sorted(bad_x)
    spans = []
    for x in xs:
        if spans and x - spans[-1][1] <= 1:
            spans[-1][1] = x
        else:
            spans.append([x, x])
    print("  [%s] whole %.1f%% (%d/%d) bar %.1f%% (%d/%d) spans %s"
          % (tag, 100.0 * bads[0] / totals[0], bads[0], totals[0],
             100.0 * bads[1] / totals[1], bads[1], totals[1],
             spans[:12]))


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
    poke(vm, SHAKE_ADDR, 0, 1)
    poke(vm, PEND_OPENER, 0, 1)
    poke(vm, sym_addr('boss_state'), BOSS_FIGHT, 1)
    poke(vm, BANNER_ADDR, 0, 2)
    poke(vm, sym_addr('boss_pat_timer'), 127, 1)
    poke(vm, sym_addr('boss_fire_timer'), 127, 1)
    # pin the boss so it cannot walk into a column while we sample
    poke(vm, sym_addr('boss_hp'), 400, 2)
    assert wait_frames(vm, 2), "fight never produced a frame"

    poke(vm, sym_addr('boss_laser'), 90, 1)
    poke(vm, RESTORE_FLAG, 0, 1)
    assert wait_frames(vm, 2), "laser never came up"
    assert tlm(vm, 'laser') > 0

    # walk the last frames of the laser
    last_on = None
    while tlm(vm, 'laser') > 0:
        assert wait_frames(vm, 1), "game stopped before the laser expired"
        if tlm(vm, 'laser') == 1:
            last_on = vm.right_request
    # now tlm laser == 0: the game_frame that just finished was the restore frame
    # Freeze the field (BOSS_FREEZE) so no actor can walk over the columns
    # while we grade them; the hold never fires an opener without the pending
    # flag, and the freeze timer outlasts the six samples below.
    poke(vm, sym_addr('boss_state'), 5, 1)
    poke(vm, 0xF900FA3C, 127, 1)   # boss_freeze_timer (firmware.map)
    poke(vm, PEND_OPENER, 0, 1)
    print("stage %d: laser expired" % stage_idx)
    mismatch_report(vm, stage_idx, "F0 restore frame")
    for n in (1, 2, 3, 4, 5, 6):
        assert wait_published(vm), "no further publish"
        mismatch_report(vm, stage_idx, "F+%d" % n)


if __name__ == "__main__":
    code = load_code_from_source(DEFAULT_SOURCE)
    for s in (0, 1, 2):
        run_stage(code, s)
