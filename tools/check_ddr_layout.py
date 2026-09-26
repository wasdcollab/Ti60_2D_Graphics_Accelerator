#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Every DDR scratch surface must own a disjoint address range.

Two surfaces that overlap are not a style problem: the one that is written later
silently destroys the other, and nothing in the firmware notices.  It has
happened twice now:

  * MM_REIMU_TILT_L/R, MM_BURST_FRAME and MM_LASER_BAR all sat inside
    MM_STRIP_LAYER, which is composed the first time a stage is entered - the
    craft lost its leaning poses (it vanished while the stick was pushed) and
    every impact burst and boss laser column was drawn from parallax pixels;
  * MM_PORTRAIT sat inside the surface ART_REIMU_HUD_LARGE decodes into, so
    boot-time asset decoding painted white pixels over the top of the title
    screen's portrait.

The second one is why this file now reads the ASSET table as well: the decode
destinations in sw/app/visual_assets.c are DDR addresses too, and they are
written at boot, before anything else gets a chance to run.

Addresses come from sw/driver/memory_map.h and sw/app/visual_assets.c, which are
the two sources of truth.  SIZES below lists the surfaces whose extent is not
derivable from a table.

Run:  python tools/check_ddr_layout.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MMH = ROOT / "sw" / "driver" / "memory_map.h"
ASSETS = ROOT / "sw" / "app" / "visual_assets.c"

# ---------------------------------------------------------------------------
# Surface sizes in bytes.  name -> (size, where the size comes from)
# ---------------------------------------------------------------------------
SIZES = {
    "MM_ENTITY_BASE":     (650 * 28,         "docstring: 650 entities x 28 B"),
    "MM_ENEMY_BASE":      (32 * 16,          "32 enemies x 16 B"),
    "MM_EBULLET_BASE":    (192 * 8,          "192 enemy bullets x 8 B"),
    "MM_ITEM_BASE":       (16 * 8,           "16 items x 8 B"),
    "MM_TELEMETRY_BASE":  (52 * 4,          "52 telemetry words"),
    "MM_PLAYER_SPRITE":   (32 * 4 * 32,      "32x32, stride 128"),
    "MM_ENEMY_SPRITE":    (24 * 4 * 24,      "24x24, stride 96"),
    "MM_ENEMY2_SPRITE":   (24 * 4 * 24,      "24x24, stride 96"),
    "MM_BOSS_SPRITE":     (64 * 4 * 64,      "64x64, stride 256"),
    "MM_AURA_SPRITE":     (64 * 4 * 64,      "64x64, stride 256"),
    "MM_REIMU_BASE":      (4 * 0x2400,       "four 48x48 poses at a 192 pitch"),
    "MM_VISUAL_FX":       (16 * 8,           "16 particles x 8 B"),
    "MM_PBULLET_BASE":    (128 * 8,          "128 player bullets x 8 B"),
    "MM_BOSS_CIRNO":      (64 * 256,         "64x64, stride 256"),
    "MM_BOSS_DREAM":      (64 * 256,         "64x64, stride 256"),
    "MM_LASER_GLOW":      (16 * 4 * 768,     "16x768, stride 64"),
    "MM_SHADE_SPRITE":    (24 * 96,          "24x24, stride 96"),
    "MM_EBULLET_TILE":    (8 * 64 * 13,      "eight 13x13 tiles at a 64 pitch"),
    # The three banks the merged-tile work added.  They were checked by hand
    # when they landed and by nothing since, so they are exactly the class of
    # surface this file exists to police.
    "MM_PBULLET_TILE":    (8 * 32 * 26,      "eight 7x26 shot tiles at a 32 pitch"),
    "MM_EBULLET_DIRTILE": (8 * 16 * 64 * 13, "8 colours x 16 headings, 13x13 at 64"),
    "MM_HUD_LABELS":      (22 * 512 * 8,     "22 captions, 128x8 at a 512 pitch"),
    "MM_PORTRAIT":        (240 * 240 * 4,    "portrait_build: 48x48 at scale 5"),
    "MM_FONT_TABLE":      (6 * 4,            "six uint32_t atlas bases"),
    "MM_FONT_ATLASES":    (0x222000,         "scales 1..6, ends at MM_STRESS_SPRITE"),
    "MM_STRESS_SPRITE":   (0x5000,           "64x64 stride 256 + guard band"),
    "MM_STRESS_PANEL":    (128 * 4096,       "1024x128, stride 4096"),
    "MM_STRESS_TELEMETRY": (14 * 4,          "14 uint32_t words"),
    "MM_STAGE_BG":        (3 * 0x600000,     "three 1366x768 plates at SCREEN_STRIDE"),
    "MM_STAGE_STRIP":     (32 * 4 * 768,     "32x768 weather tile at SB_STRIP_STRIDE"),
    "MM_STAGE_ALT":       (2 * 32 * 4 * 768, "two 32x768 repaints at 128"),
    "MM_REIMU_TILT_L":    (48 * 4 * 48,      "48x48 at a 192 pitch"),
    "MM_REIMU_TILT_R":    (48 * 4 * 48,      "48x48 at a 192 pitch"),
    "MM_BURST_FRAME":     (24 * 448 * 112,   "24 frames of 112x112 at a 448 pitch"),
    "MM_LASER_BAR":       (3 * 64 * 768,     "three 16x768 bars at a 64 pitch"),
    "MM_LANCE":           (8 * 96 * 24,      "eight 24x24 shafts at a 96 pitch"),
    "MM_ORB_TILE":        (8 * 64 * 16,      "eight 16x16 big orb tiles at a 64 pitch"),
    "MM_PARTICLE_TILE":   (4 * 32 * 8,       "four 8x8 particle tiles at a 32 pitch"),
    "MM_CARD_BG":         (768 * 8192,       "1366x768 plate at SCREEN_STRIDE"),
    "MM_WEATHER_RESTORE_CACHE": (2 * 32 * 256 * 43 * 4,
                                  "active stage and card, 32 phases each"),
    "MM_VISUAL_BACKGROUND": (768 * 8192,     "1366x768 plate at SCREEN_STRIDE"),
    "MM_STAGE_RLE":       (0x4000,           "staging for the three plate RLE streams"),
}

