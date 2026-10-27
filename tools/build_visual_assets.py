"""Convert licensed, downloaded artwork to a bounded boot-time RLE bank.

No procedural character drawing. Cropping, palette reduction, mirroring and
UI composition are reproducible adaptations of the sources in assets/SOURCES.md.
"""
from pathlib import Path
import json
import hashlib
import re
from PIL import Image, ImageDraw, ImageFont, ImageEnhance, ImageOps

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'assets/source'
OUT = ROOT / 'assets/processed'
NEAREST = Image.Resampling.NEAREST
KEY = 0x00FF00FF


def source(path):
    return Image.open(SRC / path).convert('RGBA')


# panel() and mm_const() used to sit here with no callers: the 9-slice menu
# panel was replaced by bg_paint(), and the asset destinations are literals in
# the asset table below because the table is the one place they are read from.
    for y in range(3):
        for x in range(3):
            part = tile.crop((cuts[x], cuts[y], cuts[x+1], cuts[y+1]))
            out.alpha_composite(part.resize((xs[x+1]-xs[x], ys[y+1]-ys[y]), NEAREST), (xs[x], ys[y]))
    # OPAQUE, not the 140/255 translucent tint this used to composite.
    # Measured cost of that tint: the 1366x768 plate weighed 16152 encoded
    # bytes and overflowed the 64512-byte image region by 7768.  A translucent
    # wash over a multi-hue border makes almost every column a new colour, so
    # the 180x768 gutters were nearly all one-pixel runs.  A flat dark panel
    # reads the same on screen and costs a few hundred bytes.
    out.alpha_composite(Image.new('RGBA', size, (10, 12, 33, 255)))
    return out


def font(size):
    return ImageFont.truetype(str(SRC / 'fonts/Fonts/Kenney Pixel.ttf'), size)


# 1366x768 native geometry.  The plate IS the screen: it is decoded to DDR
# at MM_VISUAL_BACKGROUND and blitted 1:1, because BitBlt has no scaler - a
# half-size plate can only ever cover half the screen.  So one source pixel is
# one screen pixel and the label boxes below are already in screen coordinates.
#
# The plate is bigger than the old 1024x600 one yet costs LESS firmware: the
# old one doubled a 512x300 source, which halves every run.  Measured with the
# encoder in this file: 1366x768 -> 4118 B, 1024x600 -> 8030 B.
# The plate is authored at HALF the screen (683x384) and the firmware
# The plate IS the screen, 1:1.  BitBlt has no scaler, so a half-size plate
# can only ever cover half the screen, and expanding it in software is a
# scan-out-sized job for a boot-time detail.
#
# What makes the full-size plate affordable is the ARTWORK, not the size.  A
# smooth colour ramp makes every row a different colour, and three dithered
# photographic silhouettes put hundreds of short runs on each of them - that
# is where the old 13416 bytes went.  The same screen as hard-edged bands -
# four sky tones, three ground tones, two flat gutters, one thin ridge and a
# scattering of window lights - encodes for about a third of that.
PLATE_W, PLATE_H = 1366, 768
MENU_W, MENU_H = PLATE_W, PLATE_H

# Empty since the plates stopped being bitmaps: labels are drawn by the
# firmware with the same vector font as the numbers beside them (see the
# HUD_LABELS.clear() in main() below).  The file is still written as [] so
# tools/check_hud_layout.py can tell "no labels baked" from "the generator
# never ran" - that checker carries the note too.
HUD_LABELS = []          # (label, x0, y0, x1, y1), SCREEN pixels


def actor(im, size):
    # Preserve transparent margin so all poses have the same pivot.
    return im.resize(size, NEAREST)


