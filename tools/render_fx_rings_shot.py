"""Render one gameplay frame with a few procedural impact rings on screen.

Nothing here is faked: the firmware builds the descriptors from its own
visual_fx pool, the scanout model draws them, and the picture is what the board
would show for that frame.  Used to eyeball the layer and to give the review a
picture to argue about.

Run: python tools/render_fx_rings_shot.py
"""
import os
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
sys.path.insert(0, str(ROOT / "tools"))
os.environ.setdefault("SIM_PURE_PYTHON", "1")

import test_runner as T                      # noqa: E402
from test_recovery_menu import publish       # noqa: E402
from rv32i_soc_vm import _Scanout, SCREEN_W, SCREEN_H, SCREEN_PITCH  # noqa: E402

FX_POOL = T.mm_value("MM_VISUAL_FX")


def frame(vm):
    vm.drain()
    fb = vm.fb[vm.right_request]
    rows = np.empty(SCREEN_H * SCREEN_W, dtype=np.uint32)
    for y in range(SCREEN_H):
        at = y * SCREEN_PITCH
        rows[y * SCREEN_W:(y + 1) * SCREEN_W] = fb[at:at + SCREEN_W]
    composed = np.empty(SCREEN_H * SCREEN_W, dtype=np.uint32)
    _Scanout(rows.ravel(), vm.params, vm.scratch32, vm.btile, vm.bpal,
             vm.right_request, SCREEN_W, SCREEN_H, SCREEN_W).compose(composed)
    composed = composed.reshape(SCREEN_H, SCREEN_W)
    return np.stack([(composed >> 16) & 0xFF, (composed >> 8) & 0xFF,
                     composed & 0xFF], axis=-1).astype(np.uint8)


def poke(vm, index, x, y, age, active=1):
    base = FX_POOL + 8 * index
    vm.store(base, x & 0xFFFF, 2)
    vm.store(base + 2, y & 0xFFFF, 2)
    vm.store(base + 4, age, 1)
    vm.store(base + 5, active, 1)


def main():
    binary = ROOT / "sw/build/firmware.bin"
    code = T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    T.start_game(vm)

    # A burst mid-clash: one hot core, two shockwaves at different ages.
    for i in range(16):
        poke(vm, i, 0, 0, 0, 0)
    poke(vm, 0, 683, 300, 1)      # core: additive white flash
    poke(vm, 1, 683, 300, 7)      # first shockwave, ~55 px across
    poke(vm, 2, 470, 470, 12)     # late wave on the left, cooling
    poke(vm, 3, 900, 430, 4)      # just past the core, still bright
    publish(vm, 2)

    img = frame(vm)
    out = ROOT / "work_sim" / "fx"
    out.mkdir(parents=True, exist_ok=True)
    from PIL import Image
    Image.fromarray(img).save(out / "rings_gameplay.png")

    desc = []
    for k in range(4):
        a = vm.load(0xF8100000 + 0x200 + 16 * k)
        if a & 0x80000000:
            desc.append((a & 0x7FF, (a >> 11) & 0x3FF,
                         (a >> 21) & 0x1FF, "add" if (a >> 30) & 1 else "blend"))
    print("slots on screen: %s" % desc)
    print("frame exported: work_sim/fx/rings_gameplay.png")


if __name__ == "__main__":
    main()
