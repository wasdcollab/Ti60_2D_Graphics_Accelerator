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
sys.path.insert(0, str(Path(__file__).resolve().parent))

import mm                                                        # noqa: E402
MMH = ROOT / "sw" / "driver" / "memory_map.h"
ASSETS = ROOT / "sw" / "app" / "visual_assets.c"

# ---------------------------------------------------------------------------
# Surface sizes in bytes.  name -> (size, where the size comes from)
# ---------------------------------------------------------------------------
SIZES = {
    "MM_BGM_PCM": (mm.mm_eval("MM_BGM_CAPACITY"), "CPU-fed PCM store"),
    "MM_ENTITY_BASE":     (650 * 28,         "docstring: 650 entities x 28 B"),
    "MM_ENEMY_BASE":      (32 * 16,          "32 enemies x 16 B"),
    # Read from the macro, not a literal.  A literal here is how a pool that
    # had been left at its OLD count still passed: the address arithmetic was
    # checked against the size this table claimed, so 512*8 of room was
    # reserved and verified while the firmware only ever indexed 128 of it -
    # the check passing told nobody that the two had come apart.
    "MM_EBULLET_BASE":    (mm.mm_eval("MM_EBULLET_COUNT") * 8,
                           "MM_EBULLET_COUNT x 8 B"),
    "MM_ITEM_BASE":       (16 * 8,           "16 items x 8 B"),
    # MM_TELEMETRY_WORDS, not the 52 this once said: the firmware writes
    # tlm[TLM_DAMAGE_ROWS] (index 55) and the map declares 64 words, so the old
    # size stopped 16 bytes short of the surface it was guarding.
    "MM_TELEMETRY_BASE":  (mm.mm_eval("MM_TELEMETRY_WORDS") * 4,
                           "MM_TELEMETRY_WORDS x 4"),
    "MM_PLAYER_SPRITE":   (32 * 4 * 32,      "32x32, stride 128"),
    "MM_ENEMY_SPRITE":    (24 * 4 * 24,      "24x24, stride 96"),
    "MM_ENEMY2_SPRITE":   (24 * 4 * 24,      "24x24, stride 96"),
    "MM_BOSS_SPRITE":     (64 * 4 * 64,      "64x64, stride 256"),
    "MM_AURA_SPRITE":     (64 * 4 * 64,      "64x64, stride 256"),
    "MM_REIMU_BASE":      (4 * 0x2400,       "four 48x48 poses at a 192 pitch"),
    "MM_VISUAL_FX":       (16 * 8,           "16 particles x 8 B"),
    "MM_PBULLET_BASE":    (mm.mm_eval("MM_PBULLET_COUNT") * 8,
                           "MM_PBULLET_COUNT x 8 B"),
    "MM_BOSS_CIRNO":      (64 * 256,         "64x64, stride 256"),
    "MM_BOSS_DREAM":      (64 * 256,         "64x64, stride 256"),
    "MM_LASER_GLOW":      (16 * 4 * 768,     "16x768, stride 64"),
    "MM_SHADE_SPRITE":    (24 * 96,          "24x24, stride 96"),
    "MM_EBULLET_TILE":    (8 * 64 * 13,      "eight 13x13 tiles at a 64 pitch"),
    # The three banks the merged-tile work added.  They were checked by hand
    # when they landed and by nothing since, so they are exactly the class of
    # surface this file exists to police.
    # One tile each since the colour split: the eight colours were pure
    # recolourings of the same shape, and the colour is a hue page now.
    # One byte a pixel since the role split: the builders write a shape ROLE
    # straight in, the ARGB word the old stride assumed had three bytes nothing
    # ever read.  That is what lets the enemy tile double its edge for free -
    # 16 x 32 x 26 is exactly what 16 x 64 x 13 was, and it has to stay that
    # way: MM_EBULLET_BASE starts immediately after this range.
    "MM_PBULLET_TILE":    (1 * 8 * 26,       "one 7x26 shot tile, a byte a pixel at an 8 pitch"),
    "MM_EBULLET_DIRTILE": (16 * 32 * 26,     "16 headings, 26x26, a byte a pixel at a 32 pitch"),
    "MM_MISSILE_TILE":    (1 * 16 * 26,      "one 13x26 homing missile tile at a 16 pitch"),
    "MM_HUD_LABELS":     (mm.mm_eval("MM_HUD_LABEL_SLOTS") * 512 * 8,
                            "slots x 128x8 at a 512 pitch"),
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
    "MM_ORB_TILE":        (1 * 16 * 16,      "one 16x16 big orb tile, a byte a pixel at a 16 pitch"),
    "MM_PARTICLE_TILE":   (8 * 32 * 8,       "eight 8x8 particle tiles at a 32 pitch"),
    "MM_CARD_BG":         (768 * 8192,       "1366x768 plate at SCREEN_STRIDE"),
    "MM_WEATHER_RESTORE_CACHE": (2 * 32 * 256 * 43 * 4,
                                  "active stage and card, 32 phases each"),
    "MM_VISUAL_BACKGROUND": (768 * 8192,     "1366x768 plate at SCREEN_STRIDE"),
    "MM_STRESS_BG":          (768 * 8192,     "1366x768 plate at SCREEN_STRIDE"),
    "MM_STAGE_RLE":       (0x4000,           "staging for the three plate RLE streams"),
    # B1: the one surface the scanout READS that the firmware writes.  One entry
    # per (bullet, GROUP of scanlines it covers), appended in draw order - 48 KB
    # a table, or 2.2% of a frame's 4.32 MB of scanout traffic.  The state it
    # replaces was expanded a thousand-fold into the framebuffer instead.
    # BOTH tables: the buckets are double buffered, one per framebuffer, because
    # the firmware builds the next frame's buckets while the scanout is still
    # showing the current one.  Sizing this as one table is what let MM_BULLET_WORK
    # land on top of the second one.
    "MM_BUCKET_TABLE":    (mm.mm_eval("MM_BUCKET_ROWS") * mm.mm_eval("MM_BUCKET_STRIDE") * 2,
                           "two bucket tables, geometry from memory_map.h"),
    "MM_BULLET_WORK":     (0x1000,           "boot-time palette and lookup, B1"),
    # One depth byte per bucket PER TABLE.  Per table is the point: the two
    # tables are written on alternate frames, so a single shared array clears the
    # wrong one and the cells it misses are re-drawn as bullets on every later
    # frame.  Read the count from the header rather than the literal 768 it used
    # to be - MM_BUCKET_ROWS counts groups since the row unit changed.
    "MM_BUCKET_COUNT_DEBUG": (192, "96 x uint16 diagnostic mirror"),
    "MM_DAMAGE_TILES": (768, "two damage maps, 96 rows of uint32"),
    "MM_RUNTIME_WORK": (320, "runtime pointers, audio packet, HUD and diagnostics"),
    "MM_EBULLET_ACTIVE_BASE": (mm.mm_eval("MM_EBULLET_COUNT") * 2, "enemy free and candidate indices"),
    "MM_PARTICLE_STATE": (mm.mm_eval("MM_PARTICLE_STATE_BYTES"), "CPU particle state"),
    "MM_LANCE_INDEX": (mm.mm_eval("MM_LANCE_INDEX_BYTES"), "CPU live lance indices"),
    "MM_POPUP_STATE": (mm.mm_eval("MM_POPUP_STATE_BYTES"), "CPU popup state"),
    "MM_PICK_MASK": (mm.mm_eval("MM_PICK_MASK_BYTES"), "CPU pickup mask"),
    "MM_BUCKET_USED":     (mm.mm_eval("MM_BUCKET_USED_BYTES"),
                           "per-table write depth, one byte a bucket"),
}

