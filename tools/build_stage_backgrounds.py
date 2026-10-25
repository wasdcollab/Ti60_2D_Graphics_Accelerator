"""Build three stage backdrops plus two parallax strips for the bullet-hell game.

Sources (see assets/SOURCES.md for the full attribution chain):

  * assets/source/stage/winter/*.png   winter pixel art background (OGA-BY 3.0)
  * assets/source/stage/volcano/*.png  2D Platformer Volcano Pack (CC0, Tio Aimar)
  * assets/source/stage/fairytale/*.png Fairy-Tale 2D Backgrounds (OGA-BY 3.0)

Every output is 1366x768, i.e. 1:1 with the screen - BitBlt has no scaler, so
a half-size plate could only ever cover half the display.

This generator was written for the 640x600 build and is re-proportioned here
rather than resampled: the 640->1366 and 600->768 factors are NOT equal
(2.134 and 1.28), so scaling the old plates would have stretched every round
bullet into an ellipse.  Everything below is expressed through sv()/sh() - a
vertical or horizontal length in the OLD coordinate system - and every
composition constant is written in those old units, so the pictures keep the
proportions they were designed with while being drawn on the new canvas.

Pixel art is *not* hand drawn: the licensed layers are nearest-neighbour
reduced to a card resolution and composited, so the artwork keeps its own
chunky pixel structure while the surrounding sky, ground haze and parallax
strips are built from a shared colour ramp.

Outputs
    sw/app/stage_bg.h    ART_* indices, strip table, geometry
    sw/app/stage_bg.c    one asset bank: palette + RLE + strip tile
    assets/processed/stage_*.png, strip_*.png   review copies
"""
from pathlib import Path
import re
import sys

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'assets' / 'source' / 'stage'
OUT = ROOT / 'assets' / 'processed'
NEAR = Image.Resampling.NEAREST
KEY = 0x00FF00FF
BG_W, BG_H = 1366, 768
CARD = (80, 75)
# The playfield's own bounds on the screen.  main.c clips every game draw to
# this band (GAME_LEFT..GAME_RIGHT) and keeps the HUD in the two 180-pixel
# gutters outside it.
GAME_LEFT, GAME_RIGHT = 181, 1185
STRIP_PERIOD = 32
STRIP_H = BG_H

# The old design's grid.  A length written in it is scaled by the factor of
# the axis it runs along, so a moon stays a circle and a ridge line keeps its
# height proportion.  Horizontal sizes are NOT scaled by the vertical factor -
# that is exactly the squash this rework exists to avoid.
SCALE_H = BG_H / 600.0                    # 1.28
SCALE_W = BG_W / 640.0                    # 2.1344


def sv(v):
    """A VERTICAL length (rows, heights, radii) from the 640x600 design."""
    return int(round(v * SCALE_H))


def sh(v):
    """A HORIZONTAL length (columns, offsets, pitches) from the old design."""
    return int(round(v * SCALE_W))


def load(path):
    p = SRC / path
    if not p.exists():
        raise SystemExit('missing stage source: %s (see assets/SOURCES.md)' % p)
    return Image.open(p).convert('RGBA')


def cover(im, res):
    """Cover-fit to res with nearest sampling, preserving pixel-art structure."""
    tw, th = res
    scale = max(tw / im.width, th / im.height)
    nw = max(tw, int(im.width * scale + 0.5))
    nh = max(th, int(im.height * scale + 0.5))
    im = im.resize((nw, nh), NEAR)
    left, top = (nw - tw) // 2, (nh - th) // 2
    return im.crop((left, top, left + tw, top + th))


def vramp(colors, h):
    """A vertical gradient band h pixels tall from a colour list."""
    band = Image.new('RGBA', (1, len(colors)))
    band.putdata([(r, g, b, 255) for r, g, b in colors])
    return band.resize((BG_W, h), Image.Resampling.BILINEAR).convert('RGBA')


def palette(im, count):
    """Quantise one backdrop to its own <=count colour palette.

    Sharing a single palette across all three stages pushed the warm lava
    palette onto the ice stage and turned it mauve, so every backdrop gets a
    palette of its own; the decoder indexes a per-asset palette anyway.
    """
    alpha = im.getchannel('A')
    q = im.convert('RGB').quantize(colors=count, method=Image.Quantize.MEDIANCUT,
                                   dither=Image.Dither.NONE).convert('RGBA')
    q.putalpha(alpha)
    return q


def sky3(size, stops):
    """size=(w, h) vertical gradient through stops=[((r,g,b), pos0_255), ...]."""
    w, h = size
    stops = sorted(stops, key=lambda s: s[1])
    im = Image.new('RGBA', (1, h))
    data = []
    for y in range(h):
        v = y * 255 // max(1, h - 1)
        lo = stops[0]
        hi = stops[-1]
        for i in range(len(stops) - 1):
            if stops[i][1] <= v <= stops[i + 1][1]:
                lo, hi = stops[i], stops[i + 1]
                break
        span = max(1, hi[1] - lo[1])
        t = (v - lo[1]) / span
        r = int(lo[0][0] + (hi[0][0] - lo[0][0]) * t)
        g = int(lo[0][1] + (hi[0][1] - lo[0][1]) * t)
        b = int(lo[0][2] + (hi[0][2] - lo[0][2]) * t)
        data.append((r, g, b, 255))
    im.putdata(data)
    return im.resize((w, h), NEAR).convert('RGBA')


def horizon(w, seed, base, rough, lobes):
    """A jagged horizon line: sum of a few sine lobes, fixed by its seed."""
    import math
    import random
    rnd = random.Random(seed)
    phases = [rnd.random() * 6.283 for _ in range(lobes)]
    freqs = [1.0 + i * 0.7 + rnd.random() for i in range(lobes)]
    amps = [1.0 / (1.0 + i * 1.4) for i in range(lobes)]
    total = sum(amps)
    line = []
    for x in range(w):
        t = x / float(w)
        v = sum(amps[i] * math.sin(6.283 * freqs[i] * t + phases[i])
                for i in range(lobes)) / total
        line.append(int(base + rough * v))
    return line


def silhouette(w, h, line, fill, seed=0, wiggle=0, jitter=0):
    """Fill everything below ``line`` with ``fill``."""
    import random
    rnd = random.Random(seed)
    im = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    px = im.load()
    for x in range(w):
        top = line[x] + (rnd.randrange(-jitter, jitter + 1) if jitter else 0)
        for y in range(max(0, top), h):
            px[x, y] = fill
    return im


