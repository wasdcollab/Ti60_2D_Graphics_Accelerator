# -*- coding: utf-8 -*-
"""Diagnose: game pass period and input confirmation under the new timestep."""
import sys
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SIM_DIR))

from test_runner import (new_vm, load_code_from_source, DEFAULT_SOURCE, start_game,
                         poke, sym_addr, tlm, wait_published, raw_btn, TICK,
                         player_pos, SPAWN_X, SPAWN_Y)

code = load_code_from_source(DEFAULT_SOURCE)
vm = new_vm(code)
start_game(vm)

# --- pass period ---
s0 = vm.steps
for i in range(5):
    assert wait_published(vm)
    print("pass %d: %d steps" % (i, vm.steps - s0))
    s0 = vm.steps

# --- stick push: how many passes until the craft moves ---
start = player_pos(vm)
PX = 0xF900FA5C                     # player_x (firmware.sym)
vm.joy = (128 << 8) | 220          # x high: move right
steps = 0
for k in range(12):
    for _ in range(TICK):
        vm.step()
    steps += TICK
    px = int.from_bytes(vm.ram[PX - 0xF9000000:PX - 0xF9000000 + 2], "little", signed=True)
    axis = (vm.ram[0xF900FA78 - 0xF9000000], vm.ram[0xF900FA78 - 0xF9000000 + 1],
            vm.ram[0xF900FA79 - 0xF9000000], vm.ram[0xF900FA79 - 0xF9000000 + 1])
    print("  %d steps: player_x(RAM)=%d joy=%#x pad_axis=%r" % (steps, px, vm.joy, axis))
vm.joy = (128 << 8) | 128
for _ in range(TICK * 2):
    vm.step()

# --- centre press: does the bomb fire ---
poke(vm, sym_addr('bomb_charge'), 8, 1)
b0 = tlm(vm, 'bomb')
vm.btn = raw_btn('ok')
spent = 0
fired = None
while spent < 300_000:
    vm.step()
    spent += 1
    if tlm(vm, 'bomb') < b0:
        fired = spent
        break
vm.btn = raw_btn()
print("centre press: bomb fired after %d steps (bomb %d -> %d)" %
      (fired, b0, tlm(vm, 'bomb')))