# 0x04000000 is where the modelled DDR window ends; rv32i_soc_vm.py asserts on
# any access past it.
DDR_END = 0x04000000


def defines():
    """{name: value} for every plain #define with a hex or decimal literal."""
    out = {}
    txt = MMH.read_text(encoding="utf-8")
    for name, expr in re.findall(
            r"^#define\s+([A-Z_][A-Z_0-9]*)\s+\(?\s*(0x[0-9A-Fa-f]+|\d+)"
            r"\s*[UL]*\s*\)?\s*(?:/\*.*)?$", txt, re.M):
        out[name] = int(expr, 0)
    # MM_STAGE_STRIP is defined as a small sum of two earlier names
    if "MM_STAGE_STRIP" not in out and "MM_STAGE_BG" in out:
        m = re.search(r"^#define\s+MM_STAGE_STRIP\s+\(\s*([A-Z_][A-Z_0-9]*)\s*"
                      r"\+\s*(\d+)\s*U?L?\s*\*\s*([A-Z_][A-Z_0-9]*)\s*\)\s*$",
                      txt, re.M)
        if m:
            out["MM_STAGE_STRIP"] = (out[m.group(1)]
                                     + int(m.group(2)) * out[m.group(3)])
    return out


def asset_regions():
    """The decode destinations in visual_assets.c, as [start, end, label).

    Each entry is {palette, rle, words, dst, w, h, scale}; the decoder writes
    w*scale*4 bytes per row for h*scale rows, so the surface is w*h*scale^2*4.
    These are filled at boot, before the first frame, which makes them the most
    dangerous surfaces in the build to overlap.
    """
    txt = ASSETS.read_text(encoding="utf-8")
    out = []
    for pal, _rle, _words, addr, w, h, scale in re.findall(
            r"\{(p_\w+),(r_\w+),(\d+)u,(0x[0-9A-Fa-f]+)u,(\d+),(\d+),(\d+)\}",
            txt):
        a, w, h, s = int(addr, 16), int(w), int(h), int(scale)
        out.append((a, a + w * h * s * s * 4,
                    "asset %s (%dx%d scale %d)" % (pal, w, h, s)))
    if not out:
        raise SystemExit("could not parse any assets out of %s" % ASSETS)
    return out


