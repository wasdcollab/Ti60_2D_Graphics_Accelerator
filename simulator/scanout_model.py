#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
simulator/scanout_model.py
==========================
Byte-level model of the Ti60's scanout compositor.

WHY THIS EXISTS
    Most of the picture never reaches the framebuffer.  The scanout draws six
    layers while the pixels stream past, in this order (rtl/v_dma/video_dma_read.v,
    the output always block):

        HUD  >  beam (opaque)  >  laser columns (saturated add)
             >  weather (snow)  >  bullet curtain  >  framebuffer

    The VM has no scanout, so before this module existed the exported pictures
    were the *framebuffer*: the backdrop and nothing else, with no snow, no
    laser columns, no bullets, no beam and no FPS digits in them.  The scene
    assertions are right to read vm.fb directly - that is the state the firmware
    produced - but a picture of the framebuffer is not a picture of the screen.

    This module reproduces the six layers so save_frame_bmp() can export what
    the panel would show.  It only reads state the VM already keeps, and it
    never writes back into the VM, so no scenario's verdict can change.

WHAT IT READS
    Every layer except the framebuffer and the bullets is driven by an APB word
    the firmware writes once a frame; the VM already stores all of them in
    vm.params.  The bullets come from the per-scanline bucket table in DDR,
    which the firmware writes through the ordinary memory path.

CORRESPONDENCE
    Each layer function names the RTL file it mirrors and the line numbers of
    the expressions it transcribes.  Where the RTL has a pipeline delay
    (video_bullet_overlay emits the pixel sampled three clock edges earlier) the model composes
    combinationally: a few pixels of latency does not change which layer wins
    a pixel, and the model's job is the picture, not the timing.
