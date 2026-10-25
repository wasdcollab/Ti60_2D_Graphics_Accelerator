"""End-to-end check of the procedural impact ring layer in the workbench.

The ring is a scanout layer: the firmware writes four 96-bit descriptors to APB
bank 2 and the hardware draws the circle.  This test pokes one entry into the
firmware's own visual_fx pool, runs a frame, and checks both halves of that:

  * the descriptor the firmware built (read back from APB 0x200..0x22F), and
  * the pixels, by diffing a frame with the ring against one without it and
    measuring where the change landed - it has to be an annulus of the radius
    the descriptor asked for, with the hole left alone.

Run: python tools/test_fx_ring_vm.py
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
APB = 0xF8100000


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
                     composed & 0xFF], axis=-1).astype(np.int16)


def set_slot0(vm, x, y, age, active):
    """visual_fx_t is {int16 x, int16 y, u8 age, u8 active, u8 pad[2]}."""
    vm.store(FX_POOL, x & 0xFFFF, 2)
    vm.store(FX_POOL + 2, y & 0xFFFF, 2)
    vm.store(FX_POOL + 4, age, 1)
    vm.store(FX_POOL + 5, active, 1)


def main():
    binary = ROOT / "sw/build/firmware.bin"
    code = T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    T.start_game(vm)

    # A frame with no impact at all, as the reference.
    set_slot0(vm, 0, 0, 0, 0)
    publish(vm, 3)
    base = frame(vm)

    # One impact, old enough to be a shockwave rather than a core.
    cx, cy, age = 683, 384, 9
    set_slot0(vm, cx, cy, age, 1)
    publish(vm, 2)
    shot = frame(vm)

    # ---- the descriptor the firmware built ---------------------------------
    # Slot 0 is the player-hit ring when one is live, so find the slot whose
    # centre is the impact this test poked in rather than assuming an index.
    slot = -1
    for k in range(4):
        if vm.load(APB + 0x200 + 16 * k) & 0x80000000:
            sx = vm.load(APB + 0x200 + 16 * k) & 0x7FF
            sy = (vm.load(APB + 0x200 + 16 * k) >> 11) & 0x3FF
            if abs(sx - cx) <= 1 and abs(sy - cy) <= 1:
                slot = k
                break
    assert slot >= 0, "no hardware slot carries the poked impact"
    a = vm.load(APB + 0x200 + 16 * slot)
    wb = vm.load(APB + 0x204 + 16 * slot)
    wc = vm.load(APB + 0x208 + 16 * slot)
    assert ((a >> 30) & 1) == 0, "a shockwave must blend, not add: %08x" % a
    got_cx, got_cy = a & 0x7FF, (a >> 11) & 0x3FF
    ro, ri = (a >> 21) & 0x1FF, (wb >> 16) & 0x1FF
    alpha, rgb = wb & 0xFF, wc & 0xFFFFFF
    # The firmware ages the entry once per logic tick, so read back what it
    # actually drew instead of assuming how many ticks a publish() covered.
    drawn_age = vm.load(FX_POOL + 4, 1)
    assert 4 <= drawn_age <= 20, "unexpected drawn age %d" % drawn_age
    want_r = 26 + (drawn_age - 4) * 6
    assert abs(got_cx - cx) <= 1 and abs(got_cy - cy) <= 1, \
        "centre %d,%d want %d,%d" % (got_cx, got_cy, cx, cy)
    assert ro == want_r, "r_out %d want %d" % (ro, want_r)
    assert ri == want_r - 7, "r_in %d want %d" % (ri, want_r - 7)
    assert 0 < alpha < 255 and rgb != 0, "alpha/colour not set: %02x %06x" % (alpha, rgb)
    print("descriptor: centre (%d,%d) r %d..%d alpha %d rgb %06x"
          % (got_cx, got_cy, ri, ro, alpha, rgb))

    # ---- where the pixels changed -----------------------------------------
    # The game is running, so two frames captured a tick apart differ
    # everywhere the bullets and the snow moved.  Hold the framebuffer and the
    # register file still and re-compose the SAME frame twice: once with the
    # ring as the firmware wrote it, once with the ring slots cleared.  What is
    # left is exactly the layer.
    hold = dict(vm.params)
    for k in range(4):
        for word in range(3):
            vm.params[0x200 + 16 * k + 4 * word] = 0
    off = frame(vm)
    vm.params.update(hold)
    shot = frame(vm)
    diff = np.abs(shot - off).max(axis=2)
    ys, xs = np.nonzero(diff > 6)
    assert len(xs) > 200, "the ring drew almost nothing (%d px)" % len(xs)
    dx = xs - got_cx
    dy = ys - got_cy
    rad = np.sqrt(dx * dx + dy * dy)
    # every changed pixel has to be on the ring, and the hole has to be clean
    inside = (rad < ri - 3).sum()
    outside = (rad > ro + 3).sum()
    assert outside <= 2, "%d changed pixels outside r=%d" % (outside, ro + 3)
    assert inside <= 2, "%d changed pixels in the hole (r<%d)" % (inside, ri - 3)
    print("pixels: %d changed, radius %.1f..%.1f (r_in %d, r_out %d), "
          "hole/outside clean" % (len(xs), rad.min(), rad.max(), ri, ro))

    # ---- the core: additive, and it must clip toward white ----------------
    set_slot0(vm, cx, cy, 1, 1)
    publish(vm, 2)
    core_slot = -1
    for k in range(4):
        kk = vm.load(APB + 0x200 + 16 * k)
        if (kk >> 31) and abs((kk & 0x7FF) - cx) <= 1 and \
                abs(((kk >> 11) & 0x3FF) - cy) <= 1:
            core_slot = k
    assert core_slot >= 0, "no slot carries the core"
    a2 = vm.load(APB + 0x200 + 16 * core_slot)
    assert (a2 >> 30) & 1, "the young core must use the additive path: %08x" % a2

    # same frozen-frame trick: the core against the same frame without it
    hold = dict(vm.params)
    for k in range(4):
        for word in range(3):
            vm.params[0x200 + 16 * k + 4 * word] = 0
    off_core = frame(vm)
    vm.params.update(hold)
    core = frame(vm)
    d = core[cy - 2:cy + 3, cx - 2:cx + 3].astype(np.int32)
    b = off_core[cy - 2:cy + 3, cx - 2:cx + 3].astype(np.int32)
    gain = (d - b).mean()
    assert gain > 20, "the core did not brighten the picture (%.1f)" % gain
    print("core: additive, +%.1f average brightness over the centre" % gain)

    out = ROOT / "work_sim" / "fx"
    out.mkdir(parents=True, exist_ok=True)
    from PIL import Image
    Image.fromarray(shot.astype(np.uint8)).save(out / "ring_vm.png")
    print("PASS impact ring: descriptor, annulus, hole and core all as designed")
    print("  frame exported: work_sim/fx/ring_vm.png")


if __name__ == "__main__":
    main()
