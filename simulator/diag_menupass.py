# -*- coding: utf-8 -*-
"""Measure the menu pass period in VM steps."""
import sys
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SIM_DIR))

from test_runner import (new_vm, load_code_from_source, DEFAULT_SOURCE, wait_for_boot, TICK)

code = load_code_from_source(DEFAULT_SOURCE)
vm = new_vm(code)
vm.joy = (128 << 8) | 128
wait_for_boot(vm)
for _ in range(TICK * 2):
    vm.step()
s0 = vm.steps
for i in range(6):
    was = vm.right_request
    while vm.right_request == was:
        vm.step()
    print("pass %d: %d steps" % (i, vm.steps - s0))
    s0 = vm.steps