def _partial(a0, a1, b0, b1):
    """Ranges that cross each other's border.

    A range wholly inside another one is NOT a collision here: an asset whose
    decode address is 0x01610000 is *the* thing MM_REIMU_BASE names, and the
    four craft poses are four assets filling one named bank.  What must never
    happen is a range that starts inside another and ends outside it - that is
    the MM_PORTRAIT case, where a 144x144 decode ran across the start of a
    240x240 portrait.
    """
    if not (a0 < b1 and b0 < a1):
        return False
    contained = (b0 <= a0 and a1 <= b1) or (a0 <= b0 and b1 <= a1)
    return not contained


# Names in memory_map.h that hold a small number or a size rather than a DDR
# address.  Anything else starting with MM_ whose value lands in the DDR window
# is a surface, and a surface that SIZES does not know about is a surface this
# checker silently ignores - which is how two names ended up on one address.
NOT_AN_ADDRESS = {
    "MM_STAGE_BG_STRIDE",     # a size in bytes
    "MM_REIMU_PITCH",
    "MM_REIMU_ROW",
}


def unregistered(addrs):
    """MM_* defines that look like DDR addresses but have no entry in SIZES."""
    out = []
    for name, value in sorted(addrs.items()):
        if not name.startswith("MM_") or name in SIZES or name in NOT_AN_ADDRESS:
            continue
        if 0x01000000 <= value < DDR_END:
            out.append((name, value))
    return out


def main():
    addrs = defines()
    regions = []
    missing = []
    for name, (size, _why) in SIZES.items():
        if name not in addrs:
            missing.append(name)
            continue
        regions.append((addrs[name], addrs[name] + size, name))
    if missing:
        print("  *** %d surface(s) named in this checker have left memory_map.h: %s"
              % (len(missing), ", ".join(sorted(missing))))
        return 1

    holes = unregistered(addrs)
    if holes:
        print("  *** %d DDR address(es) in memory_map.h are NOT in the size table,"
              % len(holes))
        print("      so nothing below checks them:")
        for name, value in holes:
            print("        %-28s %#010x" % (name, value))
        print("      Add each one to SIZES with the size its builder writes.")
        return 1

    assets = asset_regions()

    bad = []
    for a in assets:
        if a[1] > DDR_END:
            bad.append("%s [%#x, %#x) runs past the end of DDR" % (a[2], a[0], a[1]))
        for name, (size, _why) in SIZES.items():
            if name not in addrs:
                continue
            start, end = addrs[name], addrs[name] + size
            if _partial(a[0], a[1], start, end):
                bad.append("%s [%#x, %#x) crosses %s [%#x, %#x)"
                           % (a[2], a[0], a[1], name, start, end))

    # assets against each other: two entries may share one decoded picture only
    # by sharing the address exactly; crossing borders is always a mistake
    assets.sort()
    for i, a in enumerate(assets):
        for j in range(i + 1, len(assets)):
            b = assets[j]
            if b[0] >= a[1]:
                break
            if _partial(a[0], a[1], b[0], b[1]):
                bad.append("%s [%#x, %#x) crosses %s [%#x, %#x)"
                           % (a[2], a[0], a[1], b[2], b[0], b[1]))

    regions.sort()
    for i, (start, end, name) in enumerate(regions):
        if end > DDR_END:
            bad.append("%s [%#x, %#x) runs past the end of DDR (%#x)"
                       % (name, start, end, DDR_END))
        for j in range(i + 1, len(regions)):
            start2, end2, name2 = regions[j][0], regions[j][1], regions[j][2]
            if start2 >= end:
                break
            bad.append("%s [%#x, %#x) overlaps %s [%#x, %#x) by %d bytes"
                       % (name, start, end, name2, start2, end2,
                          min(end, end2) - start2))

    highest = max([e for _s, e, _n in regions] + [a[1] for a in assets])
    print("  DDR layout: %d surfaces + %d decoded assets, %#x..%#x of a %#x window"
          % (len(regions), len(assets), regions[0][0], highest, DDR_END))
    if bad:
        print("  *** %d DDR layout collision(s):" % len(bad))
        for line in bad:
            print("      " + line)
        return 1
    print("  DDR layout: every surface and asset owns a disjoint range")
    return 0


if __name__ == "__main__":
    sys.exit(main())