"""

# ---------------------------------------------------------------------------
# Geometry, mirroring the RTL localparams and sw/driver/memory_map.h.
# ---------------------------------------------------------------------------
PLAY_LEFT = 181          # video_weather.v PLAY_LEFT  == main.c GAME_LEFT
PLAY_RIGHT = 1185        # video_weather.v PLAY_RIGHT == main.c GAME_RIGHT

HALF_PIXELS = 512

BUCKET_STRIDE = 4096      # bytes per bucket (MM_BUCKET_STRIDE)
BUCKET_SLOTS = 1024       # MM_BUCKET_SLOTS
# Scanlines sharing one bucket (MM_BUCKET_GROUP_ROWS).  The firmware appends one
# entry per group a bullet crosses, not one per scanline, and stores the tile row
# of the GROUP'S first scanline; this model adds the offset back (see
# _bucket_entries).
BUCKET_GROUP_ROWS = 8
# The second table, for FB_*_BACK: MM_BUCKET_STRIDE * MM_BUCKET_ROWS.
BUCKET_SWAP_OFFSET = 0x00060000

# video_bullet_overlay.v's run layout, transcribed:
#   slot 0..15  enemy bullets  26x26, a 32-byte row stride -> 832 B each
#   slot 16     player shots    7x26, an 8-byte row stride -> 208 B each
#   slot 17     orbs           26x16, a 16-byte row stride -> 416 B each
#   slot 18     missiles       13x26, a 16-byte row stride -> 416 B each
# The orb run is 26 rows now, not 16: bullet_store_build() pads it with ten
# transparent rows so that every slot's tile is TILE_ROWS tall and the scanout
# can reject an out-of-range tile row with one constant comparison.
N_TILES = 27
EB_BYTES = 832
TILE_ROWS = 26
PB_BASE = 13312
ORB_BASE = 13520
MS_BASE = 13936
# role + hue*32, the one line of arithmetic the RTL does between the tile RAM
# and the palette RAM.  32 is a power of two, so it is a concatenation there.
PAGE = 32

SCRATCH_BASE = 0x01600000

# video_dual_hud.v:42-63, the character ROM.
_HUD_BITMAP = (
    0x3C66C3C3C3C3C3C3C3C3663C, 0x18387818181818181818187E,
    0x3C66C303060C183060C0C3FF, 0x3C66C303061C060303C3663C,
    0x060E1E3666C6FF060606060F, 0xFFC0C0C0FC06030303C3663C,
    0x3C66C0C0FCC6C3C3C3C3663C, 0xFFC306060C0C181830303030,
    0x3C66C3C3663C66C3C3C3663C, 0x3C66C3C3C3C33F030303663C,
    0xFFC0C0C0FCC0C0C0C0C0C0C0, 0xFCC6C3C3C3C6FCC0C0C0C0C0,
    0x3C66C3C0C0780E0303C3663C, 0x000018180000001818000000,
    0x000000000000000000000000, 0x3C66C3C0C0C0C0C0C0C3663C,
    0xC3C3C3C3C3C3C3C3C3C3663C, 0x3C66C3C0C0CFC3C3C3C3663E,
    0x183C66C3C3C3FFC3C3C3C3C3,
)

_LASER_SHEATH = (0xFFA0C8, 0xFF80A0, 0xD05070)
_LASER_BEAM = (0xFF2050, 0xE01840, 0x901028)
_LASER_HAZE = (0x500C18, 0x380810, 0x20040A)


def _u32(v):
    return v & 0xFFFFFFFF


def _blend8(fg, bg, a):
    """(fg*a + bg*(255-a) + 127) / 255, per channel.

    Transcribed from video_dma_read.v's blend8() so the model and the RTL cannot
    disagree about what an alpha byte means.  alpha == 255 is handled by the
    caller as a plain replace, exactly as the RTL does, so an opaque palette
    reproduces the pre-alpha picture bit for bit.
    """
    return (fg * a + bg * (255 - a) + 127) // 255


def _composite(base, fg, add, alpha):
    """One scanout layer pixel over `base`: ADD, blend, or replace at 255.

    The three answers the compositor has had since the bullet curtain, the beam
    and the laser columns each grew a selector.  The add branch is the same
    min(255, base + fg) the RTL runs, and 255 is the plain replace the model
    printed back when every layer only had that one.
    """
    if add:
        nb = (base & 0xFF) + (fg & 0xFF)
        ng = ((base >> 8) & 0xFF) + ((fg >> 8) & 0xFF)
        nr = ((base >> 16) & 0xFF) + ((fg >> 16) & 0xFF)
        return ((nr if nr < 256 else 255) << 16 |
                (ng if ng < 256 else 255) << 8 |
                (nb if nb < 256 else 255))
    if alpha >= 0xFF:
        return fg
    return (_blend8((fg >> 16) & 0xFF, (base >> 16) & 0xFF, alpha) << 16 |
            _blend8((fg >> 8) & 0xFF, (base >> 8) & 0xFF, alpha) << 8 |
            _blend8(fg & 0xFF, base & 0xFF, alpha))
# ---------------------------------------------------------------------------
# video_weather.v -- the snow layer
# ---------------------------------------------------------------------------
def _weather_dots():
    """strip_dots_build() in hardware: video_weather.v:76-159.

    Four xorshift32 steps per dot, feeding y / x / h in that order, exactly as
    the RTL's gen_step case does and as main.c's strip_dots_build() did.
    """
    s = 0x54
    dots = []
    for _ in range(170):
        s = _u32(s ^ (s << 13)); s = _u32(s ^ (s >> 17)); s = _u32(s ^ (s << 5))
        y = 32 + ((s >> 9) & 511)
        s = _u32(s ^ (s << 13)); s = _u32(s ^ (s >> 17)); s = _u32(s ^ (s << 5))
        x = s & 31
        s = _u32(s ^ (s << 13)); s = _u32(s ^ (s >> 17)); s = _u32(s ^ (s << 5))
        h1 = s & 1
        s = _u32(s ^ (s << 13)); s = _u32(s ^ (s >> 17)); s = _u32(s ^ (s << 5))
        style = (h1 << 1) | (s & 1)
        dots.append((style, y, x))
    return dots


_WEATHER_DOTS = _weather_dots()


def _weather_colours(stage):
    """video_weather.v:121-125.  0 ice, 1 lava, 2 dream, 3 card -> ice."""
    if stage == 0 or stage == 3:
        return 0xEEF8FF, 0xCEE4FF
    if stage == 1:
        return 0xFF9A3C, 0x7F4D1E
    return 0xD8A8FF, 0x6C547F


def _weather_line_slots(y, slide, scroll):
    """The up-to-8 dots scanline y displays, in table order.

    video_weather.v:106-118, 164-193, 228-229.  The RTL collects the next
    line's dots during the current one and hands the set over at the line tail,
    so line y shows every dot whose y_top <= y <= y_top + height.  Slots fill in
    table order and stop at eight; a ninth match is dropped, as in the RTL.
    """
    slots = []
    for style, dy, dx in _WEATHER_DOTS:
        y_top = dy + slide
        if y_top <= y <= y_top + (style >> 1):
            slots.append(((dx - scroll) & 0x1F, style))
            if len(slots) == 8:
                break
    return slots


# ---------------------------------------------------------------------------
# video_laser.v -- the boss laser columns
# ---------------------------------------------------------------------------
def _laser_pixel(rel, y_flow, band):
    """video_laser.v: the column profile - colour AND how it composites.

    Returns (rgb, add, alpha).  Three bands, and the blend comes out of the same
    profile as the colour, because which column is the light source is a fact
    about this shape:

        rel 7, 8          the core: white, and the only columns that ADD
        rel 4..11         the halo: the sheath and beam colours, blended at 190
        rel 0..3, 12..15  the rim: the haze, blended at 130

    Every drawn column used to add, and six of the sixteen were white or near
    white, so the whole strip saturated on any non-zero background and the core's
    over-exposure became the column's.  The surge no longer widens the core for
    the same reason: it moves the sheath pair between rel 6/9 and rel 5/10, so
    the pulse rides on blended columns instead of on more white.
    """
    if band == 0:
        surge = ((y_flow >> 4) & 1) ^ ((y_flow >> 2) & 1)
    elif band == 1:
        surge = ((y_flow >> 3) & 1) ^ ((y_flow >> 1) & 1)
    else:
        surge = 0
    if rel == 7 or rel == 8:
        return 0xFFFFFF, True, 255
    if surge:
        if rel == 5 or rel == 10:
            return _LASER_SHEATH[band], False, 190
    else:
        if rel == 6 or rel == 9:
            return _LASER_SHEATH[band], False, 190
    if 4 <= rel <= 11:
        return _LASER_BEAM[band], False, 190
    return _LASER_HAZE[band], False, 130


# ---------------------------------------------------------------------------
# video_beam.v -- the craft's beam and the warning hairlines
# ---------------------------------------------------------------------------
def _beam_pixel(rel):
    """video_beam.v's column table: (rgb, add, alpha).

    Columns 0, 1, 14 and 15 are MAGENTA_KEY in the sheet, so nobody draws them.
    The two centre columns are the light source and the only ones that ADD; the
    halo and the rim blend, so the snow reads through them and the beam stays a
    light shining through air rather than a solid white bar.  This table used to
    be six columns of white or near white that all added, and it carried a b_hot
    phase that the RTL no longer has.
    """
    if rel == 7 or rel == 8:
        return 0xFFFFFF, True, 255
    if rel == 5 or rel == 10:
        return 0x8AD8FF, False, 190
    if rel == 6 or rel == 9:
        return 0xC0EEFF, False, 190
    if rel == 2 or rel == 13:
        return 0x2E6C8C, False, 130
    if rel == 3 or rel == 12:
        return 0x4696C0, False, 130
    if rel == 4 or rel == 11:
        return 0x66C0E8, False, 130
    return 0x000000, False, 0        # 0, 1, 14, 15: keyed, drawn by nobody
class Scanout(object):
    """The six layers, with everything frame-constant derived once."""

    def __init__(self, fb_pixels, params, scratch32, btile, bpal,
                 base_addr, width, height, pitch):
        self.fb = fb_pixels
        self._raw_cache = {}
        self._pool_cache = {}
        self.p = params
        self.scratch32 = scratch32
        self.btile = btile
        self.bpal = bpal
        self.base = base_addr
        self.w = width
        self.h = height
        self.pitch = pitch

        get = params.get

        # ---- weather, and the laser fields that ride in the same word --------
        self.weather = get(0x78, 0)
        self.w_en = (self.weather >> 15) & 1
        self.w_stage = (self.weather >> 13) & 3
        self.w_scroll = (self.weather >> 8) & 0x1F
        self.w_slide = self.weather & 0xFF
        self.w_bright, self.w_dim = _weather_colours(self.w_stage)
        self.l_en = (self.weather >> 18) & 1
        self.l_band = (self.weather >> 19) & 3

        colx = get(0xB0, 0) | (get(0xB4, 0) << 32)
        self.l_cols = [(colx >> (12 * k)) & 0xFFF for k in range(4)]

        # ---- beam and hairlines --------------------------------------------
        bctrl = get(0xBC, 0)
        self.b_x = get(0xB8, 0) & 0xFFF
        self.b_len = bctrl & 0x7FF
        self.b_en = (bctrl >> 11) & 1
        self.hair = []
        for k in range(3):
            o = 0xC0 + 16 * k
            self.hair.append((get(o, 0) & 0xFFF, get(o + 4, 0) & 0xFFFFFF,
                              get(o + 8, 0) & 0xFFFFFF,
                              get(o + 12, 0) & 0xFFFFFF))

        # ---- occlusion box (weather, beam, laser and bullets all read it) ----
        mx, my = get(0x8C, 0), get(0xAC, 0)
        self.box_on = bool(mx >> 31)
        self.bx0, self.bx1 = mx & 0x7FF, (mx >> 11) & 0x7FF
        self.by0, self.by1 = my & 0x7FF, (my >> 11) & 0x7FF

        # ---- the bucket table for THIS framebuffer --------------------------
        # Double buffered, and which table is live follows bit 22 of the scanned
        # base address - video_dma_read.v:306-314.
        bk = get(0xF0, 0)
        if bk:
            bk += BUCKET_SWAP_OFFSET if (base_addr >> 22) & 1 else 0
        self.bucket_off = (bk - SCRATCH_BASE) if bk else -1
        self.bucket_ok = (bk != 0 and self.bucket_off >= 0 and
                          self.bucket_off + (self.h // BUCKET_GROUP_ROWS) *
                          BUCKET_STRIDE <= len(self.scratch32) * 4)

        # ---- the FPS overlay -------------------------------------------------
        self.hud_en = get(0x5C, 1) & 1
        fps = get(0x34, 0)
        self.cpu_fps = fps & 0xFF
        self.fpga_fps = (fps >> 8) & 0xFF

    # -- helpers -----------------------------------------------------------
    def _in_box(self, x, y):
        return (self.box_on and self.bx0 <= x <= self.bx1 and
                self.by0 <= y <= self.by1)

    def _bucket_raw(self, group):
        """One group's table entries as written, in draw order.

        (bx, trow_bias, slot, width, hue).  Zero slots are skipped: the RTL's
        phase 2 only appends an entry when `new_bullet != 0`.

        `at` converts the byte offset to scratch32's word index with `>> 2`.  A
        byte offset used directly against the word view does not raise - it
        reads a valid but unrelated word.
        """
        if group in self._raw_cache:
            return self._raw_cache[group]
        at = (self.bucket_off + group * BUCKET_STRIDE) >> 2
        end = at + BUCKET_SLOTS
        s = self.scratch32
        if at < 0 or end > len(s):
            out = ()
        else:
            out = tuple((e & 0x7FF, (e >> 11) & 0x3F, (e >> 17) & 0x7F,
                         (e >> 24) & 0x1F, (e >> 29) & 0x7)
                        for e in s[at:end] if e)
        self._raw_cache[group] = out
        return out

    def _pool_for(self, group):
        """The active pool as of `group` — dma_bucket_prefetch.v gen_active_pool.

        With SINGLE_GROUP_REG = 1 a sprite is written once, in its starting
        group, so a group's table alone no longer describes what is on screen.
        The pool evolves at each group boundary:

            phase 1  survivors keep their order, bias += 8, dropped once
                     bias + 8 reaches 34 (their last tile row has scrolled out)
            phase 2  this group's new entries are appended behind the survivors

        Order matters: video_bullet_overlay.v lets the highest index win, so the
        pool's order — not the table's write order — is what the picture shows.
        Capacity is BUCKET_SLOTS; anything past that is dropped silently.
        """
        if group in self._pool_cache:
            return self._pool_cache[group]
        base = ()
        if group > 0:
            base = tuple((bx, bias + 8, slot, width, hue)
                         for (bx, bias, slot, width, hue) in self._pool_for(group - 1)
                         if bias + 8 < 34)
        merged = (base + self._bucket_raw(group))[:BUCKET_SLOTS]
        self._pool_cache[group] = merged
        return merged

    def _bucket_entries(self, y):
        """The live entries of scanline y: (bx, trow, slot, width, hue).

        Sourced from the active pool, which is what the scanout actually reads.
        The tile row is reconstructed from the pool's row bias:

            trow = row_bias - 8 + (y mod BUCKET_GROUP_ROWS)

        which is identically y minus the tile's top row. Invalid rows and
        transparent pixels are rejected before priority selection, matching the
        RTL coverage cache.
        """
        group = y // BUCKET_GROUP_ROWS
        dy = y & (BUCKET_GROUP_ROWS - 1)
        return [(bx, bias - 8 + dy, slot, width, hue)
                for (bx, bias, slot, width, hue) in self._bucket_raw(group)]
    def _hud_pixel(self, x, y):
        """video_dual_hud.v:13-20 and 40-67.  None where it draws nothing."""
        if not self.hud_en or x < 16 or y < 8 or y >= 32:
            return None
        right = x >= HALF_PIXELS
        if right:
            if not (656 <= x < 848):
                return None
        elif x >= 192:
            return None
        lx = x - (656 if right else 16)
        ly = y - 8
        cell = (lx >> 4) & 0xF
        fps = self.fpga_fps if right else self.cpu_fps
        if right:
            ch = {0: 10, 1: 11, 2: 17, 3: 18, 4: 13, 6: (fps >> 4) & 0xF,
                  7: fps & 0xF, 9: 10, 10: 11, 11: 12}.get(cell, 14)
        else:
            ch = {0: 15, 1: 11, 2: 16, 3: 13, 5: (fps >> 4) & 0xF,
                  6: fps & 0xF, 8: 10, 9: 11, 10: 12}.get(cell, 14)
        row = (ly >> 1) & 0xF
        col = (lx >> 1) & 7
        fg = (_HUD_BITMAP[ch] >> (95 - (row << 3) - col)) & 1
        if right:
            return 0x00FF00 if fg else 0x0000FF
        return 0xFFFF00 if fg else 0x000000

    def _bullet_pixel(self, slot, row, rel):
        """video_bullet_overlay.v's stage-3 address arithmetic.

        Returns the cell's ROLE, or None when the pixel is transparent.  It is
        not a palette index any more: the tile holds shapes only, and the caller
        turns the role into an index with role + hue*32 out of the bucket
        entry's colour page.

        The address arithmetic is transcribed rather than simplified: the
        player shots' 8-byte row stride and the orbs' separate run are exactly
        the two places a "tidy" version of this picks the wrong tile.
        """
        if slot < 0 or slot >= N_TILES or row < 0 or row >= TILE_ROWS:
            return None
        if slot == 16:
            base, shift = PB_BASE, 3        # the player shot's 8-byte stride
        elif slot == 17:
            base, shift = ORB_BASE, 4
        elif slot == 18:
            base, shift = MS_BASE, 4        # the missile, same stride as the orb
        elif slot >= 19:
            base, shift = 14368 + (slot-19)*832, 5
        else:
            # The enemy run is the only one with more than one tile in it, and
            # its 32-byte stride is what a 26-wide tile needs.
            base, shift = slot * EB_BYTES, 5
        addr = base + (row << shift) + rel
        if addr < 0 or addr >= len(self.btile):
            return None
        role = self.btile[addr] & 0x1F
        # Transparent is decided by the tile byte itself, NOT by the colour and
        # NOT by the concatenated index: role 0 on hue page 3 is index 96,
        # which is an ordinary entry with a colour in it.
        return role if role else None
    # -- the compositor ----------------------------------------------------
    def compose(self, out):
        """Composite the frame into `out` (a sequence of w*h ARGB words).

        One pass per scanline, in the RTL's own priority order, so that each
        pixel is decided by the same chain of "does this layer own it" tests
        that video_dma_read.v's output block performs - only without the
        pipeline registers, which shift the picture sideways rather than
        change which layer wins.
        """
        w, h, pitch = self.w, self.h, self.pitch
        fb = self.fb

        slot_of = [-1] * w      # -1 = no entry; tile slot 0 is valid
        row_of = [0] * w        # that tile's row
        col_of = [0] * w        # the pixel's column inside that tile
        hue_of = [0] * w        # that entry's colour page, [31:29]
        touched = []            # pixels the previous scanline claimed

        for y in range(h):
            row_off = y * pitch
            out_off = y * w

            # ---- the bullet curtain for this scanline -------------------------
            if self.bucket_ok:
                # Clear only what the previous line touched; a full 1366-wide
                # wipe every line is 200k list stores a frame for nothing.
                for xr in touched:
                    slot_of[xr] = -1
                touched = []
                for bx, row, slot, width, hue in self._bucket_entries(y):
                    # video_bullet_overlay.v:135-143: a hit on [bx, bx+width).
                    if width == 0:
                        continue
                    x_end = bx + width
                    if x_end > w:
                        x_end = w
                    xr = bx if bx > 0 else 0
                    while xr < x_end:
                        # Match the RTL coverage cache: transparent/invalid
                        # entries do not consume any priority position.
                        if self._bullet_pixel(slot, row, xr - bx) is None:
                            xr += 1
                            continue
                        if slot_of[xr] < 0:       # first touch records the span
                            touched.append(xr)
                        # Last nontransparent entry wins at arbitrary depth.
                        slot_of[xr] = slot
                        row_of[xr] = row
                        col_of[xr] = xr - bx
                        hue_of[xr] = hue
                        xr += 1

            # ---- the snow layer -------------------------------------------------
            # The strip repeats every 32 pixels, so one dot is a whole column of
            # marks (video_weather.v:195-209).
            hits = {}
            if self.w_en:
                for x0, style in _weather_line_slots(y, self.w_slide, self.w_scroll):
                    for xx in range(x0, w, 32):
                        if PLAY_LEFT <= xx <= PLAY_RIGHT:
                            hits.setdefault(xx, []).append(style)

            # ---- beam geometry ---------------------------------------------------
            # No b_hot any more: the scanout's beam has one profile for every row
            # (video_beam.v), and the row-phase version of it was dropped when
            # the beam grew its per-column selector.
            b_hit = self.b_en and y < self.b_len
            b_lo = self.b_x - 8
            b_hi = self.b_x + 8

            # ---- laser columns ---------------------------------------------------
            laser_cols = None
            if self.l_en:
                laser_cols = []
                for k in range(4):
                    c = self.l_cols[k]
                    # A centre of 0 parks that column off screen (video_laser.v:67).
                    if c == 0:
                        continue
                    lo = c - 8
                    hi = c + 8
                    if hi > 0 and lo < w:
                        y_flow = (y - (self.w_scroll << 4)) & 0x7FF
                        laser_cols.append((lo, hi, y_flow))
                if not laser_cols:
                    laser_cols = None

            for x in range(w):
                if self._in_box(x, y):
                    # Every scanout layer honours the box; the framebuffer shows
                    # through untouched (video_weather.v:225-228 and the three
                    # layers that copied the same comparison).
                    out[out_off + x] = fb[row_off + x] | 0xFF000000
                    continue

                r = fb[row_off + x]

                # ---- L5: the bullet curtain ---------------------------------
                # Under the snow, over the framebuffer.  Clipped to the playfield
                # and refused for a slot past the last tile, both as the RTL does
                # (video_bullet_overlay.v:272-274).
                #
                # The palette entry is {alpha, rgb}: the tile byte is an INDEX,
                # so the entry is the only place a per-colour opacity can live.
                # alpha 255 replaces, anything else blends against what the
                # bullet is drawn OVER - the framebuffer, which is what r holds
                # at this point in the loop.  The precipitation above is a
                # separate, later layer and is not part of this background.
                if self.bucket_ok and PLAY_LEFT <= x < PLAY_RIGHT:
                    # Coverage was checked before selecting this winner.
                    slot = slot_of[x]
                    row  = row_of[x]
                    col  = col_of[x]
                    hue  = hue_of[x]
                    role = self._bullet_pixel(slot, row, col) if slot >= 0 else None
                    if role is not None:
                        # role + hue*32.  The tile carries no colour; the page the
                        # bullet named in its bucket entry is what picks one of the
                        # eight for this role.
                        idx = role + hue * PAGE
                        pal = self.bpal
                        entry = pal[idx] if idx < len(pal) else 0
                        fg = entry & 0xFFFFFF
                        a = (entry >> 24) & 0xFF
                        if a == 0xFE:
                            # video_bullet_overlay.v's ADD_CODE: the one alpha
                            # value that is not an opacity, which is how one tile
                            # carries an added trail next to a blended body.
                            r = _composite(r, fg, True, 255)
                        else:
                            r = _composite(r, fg, False, a)

                # ---- L4: the snow, above the framebuffer and the bullets ----
                if hits:
                    styles = hits.get(x)
                    if styles is not None:
                        # The RTL's priority encoder takes the first hit among
                        # the up-to-8 slots on this line.
                        r = self.w_dim if (styles[0] & 1) else self.w_bright

                # ---- L3: the boss's laser columns -----------------------------
                # Core adds, halo and rim blend, and the profile carries both -
                # see _laser_pixel.  This used to add on all sixteen columns,
                # which is the change the spec asked for.
                if laser_cols is not None:
                    for lo, hi, y_flow in laser_cols:
                        if lo <= x < hi:
                            lc, l_add, l_a = _laser_pixel(x - lo, y_flow, self.l_band)
                            r = _composite(r, lc, l_add, l_a)
                            break

                # ---- L2: the craft's beam, and the warning hairlines ----------
                #
                # The beam is light, so its core SATURATES ADD on top of what is
                # below it - video_dma_read.v does min(255, base + beam) per
                # channel - but only its core.  Its halo and rim blend, because
                # an added cyan would bleach the snow toward white exactly where
                # the colour is supposed to show.  Both answers come out of the
                # layer's own column table; see _beam_pixel.
                #
                # The hairlines deliberately have neither: they have to stay
                # legible over a bright snow ridge, and adding to a bright
                # backdrop is how a warning mark washes out where it is most
                # needed.  They keep replacing, as they always have.
                if b_hit and b_lo <= x < b_hi:
                    rel = x - b_lo
                    # Columns 0, 1, 14 and 15 were MAGENTA_KEY in the blit, so
                    # they keep what is underneath (video_beam.v).
                    bc, b_add, b_a = _beam_pixel(rel)
                    if b_a > 0:
                        r = _composite(r, bc, b_add, b_a)
                else:
                    for hx, c_out, c_lft, c_mid in self.hair:
                        if hx == 0:
                            continue
                        if x == hx - 2 or x == hx + 1:
                            c = c_out
                        elif x == hx - 1:
                            c = c_lft
                        elif x == hx:
                            c = c_mid
                        else:
                            continue
                        # A colour of 0 means the blit emitted no pixel for that
                        # column, so nothing is drawn there (video_beam.v:148-149).
                        if c:
                            r = c
                        break

                # ---- L1: the FPS overlay, last and therefore on top -------
                hv = self._hud_pixel(x, y)
                if hv is not None:
                    r = hv

                out[out_off + x] = r | 0xFF000000
        return out
