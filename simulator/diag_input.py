# -*- coding: utf-8 -*-
"""Minimal input probe: menu stick walk with the new VM tick."""
import sys
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SIM_DIR))

from test_runner import (new_vm, load_code_from_source, DEFAULT_SOURCE, wait_for_boot,
                         TICK, peek)

PAD_AXIS = 0xF900FA78


def axis_state(vm):
    return (vm.ram[PAD_AXIS - 0xF9000000], vm.ram[PAD_AXIS + 1 - 0xF9000000])


code = load_code_from_source(DEFAULT_SOURCE)
vm = new_vm(code)
vm.joy = (128 << 8) | 128
wait_for_boot(vm)
for _ in range(TICK * 2):
    vm.step()
print("axis:", axis_state(vm), "menu_sel:", peek(vm, 'menu_sel'))
vm.joy = (216 << 8) | 128
for i in range(6):
    for _ in range(TICK):
        vm.step()
    print("  +%d ticks: axis %r menu_sel %d" % (i + 1, axis_state(vm), peek(vm, 'menu_sel')))
vm.joy = (128 << 8) | 128
for _ in range(TICK * 4):
    vm.step()
print("released: axis %r menu_sel %d" % (axis_state(vm), peek(vm, 'menu_sel')))
