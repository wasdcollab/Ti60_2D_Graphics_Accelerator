# -*- coding: utf-8 -*-
"""Quick probe: relate tlm[46] FRAME_CYC to VM steps and publishes."""
import sys
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SIM_DIR))

from test_runner import (new_vm, load_code_from_source, DEFAULT_SOURCE, start_game,
                         tlm, wait_frames, wait_published, SCRATCH_BASE, TLM_BASE)


def read_tlm_raw(vm, idx):
    off = TLM_BASE - SCRATCH_BASE + 4 * idx
    return int.from_bytes(vm.scratch[off:off + 4], "little")


code = load_code_from_source(DEFAULT_SOURCE)
vm = new_vm(code)
start_game(vm)
assert wait_frames(vm, 5)
s0 = vm.steps
print("pass | steps-delta | tlm46 | frames")
for i in range(6):
    assert wait_published(vm), "no publish"
    print("  %d  |  %8d  | %7d | %d" % (i, vm.steps - s0, read_tlm_raw(vm, 46), tlm(vm, "frames")))
    s0 = vm.steps