# Where the modelled DDR window ends: SCRATCH_BASE + SCRATCH_SIZE, i.e. what
# rv32i_soc_vm.py will assert on.  It moved to 0x04A00000 when B1 put the bullet
# bucket table at 0x0480_0000 - the part is 256 MB and the scanout addresses 28
# bits, so the only thing that had to grow was the model.
DDR_END = mm.mm_eval("MM_BGM_PCM") + mm.mm_eval("MM_BGM_CAPACITY")


def defines():
    """{name: value} for every MM_ name in memory_map.h.

    The parser is tools/mm.py, which expands expressions through the other
    names in the same file: MM_REIMU_1, MM_REIMU_3 and MM_STAGE_STRIP are all
    written as sums, and the old regex - literal numbers only - walked straight
    past them, which is how three real addresses stayed outside this checker.
    """
    return mm.mm_all()


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
# DDR names that are an OFFSET INSIDE a surface this table already covers.
# They must still be resolved (a name that will not resolve is a rename this
# file has to hear about) but they are not separate ranges: MM_REIMU_1 and
# MM_REIMU_3 are two of the four poses in MM_REIMU_BASE, and the four poses
# are exactly what that bank's size is made of.
CONTAINED_ALIASES = {
    "MM_REIMU_1":         "MM_REIMU_BASE",
    "MM_REIMU_3":         "MM_REIMU_BASE",
}

# How far past its parent each alias must still land.
ALIAS_MARGIN = 0x2400

NOT_AN_ADDRESS = {
    "MM_STAGE_BG_STRIDE",     # a size in bytes
    "MM_REIMU_PITCH",
    "MM_REIMU_ROW",
}


def unregistered(addrs):
    """MM_* defines that look like DDR addresses but have no entry in SIZES."""
    out = []
    for name, value in sorted(addrs.items()):
        if name in CONTAINED_ALIASES:
            continue
        if not name.startswith("MM_") or name in SIZES or name in NOT_AN_ADDRESS:
            continue
        if 0x01000000 <= value < DDR_END:
            out.append((name, value))
    return out


def main():
    addrs = defines()
    # A name that will not resolve is a rename this file has to hear about,
    # and a name that stops landing inside its parent is a surface that has
    # moved out from under it.  Either one is a failure, not a silent skip.
    for alias, parent in sorted(CONTAINED_ALIASES.items()):
        if alias not in addrs or parent not in addrs:
            print("  *** %s is an alias of %s, and one of them is not in"
                  " memory_map.h any more" % (alias, parent))
            return 1
        if not (addrs[parent] <= addrs[alias]
                < addrs[parent] + SIZES[parent][0]):
            print("  *** %s (%#x) no longer sits inside %s (%#x, %d bytes)"
                  % (alias, addrs[alias], parent, addrs[parent],
                     SIZES[parent][0]))
            return 1
        if addrs[alias] + ALIAS_MARGIN > addrs[parent] + SIZES[parent][0]:
            print("  *** %s (%#x + %#x) runs past the end of %s"
                  % (alias, addrs[alias], ALIAS_MARGIN, parent))
            return 1

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
