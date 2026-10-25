"""Render a same-frame visual A/B for the effects discussion.

Three (four) images, one scene, one frame:

  1_original.png      the VM's scanout composite, no post-processing at all
                      (this is what GLOW FX = OFF looks like)
  2_current_glow.png  bloom applied to the pixels the firmware already marks
                      emissive (MM_EMISSIVE_TAG in the framebuffer + the
                      scanout layers) - i.e. roughly the board with GLOW ON
  3_added_glow.png    2 plus the "asset" pass: the playfield's own highlights
                      (moon, ice crystals, boss/player specular) are emissive
                      too, which is the change being proposed
  4_glow_ui.png       3 plus a 74% opaque pause card, previewing translucent
                      UI panels over a live battle

The bloom is NOT bit-exact with video_bloom_filter.v (that kernel is a 5-line
by +-15 tap convolution with its own packing); it is a separable isotropic
Gaussian of comparable reach and gain, applied in the same place in the chain
(after compositing, before the colour matrix).  It is a look preview, not a
board photograph.  Everything else - the scene, the frame, the camera - is
identical between the images, and the scene itself is the real firmware
rendered by the real scanout model.
"""
import argparse
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
sys.path.insert(0, str(ROOT / "tools"))
os.environ.setdefault("SIM_PURE_PYTHON", "1")

import test_runner as T                      # noqa: E402
from profile_stress_frame import symbols     # noqa: E402
from rv32i_soc_vm import SCREEN_W, SCREEN_H, SCREEN_PITCH, _Scanout  # noqa: E402

OUT = ROOT / "work_sim" / "fx"
PLAY_LEFT, PLAY_RIGHT = 181, 1185            # video_weather.v PLAY_LEFT/RIGHT


def capture(vm):
    """Return (composed_rgb, fb_argb) as HxWx3 uint8 and HxW uint32."""
    vm.drain()
    fb = vm.fb[vm.right_request]
    rows = np.empty(SCREEN_H * SCREEN_W, dtype=np.uint32)
    for y in range(SCREEN_H):
        at = y * SCREEN_PITCH
        rows[y * SCREEN_W:(y + 1) * SCREEN_W] = fb[at:at + SCREEN_W]
    rows = rows.reshape(SCREEN_H, SCREEN_W)

    composed = np.empty(SCREEN_H * SCREEN_W, dtype=np.uint32)
    _Scanout(rows.ravel(), vm.params, vm.scratch32, vm.btile, vm.bpal,
               vm.right_request, SCREEN_W, SCREEN_H, SCREEN_W).compose(composed)
    composed = composed.reshape(SCREEN_H, SCREEN_W)
    rgb = np.stack([(composed >> 16) & 0xFF, (composed >> 8) & 0xFF,
                    composed & 0xFF], axis=-1).astype(np.uint8)
    return rgb, rows


def to_float(rgb):
    return rgb.astype(np.float32) / 255.0


def gauss_blur(a, sigma, axis):
    """Separable Gaussian, reflect-padded, no scipy."""
    radius = max(1, int(3.0 * sigma))
    xs = np.arange(-radius, radius + 1, dtype=np.float32)
    k = np.exp(-(xs ** 2) / (2.0 * sigma * sigma))
    k /= k.sum()
    pad = [(0, 0)] * a.ndim
    pad[axis] = (radius, radius)
    p = np.pad(a, pad, mode="reflect")
    out = np.zeros_like(a)
    n = a.shape[axis]
    for i, kv in enumerate(k):
        sl = [slice(None)] * a.ndim
        sl[axis] = slice(i, i + n)
        out += kv * p[tuple(sl)]
    return out