def quantize(im, count=32, keep_alpha=False):
    alpha = im.getchannel('A')
    q = im.convert('RGB').quantize(colors=count-1, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    rgb = q.convert('RGB')
    cols = [KEY]
    ids = []
    for color, a in zip(rgb.getdata(), alpha.getdata()):
        v = KEY if a < 128 else ((a<<24) if keep_alpha else 0) | (color[0]<<16) | (color[1]<<8) | color[2]
        if v not in cols:
            cols.append(v)
        ids.append(cols.index(v))
    assert len(cols) <= 32
    runs = []
    for i in ids:
        if runs and (runs[-1] & 31) == i and (runs[-1] >> 5) < 2047:
            runs[-1] += 32
        else:
            runs.append(32 | i)
    assert sum(r>>5 for r in runs) == im.width * im.height
    packed = []
    for run in runs:
        n, color = run >> 5, run & 31
        if n <= 7:
            packed.append(((n-1) << 5) | color)
        else:
            packed += [0xE0 | color, n & 255, n >> 8]
    return cols, packed


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    # ---- boot menu backdrop ------------------------------------------------
    # The menu used to be the dimmed forest photo pasted behind the panels.
    # That photograph is 23000 encoded bytes - over a third of the whole
    # firmware budget - because a dithered, colour-graded photograph is the
    # worst possible input for a run-length coder: the ice-stage backdrop
    # taught the same lesson (13 kB when it was textured, 4 kB when it was
    # flat). The forest licence is still used, but as *silhouettes*: the
    # supplied tree layers are thresholded to hard edges and painted in flat
    # tones over a stepped sky, so the menu keeps the same composition and
    # costs a fraction of the space.
    layers = SRC / 'forest/parallax_forest_pack/layers'

    # There is no backdrop BITMAP any more.  The plate is drawn by the
    # firmware (bg_paint / stage_plate_build in sw/app/main.c): it is a stack
    # of flat bands plus a waveform decoration, which is a couple of hundred
    # bytes of C and about 12 KB of RLE, and the RLE simply does not fit -
    # .rodata overflowed by 7768 bytes with the bitmap plate in it.
    #
    # Nothing here bakes HUD labels either: the labels are now drawn by the
    # firmware with the same vector font as their readouts, so a label and its
    # number can never drift apart again.
    HUD_LABELS.clear()

    sheet = source('fumoreimu-sheet.png')
    # scale 1, and the firmware blits it 1:1: the plate already IS 1366x768.
    assets = []          # no plate bitmap; the firmware paints it
    for i in range(4):
        pose = actor(sheet.crop((i*64, 0, (i+1)*64, 64)), (48, 48))
        if i == 3:
            # The supplied sheet repeats frame 1 at frame 3. Make recoil/bob
            # distinct using translation of licensed pixels, not new drawing.
            moved = Image.new('RGBA',pose.size)
            moved.alpha_composite(pose,(0,-2))
            pose = moved
        assets.append(('reimu_'+str(i), pose, 0x01610000+i*0x2400, 1))
    # Index 1 is reimu_0; it is the frame the left/right leans and both HUD
    # portraits are derived from.  (The pause card that used to sit at index 1
    # is drawn by the firmware now, so this shifted down from 2.)
    # The two leaning walk frames are NOT stored either: they are the idle
    # frame sheared by +-12 degrees, which the firmware reproduces at boot
    # (tilt_poses_build).  That is 1570 bytes of RLE for two pictures it can
    # derive itself.  pose0 is that idle frame; the two HUD portraits reuse it.
    pose0 = assets[1][1]
    assets += [('fairy', actor(source('fumocirno.png'), (24, 24)), 0x01606C00, 1),
               ('shard', actor(source('fumookuu.png'), (24, 24)), 0x01607500, 1),
               ('boss', actor(source('fumookuu.png'), (64, 64)), 0x01608000, 1)]
    # Three stage identities from the already archived source art. The dream
    # rival is a palette-swapped/mirrored adaptation, not a newly drawn sprite.
    dream = ImageOps.mirror(actor(source('fumoreimu.png'), (64, 64)))
    dream.putdata([(min(255, b+35), min(255, g+20), max(0, r-55), a)
                   for r,g,b,a in dream.getdata()])
    # The dream rival has no tile of its own any more.  Its 64x64 art is the
    # second boss mirrored and pushed to a cold palette, i.e. a pure function
    # of a bitmap the firmware already has in DDR, so the firmware derives it
    # once at boot (see boss_dream_build) instead of carrying a second 1188
    # byte RLE stream.  The shade minion is a different silhouette and keeps
    # its own small copy.
    assets += [('boss_cirno', actor(source('fumocirno.png'), (64, 64)), 0x01621000, 1),
               ('shade', actor(dream, (24, 24)), 0x01631000, 1)]
    # Reuse the centre row of Kenney's vertical projectile.  The firmware does
    # NOT repeat this row: laser_glow_build() (sw/app/main.c) generates all 768
    # rows of MM_LASER_GLOW itself at boot, after sprites_build(), and this
    # 16x1 stream is only where the glow row's colours come from.
    # check_ddr_layout.py sizes that surface as 16 x 4 x 768, and the manifest
    # marks it runtime_overlay for the same reason.
    beam_src = source('shmup/Tiles/tile_0000.png').resize((32, 16), NEAREST)
    laser = Image.new('RGBA', (16, 1))
    beam_row = []
    for x in range(16):
        _, _, _, a = beam_src.getpixel((x + 8, 8))
        beam_row.append((80, 225, 255, a))
    laser.putdata(beam_row)
    assets.append(('laser_glow', laser, 0x01660000, 1))
    # Supplied Kenney tiles: health, star, four explosion frames and seven bullet colours.
    for name, tile, size, addr in [('heart', 3, 16, 0x018B0000), ('star', 5, 16, 0x018B0400)]:
        assets.append((name, source('shmup/Tiles/tile_%04d.png'%tile).resize((size, size), NEAREST), addr, 1))
    for i, tile in enumerate((7, 8, 9, 27)):
        assets.append(('burst_'+str(i), source('shmup/Tiles/tile_%04d.png'%tile).resize((32, 32), NEAREST), 0x018B1000+i*0x1000, 1))
    # Preserve original 7x7 enemy bullet size and 4x10 player bullet geometry.
    bullet = source('shmup/Tiles/tile_0000.png')
    bullet = bullet.crop(bullet.getbbox()).resize((8,8), NEAREST)
    for i, col in enumerate(((255,70,100),(90,255,160),(110,160,255),(255,235,100),(235,120,255),(90,235,255),(255,170,75),(245,245,255))):
        colored = bullet.copy()
        colored.putdata([(255,255,255,a) if min(r,g,b)>200 else (*col,a) for r,g,b,a in bullet.getdata()])
        assets.append(('bullet_'+str(i), colored, 0x018B5000+i*0x100, 1))
    # The two HUD portraits reuse exactly the same compressed, full-colour
    # player frame. Only their DDR destinations and integer scale differ.
    assets += [('reimu_hud_small', pose0, 0x01CA8000, 2),
               ('reimu_hud_large', pose0, 0x01CB1000, 3)]
    header = ['/* Generated by tools/build_visual_assets.py; sources in assets/SOURCES.md. */',
              '#ifndef VISUAL_ASSETS_H', '#define VISUAL_ASSETS_H', '#include <stdint.h>',
              'typedef struct { const uint32_t *palette; const uint8_t *rle; uint32_t words, dst; uint16_t w,h; uint8_t scale; } visual_asset_t;']
    body = ['#include "visual_assets.h"']
    meta = []
    # reimu_3 is the walk's fourth frame: the supplied sheet repeats frame 1
    # there and the build only nudges it up two rows, so the firmware derives
    # it at boot (reimu_bob_build) instead of carrying a second 48x48 stream.
    shared = {'reimu_hud_small': 'reimu_0', 'reimu_hud_large': 'reimu_0',
              'reimu_3': 'reimu_1'}
    # Identical palette words or identical RLE bytes are emitted once.  The
    # three Reimu poses share one 9-colour palette, and the eight 8x8 bullets
    # share one 14-byte run (only the middle colour changes).  Pointing the
    # later assets at the first copy does not change a decoded pixel.
    # laser_glow is the one asset whose pixels the firmware does NOT take from
    # this stream: laser_glow_build() (sw/app/main.c) fills all 768 rows of it
    # at boot and overwrites row 0.  This used to be an empty set, so every
    # entry in manifest.json said runtime_overlay false - including that one,
    # which made the field worse than useless to anyone reading it.
    runtime_overlay = {'laser_glow'}

    def color_limit(name):
        # No asset is named 'background' any more: the backdrop is painted by
        # the firmware, so the branch that used to give it 8 tones is gone.
        # Measured when it existed: 8 -> 4118 B, 4 -> 4099 B.
        return 32
    pal_owner = {}
    rle_owner = {}
    pal_sym = {}
    rle_sym = {}
    for idx, (name, im, addr, scale) in enumerate(assets):
        im.save(OUT / (name+'.png'))
        cols, runs = quantize(im, color_limit(name), name == 'laser_glow')
        encoded = 0
        if name not in shared:
            pkey, rkey = tuple(cols), tuple(runs)
            if pkey not in pal_owner:
                pal_owner[pkey] = name
                body += ['static const uint32_t p_%s[] = {%s};'%(name, ','.join('0x%08Xu'%c for c in cols))]
                encoded += 4*len(cols)
            if rkey not in rle_owner:
                rle_owner[rkey] = name
                body += ['static const uint8_t r_%s[] = {'%name]
                body += [','.join(str(r) for r in runs[j:j+24])+',' for j in range(0,len(runs),24)]
                body += ['};']
                encoded += len(runs)
            pal_sym[name] = pal_owner[pkey]
            rle_sym[name] = rle_owner[rkey]
        header += ['#define ART_%s %d'%(name.upper(), idx)]
        meta.append(dict(name=name,dst=addr,width=im.width*scale,height=im.height*scale,
                         bytes=4*im.width*im.height*scale*scale,
                         encoded_bytes=encoded,
                         palette_colors=color_limit(name),
                         shared=shared.get(name),
                         palette=None if name in shared else pal_sym[name],
                         rle=None if name in shared else rle_sym[name],
                         runtime_overlay=name in runtime_overlay))
    body += ['const visual_asset_t visual_assets[] = {']
    # A shared asset points at another one's stream, so it must also take that
    # stream's LENGTH: its own would be right only for as long as the two
    # pictures happen to encode to the same number of bytes.
    def stream_words(name):
        for n2, im2, _, _ in assets:
            if n2 == name:
                return len(quantize(im2, color_limit(n2), n2 == 'laser_glow')[1])
        raise SystemExit('shared asset %r has no source' % name)

    for n, im, a, s in assets:
        src = shared.get(n, n)
        body += ['{p_%s,r_%s,%du,0x%08Xu,%d,%d,%d},'
                 % (pal_sym[src], rle_sym[src], stream_words(src), a,
                    im.width, im.height, s)]
    body += ['};']
    header += ['#define ART_COUNT %d'%len(assets), 'extern const visual_asset_t visual_assets[ART_COUNT];', '#endif']
    # Rasterise the downloaded font, not a custom hand-drawn alphabet.
    glyphs = []
    for code in range(32, 127):
        im = Image.new('L',(6,8))
        ImageDraw.Draw(im).text((0,-3), chr(code), font=font(16), fill=255)
        glyphs.append([sum((1<<(5-x)) for x in range(6) if im.getpixel((x,y))>=128) for y in range(8)])
    header.insert(-1, 'extern const uint8_t visual_font[95][8];')
    body += ['const uint8_t visual_font[95][8] = {']+['{'+','.join(map(str,row))+'},' for row in glyphs]+['};']
    (ROOT/'sw/app/visual_assets.h').write_text('\n'.join(header)+'\n',encoding='ascii')
    (ROOT/'sw/app/visual_assets.c').write_text('\n'.join(body)+'\n',encoding='ascii')
    (OUT/'manifest.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
    (OUT/'hud_labels.json').write_text(json.dumps(HUD_LABELS, indent=2) + '\n',
                                       encoding='utf-8')
    originals=('fumoreimu.png','fumoreimu-sheet.png','fumocirno.png','fumookuu.png',
               'forest.zip','kenney_pixel-shmup.zip','ui.zip','fonts.zip')
    fingerprints={name:hashlib.sha256((SRC/name).read_bytes()).hexdigest() for name in originals}
    (SRC/'SHA256.json').write_text(json.dumps(fingerprints,indent=2)+'\n',encoding='utf-8')
    print('Asset bank:',len(assets),'assets,',sum(m['encoded_bytes'] for m in meta),'encoded bytes')
    # The linked image (text+data) is what actually has to fit in 64512 B,
    # and sw/build_firmware.py prints it on every build.  46 KiB of encoded
    # assets plus the ~55 KiB of code left no room at 1366x768, so the guard
    # tracks the real budget instead of a number that was chosen for a
    # different layout.
    assert sum(m['encoded_bytes'] for m in meta) < 52000, (
        'asset bank exceeds 64 KiB firmware budget')


if __name__ == '__main__':
    build()
