# -*- coding: utf-8 -*-
"""Diag slow-frame: does game logic advance at a constant rate vs real time?

Measures d(frames)/d(core cycles) over a 30-publish window with light and
heavy render loads.  With the fix, the ratio must stay ~1/1333333 either way;
before the fix it falls when the display frame gets longer (dropped frames).
"""
import sys
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SIM_DIR))

import test_runner as tr
from test_runner import (new_vm, load_code_from_source, DEFAULT_SOURCE, start_game,
                         tlm, wait_frames, wait_published, SCRATCH_BASE,
                         EBULLET_BASE, EBULLET_COUNT, TLM_BASE)

FRAME_CYC_IDX = 46                     # TLM_FRAME_CYC in memory_map.h
LOGIC_STEP_CYCLES = 100000000 // 75     # 1333333
PCT = 1.0 / LOGIC_STEP_CYCLES


def read_tlm_raw(vm, idx):
    off = TLM_BASE - SCRATCH_BASE + 4 * idx
    return int.from_bytes(vm.scratch[off:off + 4], "little")


def inject_load(vm, n):
    off = EBULLET_BASE - SCRATCH_BASE
    placed = 0
    for i in range(EBULLET_COUNT):
        if placed >= n:
            break
        p = off + i * 8
        if vm.scratch[p + 6]:
            continue
        x = 250 + (i * 37) % 900
        y = 140 + (i * 53) % 330
        vm.scratch[p:p + 2] = x.to_bytes(2, "little", signed=True)
        vm.scratch[p + 2:p + 4] = y.to_bytes(2, "little", signed=True)
        vm.scratch[p + 4] = 0           # vx
        vm.scratch[p + 5] = 0           # vy (static: render load, no hits)
        vm.scratch[p + 6] = 0x01        # EF_ACTIVE
        vm.scratch[p + 7] = (i % 4) + 1
        placed += 1
    return placed


def measure(code, load_n, window=60):
    vm = new_vm(code)
    start_game(vm)
    if load_n:
        placed = inject_load(vm, load_n)
        print("  injected %d static enemy bullets" % placed)
    assert wait_frames(vm, 5), "game stopped"
    f0 = tlm(vm, "frames")
    cyc = 0
    for _ in range(window):
        assert wait_published(vm), "no publish"
        cyc += read_tlm_raw(vm, FRAME_CYC_IDX)
    f1 = tlm(vm, "frames")
    return f1 - f0, cyc


if __name__ == "__main__":
    code = load_code_from_source(DEFAULT_SOURCE)
    for name, load in (("light", 0), ("heavy", 50)):
        df, cyc = measure(code, load)
        ratio = df / cyc
        print("%s load: %d logic frames over %d cycles, ratio %.9f (target %.9f, "
              "%.1f%% off)" % (name, df, cyc, ratio, PCT, 100.0 * (ratio / PCT - 1.0)))