def bloom(rgb, mask, gain, sigma_h=6.0, sigma_v=2.0):
    """Isotropic-ish glow: mask the emitters, blur, add with a soft knee."""
    img = to_float(rgb)
    emis = img * mask[..., None]
    glow = gauss_blur(gauss_blur(emis, sigma_v, 0), sigma_h, 1)
    # normalise so the tight core of a lone emitter adds ~55% of its own value
    peak = float(glow.max()) or 1.0
    glow *= min(1.0, 0.55 / peak) if peak > 0.55 else 1.0
    out = img + gain * glow
    # soft-knee shoulder: compress above 0.86 instead of clipping to flat white
    knee = 0.86
    over = out - knee
    out = np.where(over > 0, knee + (1.0 - knee) * np.tanh(over / (1.0 - knee)), out)
    return (np.clip(out, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)


def luma(img):
    return (0.2126 * img[..., 0] + 0.7152 * img[..., 1] + 0.0722 * img[..., 2])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--load", type=int, default=1200)
    ap.add_argument("--frames", type=int, default=40)
    ap.add_argument("--gain", type=float, default=0.9)
    ap.add_argument("--mode", choices=("pressure", "boss"), default="pressure")
    ap.add_argument("--tag", default="")
    ap.add_argument("--sigma-h", type=float, default=6.0)
    ap.add_argument("--recapture", action="store_true")
    args = ap.parse_args()

    binary = ROOT / "sw/build/firmware.bin"
    sym = symbols(binary.with_suffix(".elf"))
    code = T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    if args.mode == "pressure":
        T._enter_pressure_stage(vm)
        vm.store(sym["stress_target"], args.load, 2)
        vm.store(sym["stress_prev_y"], 0, 1)
    else:
        # the real boss stage, stage 0 (ice): the moon and the crystals are in
        # frame, which is where "let the art emit" is easiest to see
        T.start_game(vm)
    # publish() lives in test_recovery_menu
    from test_recovery_menu import publish
    print("  running %d frames (%s) ..." % (args.frames, args.mode), flush=True)
    publish(vm, args.frames)
    live = vm.load(sym["stress_live"], 2) if "stress_live" in sym else None

    OUT.mkdir(parents=True, exist_ok=True)
    suffix = ("_" + args.tag) if args.tag else ""
    cache = OUT / ("capture%s.npz" % suffix)
    if cache.exists() and not args.recapture:
        z = np.load(cache)
        rgb, rows = z["rgb"], z["rows"]
        print("  frame: from %s (no VM run)" % cache.name)
    else:
        rgb, rows = capture(vm)
        np.savez_compressed(cache, rgb=rgb, rows=rows)
        print("  frame: captured and cached to %s" % cache.name)

    # ---- masks -----------------------------------------------------------
    fb_a = (rows >> 24) & 0xFF
    fb_rgb = np.stack([(rows >> 16) & 0xFF, (rows >> 8) & 0xFF, rows & 0xFF],
                      axis=-1).astype(np.uint8)
    fb_changed = np.any(fb_rgb != rgb, axis=-1)          # a scanout layer owns it
    lum = luma(rgb.astype(np.float32))

    xs = np.arange(SCREEN_W)[None, :]
    play = (xs >= PLAY_LEFT) & (xs <= PLAY_RIGHT)        # broadcast over rows

    m_current = ((fb_a >= 32) | (fb_changed & (lum > 110))) & (lum > 30)
    m_current = m_current.astype(np.float32)
    # the proposed asset pass: the playfield's own highlights become emitters
    # too, with a soft ramp so mid-tones are not dragged into the glow
    hi = np.clip((lum - 168.0) / 48.0, 0.0, 1.0) * play
    m_added = np.clip(m_current + hi, 0.0, 1.0)

    img_original = rgb
    img_current = bloom(rgb, m_current, args.gain, args.sigma_h)
    img_added = bloom(rgb, m_added, args.gain, args.sigma_h)

    # ---- translucent pause card -----------------------------------------
    card_src = ROOT / "docs/recovery_evidence/recovered_pause.png"
    img_ui = img_added.copy()
    if card_src.exists():
        pause = np.asarray(Image.open(card_src).convert("RGB"))
        # the card sits at x 430..941, y 188..579 in the 1366x768 layout
        x0, y0, x1, y1 = 430, 188, 941, 579
        panel = pause[y0:y1, x0:x1].astype(np.float32)
        base = img_ui[y0:y1, x0:x1].astype(np.float32)
        img_ui[y0:y1, x0:x1] = (0.74 * panel + 0.26 * base).astype(np.uint8)

    for name, img in (("1_original", img_original),
                      ("2_current_glow", img_current),
                      ("3_added_glow", img_added),
                      ("4_glow_ui", img_ui)):
        Image.fromarray(img).save(OUT / (name + suffix + ".png"))
        print("  -> %s.png" % name)

    # ---- contact sheet ---------------------------------------------------
    labels = (("1  ORIGINAL (no post)", img_original),
              ("2  CURRENT GLOW", img_current),
              ("3  + ASSET GLOW", img_added),
              ("4  + TRANSLUCENT UI", img_ui))
    scale = 0.5
    tw, th = int(SCREEN_W * scale), int(SCREEN_H * scale)
    pad, top = 8, 22
    sheet = Image.new("RGB", (pad + 2 * (tw + pad), pad + 2 * (th + top + pad)),
                      (18, 18, 22))
    from PIL import ImageDraw
    d = ImageDraw.Draw(sheet)
    for i, (label, img) in enumerate(labels):
        cx = pad + (i % 2) * (tw + pad)
        cy = pad + (i // 2) * (th + top + pad)
        d.text((cx + 2, cy + 4), label, fill=(235, 235, 240))
        sheet.paste(Image.fromarray(img).resize((tw, th), Image.LANCZOS),
                    (cx, cy + top))
    sheet.save(OUT / ("0_sheet" + suffix + ".png"))
    print("  -> 0_sheet%s.png   (live bullets at capture: %s)" % (suffix, live))
    print("out dir:", OUT)


if __name__ == "__main__":
    main()
