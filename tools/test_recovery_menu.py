"""Verify boot-built glyphs and the visible pause card against the linked firmware."""
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
os.environ.setdefault("SIM_PURE_PYTHON", "1")
import test_runner as T


def publish(vm, count=2):
    target = len(vm.right_published) + count
    for _ in range(20_000_000):
        vm.step()
        if len(vm.right_published) >= target:
            return
    raise AssertionError("pause publication stalled")


def press(vm, key, condition):
    assert T.press_until(vm, [key], condition, budget=20_000_000)
    publish(vm)


def main():
    code = T.load_code_from_source(ROOT / "sw/build/firmware.bin")
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    assert len(vm.asset_rom) == 16384
    checked = 0
    for scale in range(1, 7):
        atlas = vm.load(T.mm_value("MM_FONT_TABLE") + (scale-1)*4)
        for ch in "AGX096":
            glyph = ord(ch)-32
            for y in range(8*scale):
                row = vm.asset_rom[0x3C00 + glyph*8 + y//scale]
                for x in range(6*scale):
                    expected = 0xFFFFFF if row & (32 >> (x//scale)) else 0xFF00FF
                    address = atlas + (glyph//16)*4096*scale*scale + (glyph%16)*32*scale
                    assert vm.load(address+y*512*scale+x*4) == expected
                    checked += 1
    print("PASS font ROM/atlas: %d pixels across all six scales" % checked, flush=True)
    T.menu_enter(vm, 1)
    assert T.wait_frames(vm, 1)
    press(vm, "b", lambda: T.tlm(vm, "paused") == 1)
    frozen = T.tlm(vm, "frames")
    press(vm, "y", lambda: T.tlm(vm, "settings") == 6)
    for enabled in (0, 1):
        press(vm, "x", lambda: vm.params.get(0x88, 0) & 1 == enabled)
        assert T.tlm(vm, "frames") == frozen
    pixels = vm.fb[vm.right_request]
    visible = sum((pixels[y*2048+x] & 0xFFFFFF) == 0xFFFFFF
                  for y in range(514, 530) for x in range(459, 557))
    assert visible > 80, "GLOW FX label is blank"
    out = ROOT / "simulator/output"
    T.save_frame(vm, vm.right_request, out / "recovered_pause.bmp", out / "recovered_pause.png")
    for row in (0, 1, 2):
        press(vm, "a", lambda: T.tlm(vm, "settings") == row)
    press(vm, "x", lambda: T.tlm(vm, "paused") == 0)
    assert T.wait_frames(vm, 1)
    print("PASS visible pause card: GLOW FX OFF/ON, frozen world, RESUME; min SP=%#x" % vm.min_sp, flush=True)


if __name__ == "__main__":
    main()