def snowcap(im, line, depth, color, seed):
    """Lay ``color`` over the top ``depth`` rows of a silhouette.

    The cap's lower edge follows a slow sine, never a per-column random: a
    jagged edge is a colour boundary that restarts a run on every column, and
    three ridge lines with random snow edges cost more firmware than the whole
    lava backdrop (measured: 9 kB of the ice stage's 13 kB).
    """
    import math
    px = im.load()
    w, h = im.size
    ph = (seed % 97) * 0.31
    for x in range(w):
        cap = line[x]
        t = x / float(w)
        thick = depth * (0.65 + 0.35 * math.sin(6.283 * 1.5 * t + ph))
        lim = min(h, cap + int(thick))
        for y in range(max(0, cap), lim):
            px[x, y] = color
    return im


def bands(colors, y0, y1):
    """A stepped vertical ramp: each colour gets an equal slice of y0..y1.

    Stepped rather than interpolated because the firmware RLE coder pays per
    run, so a clean band costs one run per row while a dither costs dozens.
    """
    h = max(1, y1 - y0)
    im = Image.new('RGBA', (BG_W, h))
    px = im.load()
    for y in range(h):
        c = colors[min(len(colors) - 1, y * len(colors) // h)]
        for x in range(BG_W):
            px[x, y] = (c[0], c[1], c[2], 255)
    return im


def broadleaf(px, x0, base, height, half, trunk, canopy, canopy2, seed):
    """A single stylised broadleaf tree, drawn as long horizontal spans.

    Each row is one contiguous span (or two, for the split canopy), so a whole
    tree costs three or four runs a row instead of one per jagged pixel.
    """
    import math
    import random
    rnd = random.Random(seed)
    trunk_w = max(2, half // 7)
    trunk_top = base - int(height * 0.30)
    for y in range(trunk_top, base + 1):
        for dx in range(-trunk_w, trunk_w + 1):
            px[(x0 + dx) % BG_W, y] = trunk
    top = base - height
    span = max(1, trunk_top - top)
    for y in range(top, trunk_top + 1):
        # a dome that is widest a third of the way up, drawn as one contiguous
        # row span in a single tone per row - the RLE coder's favourite shape
        u = (y - top) / float(span)
        w = int(half * math.sqrt(max(0.0, 1.0 - (1.0 - u) ** 2)))
        if w <= 1:
            continue
        tone = canopy if u < 0.55 else canopy2
        for dx in range(-w, w + 1):
            px[(x0 + dx) % BG_W, y] = tone


def tint(im, dark, light):
    """Recolour a layer onto a two-colour ramp while keeping its silhouette."""
    a = im.getchannel('A')
    gray = im.convert('L')
    span = Image.new('L', (1, 256))
    span.putdata(list(range(256)))
    ramped = Image.merge('RGBA', (
        gray.point(lambda v: dark[0] + (light[0] - dark[0]) * v // 255),
        gray.point(lambda v: dark[1] + (light[1] - dark[1]) * v // 255),
        gray.point(lambda v: dark[2] + (light[2] - dark[2]) * v // 255),
        a))
    del span
    return ramped


def solidify(card):
    """Posterise a card to a hard-edged silhouette.

    The fairy-tale layers are 1920x1080 paintings: reduced to 80x75 their
    edges are still thousands of intermediate values, and every one of them
    becomes a one-pixel run in the backdrop's RLE stream.  Thresholding the
    alpha and keeping four tone steps turns the same tree line into a handful
    of flat colours.
    """
    a = card.getchannel('A').point(lambda v: 255 if v >= 96 else 0)
    rgb = card.convert('RGB').quantize(colors=4, method=Image.Quantize.MEDIANCUT,
                                       dither=Image.Dither.NONE).convert('RGB')
    out = rgb.convert('RGBA')
    out.putalpha(a)
    return out


def pixelate_layer(path, res=CARD, boost=1.0, tint_pair=None, mirror=False):
    """Reduce a licensed layer to a pixel-art card."""
    im = cover(load(path), res)
    if mirror:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    if tint_pair is not None:
        im = tint(im, tint_pair[0], tint_pair[1])
    if boost != 1.0:
        im = ImageEnhance.Brightness(im).enhance(boost)
    return im


def stamp(bg, layer, pos=(0, 0)):
    """Composite an RGBA layer using ITS OWN alpha as the mask.

    Image.paste(im, pos) with no mask uses *im*'s alpha to blend, while
    Image.paste(im, pos, mask) uses the mask - and both differ from
    alpha_composite, which in Pillow 11 leaves the untouched part of an
    opaque destination transparent.  Getting this wrong silently wiped the
    whole sky of the ice stage: the pasted layer's transparent region
    overwrote it with alpha 0.
    """
    bg.paste(layer, pos, layer)


def place(bg, card, box, alpha=1.0):
    """Nearest-enlarge a card into box=(x, y, w, h) of the backdrop.

    alpha < 1.0 is a deterministic checkerboard dither, not a real blend.  A
    partial alpha value becomes a *different colour* once the layer is
    flattened onto the backdrop, and every such colour scatters one-pixel runs
    through the RLE stream: blending the fairy-tale tree line at 0.5 produced
    626 colours and a 27 kB backdrop.  Dropping half the pixels in a regular
    pattern keeps the layer's own colours (so they stay in the palette) and
    keeps three quarters of the runs long.
    """
    x, y, w, h = box
    piece = card.resize((w, h), NEAR)
    if alpha < 1.0:
        mask = Image.new('L', (w, h), 255)
        mp = mask.load()
        keep = max(1, min(15, int(round(alpha * 16))))
        for yy in range(h):
            for xx in range(w):
                mp[xx, yy] = 255 if ((xx + yy * 2) % 16) < keep else 0
        piece.putalpha(Image.composite(piece.getchannel('A'),
                                       Image.new('L', (w, h), 0), mask))
    stamp(bg, piece, (x, y))


# --------------------------------------------------------------------------
# stage 1: frozen shrine
# --------------------------------------------------------------------------
# Every backdrop is built from FLAT banded shapes on purpose.  The boot RLE
# coder wins on long horizontal runs, so a dithered gradient costs ten times
# more firmware than a stepped one - and flat silhouettes also keep the
# playfield readable behind a screen full of bullets.
ICE_SKY = [(6, 10, 28), (10, 18, 44), (16, 30, 66), (24, 46, 90),
           (38, 68, 118), (60, 96, 148), (92, 132, 176), (134, 174, 208),
           (176, 208, 234), (206, 230, 246), (222, 238, 250)]
ICE_LAKE = [(198, 226, 246), (182, 212, 238), (166, 198, 230),
            (150, 184, 220), (136, 170, 210), (122, 156, 198),
            (108, 142, 186)]
ICE_FAR = (44, 68, 112)
ICE_MID = (30, 48, 88)
ICE_NEAR = (18, 30, 62)
ICE_FAR_SNOW = (168, 196, 226)
ICE_MID_SNOW = (136, 168, 204)
ICE_NEAR_SNOW = (104, 136, 176)
ICE_TREE = (12, 20, 44)
ICE_FLAKE = (236, 244, 255)
ICE_HORIZON = sv(330)


def build_ice():
    """Frozen ridge lines over a pale ice field, at night.

    Flat banded shapes on purpose: the firmware RLE coder pays per run, so a
    stepped ramp costs one run a row where a dithered gradient costs hundreds,
    and flat silhouettes also keep the playfield readable behind the bullets.
    """
    bg = Image.new('RGBA', (BG_W, BG_H), (0, 0, 0, 255))
    bg.paste(bands(ICE_SKY, 0, ICE_HORIZON), (0, 0))
    bg.paste(bands(ICE_LAKE, ICE_HORIZON, BG_H), (0, ICE_HORIZON))

    # Lobes are NOT scaled: horizon() normalises x to 0..1, so the same lobe
    # count on a 2.13x wider canvas is a 2.13x longer wavelength.  That is
    # deliberate - every extra lobe is another colour change per row in the
    # RLE stream, and long ridge spans are what keep the plate small.
    far = horizon(BG_W, 0x11, ICE_HORIZON - sv(110), sv(30), 3)
    mid = horizon(BG_W, 0x22, ICE_HORIZON - sv(62), sv(24), 4)
    near = horizon(BG_W, 0x33, ICE_HORIZON - sv(10), sv(18), 5)
    stamp(bg, silhouette(BG_W, BG_H, far, ICE_FAR + (255,), 0x11))
    snowcap(bg, far, sv(22), ICE_FAR_SNOW + (255,), 0x11)
    stamp(bg, silhouette(BG_W, BG_H, mid, ICE_MID + (255,), 0x22))
    snowcap(bg, mid, sv(16), ICE_MID_SNOW + (255,), 0x22)
    stamp(bg, silhouette(BG_W, BG_H, near, ICE_NEAR + (255,), 0x33))
    snowcap(bg, near, sv(11), ICE_NEAR_SNOW + (255,), 0x33)

    import random
    rnd = random.Random(0x1CE)
    px = bg.load()
    mo_r = sv(30)
    for y in range(sv(20), sv(116)):          # pale moon above the ridges
        for x in range(sh(392), sh(488)):
            dx, dy = x - sh(440), y - sv(68)
            if dx * dx + dy * dy < mo_r * mo_r:
                px[x, y] = ICE_SKY[-1] + (255,)
    # 38 conifers at the old pitch, each one 30-66 runs of its own.  Fewer and
    # shorter: the ridge reads the same at a glance and the RLE stream is
    # 1500 runs lighter.
    for tx in range(sh(14), BG_W - sh(18), sh(30)):   # conifers, near ridge
        base = near[tx]
        hgt = rnd.randrange(sv(10), sv(20))
        half_w = rnd.randrange(sv(4), sv(8))
        for row in range(hgt):
            w = 1 + (half_w * row * 2) // hgt
            for dx in range(-w, w + 1):
                px[(tx + dx) % BG_W, max(0, base - row)] = ICE_TREE + (255,)
    for y in range(ICE_HORIZON + sv(16), BG_H, sv(26)):
        # wind-blown drifts on the ice: long dashes, cheap and readable
        off = rnd.randrange(BG_W)
        col = ICE_LAKE[min(len(ICE_LAKE) - 1, 1 + (y - ICE_HORIZON) // sv(40))]
        for k in range(rnd.randrange(sh(70), sh(230))):
            px[(off + k) % BG_W, y] = col + (255,)
    # 160 specks was sparse on 640 columns; the count is deliberately NOT
    # scaled by area - every speck costs two extra runs in its row, and the
    # firmware image has 6 KB of headroom, not 60.
    for _ in range(96):                       # sparse drifting snow
        px[rnd.randrange(BG_W), rnd.randrange(sv(12), ICE_HORIZON + sv(40))] = ICE_FLAKE + (255,)
    return bg


# --------------------------------------------------------------------------
# stage 2: volcanic hollow
# --------------------------------------------------------------------------
LAVA_SKY = [(14, 5, 10), (26, 6, 10), (44, 8, 10), (68, 12, 10),
            (100, 20, 12), (138, 32, 15), (176, 50, 18), (208, 78, 24),
            (232, 112, 36), (246, 152, 62), (250, 190, 106)]
LAVA_ROCK_FAR = (58, 19, 16)
LAVA_ROCK_MID = (44, 14, 12)
LAVA_ROCK_NEAR = (30, 10, 9)
LAVA_LAKE = [(150, 40, 18), (176, 54, 20), (204, 74, 24),
             (228, 100, 30), (242, 132, 42), (250, 170, 66)]
LAVA_GLOW = (252, 226, 150)
LAVA_EMBER = (232, 132, 56)
LAVA_HORIZON = sv(340)


def build_lava():
    """An erupting cone behind a lava lake: banded rock rims, hot valley floor."""
    bg = Image.new('RGBA', (BG_W, BG_H), (0, 0, 0, 255))
    bg.paste(bands(LAVA_SKY, 0, sv(250)), (0, 0))
    bg.paste(bands(LAVA_LAKE, sv(250), BG_H), (0, sv(250)))

    import random
    rnd = random.Random(0x1A7A)
    px = bg.load()
    cone = horizon(BG_W, 0x44, sv(208), sv(26), 3)
    for x in range(BG_W):
        d = abs(x - BG_W // 2) / float(BG_W // 2)
        cone[x] = min(cone[x], int(sv(112) + sv(148) * d ** 1.35) + rnd.randrange(-2, 3))
    stamp(bg, silhouette(BG_W, BG_H, cone, LAVA_ROCK_FAR + (255,), 0x44))
    # Eruption.  The vent glow used to be a flat-bottomed slab pinned to the
    # ridge, and the first attempt at fixing it - an oval burst of light - was
    # worse: a pale disc on a peak reads as a sun at any viewing distance.  A
    # hot mouth plus embers climbing the sky is unmistakably a volcano, and it
    # costs fewer runs than the slab did.
    vent_x, vent_y = BG_W // 2, cone[BG_W // 2]
    for dx in range(-sv(9), sv(9) + 1):             # the mouth itself
        px[vent_x + dx, vent_y + sv(2)] = LAVA_GLOW + (255,)
        px[vent_x + dx, vent_y + sv(3)] = LAVA_EMBER + (255,)
    for k in range(38):                             # embers on their way up
        ex = vent_x + rnd.randrange(-sv(30), sv(30) + 1)
        ey = vent_y - sv(8) - rnd.randrange(0, sv(62))
        if 0 <= ex < BG_W and 0 <= ey < BG_H:
            px[ex, ey] = (LAVA_GLOW if k % 3 else LAVA_EMBER) + (255,)

    rim = horizon(BG_W, 0x55, LAVA_HORIZON - sv(66), sv(22), 5)
    stamp(bg, silhouette(BG_W, BG_H, rim, LAVA_ROCK_MID + (255,), 0x55))
    shelf = horizon(BG_W, 0x66, LAVA_HORIZON - sv(8), sv(14), 4)
    stamp(bg, silhouette(BG_W, BG_H, shelf, LAVA_ROCK_NEAR + (255,), 0x66))
    for _ in range(34):                       # cracks glowing along the shelf
        x = rnd.randrange(BG_W - sh(12))
        y = shelf[x] + rnd.randrange(0, sv(16))
        for k in range(rnd.randrange(3, sh(10))):
            px[min(BG_W - 1, x + k), y] = LAVA_GLOW + (255,)
    for y in range(LAVA_HORIZON + sv(14), BG_H, sv(26)):
        # slow lava currents: long hot streaks instead of a stipple
        off = rnd.randrange(BG_W)
        col = LAVA_LAKE[min(len(LAVA_LAKE) - 1, 2 + (y - LAVA_HORIZON) // sv(70))]
        for k in range(rnd.randrange(sh(90), sh(260))):
            px[(off + k) % BG_W, y] = col + (255,)
    for _ in range(26):                       # drifting embers
        px[rnd.randrange(BG_W), rnd.randrange(sv(300), BG_H)] = LAVA_GLOW + (255,)
    return bg


# --------------------------------------------------------------------------
# stage 3: dream reflection
# --------------------------------------------------------------------------
DREAM_SKY = [(18, 9, 42), (28, 13, 58), (40, 19, 76), (54, 26, 94),
             (72, 34, 112), (92, 44, 128), (114, 56, 142), (138, 72, 152),
             (162, 92, 162), (186, 114, 174), (210, 140, 190), (230, 172, 208)]
DREAM_MIRROR = [(96, 48, 116), (82, 40, 102), (68, 33, 88),
                (56, 27, 74), (46, 22, 62), (38, 18, 52),
                (30, 14, 42)]
DREAM_TRUNK = (26, 12, 40)
DREAM_CANOPY = (52, 24, 78)
DREAM_CANOPY2 = (74, 38, 104)
DREAM_MOON = (250, 244, 255)
DREAM_STAR = (232, 240, 255)
DREAM_HORIZON = sv(318)


def build_dream():
    """Twilight over a mirrored garden; the fairy-tale pack is the tree line."""
    bg = Image.new('RGBA', (BG_W, BG_H), (0, 0, 0, 255))
    bg.paste(bands(DREAM_SKY, 0, DREAM_HORIZON), (0, 0))
    bg.paste(bands(DREAM_MIRROR, DREAM_HORIZON, BG_H), (0, DREAM_HORIZON))

    import random
    rnd = random.Random(0xD3EA)
    px = bg.load()
    for _ in range(150):                      # sky field, clear of the HUD band
        px[rnd.randrange(BG_W), rnd.randrange(sv(30), sv(240))] = DREAM_STAR + (255,)
    dr_r = sv(32)
    for y in range(sv(40), sv(136)):          # moon disc
        for x in range(sh(382), sh(478)):
            dx, dy = x - sh(430), y - sv(88)
            if dx * dx + dy * dy < dr_r * dr_r:
                px[x, y] = DREAM_MOON + (255,)

    # ground the tree line just above the horizon, dither-blended so its own
    # colours survive into the palette
    # A broadleaf line instead of the painted fairy-tale layers: the painting
    # carries thousands of edge tones that cost 18 kB of RLE, while these
    # spans cost a tenth of that and read far more clearly behind bullets.
    # The tree line was the single most expensive element in the whole bank:
    # 30 broadleaves at the old pitch, ~180 runs each.  19 slightly smaller
    # ones cost a third of that and still close the horizon off.
    for tx in range(sh(22), BG_W - sh(26), sh(74)):
        broadleaf(px, tx, DREAM_HORIZON - sv(4), sv(56) + rnd.randrange(0, sv(16)),
                  rnd.randrange(sv(14), sv(22)), DREAM_TRUNK, DREAM_CANOPY,
                  DREAM_CANOPY2, 0xD3EA + tx)

    for y in range(DREAM_HORIZON + sv(10), BG_H, sv(22)):
        off = rnd.randrange(BG_W)             # mirror shimmer bands
        col = DREAM_MIRROR[min(len(DREAM_MIRROR) - 1, (y - DREAM_HORIZON) // sv(44))]
        for k in range(rnd.randrange(sh(50), sh(170))):
            px[(off + k) % BG_W, y] = col + (255,)
    for _ in range(28):                       # stray petals on the floor
        px[rnd.randrange(BG_W), rnd.randrange(DREAM_HORIZON, BG_H)] = DREAM_STAR + (255,)
    return bg


# --------------------------------------------------------------------------# --------------------------------------------------------------------------
# parallax strips: 32 x SB_BG_H, tiling horizontally with period 32
# --------------------------------------------------------------------------
def build_strip(name, rows, seed, density, palette, width=1):
    """A magenta-keyed speckle strip, 32 wide and tiling with period 32.

    The scanout copy is an opaque colour-key blit, so every pixel here is
    either fully drawn or fully transparent magenta - a half transparent
    colour would simply paint the plank colour over the backdrop.
    """
    import random
    rnd = random.Random(seed)
    im = Image.new('RGBA', (STRIP_PERIOD, BG_H), (255, 0, 255, 255))
    px = im.load()
    cols = [(r, g, b, 255) for r, g, b in palette]
    for _ in range(density):
        y = rnd.randrange(rows[0], rows[1])
        x = rnd.randrange(STRIP_PERIOD)
        w = 1 + rnd.randrange(width)
        h = 1 + rnd.randrange(2)
        col = cols[rnd.randrange(len(cols))]
        for dy in range(h):
            for dx in range(w):
                if rows[0] <= y + dy < rows[1]:
                    px[(x + dx) % STRIP_PERIOD, y + dy] = col
    return im


# --------------------------------------------------------------------------
# packed encoding
# --------------------------------------------------------------------------
def unique_colours(images):
    cols = [KEY]
    for im in images:
        seen = set()
        for color, a in zip(im.convert('RGB').getdata(), im.getchannel('A').getdata()):
            v = KEY if a < 128 else (color[0] << 16) | (color[1] << 8) | color[2]
            if v not in seen:
                seen.add(v)
                if v not in cols:
                    cols.append(v)
    return cols


def remap(im, cols):
    lut = []
    table = {}
    for i, c in enumerate(cols):
        table[c] = i
    alpha = im.getchannel('A')
    rgb = im.convert('RGB')
    for color, a in zip(rgb.getdata(), alpha.getdata()):
        v = KEY if a < 128 else (color[0] << 16) | (color[1] << 8) | color[2]
        lut.append(table.get(v, 0))
    return lut


def index4(im, cols):
    """(colour list, index stream) with the indices packed into four bits.

    unique_colours() puts the colour key first and appends in order of first
    appearance, so a fully opaque plate comes back as seventeen entries with
    the key unused and its real colours one place too high for the four-bit
    field.  Renumber the colours that actually occur; the picture, and the
    order the palette is emitted in, are untouched.
    """
    idx = remap(im, cols)
    used = sorted(set(idx))
    assert len(used) <= 16, 'four bits hold 16 colours, this plate uses %d' % len(used)
    back = {u: k for k, u in enumerate(used)}
    return [cols[u] for u in used], [back[v] for v in idx]


def rle(indices):
    """Pack a colour-index stream into the firmware's run format.

    A tag byte is (length-1) in the top 4 bits plus a 4-bit colour index.  The
    all-ones length field escapes to a one-byte count, and a zero count there
    escapes again to a 16-bit one, so a run costs one byte up to 15 pixels, two
    up to 255, and four beyond that.

    Five bits of colour and three of length was the old split.  Against the
    real plates that was backwards: they use sixteen colours and most of their
    runs are long, so two thirds of the stream paid the three-byte escape to
    buy a colour bit no pixel ever set.  Swapping the two fields takes the
    three plates from 15796 bytes to 11937 with no pixel changed.
    """
    runs = []
    for i in indices:
        if runs and (runs[-1] & 15) == i and (runs[-1] >> 4) < 65535:
            runs[-1] += 16
        else:
            runs.append(16 | i)
    out = bytearray()
    for run in runs:
        n, c = run >> 4, run & 15
        if n <= 15:
            out.append(((n - 1) << 4) | c)
        elif n <= 255:
            out += bytes([0xF0 | c, n])
        else:
            out += bytes([0xF0 | c, 0, n & 255, n >> 8])
    return out


# The two 4-pixel accent columns that separate the playfield from the HUD
# gutters.  main.c used to FILL them onto the frame every single frame -- two
# 4x768 commands, i.e. 1536 of the ~5100 DRAM rows a frame activated, to move
# 24 KB of pixels.  That is the worst row-per-byte ratio in the whole build and
# it was ~30% of the frame's row budget, for pure decoration.
#
# The columns never move and the stage plate is already the surface the damage
# restorer brings back, so they belong IN the plate: the firmware then draws
# nothing at all and the restorer puts them back for free.  One entry per
# stage, in the same order (and the same colours) as main.c's `accent`.
BORDER_ACCENT = [(0x30, 0x70, 0xD0), (0xD0, 0x50, 0x30), (0x90, 0x60, 0xC0)]


def borders(im, rgb):
    """Stamp the two playfield border columns into a plate."""
    px = im.load()
    col = tuple(rgb) + (255,)
    xs = list(range(GAME_LEFT - 4, GAME_LEFT)) + \
         list(range(GAME_RIGHT, GAME_RIGHT + 4))
    for x in xs:
        for y in range(BG_H):
            px[x, y] = col


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    bgs = [('stage_ice', build_ice(), 16),
           ('stage_lava', build_lava(), 16),
           ('stage_dream', build_dream(), 16)]
    # NOTE: the playfield border columns are deliberately NOT stamped into the
    # plate.  They were, briefly: a vertical 4-pixel line cuts every horizontal
    # run it crosses, and this stream is RLE-coded per row, so two of them took
    # the bank from 12,313 B to 32,149 B - straight through the 16,384-byte
    # asset ROM.  main.c draws them once per (buffer, plate) pair instead and
    # keeps them alive by keeping the gutter repaints and the damage restorer
    # off their columns.
    previews = {}
    strips = [
        # One drifting layer is enough: each strip costs its own RLE stream and
        # 20 scanout blits a frame, and the stages already carry their own
        # static scenery.  Magenta plus a flat colour pair is all a strip
        # contains, so no palette is emitted for it.
        ('snow', 30, build_strip('snow', (30, STRIP_H), 0x54, 218,
                                 [(238, 248, 255), (206, 228, 255)])),
    ]
    # Every backdrop carries its own palette.  Sharing one across all three
    # forced them all onto the union of their colours: the ice stage came out
    # mauve, and every asset paid 4 bytes for every colour in the union.
    assets = []
    for name, im, limit in bgs:
        im = palette(im, limit)
        cols, idx = index4(im, unique_colours([im]))
        blob = rle(idx)
        runs = 1
        for k in range(1, len(idx)):
            if idx[k] != idx[k - 1]:
                runs += 1
        im.save(OUT / (name + '.png'))
        assets.append((name, cols, blob, BG_W, BG_H, 0, BG_H))
        print('%-14s %dx%d cols=%2d runs=%-6d encoded=%5d bytes' %
              (name, BG_W, BG_H, len(cols), runs, 4 * len(cols) + len(blob)))

    for name, y0, im in strips:
        # The strip's PIXELS are not the ones on screen, and no firmware
        # function redraws them: rtl/v_dma/video_weather.v regenerates a
        # 170-dot scatter from its own LFSR in hardware, and what this script
        # draws is a 218-dot preview with Python's random.Random(0x54).  Two
        # different generators, two different counts - the file below is for
        # looking at, the weather layer is what the player sees.  Only the
        # geometry (which rows, which width) is shared, in the table entry.
        px = im.load()
        rows = [y for y in range(BG_H)
                if any(px[x, y] != (255, 0, 255, 255) for x in range(STRIP_PERIOD))]
        assert rows, 'strip %s is empty' % name
        assets.append((name, [0x00FF00FF], b'\x00',
                       STRIP_PERIOD, BG_H, rows[0], rows[-1] + 1))
        preview = Image.new('RGB', (STRIP_PERIOD * 4, BG_H), (24, 24, 40))
        for i in range(4):
            preview.paste(im.convert('RGB'), (i * STRIP_PERIOD, 0))
        previews[name] = preview
        print('%-14s %dx%d PREVIEW ONLY (screen is rtl/v_dma/video_weather.v,'
              ' 170 dots) rows=%d..%d' %
              (name, STRIP_PERIOD, BG_H, rows[0], rows[-1]))

    # Stamped on the review copies, because the speckles in them are NOT the
    # speckles on screen: rtl/v_dma/video_weather.v regenerates a 170-dot
    # scatter in hardware from its own LFSR.  Anyone tuning density or colour
    # here is tuning a picture no player sees.  Drawn after the loop, so the
    # ImageDraw object cannot perturb the random sequence that places dots.
    for name, preview in sorted(previews.items()):
        d = ImageDraw.Draw(preview)
        d.rectangle([0, 0, STRIP_PERIOD * 4 - 1, 9], fill=(120, 0, 0))
        d.text((2, 1), 'PREVIEW ONLY - screen is video_weather.v', fill=(255, 220, 220))
        preview.save(OUT / (name + '.png'))

    offs, total = write_rom(assets)
    write_header(assets, offs, total)
    write_body(assets, offs)
    encoded = sum(4 * len(a[1]) + len(a[2]) for a in assets)
    print('stage bank: %d assets, %d encoded bytes (asset ROM %d B)' %
          (len(assets), encoded, total))
    return 0


def write_rom(assets):
    """Emit the three plate RLE streams as the bitstream's asset ROM.

    They used to sit in .rodata, which is the CPU's own 64 KiB: 12,313 B of a
    region that had 80 B free.  The plate data has to live in something that
    survives power-off, and the only such thing the CPU can reach on this board
    is the bitstream itself - so it becomes a BRAM initialised from this hex
    file and read back through the BitBlt APB window at boot (see
    rtl/bitblt/bitblt_asset_rom.v).  MM_STAGE_RLE in DDR is only a staging
    buffer for the copy.

    One hex byte per line: $readmemh fills one array element per line, so a
    packed line would load a 32-bit value into an 8-bit element.
    """
    plates = [(n, blob) for (n, cols, blob, w, h, s, strip) in assets
              if n.startswith('stage_')]
    offs, cur = {}, 0
    for n, blob in plates:
        offs[n] = cur
        cur += len(blob)
    data = bytearray()
    for n, blob in plates:
        data.extend(blob)

    # THE LIMIT IS THE ROM'S DEPTH, and nothing compared the two until now: the
    # writer took whatever it was handed.  It has been over the line before -
    # two 4-pixel border lines stamped into the plates cut every horizontal run
    # and took this bank from 12,313 B to 32,149 B, straight through a 16,384
    # byte BRAM.  stage_bg.h would still have published offsets and lengths that
    # ran past the end, and stage_bg_boot() would have copied ROM garbage (or
    # whatever the fabric was holding) into MM_STAGE_RLE for the third plate.
    rom_v = ROOT / 'rtl' / 'bitblt' / 'bitblt_asset_rom.v'
    m = re.search(r'parameter\s+integer\s+ADDR_WIDTH\s*=\s*(\d+)',
                  rom_v.read_text(encoding='utf-8'))
    if not m:
        raise SystemExit('bitblt_asset_rom.v has no ADDR_WIDTH: the ROM this '
                         'bank is written into cannot be sized')
    rom_bytes = 1 << int(m.group(1))
    print('asset ROM      %d bytes written, %d available' % (len(data), rom_bytes))
    if len(data) > rom_bytes:
        raise SystemExit(
            'STAGE RLE OVERFLOWS THE ASSET ROM: %d bytes written, %d fit '
            '(bitblt_asset_rom.v ADDR_WIDTH=%s). The plate only fits if it '
            'codes for fewer bytes - flat bands instead of gradients, fewer '
            'colours, or a chunkier decoration.'
            % (len(data), rom_bytes, m.group(1)))

    rom = ROOT / 'rtl' / 'bitblt' / 'bg_rle.hex'
    rom.parent.mkdir(parents=True, exist_ok=True)
    rom.write_text('\n'.join('%02x' % b for b in data) + '\n',
                   encoding='ascii', newline='\n')
    path_vh = ROOT / 'rtl' / 'bitblt' / 'bg_rle_path.vh'
    path_vh.write_text(
        '// Generated by tools/build_stage_backgrounds.py - do not edit.\n'
        '// Absolute on purpose: Efinity resolves a bare $readmemh filename against\n'
        '// a base it does not document, whereas the SoC IP generator uses absolute\n'
        '// paths for its own $readmemb calls.  That is the one form this project\n'
        '// has seen work, and the tool that writes the data writes the path.\n'
        '`define BG_ROM_INIT_FILE "%s"\n' % rom.as_posix(),
        encoding='ascii', newline='\n')
    print('asset ROM      %d bytes -> %s' % (len(data), rom.relative_to(ROOT)))
    return offs, len(data)


def c_array(name, values, per_line=24, fmt='%d'):
    lines = []
    for i in range(0, len(values), per_line):
        lines.append(','.join(fmt % v for v in values[i:i + per_line]) + ',')
    return 'static const uint8_t %s[] = {\n%s\n};\n' % (name, '\n'.join(lines))


def write_header(assets, offs, total):
    h = ['/* Generated by tools/build_stage_backgrounds.py; sources in assets/SOURCES.md. */',
         '#ifndef STAGE_BG_H',
         '#define STAGE_BG_H',
         '#include <stdint.h>',
         '',
         'typedef struct {',
         '    const uint32_t *palette;',
         '    const uint8_t  *rle;',
         '    uint16_t w, h;',
         '    uint16_t y0, y1;      /* rows that actually carry pixels */',
         '} stage_asset_t;',
         '']
    for i, (name, _cols, _blob, _w, _h, _scale, _strip) in enumerate(assets):
        h.append('#define SB_%s %d' % (name.upper(), i))
    h += (['#define SB_COUNT %d' % len(assets),
          '',
          '/* The plate IS the screen, 1:1.  BitBlt has no scaler, so a half-size',
          ' * plate could only ever cover half the display - and a 640x600 plate',
          ' * stretched to 1366x768 would need 2.13x horizontally against 1.28x',
          ' * vertically, which turns every round bullet into an ellipse. */',
          '#define SB_BG_W %d' % BG_W,
          '#define SB_BG_H %d' % BG_H,
          '#define SB_STRIP_PERIOD %d' % STRIP_PERIOD,
          '/* The weather tile is SB_STRIP_PERIOD COLUMNS wide, so its row pitch is',
          ' * SB_STRIP_PERIOD*4 bytes and not the framebuffer stride.  Laid out at',
          ' * SCREEN_STRIDE it would claim 6 MiB of DDR for 96 KiB of data. */',
          '#define SB_STRIP_STRIDE (SB_STRIP_PERIOD * 4)',
          '#define SB_STRIP_BYTES  (SB_STRIP_STRIDE * SB_BG_H)',
          '',
          '/* The three backdrops occupy stage_assets[0..2]; the parallax strip is',
          " * the last entry.  Its PIXELS are not stored: the firmware's",
          " * snow_build() redraws the same speckle scatter at boot, so only",
          ' * its geometry survives, in the table entry below. */',
          '#define SB_STAGE_COUNT 3',
          '',
          '/* Where each plate RLE stream sits inside the bitstream asset ROM',
          ' * (rtl/bitblt/bg_rle.hex) and how large that ROM is.  stage_bg_boot()',
          ' * copies the whole ROM to MM_STAGE_RLE and points stage_rle[] at the',
          ' * per-plate offsets inside that DDR copy. */',
          '#define SB_RLE_TOTAL %d' % total,
          '#define SB_RLE_ROM_BYTES %d' % total] +
          ['#define SB_RLE_OFF_%s %d' % (n.upper(), offs[n]) for n in sorted(offs)] +
          ['#define SB_RLE_LEN_%s %d' % (n.upper(), len(b))
           for n, b in [(a[0], a[2]) for a in assets if a[0] in offs]] +
          ['',
           'extern const stage_asset_t stage_assets[SB_COUNT];',
           'extern const uint8_t *stage_rle[SB_COUNT];',
           'void stress_bg_build(void);',
           '',
           '#endif /* STAGE_BG_H */',
           ''])
    (ROOT / 'sw' / 'app' / 'stage_bg.h').write_text('\n'.join(h), encoding='ascii', newline='\n')


def write_body(assets, offs):
    body = ['/* Generated by tools/build_stage_backgrounds.py; sources in assets/SOURCES.md. */',
            '#include "stage_bg.h"',
            '']
    for name, cols, blob, _w, _h, _scale, _strip in assets:
        body.append('static const uint32_t pal_%s[] = {%s};' %
                    (name, ','.join('0x%08Xu' % c for c in cols)))
        # A plate's RLE stream is in the asset ROM, not here; only the strip,
        # which has no pixels of its own, still carries its one-byte placeholder.
        if name not in offs:
            body.append(c_array('rle_' + name, list(blob), 24))
    body.append('const stage_asset_t stage_assets[SB_COUNT] = {')
    for name, cols, blob, w, h, scale, strip in assets:
        if name in offs:
            body.append('{pal_%s, 0, %du, %du, %du, %du},   /* RLE is in the asset ROM */'
                        % (name, w, h, scale, strip))
        else:
            body.append('{pal_%s, rle_%s, %du, %du, %du, %du},' % (name, name, w, h, scale, strip))
    body += ['};',
             '',
             '/* Pointed at the DDR staging copy by stage_bg_boot(), once the asset',
             ' * ROM has been read back over APB.  A plate whose stream was never',
             ' * uploaded keeps a NULL here, so a missed upload decodes nothing',
             ' * instead of walking off the end of a stale pointer. */',
             'const uint8_t *stage_rle[SB_COUNT];',
             '',
             '#include "memory_map.h"',
             '#include "gpu2d.h"',
             '',
             'void stress_bg_build(void)',
             '{',
             '    static const uint32_t sky_bands[20] = {',
             '        0x00020510u, 0x00030718u, 0x00040A22u, 0x00060E2Eu,',
             '        0x0008133Au, 0x000B1948u, 0x000F2056u, 0x00142764u,',
             '        0x001A2D70u, 0x0022327Au, 0x002C3580u, 0x00363582u,',
             '        0x0040337Eu, 0x004A2F76u, 0x0054296Au, 0x005C235Cu,',
             '        0x00621E4Eu, 0x00641A40u, 0x00601634u, 0x0056122Au',
             '    };',
             '    static const int16_t bg_peaks[17] = {',
             '        260, 210, 175, 230, 195, 275, 330, 375, 375, 340, 275, 205, 170, 215, 185, 245, 260',
             '    };',
             '    static const int16_t fg_peaks[17] = {',
             '        430, 390, 340, 300, 335, 380, 435, 470, 470, 435, 380, 335, 300, 340, 390, 430, 450',
             '    };',
             '',
             '    volatile uint32_t *row = (volatile uint32_t *)MM_STRESS_BG;',
             '',
             '    for (unsigned y = 0; y < SB_BG_H; y++) {',
             '        unsigned b_idx = (y * 20u) / 460u;',
             '        if (b_idx >= 20u) b_idx = 19u;',
             '        uint32_t sky_c = sky_bands[b_idx];',
             '        uint32_t sr = (sky_c >> 16) & 0xFFu;',
             '        uint32_t sg = (sky_c >> 8) & 0xFFu;',
             '        uint32_t sb = sky_c & 0xFFu;',
             '        int dy_caldera = (int)y - 470;',
             '        int dy_cr = (int)y - 580;',
             '',
             '        for (unsigned x = 0; x < SB_BG_W; x++) {',
             '            uint32_t r = sr, g = sg, b = sb;',
             '',
             '            if (y < 280u) {',
             '                uint32_t h = (x * 1664525u + y * 1013904223u) ^ 0x20261011u;',
             '                h ^= h >> 16;',
             '                if ((h & 0x7FFu) == 0x123u) {',
             '                    r = 255u; g = 255u; b = 255u;',
             '                } else if ((h & 0x7FFu) == 0x456u) {',
             '                    r = 160u; g = 208u; b = 255u;',
             '                }',
             '            }',
             '',
             '            int dx_c = (int)x - 683;',
             '            if (dx_c < 0) dx_c = -dx_c;',
             '            int dist_sq = dx_c * dx_c + dy_caldera * dy_caldera * 3;',
             '            if (dist_sq < 260 * 260) {',
             '                int glow = (260 * 260 - dist_sq) / 450;',
             '                if (glow > 90) glow = 90;',
             '                r += (uint32_t)glow;',
             '                g += (uint32_t)(glow / 4);',
             '                if (b > (uint32_t)(glow / 3)) b -= (uint32_t)(glow / 3);',
             '                else b = 0;',
             '                if (r > 255u) r = 255u;',
             '                if (g > 255u) g = 255u;',
             '            }',
             '',
             '            unsigned seg_bg = (x * 16u) / SB_BG_W;',
             '            if (seg_bg >= 16u) seg_bg = 15u;',
             '            unsigned rem_bg = (x * 16u) - seg_bg * SB_BG_W;',
             '            int base_bg = bg_peaks[seg_bg] + ((bg_peaks[seg_bg + 1u] - bg_peaks[seg_bg]) * (int)rem_bg) / (int)SB_BG_W;',
             '            int noise_bg = (int)((x * 37u + 13u) & 15u) - 7;',
             '            int by = base_bg + noise_bg;',
             '',
             '            if ((int)y >= by) {',
             '                int dy = (int)y - by;',
             '                if (dy < 36) {',
             '                    int shade = (36 - dy) * 3;',
             '                    r = 195u + (uint32_t)shade;',
             '                    g = 220u + (uint32_t)shade;',
             '                    b = 248u + (uint32_t)(shade / 2);',
             '                    if (((x ^ (y >> 1)) & 3u) == 0u) {',
             '                        r = (r > 30u) ? r - 30u : 0u;',
             '                        g = (g > 25u) ? g - 25u : 0u;',
             '                        b = (b > 15u) ? b - 15u : 0u;',
             '                    }',
             '                    if (r > 255u) r = 255u;',
             '                    if (g > 255u) g = 255u;',
             '                    if (b > 255u) b = 255u;',
             '                } else {',
             '                    int dep = (dy - 36 < 50) ? (dy - 36) : 50;',
             '                    r = 24u + (uint32_t)(dep / 4);',
             '                    g = 38u + (uint32_t)(dep / 3);',
             '                    b = 62u + (uint32_t)(dep / 2);',
             '                }',
             '            }',
             '',
             '            unsigned seg_fg = (x * 16u) / SB_BG_W;',
             '            if (seg_fg >= 16u) seg_fg = 15u;',
             '            unsigned rem_fg = (x * 16u) - seg_fg * SB_BG_W;',
             '            int base_fg = fg_peaks[seg_fg] + ((fg_peaks[seg_fg + 1u] - fg_peaks[seg_fg]) * (int)rem_fg) / (int)SB_BG_W;',
             '            int noise_fg = (int)((x * 53u + 19u) & 15u) - 7;',
             '            int fy = base_fg + noise_fg;',
             '',
             '            if ((int)y >= fy) {',
             '                int dy = (int)y - fy;',
             '                /* The caldera used to be a WINDOW: every pixel inside',
             '                 * x 430..936 with y >= 440 took the magma palette, so the',
             '                 * rock face carried a hard-edged rectangle of it - two',
             '                 * vertical seams and one horizontal, dead straight, on a',
             '                 * slope that is otherwise all curves.  On the board it',
             '                 * reads as a rendering fault rather than as rock.',
             '                 *',
             '                 * The region is now the very ellipse the lava rings are',
             '                 * drawn from, so the shape of the area matches the shape',
             '                 * of the thing in it.  Its outermost ring is a dark',
             '                 * basalt whose channels (28,14,16) sit within a few',
             '                 * levels of the wall the branch below paints at the same',
             '                 * place - 24+dx_c/20, 16+dx_c/35, 22+dx_c/25 - so the',
             '                 * seam that was a straight line becomes a soft curve in',
             '                 * near-identical tones, and stops reading as an edge. */',
             '                int dx_cr = (int)x - 683;',
             '                int d_magma_sq = dx_cr * dx_cr + dy_cr * dy_cr * 4;',
             '',
             '                if (d_magma_sq < 200 * 200) {',
             '                    if (d_magma_sq < 55 * 55) {',
             '                        r = 255u; g = 246u; b = 190u;',
             '                    } else if (d_magma_sq < 90 * 90) {',
             '                        r = 255u; g = 160u; b = 24u;',
             '                    } else if (d_magma_sq < 135 * 135) {',
             '                        r = 210u; g = 40u; b = 10u;',
             '                    } else if (d_magma_sq < 170 * 170) {',
             '                        r = 90u; g = 18u; b = 12u;',
             '                    } else {',
             '                        r = 28u; g = 14u; b = 16u;',
             '                    }',
             '',
             '                    if ((((x >> 3) ^ (y >> 2)) % 7u == 0u) &&',
             '                        (d_magma_sq > 45 * 45) && (d_magma_sq < 160 * 160)) {',
             '                        r = 38u; g = 12u; b = 14u;',
             '                    }',
             '',
             '                    if ((x * 5u + y * 11u) % 89u < 3u) {',
             '                        r = 255u; g = 120u; b = 20u;',
             '                    }',
             '                } else {',
             '                    if (dy < 30 && y < 350u) {',
             '                        int shade = (30 - dy) * 4;',
             '                        r = 185u + (uint32_t)shade;',
             '                        g = 210u + (uint32_t)shade;',
             '                        b = 242u + (uint32_t)(shade / 2);',
             '                        if (r > 255u) r = 255u;',
             '                        if (g > 255u) g = 255u;',
             '                        if (b > 255u) b = 255u;',
             '                    } else {',
             '                        int off_x = (dx_c / 20 < 40) ? dx_c / 20 : 40;',
             '                        int off_gx = (dx_c / 35 < 20) ? dx_c / 35 : 20;',
             '                        int off_bx = (dx_c / 25 < 30) ? dx_c / 25 : 30;',
             '                        r = 24u + (uint32_t)off_x;',
             '                        g = 16u + (uint32_t)off_gx;',
             '                        b = 22u + (uint32_t)off_bx;',
             '',
             '                        if (y >= 460u && dx_c < 420 && ((x * 7u + y * 13u) % 113u < 3u)) {',
             '                            r = 245u; g = 75u; b = 15u;',
             '                        }',
             '                    }',
             '                }',
             '            }',
             '',
             '            row[x] = (r << 16) | (g << 8) | b;',
             '        }',
             '        row += SCREEN_STRIDE / 4u;',
             '    }',
             '',
             '    gpu2d_flush_dcache();',
             '}',
             '']
    (ROOT / 'sw' / 'app' / 'stage_bg.c').write_text('\n'.join(body), encoding='ascii', newline='\n')


if __name__ == '__main__':
    sys.exit(main())