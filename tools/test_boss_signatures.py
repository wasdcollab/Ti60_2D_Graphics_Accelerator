"""Execute the linked RV32 firmware to check all three signature attacks.

No timing/FPS is inferred from the VM. The existing opener and the pressure
stage are checked separately so the added attacks cannot replace them.
"""
import json
import os
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "simulator"), str(ROOT / "tools")]
os.environ.setdefault("SIM_PURE_PYTHON", "1")
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func


def setup(vm, syms, stage):
    vm.r[2] = 0xF9010000
    call_func(vm, syms["game_init"])
    for name, value, size in (("stage_bg_active", stage, 4), ("wave", stage, 2),
                              ("boss_state", 2, 1), ("boss_hp_max", 1000, 2),
                              ("boss_hp", 500, 2), ("boss_opener_stage", 1, 1),
                              ("boss_x", 620, 2), ("boss_y", 150, 2),
                              ("boss_fire_timer", 255, 1), ("boss_pat_timer", 255, 1)):
        vm.store(syms[name], value, size)


def live_bullets(vm):
    base, count = T.mm_value("MM_EBULLET_BASE"), T.mm_value("MM_EBULLET_COUNT")
    result = []
    for k in range(count):
        at = base + k * 8
        if vm.load(at + 6, 1) & 1:
            result.append(struct.unpack("<hhbbBB", bytes(vm.load(at + j, 1) for j in range(8))))
    return result


def main(out=None):
    binary = ROOT / "sw/build/firmware.bin"
    syms = _symtab(binary.with_suffix(".elf"))
    code = T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    results = []
    for stage, expected in enumerate((144, 80, 64)):
        vm = T.new_vm(code)
        setup(vm, syms, stage)
        phases = []
        for age in range(192):
            call_func(vm, syms["boss_update"])
            if age < 48:
                assert not live_bullets(vm), "signature fired before its tell ended"
            phases.append(vm.load(syms["beam_phase"], 1))
        bullets = live_bullets(vm)
        assert len(bullets) == expected, (stage, len(bullets), expected)
        assert vm.load(syms["boss_signature_timer"], 1) == 0
        assert vm.load(syms["boss_signature_used"], 1) == 1
        if stage == 0:
            assert {b[5] & 7 for b in bullets} == {2, 5}
            assert len({(b[2], b[3]) for b in bullets}) >= 12
        elif stage == 1:
            assert all(phases[k] == 1 for k in range(48)) and 2 in phases
            assert len([b for b in bullets if b[3] < 0]) == 72
            assert len([b for b in bullets if b[4] & 64]) == 8
        else:
            left = [b for b in bullets if b[0] < 683]
            right = [b for b in bullets if b[0] > 683]
            assert len(left) == len(right) == 32
            assert {b[2] for b in left} == {-b[2] for b in right}
        call_func(vm, syms["boss_update"])
        assert vm.load(syms["boss_signature_timer"], 1) == 0, "one-shot attack restarted"
        vm.store(syms["boss_signature_timer"], 120, 1)
        vm.store(syms["boss_hp"], 0, 2)
        call_func(vm, syms["boss_update"])
        assert vm.load(syms["boss_signature_timer"], 1) == 0, "death left a signature active"
        assert vm.min_sp >= 0xF900FD00, "signature exceeded the reserved stack"
        results.append({"stage": stage, "frames": 192, "bullets": len(bullets), "min_sp": hex(vm.min_sp)})
        print("PASS stage %d signature: tell, unique pattern, recovery, death cleanup; %d bullets" % (stage + 1, len(bullets)), flush=True)

        # Existing 2/3-HP card still freezes and opens with its original volley.
        vm = T.new_vm(code)
        setup(vm, syms, stage)
        vm.store(syms["boss_hp"], 650, 2)
        vm.store(syms["boss_opener_stage"], 0, 1)
        call_func(vm, syms["boss_update"])
        assert vm.load(syms["boss_state"], 1) == 5
        for _ in range(41):
            call_func(vm, syms["boss_update"])
        assert vm.load(syms["boss_laser"], 1) == 90
        assert len(live_bullets(vm)) == 48
        assert vm.load(syms["boss_signature_used"], 1) == 0
        assert vm.min_sp >= 0xF900FD00, "old card exceeded the reserved stack"
    vm = T.new_vm(code)
    setup(vm, syms, 1)
    vm.store(syms["is_stress_stage"], 1, 4)
    call_func(vm, syms["boss_update"])
    assert vm.load(syms["boss_signature_timer"], 1) == 0
    print("PASS preserved old cards for all stages and excluded signature from pressure stage", flush=True)
    out = Path(out) if out is not None else ROOT / "work_sim/merge_20261029/signatures.json"
    out.write_text(json.dumps(results, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
