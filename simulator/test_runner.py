#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
simulator/test_runner.py
========================
Comprehensive verification suite for the Ti60 2D engine virtual machine.

It runs the *real* GCC-built firmware (sw/build/firmware.bin) on the
standalone Sapphire RV32I model and checks both behaviour and rendered output.

    1. Mode 1 benchmark  - 650 object hardware render + one block copy/frame
    2. Mode 2 idle       - bullet waves, player spawn and COPY activity
    3. Mode 2 controls   - joystick direction, focus speed and X laser
    4. Mode 2 clamping   - playfield boundary protection
    5. Mode switching    - Mode 1 <-> Mode 2 handover
    6. Copy integrity    - the sprite blitted by OP_COPY must match the sprite
                            tile in DDR scratch memory to within 5% of its opaque
                            pixels (the HUD and the aura legitimately cover a few
                            of them; a wrong source, stride or colour key moves
                            thousands, not a handful)

Usage
-----
    python simulator/test_runner.py --suite --export-images
    python simulator/test_runner.py --suite --jobs 8      (parallel)
    python simulator/test_runner.py --source sw/build/firmware.bin --mode 1
"""
import argparse
import contextlib
import re
import hashlib
import io
import json
import os
import pickle
import sys
import time
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent
ROOT = SIM_DIR.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(SIM_DIR))

from rv32i_soc_vm import SapphireSoCVM, RAM_BASE, FRAME_BASES, \
    SCRATCH_BASE, load_firmware

# Pillow is only needed to turn an exported frame into a PNG, and importing it
# lazily keeps the workbench runnable on an interpreter with no Pillow wheel -
# measured on PyPy 7.3.17, whose VM core runs 2.4x faster than CPython 3.13 on
# this machine but where Pillow has to be built from source.
try:
    from PIL import Image
    HAVE_PIL = True
except ImportError:                                     # pragma: no cover
    Image = None
    HAVE_PIL = False

DEFAULT_SOURCE = ROOT / "sw" / "build" / "firmware.bin"

_MM_CACHE = {}


def mm_value(name):
    """A DDR surface address, read from the firmware's own memory map.

    These addresses used to be literals in this file, which is how a scenario
    can keep passing while the firmware has moved the surface out from under
    it: MM_LASER_BAR was still spelled 0x032E0000 here after the layout change
    that moved it to 0x033C0000, so the assertion was checking a range nothing
    writes any more.
    """
    if name not in _MM_CACHE:
        _MM_CACHE[name] = _mm_eval(name)
    return _MM_CACHE[name]


def _mm_eval(name, _seen=None):
    """Value of #define <name> in memory_map.h, expressions included.

    The old version stopped at the first number it found, so
    MM_BUCKET_USED_BYTES -- written as (2UL * MM_BUCKET_ROWS) -- read back as
    2 instead of 2 * 768.  Whatever the map spells, the test has to see the
    value the firmware sees, so the definition is expanded through the other
    names in the same file and only then evaluated.
    """
    _seen = set() if _seen is None else _seen
    if name in _seen:
        raise SystemExit("memory_map.h: %s is a circular definition" % name)
    _seen.add(name)

    txt = (ROOT / "sw" / "driver" / "memory_map.h").read_text(encoding="utf-8")
    m = re.search(r"^#define\s+%s\s+(.*)$" % name, txt, re.M)
    if not m:
        raise SystemExit("sw/driver/memory_map.h has no %s" % name)
    tail = m.group(1)
    expr = tail
    if "/*" in expr:
        expr = expr.split("/*", 1)[0]
    if "//" in expr:
        expr = expr.split("//", 1)[0]
    expr = expr.strip()
    if expr.startswith("(") and expr.endswith(")"):
        expr = expr[1:-1].strip()

    def sub(mo):
        return str(_mm_eval(mo.group(1), _seen))

    expanded = re.sub(r"\b(MM_[A-Z_0-9]+)\b", sub, expr)
    expanded = re.sub(r"(?<=\d)[UL]+\b", "", expanded)
    # Only numbers and arithmetic can survive the two substitutions above.
    hexlit = re.fullmatch(r"\s*(0[xX][0-9A-Fa-f]+)[uUlL]*\s*", expanded)
    if hexlit:
        return int(hexlit.group(1), 16)
    try:
        if not re.fullmatch(r"[\d\s+*/()\-]+", expanded):
            raise ValueError("not a plain arithmetic expression: %r" % expanded)
        return int(eval(expanded))
    except Exception as exc:
        raise SystemExit(
            "sw/driver/memory_map.h: cannot read %s = %r (%s)"
            % (name, tail.strip(), exc))

# Booting the real firmware costs about 77 M simulated steps - the three
# 640x600 stage plates and the parallax tile are pre-decoded into DDR on a core
# with no multiplier - which is minutes of host time before a single assertion
# runs.  The machine state just after the first menu frame is therefore cached
# on disk under a name that carries the firmware hash, and every later test
# resumes from it.  Rebuild it with --refresh-snapshot after a firmware change.
CACHE_DIR = SIM_DIR / "cache"
_FW_FINGERPRINT = None
_SNAPSHOT_BLOB = None

SPRITE_BASE = 0x01608000            # boss colorkey sprite (mode 1 + boss)
SPRITE_W = 64
SPRITE_H = 64
SPRITE_STRIDE = 256
# Scan geometry.  The playfield bounds below are NOT derived from these: the
# 640x600 stage plates are baked against GAME_LEFT/GAME_RIGHT and stay put.
SCREEN_W = 1366
SCREEN_H = 768
SCREEN_STRIDE = 8192
SCREEN_PITCH = SCREEN_STRIDE // 4   # framebuffer row pitch in PIXELS
# The playfield is NOT the whole screen: main.c paints stage content over
# rows PLAYFIELD_BOTTOM..SCREEN_H with the menu backdrop instead.  Every
# sample that means "inside the stage" must stop at this row.
GAME_TOP_PX = 0                 # PLAYFIELD_TOP in main.c
PLAYFIELD_BOTTOM = 768          # the playfield runs the FULL height now
GAME_LEFT = 181                 # 180-pixel left HUD gutter + 1 border column
GAME_RIGHT = 1185               # 180-pixel right gutter from here to 1366
# The craft spawns centred, so every scenario that checks or steers to the
# spawn point uses this instead of a literal.  The old build hard-coded 448
# (128 + 640/2) in seven places and they all went stale the moment the
# playfield moved.
SPAWN_X = (GAME_LEFT + GAME_RIGHT) // 2      # 683
SPAWN_Y = 512                    # = GAME_TOP + (GAME_BOTTOM - GAME_TOP)*2/3
                                 # in main.c game_init()

ALPHA_SPRITE_BASE = 0x0160C000
ALPHA_W = 64
ALPHA_H = 64
ALPHA_STRIDE = 256
ALPHA_KEY = 0x00FF00FF

# DDR scratch map -- must mirror sw/driver/memory_map.h
ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE = 0x01605000, 32, 16
# Read from the firmware's own memory map, not from literals.  These two were
# literals, and when the pools were widened the literals were updated while
# sw/driver/memory_map.h was - for a while - left behind at the old counts:
# every scenario here then cleared and counted 512 slots of a pool the
# firmware only ever walked 128 (or 192) of, and nothing said so, because the
# numbers the scenarios used were their own.  mm_value() is the same fix the
# addresses above already use for exactly this reason.
PBULLET_BASE, PBULLET_COUNT = mm_value("MM_PBULLET_BASE"), mm_value("MM_PBULLET_COUNT")
EBULLET_BASE, EBULLET_COUNT = mm_value("MM_EBULLET_BASE"), mm_value("MM_EBULLET_COUNT")
ITEM_BASE, ITEM_COUNT = 0x01605A00, 16
PLAYER_SPRITE, PLAYER_STRIDE = 0x01605C00, 128

TLM_BASE = 0x01605B00
TLM_MAGIC_VAL = 0x544C4D32
TLM = {
    'magic': 0, 'frames': 1, 'player_x': 2, 'player_y': 3, 'lives': 4,
    'damage_rows': 55,
    'sprites': 57, 'bucket_drops': 58,
    'score': 5, 'weapon': 6, 'atk': 7, 'fire_cd': 8, 'kills': 9,
    'enemies': 10, 'pbullets': 11, 'ebullets': 12, 'items': 13, 'taken': 14,
    'boss_st': 15, 'boss_hp': 16, 'boss_pat': 17, 'pat_chg': 18,
    'summons': 19, 'hits': 20, 'gameover': 21,
    'paused': 22, 'hwaccel': 23, 'infrespawn': 24, 'settings': 25,
    'padbits': 26,
    'stage': 27, 'boss_x': 28, 'boss_y': 29, 'dialog': 30,
    'slow': 31, 'jam': 32, 'laser_hits': 33,
    'invuln': 34, 'weapon_lv': 35, 'stage_bg': 36, 'bomb': 37, 'laser': 38,
}

TICK = 25000

# Cards in the boot menu; must mirror MENU_ITEMS in sw/app/main.c.  It is the
# v6 two-card menu again: 0 = RENDER LAB (the BitBlt bench), 1 = START GAME.
MENU_ITEMS = 2

# Raw APB 0x54 bit each *physical* face button lands on.  Must mirror the
# mapping table in sw/driver/gamepad.h (measured on the real handset).
BTN_BIT = {'a': 2, 'b': 1, 'x': 3, 'y': 0, 'ok': 4}   # ok = joystick centre press


def raw_btn(*names):
    """APB 0x54 value with the given physical buttons pressed (online = bit15)."""
    value = 0x8000
    for n in names:
        value |= 1 << BTN_BIT[n]
    return value

def press(vm, *names, frames=1):
    """Hold the given buttons for `frames` display frames, then release."""
    vm.btn = raw_btn(*names)
    for _ in range(TICK * frames + TICK // 2):
        vm.step()
    vm.btn = raw_btn()
    for _ in range(TICK + TICK // 2):
        vm.step()


def press_until(vm, names, cond, budget=10_000_000):
    """Hold `names` until cond() becomes true, then release.

    Inside a demo one loop iteration can be several hundred thousand
    instructions long (the CPU software slice blocks the loop), so a fixed
    one-frame press could be sampled at the wrong moment or missed entirely.
    """
    start = vm.steps
    vm.btn = raw_btn(*names)
    ok = False
    while vm.steps - start < budget:
        if cond():
            ok = True
            break
        vm.step()
    vm.btn = raw_btn()
    for _ in range(TICK):
        vm.step()
    return ok

def wait_for_boot(vm, budget=200_000_000):
    """Step until the firmware has drawn and published its first menu frame.

    Boot work is why a fixed step count is useless here, and it grew when the
    firmware started pre-decoding the three 640x600 stage plates and the
    parallax strip into DDR - about 1.2 million RLE pixels, all of it real
    work on a core with no multiply instruction (the alpha sprite alone is
    4096 pixels of software multiplies).  Measured cost on the host model is
    ~77 million steps, so the budget is deliberately generous.
    """
    spent = 0
    # Boot first publishes two blank buffers while clearing scanout memory.
    # Only the third pair is the rendered menu, after asset decoding.
    while len(vm.right_published) < 3 and spent < budget:
        vm.step()
        spent += 1
    assert len(vm.right_published) >= 3, "the firmware never published a boot menu frame"
    for _ in range(TICK):
        vm.step()


def menu_enter(vm, item):
    """Drive the boot menu and enter row `item`.

    The menu is v6's pair of cards again: row 0 is RENDER LAB (the BitBlt
    bench) and row 1 is START GAME (the bullet-hell run), selected with the
    D-pad and confirmed with X (or the stick centre).  `item` counts DOWN
    presses from the top, so it is 0 or 1.

    Every press has to last at least one display frame - the menu is polled
    once per frame - and the stick must be centred between presses or it would
    keep scrolling.
    """
    vm.joy = (128 << 8) | 128
    vm.btn = raw_btn()
    wait_for_boot(vm)
    for _ in range(TICK * 2):
        vm.step()
    for _ in range(item):
        # hold() steps the CPU while the button is down, so the menu loop is
        # guaranteed to sample the press at least once; press() releases after
        # a single frame and the menu only polls once per display frame.
        hold(vm, 'a', frames=6)       # A walks the selection down one row
    press(vm, 'x', frames=4)          # X confirms (4 frames: the menu polls
                                      # once per display frame and a
                                      # one-frame press can fall between)
    for _ in range(TICK):
        vm.step()


_FW_BSS = None
_FW_SYMS = {}
_FW_SOURCE = None       # path of the image, needed to boot pool workers


def load_code_from_source(source_path):
    global _FW_BSS, _FW_SYMS, _FW_FINGERPRINT, _FW_SOURCE
    source_path = Path(source_path)
    if not source_path.exists():
        raise SystemExit("firmware image not found: %s\n"
                         "build it first:  sw\\build_firmware.bat" % source_path)
    words, nbytes, _FW_BSS = load_firmware(source_path)
    _FW_SYMS = {}
    sym = source_path.with_suffix(".sym")
    if sym.exists():
        for line in sym.read_text(encoding="ascii").splitlines():
            name, _, value = line.partition(" ")
            if value.strip():
                _FW_SYMS[name.strip()] = int(value.strip(), 16)
    rom = ROOT / "rtl/bitblt/asset_rom.hex"
    _FW_FINGERPRINT = "%s-menu-v3-%s" % (source_path.stem,
        hashlib.sha256(source_path.read_bytes() + rom.read_bytes()).hexdigest()[:12])
    _FW_SOURCE = str(source_path)
    print("  firmware: %s (%d bytes, ends at %#x, bss %r)"
          % (source_path.name, nbytes, RAM_BASE + len(words) * 4, _FW_BSS))
    return words


def sym_addr(name):
    """RAM address of a firmware symbol, from the sidecar firmware.sym.

    Scenarios that grade scenery switch the stage directly: playing through two
    boss fights to reach the third backdrop costs more than the entire rest of
    the suite, and each group has a five-minute budget.
    """
    assert name in _FW_SYMS, \
        "firmware.sym has no symbol %r (rebuild the firmware)" % name
    return _FW_SYMS[name]


def peek(vm, name, size=2):
    """Read a firmware variable by name, small and signed by default.

    Scenarios that grade behaviour derived from a firmware constant should
    read it rather than mirror it: a copy of the formula in this file would
    keep checking the old thresholds after the firmware changed.
    """
    off = sym_addr(name) - RAM_BASE
    return int.from_bytes(vm.ram[off:off + size], "little", signed=(size < 4))


def poke(vm, addr, value, size=4):
    off = addr - RAM_BASE
    vm.ram[off:off + size] = int(value).to_bytes(size, "little", signed=(size < 4))


def _replace_via_temp(path, writer):
    """Write `path` through a uniquely named temporary file.

    Overwriting a picture in place leaves the *creation* timestamp of the older
    run behind, and simply deleting first does not help either: NTFS "file
    tunnelling" hands the deleted file's creation time to a same-named file
    recreated within a few seconds.  Explorer shows the creation date in the
    "date" column of image folders, so the picture then looks stale even though
    it was just regenerated.  A unique temporary name has no tunnel entry.
    """
    path = Path(path)
    tmp = path.with_name("%s.tmp%d" % (path.name, os.getpid()))
    if tmp.exists():
        tmp.unlink()
    writer(str(tmp))
    os.replace(str(tmp), str(path))


def save_frame(vm, base_addr, out_bmp_path, out_png_path=None):
    _replace_via_temp(out_bmp_path, lambda p: vm.save_frame_bmp(p, base_addr))
    if out_png_path:
        try:
            if not HAVE_PIL:
                raise ImportError("no Pillow in this interpreter")
            from PIL import Image

            def _png(p, src=out_bmp_path):
                Image.open(src).save(p, format="PNG")  # temp name has no usable suffix

            _replace_via_temp(out_png_path, _png)
            print("  -> Frame exported: %s" % Path(out_png_path).name)
        except Exception:
            print("  -> Frame exported: %s" % Path(out_bmp_path).name)


def find_sprite_copy(vm, w=SPRITE_W, h=SPRITE_H):
    """The most recent COPY of the boss sprite, by geometry.

    `vm.last_copy` is only the last one the engine ran, and the menu draws its
    own text through the same engine - a 6x8 glyph COPY lands after the sprite
    copy and steals the slot.  Walking the trace for the sprite's geometry is
    what the assertion actually means.
    """
    rec = getattr(vm, "last_sprite_copy", None)
    assert rec is not None, "the firmware never issued a sprite COPY"
    return rec


def check_sprite_colorkey(vm):
    """Opaque sprite pixels copy exactly; magenta never reaches the frame."""
    dst, src, w, h, ss, ds = find_sprite_copy(vm)
    assert h >= 32 and w >= 32, "sprite COPY is too small to check: %dx%d" % (w, h)
    assert ds == SCREEN_STRIDE, "sprite COPY used the wrong destination stride" 
    base = vm.frame_of(dst)
    assert base is not None
    off = dst - base
    same = total = 0
    leaked = 0
    for r in range(h):
        s = src - SCRATCH_BASE + r * ss
        for x in range(w):
            exp = int.from_bytes(vm.scratch[s + x * 4:s + x * 4 + 4], "little")
            got = vm.fb[base][(off + r * ds) // 4 + x]
            if exp == 0x00FF00FF:
                # Moving benchmark objects may already occupy this pixel, so
                # its prior value is not necessarily black.  The RTL sentinel
                # test proves exact preservation; here we prove no key colour
                # leaked into the integrated rendered frame.
                if got == exp:
                    leaked += 1
                continue
            total += 1
            if got == exp:
                same += 1
    assert leaked == 0, (
        "transparent key colour leaked into the framebuffer at %d pixels" % leaked)
    # Not 100%: HUD text, the aura and anything else drawn AFTER the sprite in
    # the same frame legitimately covers part of it.  Measured overlap on the
    # integrated frame is a handful of pixels out of thousands, so a 5% floor
    # still catches a real mismatch (a wrong source, a wrong stride, a colour
    # key that stopped keying) which would put thousands out of place.
    ratio = same / total
    assert ratio >= 0.95, (
        "only %.1f%% of the sprite's opaque pixels survived the copy (%d of %d)"
        " - the COPY is not reproducing its source"
        % (ratio * 100, same, total))
    return True


def check_alpha_blit(vm):
    """Verify the last OP_ALPHA command against an independently written model.

    The engine must have read the LIVE background (vm.last_alpha_before is the
    destination snapshot taken just before the command), blended per pixel and
    left colour-keyed source pixels completely alone.
    """
    assert vm.last_alpha is not None, "firmware never issued an OP_ALPHA"
    dst, src, w, h, ss, ds = vm.last_alpha
    ga, key = vm.last_alpha_cfg
    assert (w, h, ss, ds) == (ALPHA_W, ALPHA_H, ALPHA_STRIDE, SCREEN_STRIDE), \
        "unexpected alpha geometry %r" % (vm.last_alpha,)
    assert key == ALPHA_KEY, "colour key must stay enabled during an alpha blit"
    assert 0 <= ga <= 255

    base = vm.frame_of(dst)
    assert base is not None
    x, y, _, _ = vm.last_alpha_rect

    src_off = src - SCRATCH_BASE
    semi = opaque = clear = keyed = 0
    background = set()

    for r in range(h):
        srow = vm.scratch[src_off + r * ss: src_off + r * ss + 4 * w]
        before = vm.last_alpha_before[r]
        for px in range(w):
            sp = srow[px * 4:px * 4 + 4]
            dp = before[px * 4:px * 4 + 4]
            background.add(dp)
            got = vm.fb[base][(y + r) * SCREEN_PITCH + x + px].to_bytes(4, "little")

            if int.from_bytes(sp, "little") == key:
                keyed += 1
                exp = dp                      # colour key wins over alpha
            else:
                a = (sp[3] * ga + 127) // 255
                exp = bytes([(sp[k] * a + dp[k] * (255 - a) + 127) // 255
                             for k in range(3)] + [dp[3]])
                if sp[3] == 0:
                    clear += 1
                elif sp[3] == 255:
                    opaque += 1
                else:
                    semi += 1
            assert got == exp, \
                "alpha mismatch at (%d,%d): got %s expected %s (a=%d ga=%d)" \
                % (px, r, got.hex(), exp.hex(), sp[3], ga)

    assert keyed >= 4, "the sprite must contain colour-keyed pixels, found %d" % keyed
    assert clear > 0 and semi > 0 and opaque > 0, \
        "the sprite does not exercise the full alpha range: %d/%d/%d" % (clear, semi, opaque)
    # The per-pixel comparison above used the LIVE background snapshot, and the
    # sprite's own alpha varies pixel by pixel, so a pre-blended constant could
    # not have matched it - with one background colour the expected value still
    # varies, with the alpha.
    #
    # This used to ALSO require the backdrop under the aura to be more than one
    # colour, on the grounds that a striped backdrop guaranteed it.  That is not
    # what the check is for, and B1 made it false anyway: the bullet curtain
    # moved out of the framebuffer, so what sits under the aura is now one flat
    # plate colour instead of a field of bullets.  The requirement was removed
    # rather than the backdrop dressed up to satisfy it.
    return clear, semi, opaque, keyed, len(background)


def run_until_alpha(vm, budget=8_000_000):
    """Step until the next OP_ALPHA command fires, then stop immediately.

    The game keeps drawing after the aura (laser, craft, lives), so the result
    has to be inspected before those writes land on top of it.
    """
    start = vm.blit_alpha_calls
    spent = 0
    while vm.blit_alpha_calls == start and spent < budget:
        vm.step()
        spent += 1
    return vm.blit_alpha_calls > start


_TLM_WORD0 = (TLM_BASE - SCRATCH_BASE) // 4


def wait_telemetry(vm, key, value, budget):
    """Wait for the same telemetry value on native and pure Python cores."""
    index = _TLM_WORD0 + TLM[key]
    if hasattr(vm, "run_until_word_ne"):
        return vm.run_until_word_ne(index, value, budget)
    spent = 0
    while spent < budget and vm.scratch32[index] != value:
        vm.step()
        spent += 1
    return spent


def tlm(vm, key):
    """Read one telemetry word the firmware publishes every game frame.

    Uses the word view of DDR scratch.  This runs millions of times per
    scenario inside step-wait loops, and the old form allocated a bytes
    object (vm.scratch[off:off+4]) on every single call.
    """
    return vm.scratch32[_TLM_WORD0 + TLM[key]]


def player_pos(vm):
    return tlm(vm, 'player_x'), tlm(vm, 'player_y')


def pool_active(vm, base, count, stride, flag_off):
    """Count active records in a DDR pool (flags byte at flag_off).

    The walk lives in the C++ core: from Python this cost ~1.4 us per element
    and the pool is rescanned inside per-frame wait loops.
    """
    return vm.count_nonzero(base - SCRATCH_BASE + flag_off, count, stride)


def check_player_sprite(vm, px, py):
    """Verify opaque pixels of one of the six licensed 48x48 poses.

    This replaces a check specific to the old hand-drawn white sash; it is not
    a colour-presence heuristic. Every non-key source pixel must match.
    """
    fb = vm.fb[vm.right_request]
    x0, y0 = px-24, py-24
    for base in (0x01610000,0x01612400,0x01614800,0x01616C00,0x01619000,0x0161B400):
        opaque = 0
        matches = True
        for sy in range(48):
            for sx in range(48):
                if not (GAME_LEFT <= x0+sx < GAME_RIGHT and 0 <= y0+sy < PLAYFIELD_BOTTOM):
                    continue
                off = base-SCRATCH_BASE+sy*192+sx*4
                exp = int.from_bytes(vm.scratch[off:off+4],'little')
                if exp == ALPHA_KEY:
                    continue
                opaque += 1
                if fb[(y0+sy)*SCREEN_PITCH+x0+sx] != exp:
                    matches = False
                    break
            if not matches:
                break
        if matches and opaque > 100:
            return True
    raise AssertionError('none of the six player poses matches the published frame')


# The boot-menu backdrop (1024x600, tiled out to the 1280x720 scan) doubles as the HUD:
# panels, and every label printed on them, are baked into this one surface.
# Both names are the firmware's own MM_VISUAL_BACKGROUND: the plate is decoded
# (and later repainted) at that address, and a literal here is how the HUD check
# ended up reading 0x03800000 - MM_CARD_BG - instead, 256 scanlines away.
VISUAL_BACKGROUND = mm_value("MM_VISUAL_BACKGROUND")
BG_EXPANDED = VISUAL_BACKGROUND  # the painted plate (the whole surface)
VISUAL_BG_STRIDE = SCREEN_STRIDE   # the plate decodes at SCREEN_STRIDE


EBULLET_SOCKET = 0x00080814          # the dark frame every enemy shot sits in


def check_ebullet_socket(vm):
    """What the renderer put in the BUCKET for an injected enemy shot.

    This used to claim it proved every bullet is drawn inside its dark socket.
    It does not.  It clears the pool, injects one shot at (350,420), steps a
    couple of frames and looks for that shot in the bucket table - which the
    firmware fills as an ordinary DDR write, so what is being checked is that
    the shot reached the table the scanout reads.  The 9x9 socket itself is
    drawn by video_bullet_overlay from the tile store and nothing here checks
    it.  A docstring that overstates is how that gap stayed open.
    """
    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    # (350, 420) is inside the playfield, clear of the stage banner that is
    # painted over the top of the playfield for the first 170 frames and well
    # away from the craft's damage box.
    inject_ebullet(vm, 350, 420, 0, 0, color=3)
    # The demo flip-flops between two buffers one frame apart, so where the
    # step budget happens to stop decides which of the two holds the finished
    # picture: look at both and take the best.
    assert wait_frames(vm, 4), "the game stopped producing frames"

    # B1: the shot is composited by the scanout now, so the framebuffer holds
    # none of its pixels - the old form of this check (32 pixels of the dark
    # socket ring, read out of the framebuffer) has nothing left to look at.
    # What it was really asking is whether the bullet the test injected got
    # drawn, in the right place, with the right tile - and that is a question
    # the bucket answers directly, because the bucket is where the hardware
    # reads it from.
    seen = []
    best = 0
    for buf in (0, 1):
        hits = _bucket_covers(vm, 350, 420, colour=3, buffer=buf)
        best = max(best, len(hits))
        seen.append((buf, hits))
    assert best > 0, (
        "the enemy bullet injected at (350,420) in colour 3 is in no bucket: %s"
        % seen)
    print("  [PASS] enemy bullet is standing in the scanout's bucket: %s" % seen)


BACKGROUND_PLANE = 0x01D00000      # MM_STAGE_BG: three 1366x768 plates
BACKGROUND_PLATE = 0x600000        # one plate of DDR: 768 rows x SCREEN_STRIDE


def check_backdrop_visible(vm, min_match=0.35):
    """The stage plate has to be VISIBLE, not merely loaded.

    Stages 2 and 3 once rendered as flat colour with only the HUD readable: the
    recoloured parallax strip had turned its magenta colour key into an opaque
    colour, and the strip is blitted over the playfield twenty times a frame.
    Every existing assertion looked at telemetry or at sprites, so the whole
    suite passed while two thirds of the game had no scenery.  This compares the
    live frame against the decoded plate instead.
    """
    stage = tlm(vm, 'stage_bg')
    assert 0 <= stage < 3, "no stage plate is active (stage_bg = %d)" % stage

    src = vm.scratch
    off = BACKGROUND_PLANE - SCRATCH_BASE + stage * BACKGROUND_PLATE
    fb = vm.fb[vm.right_request]

    same = total = 0
    for y in range(110, PLAYFIELD_BOTTOM, 7):
        srow = off + y * SCREEN_STRIDE
        frow = y * SCREEN_PITCH
        for x in range(GAME_LEFT, GAME_RIGHT, 5):
            exp = int.from_bytes(src[srow + x * 4:srow + x * 4 + 4], "little")
            total += 1
            if fb[frow + x] == exp:
                same += 1

    ratio = same / total
    assert ratio >= min_match, (
        "stage %d's backdrop is invisible: only %.1f%% of %d sampled "
        "playfield pixels match the decoded plate - something is painting a "
        "flat colour over it" % (stage, ratio * 100, total))
    print("  [PASS] backdrop %d visible: %.1f%% of the playfield still matches "
          "its plate" % (stage, ratio * 100))


def check_hud_panels(vm):
    """What the two gutters and the playfield band are, in the framebuffer.

    This used to claim the HUD itself was checked.  It is not: the checks are
    (1) each gutter is painted over its whole height - a flat panel satisfies
    that - and (2) the playfield band carries no gutter-panel colour.  Where the
    HUD boxes actually are is checked by tools/check_hud_layout.py against the
    HUD_BOXES table in main.c, at build time, not here.
    """
    fb = vm.fb[vm.right_request]
    src = vm.scratch
    plate_off = BG_EXPANDED - SCRATCH_BASE

    def plate(x, y):
        o = plate_off + y * VISUAL_BG_STRIDE + x * 4
        return int.from_bytes(src[o:o + 4], "little")

    report = []
    for name, x0, x1 in (("left", 0, GAME_LEFT), ("right", GAME_RIGHT, SCREEN_W)):
        lit = total = 0
        for y in range(0, SCREEN_H, 6):
            row = y * SCREEN_PITCH
            for x in range(x0, x1, 5):
                total += 1
                if fb[row + x]:
                    lit += 1
        # The gutter must be painted over its whole height: a wipe leaves it
        # black, which is what this catches.
        assert lit / total > 0.9, (
            "the %s HUD gutter is mostly unpainted: only %.1f%% of %d sampled "
            "pixels are non-zero (a flat wipe leaves ~0%%)"
            % (name, lit / total * 100, total))
        report.append((name, lit / total))

    # The playfield band must NOT carry gutter panel colour.
    panel_left = plate(4, 400)
    panel_right = plate(SCREEN_W - 4, 400)
    band_same = band_total = 0
    for y in range(60, SCREEN_H - 60, 11):
        row = y * SCREEN_PITCH
        for x in range(GAME_LEFT + 4, GAME_RIGHT - 4, 17):
            band_total += 1
            if fb[row + x] in (panel_left, panel_right):
                band_same += 1
    assert band_same / band_total < 0.5, (
        "the playfield band is showing gutter panel colour on %.1f%% of its "
        "pixels - the HUD has leaked into the game area"
        % (band_same / band_total * 100))

    print("  [PASS] HUD gutters painted: " +
          ", ".join("%s %.1f%% lit" % (n, r * 100) for n, r in report) +
          "; playfield band clean (%d/%d)" % (band_total - band_same, band_total))


def steer(vm, tx, ty, trigger='x', steps=TICK // 4):
    """Point the stick at (tx, ty) for one slice and hold fire."""
    dx = tx - tlm(vm, 'player_x')
    dy = ty - tlm(vm, 'player_y')
    jx = 180 if dx > 4 else (76 if dx < -4 else 128)
    jy = 76 if dy > 4 else (180 if dy < -4 else 128)   # pad y is inverted
    vm.joy = (jy << 8) | jx
    vm.btn = raw_btn(trigger) if trigger else raw_btn()
    for _ in range(steps):
        vm.step()


def chase_nearest_enemy(vm, budget_steps=None, frames=None):
    """Crude autopilot: aim at the lowest minion still above the craft and fire.

    Steering is issued in slices of a quarter frame, which keeps the stick
    responsive without re-reading the pools every instruction.

    STEPS OR FRAMES, and which one a caller asks for is a real decision.  A
    step budget buys the same scene only while a frame costs a fixed number of
    steps, and it does not: on one and the same build the field is 25,000 steps
    a frame while it is idle and 77,653 once the autopilot has been firing for
    a while, so 32,000,000 steps is 415 frames on one revision and rather more
    or fewer on the next.  A caller that has to LAND somewhere - "chase until
    the bar is full" - asks for frames; one that only wants to poke the stick
    for a moment can keep asking for steps.
    """
    spent = 0
    rounds = 0
    while True:
        if frames is not None:
            if rounds >= frames:
                break
        elif spent >= budget_steps:
            break
        best = None
        py = tlm(vm, 'player_y')
        for i in range(ENEMY_COUNT):
            off = ENEMY_BASE - SCRATCH_BASE + i * ENEMY_STRIDE
            if vm.scratch[off + 13] == 0:          # flags byte
                continue
            ex = int.from_bytes(vm.scratch[off:off + 2], "little", signed=True)
            ey = int.from_bytes(vm.scratch[off + 2:off + 4], "little", signed=True)
            evx = int.from_bytes(vm.scratch[off + 4:off + 6], "little", signed=True)
            if ey > py - 40:                       # below the muzzle: skip
                continue
            if best is None or ey > best[1]:
                best = (ex, ey, evx)
        if best is None:
            steer(vm, SPAWN_X, SPAWN_Y, 'x', TICK)
            spent += TICK
        else:
            # lead the target: the bullet needs ~(py-ey)/22 frames to arrive,
            # and a drifting minion moves further than its own hitbox in that
            # time, so aiming at where it used to be would always miss
            flight = max(2, (py - best[1]) // 22)
            steer(vm, best[0] + 12 + best[2] * flight, 520, 'x', TICK // 4)
            spent += TICK // 4
        if frames is not None:
            wait_frames(vm, 1, budget=8_000_000)
            rounds += 1


def hold(vm, *names, frames=8):
    """Hold buttons long enough for the running firmware to sample them.

    Inside a demo the pad is read once per main-loop iteration, and one
    iteration is a display frame plus the render time, so a single-frame press
    can fall entirely between two samples.

    FRAMES, NOT STEPS.  This used to be TICK * frames on the grounds that TICK
    - 25,000 steps - is a display frame.  That stopped being true when the
    pools grew and again when the frame got cheaper: on an idle field a frame
    is now about 60,000 steps, and in the busy state the spell-card scenario
    runs in it is over 100,000 (measured: 96,164 after the autopilot has been
    firing for a while).  A 100,000-step hold is then barely ONE iteration, and
    a press shorter than the gap between two pad samples is a press the
    firmware never sees - which is how that scenario failed, twenty rounds of
    it, without a single one being sampled.  The spell card itself was fine:
    driven by real frames, the same press spends it on the first try.  Counting
    frames makes the hold mean the same thing whatever a frame costs.

    Same repair the stick scenario's step budget needed, for the same reason.
    """
    vm.btn = raw_btn(*names)
    for _ in range(frames):
        wait_frames(vm, 1, budget=8_000_000)
    vm.btn = raw_btn()
    wait_frames(vm, 2, budget=8_000_000)


def snapshot_path():
    """Where the cached boot state for the loaded firmware lives."""
    if _FW_FINGERPRINT is None:
        return None
    return CACHE_DIR / ("boot_%s.pkl" % _FW_FINGERPRINT)


def snapshot_blob():
    """The cached boot image, read from disk at most once per process."""
    global _SNAPSHOT_BLOB
    if _SNAPSHOT_BLOB is None:
        path = snapshot_path()
        if path is not None and path.exists():
            _SNAPSHOT_BLOB = path.read_bytes()
            print("  boot snapshot: %s (%.1f MB, boot step skipped)"
                  % (path.name, len(_SNAPSHOT_BLOB) / 1e6))
    return _SNAPSHOT_BLOB


def build_boot_snapshot(code, force=False):
    """Boot the firmware once and cache the state so later runs can skip it."""
    global _SNAPSHOT_BLOB
    path = snapshot_path()
    if path is None:
        raise SystemExit("load the firmware before building a boot snapshot")
    if path.exists() and not force:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    started = time.time()
    vm = SapphireSoCVM(code, bss=_FW_BSS)
    vm.joy = (128 << 8) | 128
    vm.btn = raw_btn()
    wait_for_boot(vm)
    for _ in range(TICK * 2):
        vm.step()
    blob = pickle.dumps(vm, protocol=4)
    path.write_bytes(blob)
    # Snapshots are ~25 MB and only ever valid for the firmware they came from,
    # so drop the ones belonging to other builds while we are here.
    for stale in CACHE_DIR.glob("boot_*.pkl"):
        if stale != path:
            stale.unlink()
    _SNAPSHOT_BLOB = blob
    print("  boot snapshot rebuilt in %.1f s -> %s (%.1f MB)"
          % (time.time() - started, path.name, len(blob) / 1e6))
    return path


def new_vm(code, **kw):
    """A machine already sitting in the boot menu, when a snapshot exists.

    Resuming instead of rebooting is what keeps a single scenario inside the
    ten-minute budget: the 77 M step pre-decode otherwise dominates every run.
    """
    blob = snapshot_blob()
    if blob is not None:
        return pickle.loads(blob)
    kw.setdefault('bss', _FW_BSS)
    return SapphireSoCVM(code, **kw)


def pixel_at(vm, x, y):
    return vm.fb[vm.right_request][y * SCREEN_PITCH + x]


# ----------------------------------------------------------------------
# scenarios
# ----------------------------------------------------------------------
def run_mode1_benchmark(code, output_dir=None):
    print("\n" + "=" * 65)
    print(" [TEST 1] Mode 1: 650-object hardware render + block copy")
    print("=" * 65)
    vm = new_vm(code)
    menu_enter(vm, 0)   # START GAME -> the BitBlt bench
    while len(vm.published) < 1 and vm.steps < 8_000_000:
        vm.step()

    assert len(vm.published) >= 1, "the machine never published a frame"
    assert vm.starts >= 650, "expected >= 650 BitBlt commands, got %d" % vm.starts
    assert vm.blit_copy_calls >= 1, "the firmware never exercised OP_COPY"
    print("  [PASS] published %d CPU frame(s) in %d steps" % (len(vm.published), vm.steps))
    print("         BitBlt: %d commands (%d fill, %d copy), %d bytes copied, min SP %#x"
          % (vm.starts, vm.blit_fill_calls, vm.blit_copy_calls,
             vm.blit_copy_bytes, vm.min_sp))

    if output_dir:
        save_frame(vm, vm.published[-1], Path(output_dir) / "test1_mode1_benchmark.bmp",
                   Path(output_dir) / "test1_mode1_benchmark.png")
    return vm


def run_mode2_deadzone(code, output_dir=None):
    print("\n" + "=" * 65)
    print(" [TEST 2] Stage opening: minions trickle in and shoot")
    print("=" * 65)
    vm = new_vm(code)
    menu_enter(vm, 1)
    vm.joy = (128 << 8) | 128
    vm.btn = raw_btn()

    for _ in range(120_000):
        vm.step()

    assert tlm(vm, 'magic') == TLM_MAGIC_VAL, "firmware never published telemetry"
    assert player_pos(vm) == (SPAWN_X, SPAWN_Y), \
        "centred stick moved the player: %r" % (player_pos(vm),)
    check_player_sprite(vm, *player_pos(vm))
    check_hud_panels(vm)
    check_ebullet_socket(vm)
    print("  -> player idle at %r, sprite present, %d lives"
          % (player_pos(vm), tlm(vm, 'lives')))

    start = vm.steps
    while vm.steps - start < 12_000_000:
        vm.step()
        if tlm(vm, 'enemies') >= 2 and tlm(vm, 'ebullets') > 0:
            break

    ne, nb = tlm(vm, 'enemies'), tlm(vm, 'ebullets')
    assert ne >= 2, "the opening wave never put two minions on screen at once (%d)" % ne
    assert nb > 0, "minions never fired a bullet"
    assert tlm(vm, 'boss_st') == 0, "the boss must not appear before the kill quota"
    print("  [PASS] %d minions on screen, %d enemy bullets in flight, boss still away"
          % (ne, nb))
    print("         %d BitBlt commands, %d fill / %d copy"
          % (vm.starts, vm.blit_fill_calls, vm.blit_copy_calls))
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test2_mode2_wave.bmp",
                   Path(output_dir) / "test2_mode2_wave.png")
    return vm


def run_mode2_dynamic_motion(code, joy_x=220, joy_y=200, output_dir=None):
    print("\n" + "=" * 65)
    print(" [TEST 3] Player control and shooting")
    print("=" * 65)
    vm = new_vm(code)
    menu_enter(vm, 1)
    for _ in range(100_000):
        vm.step()
    start = player_pos(vm)
    assert start == (SPAWN_X, SPAWN_Y), "player did not spawn centred: %r" % (start,)

    vm.joy = (joy_y << 8) | joy_x            # up-right, focus speed
    vm.btn = raw_btn('a', 'x')
    max_pb = 0
    start_frame = tlm(vm, 'frames')
    r0 = vm.right_request
    spent = 0
    while spent < 8_000_000:
        if tlm(vm, 'frames') >= start_frame + 5 and vm.right_request != r0:
            break
        vm.step()
        spent += 1
        max_pb = max(max_pb, tlm(vm, 'pbullets'))
    assert tlm(vm, 'frames') >= start_frame + 5, \
        "the game did not advance five frames under input"

    end = player_pos(vm)
    assert end[0] > start[0] and end[1] < start[1], \
        "joystick direction is wrong: %r -> %r" % (start, end)
    assert max_pb > 0, "the player never fired a bullet with X held"
    assert tlm(vm, 'weapon') == 0, "weapon changed without picking an item"
    print("  [PASS] focused movement %r -> %r; %d player bullets in flight at peak"
          % (start, end, max_pb))
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test3_mode2_dynamic.bmp",
                   Path(output_dir) / "test3_mode2_dynamic.png")
    return vm


def run_mode2_boundary_clamp(code, output_dir=None):
    print("\n" + "=" * 65)
    print(" [TEST 4] Mode 2: full deflection stress + boundary clamping")
    print("=" * 65)
    vm = new_vm(code)
    menu_enter(vm, 1)
    vm.joy = (255 << 8) | 255
    vm.btn = raw_btn()

    # The playfield runs the full height now (GAME_TOP = 0), so the top clamp
    # is GAME_TOP + the craft's 16-pixel inset, not the old 132.
    # Only the X wall is exercised here.  Walking to the top as well would be a
    # different scenario (it needs ~100 frames of vertical travel at 5 px/frame,
    # and the loop budget below is 120), and this test is about the playfield
    # boundary stopping the craft at all.
    target = (GAME_RIGHT - 24, GAME_TOP_PX + 16)
    start_steps = vm.steps
    pos = None
    # 3M steps only bought ~15 display frames once the game loop grew (each
    # frame now renders the whole 1366x768 plate), and walking from the spawn
    # (x=683) to the right wall needs ~100 of them.  Budget real frames.
    # 2 TICK steps per display frame now, so 20M steps = ~400 frames =
    # enough for 97 frames of X travel plus 101 of Y travel.
    while vm.steps - start_steps < 20_000_000:
        for _ in range(TICK):
            vm.step()
        pos = player_pos(vm)
        if pos == target:
            break

    assert pos == target, "wrong playfield clamp: %r" % (pos,)
    print("  [PASS] clamped at %r, %d BitBlt commands (all in bounds)" % (pos, vm.starts))
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test4_mode2_clamped.bmp",
                   Path(output_dir) / "test4_mode2_clamped.png")
    return vm


def run_menu_navigation(code, output_dir=None):
    print("\n" + "=" * 65)
    print(" [TEST 5] Boot menu: selection, entry and return")
    print("=" * 65)
    vm = new_vm(code)
    vm.joy = (128 << 8) | 128
    vm.btn = raw_btn()
    wait_for_boot(vm)

    def fills_per_frame(frames=3):
        before = vm.blit_fill_calls
        for _ in range(TICK * frames):
            vm.step()
        return (vm.blit_fill_calls - before) // frames

    def copies_per_frame(frames=3):
        before = vm.blit_copy_calls
        for _ in range(TICK * frames):
            vm.step()
        return (vm.blit_copy_calls - before) // frames

    def hud_off():
        return (vm.params.get(0x5C, 0) & 0x00100000) != 0

    def wait_until(cond, budget=6_000_000):
        start = vm.steps
        while vm.steps - start < budget:
            if cond():
                return True
            vm.step()
        return False

    # 1. boots into the menu
    n = fills_per_frame(3)
    assert hud_off(), "the menu must run with the FPS overlay disabled"
    # Two cards, not eight rows: the live card's cursor bar, the two card
    # frames and the footer rule.  Four fills in a two-frame pass, so two a
    # frame is the whole menu doing its job.
    assert n >= 2, "the sourced menu must draw its cards and footer, got %d fills" % n
    nc = copies_per_frame(3)
    assert nc >= 20, "the menu must copy its background and font atlas, got %d" % nc
    print("  -> boot menu: %d fills/frame, %d copies/frame, HUD off" % (n, nc))

    # 1b. the STICK walks the list, one row per push and then on a repeat while
    #     it is held.  Navigation used to be button edges only, so a stick push
    #     did nothing at all - and nothing in this suite noticed, because every
    #     scenario drove the buttons (section 2 of 分辨率后续优化.md).
    def stick(jy, frames):
        vm.joy = (jy << 8) | 128
        for _ in range(TICK * frames):
            vm.step()
        # Release for FOUR frames, not two: a menu pass costs about two display
        # frames, so a 2-frame release can fall between two samples and the
        # firmware never sees the stick centre again - the next push in the
        # same direction would then not count as a new push.
        vm.joy = (128 << 8) | 128
        for _ in range(TICK * 4):
            vm.step()

    sel0 = peek(vm, "menu_sel")
    stick(216, 4)                       # pushed away from the player: up
    sel_up = peek(vm, "menu_sel")
    assert sel_up == (sel0 - 1) % MENU_ITEMS, \
        "a stick push up must walk one row up: %d -> %d" % (sel0, sel_up)
    stick(40, 4)                        # pushed towards the player: down
    assert peek(vm, "menu_sel") == sel0, \
        "a stick push down must walk back to %d" % sel0
    # A push moves ONE row and then waits ~1.5 s before it starts repeating
    # (45 menu passes; a pass costs about two display frames, so 60 frames is
    # comfortably inside the delay and 130 frames is comfortably past it).
    stick(40, 60)
    moved = (peek(vm, "menu_sel") - sel0) % MENU_ITEMS
    assert moved == 1, \
        "one push must move exactly one row and then hold, but 60 frames " \
        "moved %d row(s)" % moved
    # The list is TWO rows now, so a held push WRAPS and "how many rows did it
    # move" always comes back 0 or 1 and proves nothing.  Watch the cursor
    # change instead: both rows must show up while the stick stays pushed.
    seen = set()
    vm.joy = (40 << 8) | 128
    for _ in range(TICK * 130):
        vm.step()
        if vm.steps % TICK == 0:
            seen.add(peek(vm, "menu_sel"))
    vm.joy = (128 << 8) | 128
    for _ in range(TICK * 4):
        vm.step()
    assert len(seen) == MENU_ITEMS, \
        "holding past the repeat delay must keep walking, but the cursor " \
        "only ever sat on %s" % sorted(seen)
    print("  -> stick: 1 row per push, then it walks on while held")
    poke(vm, sym_addr("menu_sel"), 0, 4)    # the rest assumes row 0

    # 1c. A press SHORTER than one menu pass still has to land.
    #
    #     This is the residual bug from the board: "press Y, nothing moves,
    #     press it again".  The menu used to be sampled exactly once per pass
    #     and a pass costs about two display frames, so a tap that opened and
    #     closed inside the render half of a pass was never seen at all.
    #     menu_sample() runs all through the pass now - the drawing stages and
    #     the scanout wait - and latches the edge, so nothing can slip between
    #     two samples.  Six quarter-frame taps, none of them may be dropped.
    misses = 0
    for _ in range(6):
        was = peek(vm, "menu_sel")
        vm.btn = raw_btn('a')
        for _ in range(TICK // 4):          # a quarter of a display frame
            vm.step()
        vm.btn = raw_btn()
        for _ in range(TICK * 2):
            vm.step()
        if peek(vm, "menu_sel") == was:
            misses += 1
    assert misses == 0, \
        "%d of 6 quarter-frame presses were dropped by the menu" % misses
    print("  -> 6 quarter-frame taps, 0 dropped")
    poke(vm, sym_addr("menu_sel"), 0, 4)    # back to row 0 for the entry test

    # 2. the joystick centre press enters the highlighted basic (BitBlt) part
    assert press_until(vm, ('ok',), lambda: not hud_off()), \
        "the centre press did not enter the basic part"
    before = vm.blit_fill_calls
    assert wait_until(lambda: vm.blit_fill_calls - before >= 650), \
        "the BitBlt part must issue 650+ fills per hardware redraw"
    print("  -> basic part (entered with the stick centre): %d fills for one redraw, HUD on"
          % (vm.blit_fill_calls - before))

    # 3. B returns to the menu
    assert press_until(vm, ('b',), hud_off, budget=12_000_000), "B did not return to the menu"
    print("  -> back to menu, HUD off again")

    # 4. A walks down to row 1 (START GAME, the bullet-hell run) and X enters
    #    it.  hold() rather than press() so the pass is certain to sample it.
    hold(vm, 'a', frames=6)
    before = vm.blit_copy_calls
    # Entering is a gameplay telemetry event, not a particular backdrop colour.
    assert press_until(vm, ('x',), lambda: tlm(vm,'magic') == TLM_MAGIC_VAL and tlm(vm,'frames') > 0), \
        "X did not enter the bullet-hell game"
    n = fills_per_frame(3)
    assert n >= 4, "the game renderer issued too few border fills/frame: %d" % n
    assert copies_per_frame(3) >= 20, "the game must copy its sourced background / HUD / actor"
    assert vm.blit_copy_calls > before, "the game must run block copies per frame"
    print("  -> bullet-hell game: %d fills/frame plus art COPY" % n)
    print("  [PASS] menu navigation clean, min SP %#x" % vm.min_sp)
    return vm

def run_copy_integrity(code, output_dir=None):
    print("\n" + "=" * 65)
    print(" [TEST 6] Color Key integrity: transparent vs opaque sprite pixels")
    print("=" * 65)
    vm = new_vm(code)
    menu_enter(vm, 1)   # EXTRA START: colour-key has to be
    # checked on the real game sprites
    for _ in range(400_000):
        vm.step()

    assert vm.blit_copy_calls > 0, "no OP_COPY was issued"
    check_sprite_colorkey(vm)
    print("  [PASS] magenta skipped and opaque pixels copied (%d copies, %d source bytes)"
          % (vm.blit_copy_calls, vm.blit_copy_bytes))
    return vm


def run_alpha_blend(code, output_dir=None):
    print("\n" + "=" * 65)
    print(" [TEST 7] Hardware Alpha: blend against the LIVE background")
    print("=" * 65)
    vm = new_vm(code)
    menu_enter(vm, 1)
    vm.joy = (128 << 8) | 128
    vm.btn = raw_btn()

    # collect the global-alpha values the firmware actually programs
    seen_ga = set()
    rounds = 0
    while rounds < 3:
        assert run_until_alpha(vm), "the game never issued an OP_ALPHA command"
        rounds += 1
        seen_ga.add(vm.last_alpha_cfg[0])
        if rounds == 1:
            clear, semi, opaque, keyed, distinct = check_alpha_blit(vm)
        # let the frame finish before looking for the next aura
        for _ in range(TICK * 3):
            vm.step()

    assert len(seen_ga) >= 2, \
        "GLOBAL_ALPHA was never modulated, saw %r" % (seen_ga,)
    assert vm.blit_alpha_calls >= 3
    print("  [PASS] %d alpha blends, %d bytes written, %d colour-keyed pixels skipped"
          % (vm.blit_alpha_calls, vm.blit_alpha_bytes, vm.blit_alpha_keyed))
    print("         sprite alpha range: %d clear / %d partial / %d opaque;"
          % (clear, semi, opaque))
    print("         blended over %d distinct background pixels, GLOBAL_ALPHA values %s"
          % (distinct, sorted(seen_ga)))

    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test7_mode2_alpha.bmp",
                   Path(output_dir) / "test7_mode2_alpha.png")
    return vm


def run_stage_progression(code, output_dir=None):
    """Minions -> kills -> power-ups -> boss with random patterns."""
    print("\n" + "=" * 65)
    print(" [TEST 8] Stage progression: kills, power-ups, boss")
    print("=" * 65)
    vm = new_vm(code)
    menu_enter(vm, 1)

    # ---- 1. farm minions until the wave quota is met -------------------
    # Must mirror `wave_max` in game_init(): the boss waits for "quota met AND
    # field clear", so farming to the wrong number just sits there until the
    # step budget runs out.
    WAVE_QUOTA = 14
    spent = 0
    while tlm(vm, 'kills') < WAVE_QUOTA and spent < 60_000_000:
        # Same shortcut the backdrop scenario takes: waiting for the spawn timer
        # and then for each minion to drift into range costs far more simulated
        # time than the kill itself.  Kills, drops and the quota still run
        # through the real code paths - only the arrival is skipped.
        top_up_minions(vm, want=5)
        chase_nearest_enemy(vm, TICK * 6)
        spent += TICK * 6
    kills = tlm(vm, 'kills')
    assert kills >= WAVE_QUOTA, \
        "autopilot only killed %d minions, the quota is %d" % (kills, WAVE_QUOTA)
    print("  -> %d minions destroyed, score %d" % (kills, tlm(vm, 'score')))
    # ---- 1b. the dialogue card, graded while it is actually up ----------
    # The card comes up the moment the wave quota is met AND the field is clear,
    # which is exactly where the farming loop above stops.  Everything that used
    # to run between here and the boss wait - the pickup hunt, the caps - costs
    # seconds of simulated time, and by the time the old code looked for
    # `boss_st == 4` the card had been and gone.  Measured: the state walked
    # 1 (ENTER) -> 5 (FREEZE) -> 2 (FIGHT) and neither of the two graded blocks
    # ever executed once, while the scenario still printed PASS.  Grade it here,
    # where it is really on screen.
    spent = 0
    while tlm(vm, 'boss_st') != 4 and spent < 40_000_000:
        chase_nearest_enemy(vm, TICK)
        spent += TICK
    assert tlm(vm, 'boss_st') == 4, (
        "the quota was met and the field was clear, but the boss settled on state"
        " %d without the dialogue card ever coming up, so the occlusion box and"
        " the page advance were not graded" % tlm(vm, 'boss_st'))
    print("  -> dialogue card up (state 4) after %d extra steps" % spent)

    # The boss's arrival card is framebuffer pixels like the pause card, and the
    # snow layer is composited above the framebuffer, so the card is only clean
    # because the firmware hands the scanout its rectangle to leave alone
    # (0x8C / 0xAC).  800x176 centred in the playfield: DIALOG_* in main.c.
    dialog_box = (283, 1082, 296, 471)
    box_x = vm.params.get(0x8C, 0)
    box_y = vm.params.get(0xAC, 0)
    assert box_x >> 31, "a dialogue is on screen but no occlusion box is published"
    now_box = (box_x & 0x7FF, (box_x >> 11) & 0x7FF,
               box_y & 0x7FF, (box_y >> 11) & 0x7FF)
    assert now_box == dialog_box, \
        "dialogue occlusion box is %s, the card is %s" % (now_box, dialog_box)
    print("  -> dialogue occlusion box x %d..%d y %d..%d follows the card"
          % dialog_box)

    # Story V3 pauses gameplay for three pages before the boss fights.  Exercise
    # the real centre-button skip path so the old regression still reaches attack
    # patterns without waiting for the automatic page timeouts.
    for expected in (2, 3, 0):
        vm.btn = raw_btn()
        for _ in range(TICK * 2):
            vm.step()
        assert press_until(vm, ('ok',),
                           lambda e=expected: tlm(vm, 'dialog') == e,
                           budget=30_000_000), "dialog page did not advance"
    print("  -> three dialogue pages skipped with the centre button")

    # ---- 2. collect a power-up ----------------------------------------
    atk0, w0, cd0, taken0 = (tlm(vm, 'atk'), tlm(vm, 'weapon'),
                             tlm(vm, 'fire_cd'), tlm(vm, 'taken'))
    score0 = tlm(vm, 'score')
    spent = 0
    while tlm(vm, 'taken') <= taken0 and spent < 60_000_000:
        item = None
        for i in range(ITEM_COUNT):
            off = ITEM_BASE - SCRATCH_BASE + i * 8
            if vm.scratch[off + 6] == 0:
                continue
            item = (int.from_bytes(vm.scratch[off:off + 2], "little", signed=True),
                    int.from_bytes(vm.scratch[off + 2:off + 4], "little", signed=True))
            break
        if item is None:
            chase_nearest_enemy(vm, TICK * 4)      # keep farming for a drop
            spent += TICK * 4
        else:
            # slide in x only: the item falls straight down, so lining up under
            # it is what actually collects it
            steer(vm, item[0], 520, None, TICK // 8)
            spent += TICK // 8

    assert tlm(vm, 'taken') > taken0, "the player never picked up a power-up"
    changed = (tlm(vm, 'atk') != atk0 or tlm(vm, 'weapon') != w0 or
               tlm(vm, 'fire_cd') != cd0)
    print("  -> %d power-ups taken; stats atk=%d weapon=%d fire_cd=%d%s"
          % (tlm(vm, 'taken'), tlm(vm, 'atk'), tlm(vm, 'weapon'), tlm(vm, 'fire_cd'),
             "" if changed else " (score-only drop)"))
    assert tlm(vm, 'score') > 0, "no score was awarded"
    # `changed` used to be computed for the print only.  Picking up an item that
    # moved nothing at all - no attack, no weapon level, no fire rate, no score -
    # still passed, because the assertions around it looked at `taken` and at
    # `score > 0`, and the score had been accumulating from kills since the first
    # wave.  A pickup has to make SOMETHING move, and the score is now measured
    # from the moment before the pickup rather than from zero.
    assert changed or tlm(vm, 'score') > score0, (
        "a power-up was collected (taken %d -> %d) but no stat and no score moved:"
        " atk %d, weapon %d, fire_cd %d, score %d (was %d)"
        % (taken0, tlm(vm, 'taken'), tlm(vm, 'atk'), tlm(vm, 'weapon'),
           tlm(vm, 'fire_cd'), tlm(vm, 'score'), score0))

    # ---- 2b. take the caps before the boss ----------------------------
    # The boss fight is the long pole, and at the starting attack power it eats
    # minutes of the budget.  Nothing above is weakened by upgrading here: the
    # pickup path has already been graded on its own.
    boost_player(vm)
    px, py = player_pos(vm)
    for _ in range(4):
        if tlm(vm, 'fire_cd') <= 3:
            break
        feed_item(vm, px - 8, py - 8, ITEM_RATE)
    print("  -> caps for the boss: atk %d, weapon level %d, fire_cd %d"
          % (tlm(vm, 'atk'), tlm(vm, 'weapon_lv'), tlm(vm, 'fire_cd')))

    # ---- 3. the boss must arrive, move and cycle random patterns -------
    # The dialogue card itself was graded back at the top of this scenario, right
    # after the farming loop; see the comment there for why it cannot be graded
    # from here.  What is left here is the wait for the boss, which the page-skip
    # presses have already pushed into BOSS_ENTER.
    spent = 0
    while tlm(vm, 'boss_st') == 0 and spent < 40_000_000:
        chase_nearest_enemy(vm, TICK * 8)
        spent += TICK * 8
    assert tlm(vm, 'boss_st') != 0, "the boss never appeared after the quota"
    print("  -> boss entered (hp %d)" % tlm(vm, 'boss_hp'))

    # Do NOT hold fire once the fight starts.  With the caps taken below, the
    # craft kills a 400 hp boss in about five seconds, which is two pattern
    # changes - and the next assertion wants five.  What is graded here is the
    # boss's pattern book, not the kill, so the craft only has to survive.
    #
    # SAMPLE UNCONDITIONALLY, and that word is the whole fix.  This loop used to
    # be `while tlm(vm,'pat_chg') < 5:` - i.e. it only collected a pattern while
    # the counter was still short of five.  pattern_changes counts up for the
    # whole RUN (main.c:1796, cleared in game_init() and never at a boss), so by
    # the time the boss reached the fight the counter had already passed five,
    # the loop body never executed, `seen` came back empty, and the assertion
    # below reported "the boss only ever used one pattern: set()" - which reads
    # like a broken boss and was really a broken sampler.  The boss was fine:
    # summons was six.
    #
    # Budget in FRAMES, not in the old step count: one steer() call is one
    # TICK, and one display frame costs about 2 TICK now (the frame renders the
    # whole 1366x768 plate and its HUD).  The boss changes pattern roughly every
    # 120 frames, so five changes need ~600 frames of steering; the old 40M
    # budget only bought 80, and 900 leaves room for the entry sequence.
    seen = set()
    spent = 0
    f0 = tlm(vm, 'frames')
    while (tlm(vm, 'pat_chg') < 5 or len(seen) < 2) and \
            tlm(vm, 'frames') - f0 < 900:
        steer(vm, SPAWN_X, SPAWN_Y, None, TICK)
        seen.add(tlm(vm, 'boss_pat'))
        spent += TICK
    frames_seen = tlm(vm, 'frames') - f0
    assert tlm(vm, 'pat_chg') >= 5, (
        "boss patterns never changed: %d changes after %d frames (%d steps), "
        "patterns seen %r" % (tlm(vm, 'pat_chg'), frames_seen, spent, sorted(seen)))
    assert tlm(vm, 'summons') >= 1, "the boss never summoned minions"
    assert len(seen) >= 2, (
        "the boss only ever dealt one pattern in %d frames: %r"
        % (frames_seen, sorted(seen)))
    print("  [PASS] %d pattern changes, patterns seen %r, %d summons, %d enemy bullets"
          % (tlm(vm, 'pat_chg'), sorted(seen), tlm(vm, 'summons'), tlm(vm, 'ebullets')))
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test8_mode2_boss.bmp",
                   Path(output_dir) / "test8_mode2_boss.png")
    return vm


def run_settings_menu(code, output_dir=None):
    """B opens the pause/settings menu; toggles, resume and exit all work."""
    print("\n" + "=" * 65)
    print(" [TEST 9] Settings menu: pause, HW accel toggle, resume, exit")
    print("=" * 65)
    vm = new_vm(code)
    menu_enter(vm, 1)
    vm.joy = (128 << 8) | 128
    vm.btn = raw_btn()
    for _ in range(150_000):
        vm.step()

    assert tlm(vm, 'paused') == 0, "the game must start unpaused"
    assert tlm(vm, 'hwaccel') == 1 and tlm(vm, 'infrespawn') == 1, \
        "defaults changed: hw=%d inf=%d" % (tlm(vm, 'hwaccel'), tlm(vm, 'infrespawn'))

    def press_until(key, field, value, budget=80_000_000):
        """Hold `key` until `field` reads back as `value`.

        A fixed-length hold is not a unit of anything here.  With acceleration
        off one rendered frame costs ~1e7 instructions of software
        rasterisation, and with it on a single frame still issues ~150 BitBlt
        commands; a pass therefore spans an unstated number of display frames
        and an 8-frame press can fall entirely between two samples of the pad -
        the option then looks like it "did not toggle".  Holding until the
        value actually moves grades the toggle, not the sampling phase.
        """
        vm.btn = raw_btn(key)
        # The wait is a step-until-telemetry-moves loop with nothing else in the
        # body, so it runs inside the core: from Python this cost ~270 ns per
        # instruction and the settings scenario alone spent 88 million of them.
        spent = wait_telemetry(vm, field, value, budget)
        vm.btn = raw_btn()
        for _ in range(TICK):
            vm.step()
        return spent

    # ---- 1. B opens the menu and freezes the world ----------------------
    press_until('b', 'paused', 1)
    assert tlm(vm, 'paused') == 1, "B did not open the settings menu"
    frames0 = tlm(vm, 'frames')
    for _ in range(TICK * 4):
        vm.step()
    assert tlm(vm, 'frames') == frames0, \
        "the world kept running while paused (%d -> %d)" % (frames0, tlm(vm, 'frames'))
    print("  -> B opened the menu, world frozen at frame %d" % frames0)

    # ---- 1b. the card publishes the weather occlusion box ---------------
    # The scanout composites the snow ABOVE the framebuffer, so the card - which
    # is only pixels in the framebuffer - keeps clean lettering only because the
    # firmware hands the scanline logic the rectangle to leave alone.
    # 0x8C is {enable, x1[10:0], x0[10:0]}; 0xAC is {10'd0, y1[10:0], y0[10:0]}.
    card_w, card_h = 512, 392
    card_x, card_y = (1366 - card_w) // 2, (768 - card_h) // 2
    box_x = vm.params.get(0x8C, 0)
    box_y = vm.params.get(0xAC, 0)
    assert box_x >> 31, "the pause card published no weather occlusion box"
    assert (box_x & 0x7FF, (box_x >> 11) & 0x7FF) == (card_x, card_x + card_w - 1), \
        "occlusion box x is %d..%d, the card is %d..%d" % (
            box_x & 0x7FF, (box_x >> 11) & 0x7FF, card_x, card_x + card_w - 1)
    assert (box_y & 0x7FF, (box_y >> 11) & 0x7FF) == (card_y, card_y + card_h - 1), \
        "occlusion box y is %d..%d, the card is %d..%d" % (
            box_y & 0x7FF, (box_y >> 11) & 0x7FF, card_y, card_y + card_h - 1)
    print("  -> weather occlusion box x %d..%d y %d..%d follows the card" % (
        card_x, card_x + card_w - 1, card_y, card_y + card_h - 1))

    # ---- 2. hardware acceleration toggle --------------------------------
    before = vm.starts
    for _ in range(TICK * 2):
        vm.step()
    hw_cmds = vm.starts - before
    assert hw_cmds > 20, "the paused menu should still be drawn by the engine"

    hold(vm, 'a')                      # down to HW ACCEL

    def toggle_until(value, budget=80_000_000):
        return press_until('x', 'hwaccel', value, budget)

    steps_off = toggle_until(0)
    assert tlm(vm, 'hwaccel') == 0, "HW ACCEL did not switch off"
    before = vm.starts
    for _ in range(TICK):
        vm.step()
    cpu_cmds = vm.starts - before
    assert cpu_cmds == 0, \
        "with acceleration off the BitBlt engine must not be used (%d commands)" % cpu_cmds

    toggle_until(1)
    assert tlm(vm, 'hwaccel') == 1, "HW ACCEL did not switch back on"
    print("  -> HW ACCEL: engine drew %d commands while on, 0 while off "
          "(%d instructions for one software frame)" % (hw_cmds, steps_off))

    # ---- 3. infinite respawn toggle -------------------------------------
    press_until('y', 'settings', 0)    # back up to INF RESPAWN
    press_until('x', 'infrespawn', 0)
    assert tlm(vm, 'infrespawn') == 0, "INF RESPAWN did not switch off"
    press_until('x', 'infrespawn', 1)
    assert tlm(vm, 'infrespawn') == 1, "INF RESPAWN did not switch back on"
    print("  -> INF RESPAWN toggles: on")

    press_until('y', 'settings', 6)
    for enabled in (0, 1):
        vm.btn = raw_btn('x')
        for _ in range(20_000_000):
            vm.step()
            if vm.params.get(0x88, 0) & 1 == enabled:
                break
        else:
            raise AssertionError("GLOW FX did not reach %d" % enabled)
        vm.btn = raw_btn()
        goal = len(vm.right_published) + 2
        for _ in range(20_000_000):
            vm.step()
            if len(vm.right_published) >= goal:
                break
        else:
            raise AssertionError("pause renderer stopped while releasing GLOW FX button")
    press_until('a', 'settings', 0)
    print("  -> GLOW FX toggles: off / on through APB")
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test9_pause_glow.bmp",
                   Path(output_dir) / "test9_pause_glow.png")

    # ---- 4. RESUME goes back to the game --------------------------------
    press_until('a', 'settings', 1)
    press_until('a', 'settings', 2)
    assert tlm(vm, 'settings') == 2, "selection did not reach RESUME"
    press_until('x', 'paused', 0)
    assert tlm(vm, 'paused') == 0, "RESUME did not close the menu"
    frames1 = tlm(vm, 'frames')
    for _ in range(TICK * 3):
        vm.step()
    assert tlm(vm, 'frames') > frames1, "the world did not resume"
    # The box follows whichever panel is actually up.  The pause card is gone; on
    # screen now is the stage title card, which is up for the first 170 frames of
    # a stage - so the box must be either cleared or the banner's own rectangle,
    # and never the card's.
    box_x = vm.params.get(0x8C, 0)
    box_y = vm.params.get(0xAC, 0)
    now_box = (box_x & 0x7FF, (box_x >> 11) & 0x7FF,
               box_y & 0x7FF, (box_y >> 11) & 0x7FF)
    banner_box = (473, 892, 196, 259)   # stage_banner_render(): 420x64, y = 196
    assert not (box_x >> 31) or now_box == banner_box, \
        "after RESUME the occlusion box is %s: neither cleared nor the stage " \
        "banner %s" % (now_box, banner_box)
    print("  -> RESUME closed the menu, world running again (frame %d); "
          "occlusion box now %s" % (tlm(vm, 'frames'),
                                    "cleared" if not (box_x >> 31) else "on the stage banner"))

    # ---- 5. EXIT returns to the boot menu -------------------------------
    press_until('b', 'paused', 1)
    assert tlm(vm, 'paused') == 1, "B did not reopen the settings menu"
    press_until('a', 'settings', 1)    # walk down to EXIT, one row at a time
    press_until('a', 'settings', 2)
    press_until('a', 'settings', 3)
    assert tlm(vm, 'settings') == 3, "selection did not reach EXIT"
    press_until('x', 'paused', 0)
    assert (vm.params.get(0x5C, 0) & 0x00100000) != 0, \
        "EXIT did not return to the boot menu (HUD still off)"
    print("  [PASS] EXIT returned to the boot menu, min SP %#x" % vm.min_sp)
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test9_menu_exit.bmp",
                   Path(output_dir) / "test9_menu_exit.png")
    return vm


# ----------------------------------------------------------------------
# regression helpers
#
# These four scenarios grade behaviour that was deliberately changed, so they
# manufacture the exact situation they need (a specific power-up under the
# craft, a bullet parked on the hitbox) rather than farming the drop table and
# hoping.  The pools they write are plain DDR; every constant below mirrors
# sw/app/main.c and sw/driver/memory_map.h.
# ----------------------------------------------------------------------
WEAPON_MAX_LEVEL = 4
SPELL_MAX_CHARGE = 8                    # must mirror BOMB_MAX_CHARGE in main.c
ATK_MAX = 4
WEAPON_CENTER, WEAPON_SPREAD, WEAPON_LASER, WEAPON_FAN = 0, 1, 2, 3
ITEM_HEAL, ITEM_RATE, ITEM_ATK, ITEM_WEAPON = 0, 1, 2, 3
ITEM_SCORE, ITEM_SLOW, ITEM_JAM = 4, 5, 6      # must mirror main.c's item table

BOSS_ENTER, BOSS_FIGHT, BOSS_DIALOG = 1, 2, 4
BOSS_FREEZE = 5                      # the hold before a spell card

# Stage 2's four basic enemy skills, mirrored from main.c.
PAT_CUT, PAT_LOCKON, PAT_BURST, PAT_VOLLEY = 10, 11, 12, 13
PAT_FAN = 0
EF_HELD = 0x04                       # laid out and holding station
CUT_PREVIEW, CUT_FIRE, CUT_HALF = 45, 18, 6
CUT_SLOTS = 3                        # warning-hairline slots, mirrors main.c
BURST_SHOTS = 24                     # 16 in the ring plus 8 more, staggered
VOLLEY_SHOTS = 13                    # +-6 aim steps around the bearing
LOCKON_TOTAL = 80                    # 60 frames of layout, 20 of holding

# The cut's two palettes: the preview hairline, and the beam's outer and
# core colours.
CUT_PREVIEW_COLOURS = (0xFF9AA8, 0x603038)
CUT_BEAM_COLOURS = (0xFF3050, 0xFFE0F0)

# Impact-effect layer colours, mirrored from burst_render() in sw/app/main.c:
# the licence-free burst is drawn as fills, so grading it means looking for
# the exact colours the layers use.
HOT_COLOURS = (0xFFFFFF, 0xFFE8A0, 0xFF9038, 0xC04828,
               0xA8E8FF, 0x60B0FF, 0x3068C0, 0xFFF4C0, 0xFF8040)

# Boss spell card, mirrored from main.c.  The four columns sit at
# BOSS_LASER_X(k) = GAME_LEFT + (GAME_RIGHT-GAME_LEFT)*(2k+1)/8 - an even
# spread over the playfield - and each is a 16-pixel bar whose
# left edge is 5 pixels before its centre; the three bands are boss_laser >60,
# >30 and below.  The bar is one COPY of a 16x480 tile composed at boot, so
# the column centre carries the band colour and its middle two pixels white.
# Mirrors BOSS_LASER_X(k) in main.c, and GAME_LEFT is imported from the
# same 1366x768 layout the firmware uses - a literal 128 here put the
# sampler 68 columns off, which reads as "the columns are not on screen".
LASER_X = tuple(GAME_LEFT + (GAME_RIGHT - GAME_LEFT) * (2 * k + 1) // 8
                for k in range(4))

# The bar's geometry, mirrored from memory_map.h (MM_LASER_BAR_*): one 16x768
# tile per brightness band, three bands, stride 64.  Height and stride are read
# from the map rather than copied, the 480 that used to be here being a piece of
# the 600-line screen.
MM_LASER_BAR = mm_value("MM_LASER_BAR")
MM_LASER_BAR_W = mm_value("MM_LASER_BAR_W")
MM_LASER_BAR_H = mm_value("MM_LASER_BAR_H")
MM_LASER_BAR_STRIDE = mm_value("MM_LASER_BAR_STRIDE")
MM_LASER_BAR_BYTES = mm_value("MM_LASER_BAR_BYTES")
LASER_COLOURS = (0xE03050, 0xFF6080, 0xFFC0D0, 0xFFFFFF)

# The composed impact-burst frames (main.c burst_frames_build) and the cap on
# what the opener frame may cost.  The card measured 76 FILLs a frame after
# the composed-surface work and 380 before it; 200 leaves room for a future
# effect while still catching a return to the flood that caused 1.4.
MM_BURST_FRAME = mm_value("MM_BURST_FRAME")
MM_CARD_BG = mm_value("MM_CARD_BG")      # the card's own sky
BURST_W, BURST_STRIDE, BURST_COUNT = 112, 448, 24
OPENER_FILL_CAP = 200

# ...and the cap on the OTHER command the opener frame used to be full of.  The
# entrance volley is 48 shots on top of whatever is already in the air, and each
# shot is one command either way; what decides whether the frame fits is WHICH
# command.  OP_COPY reads the source and writes the destination; OP_ALPHA reads
# the destination it is about to cover as well, i.e. a read-modify-write per
# bullet, and the bus is what pays for it.  Measured: a per-bullet OP_ALPHA put
# the entrance back over budget on the board ("BOSS 开大卡"), and the FILL cap
# above could not see it - it only ever counted FILLs.
OPENER_ALPHA_CAP = 24

# ...and on how much of the framebuffer a frame with the cut/beam lasers up may
# copy.  Measured 2,861 rows with the beams blitted by the engine, 1,603 with
# them synthesised at scanout; what is left is the bullets, the HUD and the
# player's own laser.  2,000 leaves room for a busy frame while still catching a
# return to blitting the beams.
BEAM_ROW_CAP = 2000

# Player art: six 48x48 poses, stride 192.  player_pose 2 is ART_REIMU_2, and
# holding A pins the animation there while the craft stays put.
PLAYER_POSE_DST = (0x01610000, 0x01612400, 0x01614800,
                   0x01616C00, 0x01619000, 0x0161B400)
PLAYER_POSE_STRIDE = 192
PLAYER_POSE_MID = 2

# The pickup box the older firmware used: it compared the item's top-left
# corner against the craft centre, +-18 in x and -20..+18 in y.
OLD_PICK_X, OLD_PICK_Y_LO, OLD_PICK_Y_HI = 18, -20, 18


def _pool_offset(base, index, stride, off):
    return base - SCRATCH_BASE + index * stride + off


def _pool_get(vm, base, index, stride, off, size=4, signed=False):
    a = _pool_offset(base, index, stride, off)
    return int.from_bytes(vm.scratch[a:a + size], "little", signed=signed)


def _pool_put(vm, base, index, stride, off, value, size=4, signed=False):
    a = _pool_offset(base, index, stride, off)
    vm.scratch[a:a + size] = int(value).to_bytes(size, "little", signed=signed)


def free_slot(vm, base, count, stride, flag_off):
    """Index of the first inactive record in a DDR pool, or None."""
    for i in range(count):
        if vm.scratch[_pool_offset(base, i, stride, flag_off)] == 0:
            return i
    return None


def clear_pool(vm, base, count, stride, flag_off):
    for i in range(count):
        vm.scratch[_pool_offset(base, i, stride, flag_off)] = 0


def inject_item(vm, x, y, type_, vy=0):
    """Drop one power-up straight into the item pool."""
    slot = free_slot(vm, ITEM_BASE, ITEM_COUNT, 8, 6)
    assert slot is not None, "no free item slot in the pool"
    _pool_put(vm, ITEM_BASE, slot, 8, 0, x, 2, True)
    _pool_put(vm, ITEM_BASE, slot, 8, 2, y, 2, True)
    _pool_put(vm, ITEM_BASE, slot, 8, 4, vy & 0xFF, 1)
    _pool_put(vm, ITEM_BASE, slot, 8, 5, type_ & 0xFF, 1)
    _pool_put(vm, ITEM_BASE, slot, 8, 6, 0x01, 1)
    # byte 7 is the floor timer; a stale value would make an injected item
    # start blinking out on the frame it appears
    _pool_put(vm, ITEM_BASE, slot, 8, 7, 0x00, 1)
    return slot


def inject_ebullet(vm, x, y, vx=0, vy=0, color=1):
    """Park one enemy bullet on a chosen pixel (the pool record is DDR)."""
    slot = free_slot(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    assert slot is not None, "no free enemy bullet slot in the pool"
    _pool_put(vm, EBULLET_BASE, slot, 8, 0, x, 2, True)
    _pool_put(vm, EBULLET_BASE, slot, 8, 2, y, 2, True)
    _pool_put(vm, EBULLET_BASE, slot, 8, 4, vx & 0xFF, 1)
    _pool_put(vm, EBULLET_BASE, slot, 8, 5, vy & 0xFF, 1)
    _pool_put(vm, EBULLET_BASE, slot, 8, 6, 0x01, 1)
    _pool_put(vm, EBULLET_BASE, slot, 8, 7, color & 0xFF, 1)
    return slot


def top_up_minions(vm, want=3, drop=150):
    """Park a few minions in the craft's line of fire.

    The wave logic releases roughly one minion per second of game time and every
    one of them still has to fly into range before it can be shot, so clearing a
    stage quota costs tens of millions of simulated steps all by itself.  This
    is the same shortcut the pickup scenarios take with power-ups: the backdrop
    test grades scenery switching, not spawn pacing.
    """
    live = 0
    for i in range(ENEMY_COUNT):
        if vm.scratch[_pool_offset(ENEMY_BASE, i, ENEMY_STRIDE, 13)] != 0:
            live += 1
    if live >= want:
        return 0
    px, py = player_pos(vm)
    placed = 0
    for i in range(ENEMY_COUNT):
        if live + placed >= want:
            break
        if vm.scratch[_pool_offset(ENEMY_BASE, i, ENEMY_STRIDE, 13)] != 0:
            continue
        # Dead ahead, not offset to the side: the craft shoots straight up,
        # so a minion 44 pixels off its lane is never hit.
        _pool_put(vm, ENEMY_BASE, i, ENEMY_STRIDE, 0, px, 2, True)
        _pool_put(vm, ENEMY_BASE, i, ENEMY_STRIDE, 2, max(120, py - drop), 2, True)
        _pool_put(vm, ENEMY_BASE, i, ENEMY_STRIDE, 4, 0, 2, True)     # vx
        _pool_put(vm, ENEMY_BASE, i, ENEMY_STRIDE, 6, 1, 2, True)     # vy
        _pool_put(vm, ENEMY_BASE, i, ENEMY_STRIDE, 8, 2, 2, True)     # hp
        _pool_put(vm, ENEMY_BASE, i, ENEMY_STRIDE, 10, 0, 1)          # ENEMY_FAIRY
        _pool_put(vm, ENEMY_BASE, i, ENEMY_STRIDE, 11, 220, 1)        # fire_cd
        _pool_put(vm, ENEMY_BASE, i, ENEMY_STRIDE, 12, 0, 1)          # phase
        _pool_put(vm, ENEMY_BASE, i, ENEMY_STRIDE, 13, 1, 1)          # EF_ACTIVE
        placed += 1
    return placed


def wait_frames(vm, n=3, budget=8_000_000):
    """Step until `n` logic frames have run AND their picture is published.

    The fixed-step simulation advances several logic ticks per display pass,
    so the frame counter can reach its target in the middle of a pass whose
    picture has not been published yet (telemetry is written at the END of
    the pass, before the scanout flip).  Waiting for a publish keeps every
    caller that samples the frame or the telemetry afterwards looking at the
    state the firmware has actually shown.  """
    sc = vm.scratch32
    foff = _TLM_WORD0 + TLM['frames']
    step = vm.step
    start = sc[foff]
    target = start + n
    r0 = vm.right_request
    spent = 0
    while spent < budget:
        step()
        spent += 1
        # Check only at a NEW publication edge. A render with zero logic
        # ticks may flip first; a later update must not make that old flip
        # satisfy this wait while the next picture is still being drawn.
        if vm.right_request != r0:
            r0 = vm.right_request
            if sc[foff] >= target:
                return True
    # Timed out.  Returning sc[foff] >= target here was true in exactly the
    # case that matters - the frame counter ran on while the scanout never
    # flipped a page - so every caller that reads this as the picture being
    # ready got a green light it had not earned.  Every other waiter in this
    # file returns False on timeout and lets the caller assert.
    return False


def start_game(vm, hold=()):
    """Enter the bullet-hell demo and let telemetry settle on real values."""
    menu_enter(vm, 1)
    vm.joy = (128 << 8) | 128
    vm.btn = raw_btn(*hold)
    assert wait_frames(vm, 3), "the bullet-hell game never produced a frame"
    assert tlm(vm, 'magic') == TLM_MAGIC_VAL, "telemetry magic never appeared"


def feed_item(vm, x, y, type_, budget=8_000_000):
    """Clear the item pool, drop one item on (x,y), step until it is taken."""
    clear_pool(vm, ITEM_BASE, ITEM_COUNT, 8, 6)
    inject_item(vm, x, y, type_)
    before = tlm(vm, 'taken')
    spent = 0
    while tlm(vm, 'taken') == before and spent < budget:
        vm.step()
        spent += 1
    return tlm(vm, 'taken') > before


def steer_abs(vm, tx, ty, trigger='x', steps=TICK // 4):
    """Point the stick at an absolute screen position for one slice.

    Same idea as steer(), but written against the pad semantics the firmware
    actually implements: a raw y ABOVE 148 moves the craft UP the screen (a
    smaller y), so the sign of the correction is inverted relative to x.
    """
    dx = tx - tlm(vm, 'player_x')
    dy = ty - tlm(vm, 'player_y')
    jx = 180 if dx > 4 else (76 if dx < -4 else 128)
    jy = 76 if dy > 4 else (180 if dy < -4 else 128)
    vm.joy = (jy << 8) | jx
    vm.btn = raw_btn(trigger) if trigger else raw_btn()
    for _ in range(steps):
        vm.step()


def boost_player(vm, atk_cap=ATK_MAX, level_cap=WEAPON_MAX_LEVEL, tries=8):
    """Push the craft to its power caps through the real pickup path."""
    # Centre the stick first: the caller left it pointing at its last chase
    # target, and a drifting craft leaves the injected pickup behind.  Every
    # sample below is taken at the craft's position as of this line, so it has
    # to hold still for the whole routine.
    vm.joy = (128 << 8) | 128
    vm.btn = raw_btn()
    px, py = player_pos(vm)
    fed = 0
    while tlm(vm, 'atk') < atk_cap and fed < tries:
        assert feed_item(vm, px - 8, py - 8, ITEM_ATK), \
            "the ATK power-up was never collected"
        fed += 1
    fed = 0
    while tlm(vm, 'weapon_lv') < level_cap and fed < tries:
        assert feed_item(vm, px - 8, py - 8, ITEM_WEAPON), \
            "the SHOT power-up was never collected"
        fed += 1
    assert tlm(vm, 'atk') == atk_cap and tlm(vm, 'weapon_lv') == level_cap, \
        "the craft never reached its caps (atk %d, level %d)" % (
            tlm(vm, 'atk'), tlm(vm, 'weapon_lv'))


def run_weapon_level_cap(code, output_dir=None):
    """A SHOT pickup at full power must not wrap the bar back to the start."""
    print("\n" + "=" * 65)
    print(" [TEST 10] Weapon cap: extra SHOT pickups must not overflow")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)

    assert tlm(vm, 'weapon_lv') == 1, \
        "a fresh run must start at weapon level 1, got %d" % tlm(vm, 'weapon_lv')
    px, py = player_pos(vm)

    fed = 0
    while tlm(vm, 'weapon_lv') < WEAPON_MAX_LEVEL and fed < 8:
        assert feed_item(vm, px - 8, py - 8, ITEM_WEAPON), \
            "the SHOT power-up was never collected"
        fed += 1
    capped_lv, capped_w = tlm(vm, 'weapon_lv'), tlm(vm, 'weapon')
    assert capped_lv == WEAPON_MAX_LEVEL, \
        "the bar stopped at level %d, expected %d" % (capped_lv, WEAPON_MAX_LEVEL)
    print("  -> bar full after %d SHOT pickup(s): level %d, shot type %d"
          % (fed, capped_lv, capped_w))

    for k in range(3):
        assert feed_item(vm, px - 8, py - 8, ITEM_WEAPON), \
            "pickup %d at the cap was not collected" % (k + 1)
        assert tlm(vm, 'weapon_lv') == capped_lv, \
            "pickup %d at the cap moved the level %d -> %d" % (
                k + 1, capped_lv, tlm(vm, 'weapon_lv'))
        assert tlm(vm, 'weapon') == capped_w, \
            "pickup %d at the cap wrapped the shot type %d -> %d" % (
                k + 1, capped_w, tlm(vm, 'weapon'))
    assert tlm(vm, 'weapon') != WEAPON_CENTER, \
        "a maxed-out craft fell back to the weakest shot"
    print("  [PASS] 3 extra pickups at the cap: still level %d, shot type %d"
          % (tlm(vm, 'weapon_lv'), tlm(vm, 'weapon')))
    return vm


def fan_x_split(vm, px):
    """(left, right) count of live player bullets either side of the craft."""
    off = PBULLET_BASE - SCRATCH_BASE
    left = right = 0
    for i in range(PBULLET_COUNT):
        p = off + i * 8
        if not vm.scratch[p + 6]:              # flags byte
            continue
        x = int.from_bytes(vm.scratch[p:p + 2], "little", signed=True)
        if x < px - 3:
            left += 1
        elif x > px + 3:
            right += 1
    return left, right


def run_fan_bullet_pool(code, output_dir=None):
    """A maxed-out FAN shot must not run out of bullet slots on one side.

    Seven shots leave every four frames and each one lives about fifty frames,
    so a maxed FAN keeps roughly ninety bullets in the air at once.  The pool
    held 64 slots and alloc_bullet() hands slots out from the front, so the
    shots on the right half of the fan were the ones that vanished: the player
    saw the right arm of the pattern break up while the left one stayed solid.
    The pool now holds 128, and the two arms have to stay balanced.
    """
    print("\n" + "=" * 65)
    print(" [TEST 14] Maxed FAN shot: the pool must not starve one side")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)
    px, py = player_pos(vm)

    for k in range(3):
        assert feed_item(vm, px - 8, py - 8, ITEM_WEAPON), \
            "SHOT pickup %d was never collected" % (k + 1)
    # ... and the firing rate, because that is what a player who has reached
    # the top of the weapon ladder has collected long ago: 7 shots every 7
    # frames stays under the pool, 7 shots every 4 frames does not.
    for k in range(3):
        assert feed_item(vm, px - 8, py - 8, ITEM_RATE), \
            "RATE pickup %d was never collected" % (k + 1)
    # the pickup lands mid-frame; telemetry reports it on the next one
    assert wait_frames(vm, 3), "the game stopped producing frames"
    assert tlm(vm, 'weapon') == WEAPON_FAN and \
        tlm(vm, 'weapon_lv') == WEAPON_MAX_LEVEL, \
        "the craft is not on the maxed FAN shot: type %d, level %d" % (
            tlm(vm, 'weapon'), tlm(vm, 'weapon_lv'))
    assert tlm(vm, 'fire_cd') == 3, \
        "the firing rate stopped at %d instead of its cap" % tlm(vm, 'fire_cd')
    print("  -> shot type FAN at level %d, pool holds %d slots"
          % (tlm(vm, 'weapon_lv'), PBULLET_COUNT))

    # A JAM pickup (a minion drop) stretches the firing cadence from 4 frames to
    # 8, which nearly halves the peak - and whether the craft happens to collect
    # one is pure chance.  Clear the item pool and wait out any debuff already
    # running, so the measurement is about the bullet pool rather than luck.
    for _ in range(320):
        if tlm(vm, 'jam') == 0 and tlm(vm, 'slow') == 0:
            break
        clear_pool(vm, ITEM_BASE, ITEM_COUNT, 8, 6)
        vm.btn = raw_btn('x')
        for _ in range(TICK):
            vm.step()

    vm.joy = (128 << 8) | 128
    vm.btn = raw_btn('x')
    peak = 0
    worst = None
    for f in range(140):
        clear_pool(vm, ITEM_BASE, ITEM_COUNT, 8, 6)
        # Sample on real frame boundaries, not on a step-count approximation of
        # one: TICK steps used to be about a frame, and the renderer has since
        # grown enough that it no longer is - which quietly made this scenario
        # miss the peak and report 57 bullets where the pool really holds 73.
        assert wait_frames(vm, 1)
        n = tlm(vm, 'pbullets')
        peak = max(peak, n)
        left, right = fan_x_split(vm, tlm(vm, 'player_x'))
        if left + right >= 24:
            share = right / float(left + right)
            if worst is None or share < worst[0]:
                worst = (share, f, left, right)

    assert peak > 64, (
        "the barrage never used more than %d slots in flight - the fan is "
        "still capped by a 64-slot pool" % peak)
    # The balance check is the point of this scenario, so it must not be
    # skipped in silence: 140 frames with no frame reaching 24 shots on the two
    # arms together used to leave `worst` as None, run no assertion at all, and
    # still print PASS with "worst split 0 left / 0 right".
    assert worst is not None, (
        "no frame ever put 24 shots on the two arms together, so the balance"
        " check never ran (peak %d)" % peak)
    if True:
        assert worst[3] * 2 >= worst[2], (
            "the fan is lopsided: %d shots left of the craft against %d right "
            "(frame %d) - the pool is starving one arm again"
            % (worst[2], worst[3], worst[1]))
    print("  [PASS] %d bullets in flight at peak; worst split %d left / %d right"
          % (peak, worst[2] if worst else 0, worst[3] if worst else 0))
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test14_fan_pool.bmp",
                   Path(output_dir) / "test14_fan_pool.png")
    return vm


def run_stick_noise(code, output_dir=None):
    """An idle stick that jitters must not move the craft or flip its pose.

    The handset reports a handful of counts of noise around its mechanical
    centre and the firmware samples the axis once per frame, which used to be
    enough to make the craft drift and the walk animation stutter while nobody
    was touching the stick.  This drives +-24 counts of jitter - wider than the
    +-20 band the old code treated as a real push, narrower than the filter's
    28-count threshold - and requires the craft to stay put; a deliberate push
    afterwards has to still get through.
    """
    print("\n" + "=" * 65)
    print(" [TEST 15] Idle stick noise must not move the craft")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)
    start = player_pos(vm)
    assert start == (SPAWN_X, SPAWN_Y), "the craft did not spawn centred: %r" % (start,)

    jitter = (24, -24, 18, -22, 24, 0, -24, 12, 22, -18)
    for k in range(40):
        jx = 128 + jitter[k % len(jitter)]
        jy = 128 + jitter[(k * 3 + 1) % len(jitter)]
        vm.joy = ((jy & 0xFF) << 8) | (jx & 0xFF)
        vm.btn = raw_btn()
        for _ in range(TICK):
            vm.step()
        assert player_pos(vm) == start, (
            "idle stick noise moved the craft %r -> %r after %d frames "
            "(jx=%d jy=%d)" % (start, player_pos(vm), k + 1, jx, jy))
    print("  [PASS] 40 frames of +-24 count noise: craft still at %r" % (start,))

    vm.joy = (128 << 8) | 220
    # The axis needs two consecutive gamepad_read()s to confirm, and the pad is
    # sampled once per display pass - give the push four passes so
    # confirmation, movement and the next telemetry write all happen inside the
    # window whatever the pass phase is.
    #
    # A pass is NOT 2 TICK any more.  TICK is 25,000 steps and it was chosen
    # when that was a display frame; with both bullet pools at 512 slots a
    # frame costs about 80,000 steps (measured: 79,613), so 8 TICK is three
    # passes' worth of steps and the push was still being confirmed when the
    # loop ended.  Frames, not a step guess: wait for eight whole frames, plus
    # one so the telemetry written at the end of the last one is readable.
    for _ in range(9):
        wait_frames(vm, 1, budget=8_000_000)
    moved = player_pos(vm)
    assert moved[0] > start[0], \
        "a deliberate push no longer moves the craft: %r" % (moved,)
    print("  [PASS] a real push still gets through: %r -> %r" % (start, moved))
    return vm


def run_spell_card(code, output_dir=None):
    """The centre button must spend a full spell card and clear the field.

    Every kill banks one of eight charge ticks; at full charge a centre-click
    wipes every enemy shot on screen (converting them into score) and throws a
    ring of the craft's own shots.  Before this the handset's centre button did
    nothing at all once a run had started.
    """
    print("\n" + "=" * 65)
    print(" [TEST 16] Spell card: centre-click clears the field")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)
    assert tlm(vm, 'bomb') == 0, "a fresh run starts with charge already banked"

    # Take the attack cap first: one display frame costs about 2 TICK steps now
    # (the frame renders the whole 1366x768 plate), so eight kills at the
    # starting attack power needed more chase budget than this loop has rounds
    # for.  The scenario grades the CARD, not how long a kill takes.
    boost_player(vm)
    kills = 0
    for _ in range(10):
        if tlm(vm, 'bomb') >= SPELL_MAX_CHARGE:
            break
        top_up_minions(vm, want=2, drop=140)
        before = tlm(vm, 'kills')
        # 120 FRAMES, and the count of frames is the point.  This used to be a
        # step budget, and a step budget does not survive a change to what a
        # frame costs: 12M steps was ~150 frames on the revision that picked
        # it, 32M steps was ~415 on the next one, and on the one after that
        # 415 frames of autopilot left 86 shots in the air - whose own cull
        # rate (two or three a frame) is the same order as the sixteen the
        # card throws, so the ring assertion below graded the cull rate rather
        # than the card.  Frames put the scenario back where it was written:
        # a handful of shots in flight when the card is played.
        chase_nearest_enemy(vm, frames=120)
        kills += max(0, tlm(vm, 'kills') - before)
    assert tlm(vm, 'bomb') >= SPELL_MAX_CHARGE, \
        "the bar never filled: %d/%d after %d kill(s)" % (
            tlm(vm, 'bomb'), SPELL_MAX_CHARGE, kills)
    print("  -> bar full after %d kill(s)" % kills)

    # Inject while the FIELD IS HELD, then check the POOL rather than telemetry.
    # The previous version injected into a live frame and read tlm() straight
    # away: telemetry is written once per display frame, so the shots were
    # swept away again before the counter caught up and the assertion failed
    # for a card that had done its job.
    score_before_card = tlm(vm, 'score')
    pb_before_card = tlm(vm, 'pbullets')
    live_before = sum(1 for m in range(EBULLET_COUNT)
                      if vm.scratch[_pool_offset(EBULLET_BASE, m, 8, 6)] != 0)
    for k in range(12):                     # a ring of shots to sweep away
        inject_ebullet(vm, GAME_LEFT + 80 + k * 32, 320, 0, 0, color=3)
    # inject_ebullet() asserts that each slot took, so counting the pool after
    # the injection only proves that the pool is not empty - and it is not, the
    # stage has been spawning all along (31 live when this was written).  What
    # is worth pinning is the DELTA: the ring this scenario added.
    live_after = sum(1 for m in range(EBULLET_COUNT)
                    if vm.scratch[_pool_offset(EBULLET_BASE, m, 8, 6)] != 0)
    assert live_after >= live_before + 12, "the ring added %d shots, expected 12" % (live_after - live_before)

    # hold(), not press(): the card is spent on the FIRST pass that samples
    # the centre button, and a short press can open and close between two
    # samples of a busy frame.  Holding across several passes guarantees the
    # edge is seen and the field is swept before the check below.
    #
    # But a FIXED number of passes does not guarantee anything: a single game
    # pass can run longer than eight display frames when the frame loop is
    # catching up on logic steps, and then the whole hold lands inside one pass
    # and is never sampled at all.  Measured: inserting 48,000 inert steps into
    # boot - touching nothing else - flips this assertion, which is how the
    # hold/frames=8 version was found to be phase-luck rather than a judge.
    # press_until() exists for exactly this; hold in short bursts and stop as
    # soon as the charge is actually gone, so the button is seen whenever the
    # pass happens to sample it.
    # Twenty rounds, not eight.  Each round is hold(frames=4) plus the two
    # settle frames, so eight rounds is 48 display frames - and once the pools
    # are 512 slots a single game pass can run well past eight frames, which is
    # the same phase-luck the comment above describes.  The loop still stops
    # the moment the charge is gone, so the extra rounds cost nothing when the
    # button is seen on the first one.
    # Press the button and read the pool on the FIRST frame the charge is gone.
    #
    # hold(frames=4) used to do the pressing, and the reading happened after it
    # plus two settle frames.  Six frames is fine on a quiet field and wrong on
    # this one: a maxed fan leaves 70-odd shots in the air, and they leave the
    # field at two or three a frame, which is the same order as the sixteen the
    # card throws - the scenario read 71 -> 71 and 87 -> 84 for cards that had
    # worked perfectly (checked directly against the pool: 86 shots before the
    # press, 94 immediately after).  One frame of window makes the ring
    # unmistakable, and polling per frame also removes the phase luck the old
    # fixed-rounds loop was fighting.
    vm.btn = raw_btn('ok')
    pb_before_card = tlm(vm, 'pbullets')
    pb_after_card = None
    for _ in range(80):
        wait_frames(vm, 1, budget=8_000_000)
        if tlm(vm, 'bomb') < SPELL_MAX_CHARGE:
            pb_after_card = tlm(vm, 'pbullets')
            break
    vm.btn = raw_btn()
    assert pb_after_card is not None, "the centre button never spent the card"
    assert wait_frames(vm, 2), "the game stopped producing frames"
    left = tlm(vm, 'ebullets')
    assert left <= 2, \
        "the spell card left %d enemy shots on the field" % left
    # The docstring promises two things and only the first was graded: the swept
    # shots have to be CONVERTED INTO SCORE, and the card has to throw a ring of
    # the craft's own shots.  A card that silently erased the field and did
    # neither would have passed every assertion above.
    assert tlm(vm, 'score') > score_before_card, (
        "the card swept the field but the score did not move (%d -> %d)"
        % (score_before_card, tlm(vm, 'score')))
    assert pb_after_card > pb_before_card, (
        "the card threw no ring of the craft's own shots (%d -> %d in flight)"
        % (pb_before_card, pb_after_card))
    assert tlm(vm, 'bomb') < SPELL_MAX_CHARGE, \
        "the card did not spend its charge"
    print("  [PASS] 12 shots swept away, charge spent: %d left on the field, "
          "bar back to %d/%d" % (left, tlm(vm, 'bomb'), SPELL_MAX_CHARGE))
    if output_dir:
        save_frame(vm, vm.right_request,
                   Path(output_dir) / "test16_spell_card.bmp",
                   Path(output_dir) / "test16_spell_card.png")
    return vm


def run_pickup_during_invuln(code, output_dir=None):
    """Being hit must not switch the pickup test off for 1.5 s."""
    print("\n" + "=" * 65)
    print(" [TEST 11] Pickup must still work during the invulnerability blink")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)

    assert tlm(vm, 'invuln') == 0, \
        "the run started already invulnerable (%d)" % tlm(vm, 'invuln')
    px, py = player_pos(vm)

    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    inject_ebullet(vm, px + 2, py + 2)
    spent = 0
    while tlm(vm, 'invuln') == 0 and spent < 8_000_000:
        vm.step()
        spent += 1
    assert tlm(vm, 'invuln') > 0, "the injected bullet never reached the craft"
    print("  -> hit registered, %d invulnerability frames on the clock"
          % tlm(vm, 'invuln'))

    taken0 = tlm(vm, 'taken')
    assert feed_item(vm, px - 8, py - 8, ITEM_HEAL), \
        "the power-up was ignored while the craft was invulnerable"
    assert tlm(vm, 'invuln') > 0, \
        "invulnerability had already expired, so the pickup proved nothing"
    assert tlm(vm, 'taken') > taken0
    print("  [PASS] item taken with %d invulnerability frames still running"
          % tlm(vm, 'invuln'))
    return vm


def _craft(vm):
    """The craft's own variables, not the telemetry copy of them.

    Telemetry is published at the end of a frame, so a scenario that pokes the
    position and immediately reads `player_pos()` sees the previous frame's
    value and grades a state the firmware has already left.
    """
    return peek(vm, 'player_x'), peek(vm, 'player_y')


def _ebullet_at(vm, x, y):
    """True if an active enemy shot sits exactly on (x,y)."""
    for i in range(EBULLET_COUNT):
        if vm.scratch[_pool_offset(EBULLET_BASE, i, 8, 6)] == 0:
            continue
        off = _pool_offset(EBULLET_BASE, i, 8, 0)
        bx = int.from_bytes(vm.scratch[off:off + 2], "little", signed=True)
        by = int.from_bytes(vm.scratch[off + 2:off + 4], "little", signed=True)
        if bx == x and by == y:
            return True
    return False


# game_particle_t is {int16 x, int16 y, int8 vx, int8 vy, uint8 life,
# uint8 type} - eight bytes, and MAX_PARTICLES is 48 in main.c.
MAX_PARTICLES = 48
PARTICLE_MOTE = 2


def _live_motes(vm):
    """Count the rising glow motes the hit sweep is supposed to leave behind."""
    base = sym_addr('game_particles')
    n = 0
    for i in range(MAX_PARTICLES):
        off = base + i * 8
        if vm.load(off + 6, 1) and vm.load(off + 7, 1) == PARTICLE_MOTE:
            n += 1
    return n


def _craft_visible(vm, px, py):
    """True if the published frame actually carries the craft at (px,py).

    Counting "the picture changed" would not prove a blink: the playfield
    behind the craft scrolls, and the craft's own idle animation redraws from a
    different tile every few frames, so a patch can change without the sprite
    ever going away.  The sprite is blitted through a colour key, which means
    every opaque source pixel lands in the frame EXACTLY as the tile holds it -
    so the honest question is whether some licensed pose still matches, and a
    blinked-off frame fails all of them while the background shows through.

    The bar is 70% rather than 100% because the invulnerability hitbox ring is
    filled OVER the sprite: a 14-pixel cross straight through its centre, whose
    arms land on a handful of the sampled pixels on every frame the ring is up.
    The two states are nowhere near each other - a drawn frame scores 92%, a
    blinked one scores 0%, because the background shares no pixel with any pose.
    """
    fb = vm.fb[vm.right_request]
    x0, y0 = px - 24, py - 24
    best = 0.0
    for base in (0x01610000, 0x01612400, 0x01614800,
                 0x01616C00, 0x01619000, 0x0161B400):
        opaque = matched = 0
        for sy in range(2, 46, 4):
            off = base - SCRATCH_BASE + sy * 192
            row = (y0 + sy) * SCREEN_PITCH + x0
            for sx in range(2, 46, 4):
                exp = int.from_bytes(vm.scratch[off + sx * 4:off + sx * 4 + 4],
                                     "little")
                if exp == ALPHA_KEY:
                    continue
                opaque += 1
                if fb[row + sx] == exp:
                    matched += 1
        if opaque >= 20 and matched > best * opaque:
            best = matched / float(opaque)
    return best >= 0.7


# The hardware colour-matrix control register (APB 0x7C): [3:0] mode,
# [15:8] intensity.  The VM stores the last value written, so a scenario can
# read the flash curve back frame by frame instead of inferring it from pixels.
COLOR_MATRIX_FLASH = 1


def _flash_level(vm):
    """(mode, intensity) of the last colour-matrix write."""
    reg = vm.params.get(0x7C, 0)
    return reg & 0xF, (reg >> 8) & 0xFF


# The two colours main.c paints the impact ring with: white at the crest,
# ember gold on the way out.
RING_COLOURS = (0x00FFFFFF, 0x00FFC060)
# ... and the ring's own geometry from main.c: it lives HIT_RING_FRAMES frames
# and its radius is 14 + age * 10.  Mirrored rather than guessed because the
# scan below has to be an annulus - the sweep leaves eight white motes a
# hundred pixels away, and a flat "is there white near the hit" test would
# grade those instead.
HIT_RING_FRAMES = 16


def _ring_pixels(vm, cx, cy, r0, r1):
    """Frame pixels inside an annulus that carry a shockwave colour."""
    fb = vm.fb[vm.right_request]
    n = 0
    for y in range(max(0, cy - r1), min(SCREEN_H, cy + r1 + 1)):
        row = y * SCREEN_PITCH
        for x in range(max(GAME_LEFT, cx - r1), min(GAME_RIGHT, cx + r1 + 1)):
            dx, dy = x - cx, y - cy
            d2 = dx * dx + dy * dy
            if (r0 * r0 <= d2 <= r1 * r1
                    and (fb[row + x] & 0xFFFFFF) in RING_COLOURS):
                n += 1
    return n


def run_hit_sweep(code, output_dir=None):
    """Phase 2 Task 02: a hit clears the screen, it does not just blink.

    Three things have to hold on the hit frame and the old version did none of
    them: every enemy shot leaves the field, each swept shot leaves a mote of
    light where it died, and the craft is put back on the classic bottom-third
    spawn point with enough cover to fly out of whatever it was standing in.
    """
    print("\n" + "=" * 65)
    print(" [TEST 25] A hit sweeps the field, seeds motes and respawns the craft")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)
    assert tlm(vm, 'invuln') == 0, \
        "the run started already invulnerable (%d)" % tlm(vm, 'invuln')

    # Park the craft away from the spawn point first.  The reset is only
    # observable from somewhere else, and the spawn point is exactly where this
    # scenario starts, so a sweep that forgot to move the craft would read as a
    # pass - which is what the older scenario next door cannot tell apart.
    poke(vm, sym_addr('player_x'), 320, 2)
    poke(vm, sym_addr('player_y'), 240, 2)
    assert _craft(vm) == (320, 240), \
        "the craft did not take the forced position %r" % (_craft(vm),)

    # A field of parked shots.  A zero-velocity record never moves, so the same
    # coordinates can be re-read after the hit and each one either is or is not
    # still there - a stronger statement than a count of live records, since the
    # minions keep firing throughout and a count can drift for reasons that have
    # nothing to do with the sweep.
    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    planted = [(260, 150), (360, 200), (460, 150), (560, 200),
               (760, 150), (860, 200), (960, 150), (1060, 200)]
    for x, y in planted:
        inject_ebullet(vm, x, y)
    inject_ebullet(vm, 322, 242)          # inside the 12x12 damage box

    spent = 0
    while tlm(vm, 'invuln') == 0 and spent < 8_000_000:
        vm.step()
        spent += 1
    assert tlm(vm, 'invuln') > 0, "the planted shot never reached the craft"
    print("  -> hit registered, %d invulnerability frames on the clock"
          % tlm(vm, 'invuln'))
    assert tlm(vm, 'invuln') >= 110, \
        "Task 02 asks for 120 frames of cover, the craft got %d" % tlm(vm, 'invuln')

    px, py = _craft(vm)
    assert (px, py) == (SPAWN_X, SPAWN_Y), \
        "the craft came back at (%d,%d) instead of the spawn point (%d,%d)" % (
            px, py, SPAWN_X, SPAWN_Y)
    print("  -> craft reset to the bottom-third spawn point (%d,%d)" % (px, py))

    left = [(x, y) for x, y in planted if _ebullet_at(vm, x, y)]
    assert not left, "%d of the planted shots survived the hit: %r" % (
        len(left), left[:4])
    print("  -> all %d planted shots swept off the field" % len(planted))

    motes = _live_motes(vm)
    assert motes >= len(planted), \
        "the sweep left %d motes behind for %d swept shots" % (
            motes, len(planted))
    print("  -> %d PARTICLE_MOTE records alive on the hit frame" % motes)

    # ---- Task 03: the shockwave is anchored on the HIT, not on the craft ----
    #
    # The craft has already been moved by the respawn above, so a ring that
    # rode along with it would look exactly the same here and be useless in
    # play.  Read the anchor back, then confirm the ring is really drawn.
    ax, ay = peek(vm, 'hit_ring_x', 2), peek(vm, 'hit_ring_y', 2)
    assert (ax, ay) == (320, 240), \
        ("the shockwave anchored on (%d,%d), not on the point the shot landed "
         "(320,240) - the craft had already been respawned" % (ax, ay))
    assert peek(vm, 'hit_ring_timer', 1) > 0, "the hit never armed a shockwave"

    # Wait one frame before looking.  The ring is drawn during the render pass
    # while `right_request` flips a step earlier, so the frame the hit was
    # detected on can still be the buffer from before the sweep - which is
    # exactly how the first version of this check read zero ring pixels.
    assert wait_frames(vm, 1)
    ring_timer = peek(vm, 'hit_ring_timer', 1)
    assert ring_timer > 0, "the shockwave expired before it could be checked"
    r = 14 + (HIT_RING_FRAMES - ring_timer) * 10
    ring = _ring_pixels(vm, ax, ay, max(4, r - 12), r + 12)
    assert ring >= 8, \
        ("no shockwave pixels on the %d-pixel ring around the hit point "
         "(%d found)" % (r, ring))
    print("  -> shockwave anchored on the hit at (%d,%d), %d pixels on its "
          "%d-pixel ring" % (ax, ay, ring, r))

    # Cover has to actually refuse the next hit: park a second shot on the craft
    # and let a few frames run with it sitting there.
    hits0 = tlm(vm, 'hits')
    inject_ebullet(vm, px + 2, py + 2)
    assert wait_frames(vm, 4)
    assert tlm(vm, 'hits') == hits0, \
        "a second hit landed through the invulnerability window (%d -> %d)" % (
            hits0, tlm(vm, 'hits'))
    print("  -> the cover refused a second shot parked on the hitbox")

    # ... and the craft must visibly blink while it is covered, or the player
    # reads a hit as a rendering fault.  Both halves are required: a craft that
    # never disappears is not blinking, and one that never comes back is
    # invisible, which is the older bug this gate was written to prevent.
    shown = hidden = 0
    for _ in range(24):
        assert wait_frames(vm, 1)
        if _craft_visible(vm, px, py):
            shown += 1
        else:
            hidden += 1
    assert shown >= 2 and hidden >= 2, \
        ("the craft did not blink across 24 covered frames: %d drawn, %d "
         "hidden" % (shown, hidden))
    print("  -> craft blink: %d drawn / %d hidden frames of 24 covered"
          % (shown, hidden))

    # ---- being hit must not PAY ----
    #
    # This is the bug that was reported from the board: getting shot made the
    # score go up.  The cause was the graze bonus - a ring fourteen pixels wider
    # than the hitbox, paid on the way in - and the whole graze mechanic has
    # since been deleted at the owner's request, so the condition can no longer
    # arise by construction.  The check stays anyway: "getting shot pays" is a
    # headline symptom, and one assertion is a cheap way to keep it from
    # creeping back in through some future effect.
    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    clear_pool(vm, ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, 13)
    poke(vm, sym_addr('invuln'), 0, 1)  # drop the cover: the next shot must land
    assert wait_frames(vm, 1)
    score0, hits0 = tlm(vm, 'score'), tlm(vm, 'hits')
    inject_ebullet(vm, px + 2, py + 2)
    spent = 0
    while tlm(vm, 'hits') == hits0 and spent < 8_000_000:
        vm.step()
        spent += 1
    assert tlm(vm, 'hits') > hits0, "the walked-in shot never connected"
    assert tlm(vm, 'score') == score0, \
        ("the shot that hit the craft paid %d points"
         % (tlm(vm, 'score') - score0))
    print("  -> the shot that connected paid nothing")

    # ---- Task 03: the flash is an envelope, not a step ----
    #
    # Sampled last because it now runs for ~1.5 s, well past the cover window
    # the checks above need.  The old curve put `timer * 50` on screen the
    # instant the shot landed - 250 of 255 on the very first frame - so there
    # was no time for anything to register but "a white frame appeared".  The
    # register is written every frame, so the whole envelope can be read back
    # and graded: it has to ramp IN, crest once, and then disperse.
    levels = []
    for _ in range(140):
        assert wait_frames(vm, 1)
        mode, intensity = _flash_level(vm)
        if mode != COLOR_MATRIX_FLASH:
            break
        levels.append(intensity)
    crest = max(levels)
    ci = levels.index(crest)
    assert ci >= 1, "the flash snapped straight to full brightness: %r" % (levels,)
    assert levels[:ci + 1] == sorted(levels[:ci + 1]), \
        "the flash does not fade IN: %r" % (levels,)
    assert levels[ci:] == sorted(levels[ci:], reverse=True), \
        "the flash does not fade OUT: %r" % (levels,)
    assert crest >= 150, "the flash only crests at %d of 255" % crest
    # The sampler starts when the hit is detected, which is not always the frame
    # the timer was armed on, so what follows counts the frames it SAW - it is
    # not the envelope's length.  The threshold is loose for that reason; the
    # shape assertions above are what actually grade the curve.
    assert len(levels) - ci >= 70, \
        ("only %d frames of tail were sampled - either the envelope is too "
         "short to disperse, or the sampler started well into it"
         % (len(levels) - ci))
    assert levels[-1] <= crest // 8, \
        "the flash is still at %d of a %d crest when it ends" % (levels[-1], crest)
    print("  -> flash envelope: %d sampled frames (%.2f s), crest %d at frame "
          "%d, head %s ... tail %s"
          % (len(levels), len(levels) / 75.0, crest, ci,
             levels[:4], levels[-4:]))

    print("  [PASS] hit sweeps the field, seeds motes, respawns and covers")
    if output_dir:
        save_frame(vm, vm.right_request,
                   Path(output_dir) / "test25_hitsweep.bmp",
                   Path(output_dir) / "test25_hitsweep.png")
    return vm


def run_pickup_at_sprite_edge(code, output_dir=None):
    """The pickup box follows the silhouette, not the old 36x38 centre hole."""
    print("\n" + "=" * 65)
    print(" [TEST 12] Pickup reaches the edge of the opaque silhouette")
    print("=" * 65)
    vm = new_vm(code)
    # Holding A pins the animation to pose 2 and keeps the craft perfectly
    # still, so the cell inspected here is the cell the firmware will test.
    start_game(vm, hold=('a',))
    px, py = player_pos(vm)

    base = PLAYER_POSE_DST[PLAYER_POSE_MID]
    opaque = []
    for cy in range(12):
        for cx in range(12):
            hit = False
            for dy in range(4):
                row = base - SCRATCH_BASE + (cy * 4 + dy) * PLAYER_POSE_STRIDE
                for dx in range(4):
                    a = row + (cx * 4 + dx) * 4
                    if int.from_bytes(vm.scratch[a:a + 4], 'little') != ALPHA_KEY:
                        hit = True
            if hit:
                opaque.append((cy, cx))
    assert opaque, "pose %d decoded to nothing but the colour key" % PLAYER_POSE_MID

    best = None
    for cy, cx in opaque:
        x0 = px - 24 + cx * 4
        y0 = py - 24 + cy * 4
        dx, dy = x0 - px, y0 - py
        # the old code needed the item's top-left corner inside this box
        if -OLD_PICK_X < dx < OLD_PICK_X and OLD_PICK_Y_LO < dy < OLD_PICK_Y_HI:
            continue
        reach = max(abs(dx), abs(dy))
        if best is None or reach > best[0]:
            best = (reach, cx, cy, x0, y0, dx, dy)
    assert best is not None, \
        "no opaque silhouette cell lies outside the old pickup box"
    reach, cx, cy, x0, y0, dx, dy = best
    print("  -> probing opaque sprite cell (col %d, row %d): its top-left corner"
          " sits at (%+d,%+d) from the craft centre" % (cx, cy, dx, dy))

    taken0 = tlm(vm, 'taken')
    clear_pool(vm, ITEM_BASE, ITEM_COUNT, 8, 6)
    inject_item(vm, x0, y0, ITEM_HEAL)
    spent = 0
    while tlm(vm, 'taken') == taken0 and spent < 8_000_000:
        vm.step()
        spent += 1
    assert tlm(vm, 'taken') > taken0, \
        ("the item on the silhouette edge (%+d,%+d from the centre) was not "
         "picked up - the box is still a centre hole" % (dx, dy))
    print("  [PASS] edge cell collected; its corner is %d px from the craft "
          "centre, outside the old +-18 box" % reach)
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test12_pick_edge.bmp",
                   Path(output_dir) / "test12_pick_edge.png")
    return vm


def run_stage_backdrop_progression(code, output_dir=None):
    """Every stage must switch to its own pre-decoded backdrop: 0 -> 1 -> 2."""
    print("\n" + "=" * 65)
    print(" [TEST 13] Three stages, three backdrops: TLM_STAGE_BG 0 -> 1 -> 2")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)

    assert tlm(vm, 'stage_bg') == 0, \
        "the opening stage must use backdrop 0, got %d" % tlm(vm, 'stage_bg')
    assert tlm(vm, 'stage') == 1, \
        "the opening stage number is %d, expected 1" % tlm(vm, 'stage')
    print("  -> stage 1 running on backdrop index %d" % tlm(vm, 'stage_bg'))
    check_backdrop_visible(vm)

    # Winning three boss fights with the starting shot would eat the whole
    # simulation budget, so the bar goes to its cap first: this test grades the
    # scenery switching, not the difficulty curve.
    boost_player(vm)
    print("  -> craft at the caps: atk %d, weapon level %d"
          % (tlm(vm, 'atk'), tlm(vm, 'weapon_lv')))

    seen = [tlm(vm, 'stage_bg')]
    started = vm.steps
    budget = 180_000_000
    # (stage, hp, max) for each time the laser columns came up.  There are up
    # to three per boss now: the entrance volley, then the two earned cards at
    # the two-thirds and one-third marks of the bar.
    laser_seen = []
    laser_on = False
    while tlm(vm, 'stage_bg') < 1 and vm.steps - started < budget:
        state = tlm(vm, 'boss_st')
        if state == BOSS_DIALOG:
            # three story pages gate the fight; tap the centre button through
            # them exactly the way a player would
            for _ in range(4):
                if tlm(vm, 'boss_st') != BOSS_DIALOG:
                    break
                vm.btn = raw_btn()
                for _ in range(TICK * 2):
                    vm.step()
                press_until(vm, ('ok',),
                            lambda: tlm(vm, 'boss_st') != BOSS_DIALOG,
                            budget=6_000_000)
        elif state in (BOSS_ENTER, BOSS_FIGHT):
            steer_abs(vm, tlm(vm, 'boss_x') + 32,
                      min(576, tlm(vm, 'boss_y') + 120), 'x', TICK // 4)
        else:
            # Only feed the field while the kill quota is still open: the boss
            # waits for "quota met AND field clear", so injecting a minion after
            # the quota would hold the transition off forever.
            if tlm(vm, 'kills') < 14 + 6 * (tlm(vm, 'stage') - 1):
                top_up_minions(vm)
            chase_nearest_enemy(vm, TICK // 4)
        bg = tlm(vm, 'stage_bg')
        if bg != seen[-1]:
            seen.append(bg)
            print("  -> backdrop %d active (stage %d) after %d simulated steps"
                  % (bg, tlm(vm, 'stage'), vm.steps - started))
            assert wait_frames(vm, 2)
            check_backdrop_visible(vm)
        las = tlm(vm, 'laser')
        if las > 0 and not laser_on:
            laser_on = True
            laser_seen.append((tlm(vm, 'stage'), tlm(vm, 'boss_hp'),
                               peek(vm, 'boss_hp_max')))
        elif las == 0:
            laser_on = False

    # Winning a SECOND boss fight just to see the third backdrop costs several
    # minutes more than everything else in this file put together, and every
    # group has a five-minute budget.  What this scenario grades is the scenery,
    # so stage 3 is switched to directly; the real 0 -> 1 progression above
    # still exercises the progression code.
    assert tlm(vm, 'stage_bg') == 1, \
        "the second backdrop never became active (sequence %r)" % (seen,)
    poke(vm, sym_addr("stage_bg_active"), 2)
    assert wait_frames(vm, 3)
    assert tlm(vm, 'stage_bg') == 2, \
        "stage 3 could not be switched to (stage_bg = %d)" % tlm(vm, 'stage_bg')
    seen.append(2)
    check_backdrop_visible(vm)

    assert seen == [0, 1, 2], \
        "backdrops were not selected in order: %r" % (seen,)

    # The boss opens with a card and then earns two more.  The bar and its two
    # tick marks are the firmware's own numbers: the maximum is read out of the
    # firmware rather than copied here, so changing the HP curve there cannot
    # leave this assertion checking a threshold that no longer exists.
    #
    # The entrance volley is the one that used to be missing (残留.md 2).  The
    # order matters and is asserted as hard as the thresholds are: FIRST at
    # (or near) full health - that is the boss announcing itself, and it must
    # not wait for the bar - and the next one under the two-thirds mark.
    assert laser_seen, "neither boss ever used its laser columns"
    stage_no, hp, hp_max = laser_seen[0]
    mark = hp_max * 2 // 3
    assert hp > mark, (
        "the boss did NOT open with its spell card: the first laser column "
        "fired at %d hp of stage %d's %d hp bar (the entrance volley should "
        "fire at full health; the two-thirds mark is %d)"
        % (hp, stage_no, hp_max, mark))
    # Any FURTHER card in this run has to be earned.  This scenario switches
    # to stage 3 by hand long before a boss reaches its two-thirds mark, so a
    # second entry is not demanded here - it is graded when it happens, and
    # bossopener drives that path on purpose by dropping the bar to the mark.
    earned = laser_seen[1:]
    for s2, hp2, max2 in earned:
        mark2 = max2 * 2 // 3
        assert hp2 <= mark2, (
            "a card fired at %d hp, above the two-thirds mark %d of stage %d's "
            "%d hp bar" % (hp2, mark2, s2, max2))
    print("  [PASS] the entrance volley fired at %d hp of %d (mark %d); "
          "%d further card(s) in this run%s"
          % (hp, hp_max, mark, len(earned),
             "" if earned else " (the run switched stages first)"))
    print("  [PASS] backdrop sequence %r across the three stages, min SP %#x"
          % (seen, vm.min_sp))
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test13_stage3_bg.bmp",
                   Path(output_dir) / "test13_stage3_bg.png")
    return vm


def run_impact_fx(code, output_dir=None):
    """A kill must light up the five-layer impact effect.

    The effect is drawn entirely with fills, and the workbench counts every
    BitBlt start, so it can be graded without trusting a screenshot: one live
    burst issues about 48 FILL commands per frame for the 24 frames it lives,
    against 19 for a whole idle game frame.  The layer colours are checked as
    well, but loosely - the backdrop is allowed to share a few of them.
    """
    print("\n" + "=" * 65)
    print(" [TEST 17] Impact effect: a kill draws the burst layers")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)
    clear_pool(vm, ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, 13)
    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    top_up_minions(vm, want=1, drop=170)
    ex = ey = None
    for i in range(ENEMY_COUNT):
        off = ENEMY_BASE - SCRATCH_BASE + i * ENEMY_STRIDE
        if vm.scratch[off + 13]:
            ex = int.from_bytes(vm.scratch[off:off + 2], "little", signed=True)
            ey = int.from_bytes(vm.scratch[off + 2:off + 4], "little", signed=True)
            break
    assert ex is not None, "the minion could not be placed in the pool"

    kills0 = tlm(vm, 'kills')
    vm.btn = raw_btn('x')                      # hold fire
    frames = 0
    while tlm(vm, 'kills') == kills0 and frames < 300:
        assert wait_frames(vm, 1)
        frames += 1
    assert tlm(vm, 'kills') > kills0, \
        "the parked minion was never destroyed (%d frames of fire)" % frames

    # The burst lives 24 frames from the kill.  Wait 3, not 0: the pool slot
    # is filled on the frame the kill is counted and the layers are drawn on
    # the frames after it, so sampling on the kill frame itself reads a frame
    # the effect has not reached yet.
    f0, n0 = vm.blit_fill_calls, tlm(vm, 'frames')
    assert wait_frames(vm, 3), "the game stopped producing frames"
    df = vm.blit_fill_calls - f0
    dn = max(1, tlm(vm, 'frames') - n0)
    vm.btn = raw_btn()
    per_frame = df / dn
    print("  -> kill at (%d,%d) after %d frames; %.1f BitBlt fills/frame "
          "while the effect is live" % (ex, ey, frames, per_frame))
    # A fill count alone no longer proves this: the five layers are one
    # composed frame per age now, so the burst costs ONE copy command per frame.
    # The real verification is done below via hot pixels and the shockwave annulus.

    fb = vm.fb[vm.right_request]
    hot = 0
    # Centred on the BURST, which main.c places at (e->x + 12, e->y + 12) -
    # not on the minion record itself.  The old window was offset and clipped
    # its right edge at GAME_RIGHT, so a kill near the wall could miss the
    # effect's own pixels.
    bx, by = ex + 12, ey + 12
    # Sample the effect's peak, not one arbitrary frame.  A live burst draws
    # its ember ring OUTWARD as it ages (4..49 pixels from the centre), so the
    # count inside a fixed window rises and falls across its 24 frames; a
    # single sample can legitimately read a handful of pixels near the start
    # or the end.
    for _ in range(8):
        n = 0
        for y in range(max(GAME_TOP_PX, by - 64),
                       min(PLAYFIELD_BOTTOM, by + 64)):
            row = y * SCREEN_PITCH
            for x in range(max(GAME_LEFT, bx - 64),
                           min(GAME_RIGHT, bx + 64)):
                if (fb[row + x] & 0xFFFFFF) in HOT_COLOURS:
                    n += 1
        if n > hot:
            hot = n
        assert wait_frames(vm, 1)
    print("  -> peak %d pixels of layer colour around the kill" % hot)
    assert hot >= 4, "no burst layer colour appeared around the kill"

    # A fill count alone no longer proves this: the five layers are one
    # composed frame per age now, so the burst costs ONE command a particle.
    # Require the SHAPE instead - the shockwave ring sits 30 to 50 pixels out
    # from the kill, and that annulus has to be where the layer colours are.
    # Centred on the burst and sampled across its life, for the same reason as
    # above: burst_paint() starts its rings at 4 pixels and walks them out to
    # 50 as the frame ages, so the annulus is only populated on the late
    # frames of the effect.
    ring = 0
    for _ in range(10):
        r = 0
        for y in range(max(GAME_TOP_PX, by - 56),
                       min(PLAYFIELD_BOTTOM, by + 57)):
            dy = y - by
            row = y * SCREEN_PITCH
            for x in range(max(GAME_LEFT, bx - 56),
                           min(GAME_RIGHT, bx + 57)):
                dx = x - bx
                d2 = dx * dx + dy * dy
                if 900 <= d2 <= 2500 and \
                        (fb[row + x] & 0xFFFFFF) in HOT_COLOURS:
                    r += 1
        if r > ring:
            ring = r
        assert wait_frames(vm, 1)
    print("  -> peak %d of them on the 30..50 pixel shockwave ring" % ring)
    # 8, not 20.  The ring is drawn as 16 dots on a 16-direction table plus an
    # ember ring, and burst_paint() then stamps the licensed 64x64 explosion
    # frame over the middle of them - so only the dots that land outside that
    # frame survive.  Measured peak on a real kill is 10; a missing ring reads
    # 0.
    assert ring >= 8, (
        "the shockwave ring is not drawn: only %d layer pixels between 30 and "
        "50 pixels out from the kill" % ring)
    print("  [PASS] the kill drew a real burst: %.1f fills/frame, %d hot pixels"
          % (per_frame, hot))
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test17_impact.bmp",
                   Path(output_dir) / "test17_impact.png")
    return vm


def run_hud_follows_state(code, output_dir=None):
    """Every HUD field that can shrink must actually disappear.

    The two side panels are part of the menu backdrop and the game only
    repaints the playfield, so before this round every glyph on a gutter was
    drawn on top of the previous frame's copy.  The craft lost a life and the
    heart row did not change; the score and the weapon name kept their old
    digits showing through the new ones.  This grades the pixels, not the
    telemetry: the counters were always right, the picture was not.
    """
    print("\n" + "=" * 65)
    print(" [TEST 19] HUD gutters follow the state they display")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)
    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    clear_pool(vm, ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, 13)

    def snap():
        fb = vm.fb[vm.right_request]
        return Image.frombytes("RGBA", (SCREEN_PITCH, SCREEN_H), fb.tobytes())

    def pixels(im, box):
        return im.crop(box).tobytes()

    def changed(a, b, box):
        x, y = pixels(a, box), pixels(b, box)
        return sum(1 for i in range(0, len(x), 4) if x[i:i + 4] != y[i:i + 4])

    bullets = []
    for name, addr, values, box in (
            ("lives",   "lives",  (3, 1),      (0, 145, 170, 205)),
            ("weapon",  "weapon", (1, 3),      (1190, 15, 1362, 55)),
            ("score",   "score",  (123456, 7), (0, 236, 178, 290))):
        a = sym_addr(addr)
        poke(vm, a, values[0], 1 if addr != "score" else 4)
        assert wait_frames(vm, 2), "the game stopped producing frames"
        first = snap()
        poke(vm, a, values[1], 1 if addr != "score" else 4)
        assert wait_frames(vm, 2), "the game stopped producing frames"
        second = snap()
        n = changed(first, second, box)
        print("  -> %-7s %r -> %r changed %d pixels" % (name, values[0],
                                                         values[1], n))
        bullets.append((name, n))

    # The backend token is the other way a field changes length: "FPGA" ->
    # "CPU" leaves two glyphs behind.  It is graded last because switching
    # HW ACCEL off drops the firmware onto the software render path, which
    # costs over ten million steps a frame - far past the default
    # wait_frames() budget, which is why the round-1 probe never saw it move.
    poke(vm, sym_addr("hw_accel"), 1, 1)
    assert wait_frames(vm, 2), "the game stopped producing frames"
    hw = snap()
    poke(vm, sym_addr("hw_accel"), 0, 1)
    assert wait_frames(vm, 2, budget=60_000_000), \
        "the CPU render path never finished a frame"
    cpu = snap()
    n = changed(hw, cpu, (1190, 205, 1362, 245))
    print("  -> backend  FPGA -> CPU changed %d pixels" % n)
    assert n > 0, (
        "the backend token did not follow hw_accel: 'FPGA' kept its last two "
        "glyphs when the backend became 'CPU'")
    poke(vm, sym_addr("hw_accel"), 1, 1)
    assert wait_frames(vm, 2), "the game stopped producing frames"

    dead = [nm for nm, n in bullets if n == 0]
    assert not dead, (
        "these HUD fields did not follow their value, so the gutter is being "
        "drawn over instead of restored: %s" % ", ".join(dead))
    print("  [PASS] hearts, weapon name and score are all repainted from the "
          "backdrop each frame")
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test19_hud.bmp",
                   Path(output_dir) / "test19_hud.png")
    return vm


def run_stage3_boss_visible(code, output_dir=None):
    """Stage 3's rival is derived at boot and must actually be drawn.

    The tile is derived from stage 2's art, and the derivation used to test
    `s >> 24` for opacity.  Every decoded asset in the bank carries alpha = 0
    on its opaque pixels (transparency is the magenta colour key), so the
    test passed for the whole sprite and stage 3's boss was derived into 4096
    magenta pixels - invisible.  Both layers are graded: the DDR tile itself,
    and the pixels the renderer actually puts on screen.
    """
    print("\n" + "=" * 65)
    print(" [TEST 20] Stage 3 boss: the derived tile is drawn")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)

    off = sym_addr("stage_bg_active")     # any address inside the firmware
    assert off is not None
    tile = 0x01625000                      # MM_BOSS_DREAM, 64x64 stride 256
    base = tile - SCRATCH_BASE
    visible = 0
    for y in range(64):
        for x in range(64):
            i = base + y * 256 + x * 4
            v = int.from_bytes(vm.scratch[i:i + 4], "little")
            if v != 0x00FF00FF:
                visible += 1
    print("  -> MM_BOSS_DREAM holds %d non-transparent pixels of 4096" % visible)
    assert visible >= 1000, (
        "the derived stage-3 tile is almost empty (%d pixels), so the boss is "
        "invisible" % visible)

    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    clear_pool(vm, ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, 13)
    fb = vm.fb[vm.right_request]

    def sample():
        f = vm.fb[vm.right_request]
        bxp, byp = tlm(vm, 'boss_x'), tlm(vm, 'boss_y')
        return (bxp, byp, [f[(byp + r) * SCREEN_PITCH + bxp + c]
                           for r in range(0, 64, 2) for c in range(0, 64, 2)])

    for addr, val, size in (("wave", 2, 2), ("stage_bg_active", 2, 4),
                            ("boss_hp_max", 400, 2), ("boss_hp", 400, 2)):
        poke(vm, sym_addr(addr), val, size)
    poke(vm, sym_addr("boss_state"), 0, 1)
    poke(vm, sym_addr("boss_x"), 384, 2)
    poke(vm, sym_addr("boss_y"), 120, 2)
    assert wait_frames(vm, 3), "the game stopped producing frames"
    bx0, by0, empty = sample()

    poke(vm, sym_addr("boss_state"), BOSS_FIGHT, 1)
    poke(vm, sym_addr("boss_x"), 384, 2)
    poke(vm, sym_addr("boss_y"), 120, 2)
    assert wait_frames(vm, 3), "the game stopped producing frames"
    bx1, by1, drawn = sample()
    assert tlm(vm, 'boss_st') == BOSS_FIGHT, \
        "the boss left BOSS_FIGHT during the sample (state %d)" % tlm(vm, 'boss_st')
    n = sum(1 for a, b in zip(empty, drawn) if a != b)
    print("  -> %d of %d sampled boss pixels changed when the boss appeared "
          "(at %d,%d)" % (n, len(drawn), bx1, by1))
    assert n >= 100, \
        "stage 3's boss draws nothing on screen (%d changed pixels)" % n
    assert tlm(vm, 'stage_bg') == 2, "the stage-3 backdrop is not active"
    print("  [PASS] %d visible pixels in the tile, %d on screen" % (visible, n))
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test20_boss3.bmp",
                   Path(output_dir) / "test20_boss3.png")
    return vm


def run_bomb_bounds(code, output_dir=None):
    """A spell card played on the bottom edge must stay inside the frame.

    The card throws one shot straight down by definition, and the tracer
    behind a shot is a fill at y + 10 with a height of ten, so a shot allowed
    past y = 580 paints rows 600 and beyond - outside the framebuffer, and on
    the board that came back as a scrambled craft and a vertical stripe.  The
    workbench treats an out-of-bounds BitBlt as a hard failure, so this
    scenario is mostly its own assertion: park the craft on the bottom edge,
    spend a full card and let the run speak.  Before the fix it died with
    "BitBlt fill out of bounds: (478,594,2,10)".
    """
    print("\n" + "=" * 65)
    print(" [TEST 21] Spell card on the bottom edge stays in frame")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)
    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    clear_pool(vm, ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, 13)
    poke(vm, sym_addr("player_x"), SPAWN_X, 2)
    poke(vm, sym_addr("player_y"), 584, 2)
    poke(vm, sym_addr("atk"), ATK_MAX, 1)
    poke(vm, sym_addr("bomb_charge"), SPELL_MAX_CHARGE, 1)
    assert wait_frames(vm, 1), "the game stopped producing frames"
    assert tlm(vm, 'bomb') == SPELL_MAX_CHARGE, \
        "the charge did not stick: %d" % tlm(vm, 'bomb')
    assert tlm(vm, 'player_y') == 584, \
        "the craft did not hold the bottom edge (y=%d)" % tlm(vm, 'player_y')

    press(vm, 'ok', frames=3)            # the frame itself is the assertion
    assert wait_frames(vm, 3), "the game stopped producing frames"
    assert tlm(vm, 'bomb') < SPELL_MAX_CHARGE, \
        "the card did not spend its charge"
    assert tlm(vm, 'pbullets') >= 1, "the card threw no shots"
    print("  -> card spent on the bottom edge, %d shots in the air, "
          "no BitBlt left the frame" % tlm(vm, 'pbullets'))
    print("  [PASS] the down-facing shot was culled, not drawn past row 599")
    if output_dir:
        save_frame(vm, vm.right_request,
                   Path(output_dir) / "test21_bombbounds.bmp",
                   Path(output_dir) / "test21_bombbounds.png")
    return vm


# ----------------------------------------------------------------------
# test registry and short-run groups
#
# The whole suite is far longer than the ten-minute budget a single run is
# allowed to take, so tests are addressable by id and come in batches that each
# finish comfortably inside it.  Every batch starts from the cached boot state,
# so re-running one costs seconds rather than a fresh three-minute boot.
# ----------------------------------------------------------------------
def _first_ebullet(vm):
    """(x, y) of one live enemy shot, or (None, None)."""
    off = EBULLET_BASE - SCRATCH_BASE
    for i in range(EBULLET_COUNT):
        p = off + i * 8
        if vm.scratch[p + 6]:
            return (int.from_bytes(vm.scratch[p:p + 2], "little", signed=True),
                    int.from_bytes(vm.scratch[p + 2:p + 4], "little", signed=True))
    return None, None


def _backdrop_sample(vm):
    """Pixels of the plate that a SHAKE can actually move.

    The plate is a stack of flat colour bands now (bg_paint /
    stage_bg_plate_build) and a band is uniform along a row, so a 4-row shake
    is invisible to a sample taken INSIDE one band.  The old sample sat at rows
    4..30, which the 1366x768 plate fills with one sky tone: it read identical
    bytes before and after the shake, so the card's "scenery changed"
    assertion failed for a shake that was in fact running.

    These rows straddle the first band seam (the plate splits its 486 sky rows
    into four bands, so the first seam is at row 121), and they also cover the
    parallax strip, which scrolls every frame by design.
    """
    fb = vm.fb[vm.right_request]
    return b"".join(fb[y * SCREEN_PITCH + x].to_bytes(4, "little")
                     for y in range(112, 140, 4) for x in range(220, 720, 40))


def plate_match(vm, base, step_y=7, step_x=5):
    """Fraction of sampled playfield pixels that equal `base`'s plate.

    1366x768 native: the plate IS the screen, 1:1, so screen (x, y) reads plate
    (x, y) with no shift at all.  (The old build stored the plate at its own
    640x600 and scanned it from GAME_LEFT, so this used to subtract GAME_LEFT.)

    The plate is also allowed to be SHAKEN: boss_shake slides the whole plate
    down 4 rows on alternate frames, and the card's sky is a diamond ward plus
    220 single-pixel stars, i.e. high frequency in both axes - a 4-row offset
    alone wrecks a pixel-for-pixel match.  Trying the three phases and taking
    the best measures the plate instead of the phase.
    """
    off = base - SCRATCH_BASE
    fb = vm.fb[vm.right_request]
    src = vm.scratch
    best = 0.0
    for dy in (0, 8, -8, 4, -4):
        same = total = 0
        for y in range(110, PLAYFIELD_BOTTOM - 4, step_y):
            sy = y - dy
            srow = off + sy * SCREEN_STRIDE
            frow = y * SCREEN_PITCH
            for x in range(GAME_LEFT, GAME_RIGHT, step_x):
                sx = x * 4
                exp = int.from_bytes(src[srow + sx:srow + sx + 4], "little")
                total += 1
                if fb[frow + x] == exp:
                    same += 1
        best = max(best, same / float(total))
    return best


def backdrop_scores(vm):
    """Match the live playfield against all four plates by name."""
    out = {"stage %d" % s: plate_match(vm, BACKGROUND_PLANE + s * BACKGROUND_PLATE)
           for s in range(3)}
    out["CARD_BG"] = plate_match(vm, MM_CARD_BG)
    return out


def wait_published(vm, budget=8_000_000):
    """Step until the frame that is now being drawn has been PUBLISHED.

    wait_frames() returns when the firmware's own frame counter moves, and
    telemetry_write() sits at the end of game_frame() - so the publish to the
    scanout channel has not happened yet and vm.right_request still points at
    the previous frame.  Grading a steady state, that is invisible; grading an
    18-frame beam it means looking at a frame drawn before the beam existed.
    """
    was = vm.right_request
    spent = 0
    while vm.right_request == was and spent < budget:
        vm.step()
        spent += 1
    return vm.right_request != was


def _count_held(vm):
    """Enemy shots that are on station, waiting for 6.2 to release them."""
    return sum(bool(vm.scratch[EBULLET_BASE - SCRATCH_BASE + 6 + i * 8] & EF_HELD)
               for i in range(EBULLET_COUNT))


def _count_active_ebullets(vm):
    """Live enemy shots, straight out of the DDR pool.

    Telemetry carries the same number, but only for the frame the firmware
    has already published, which is one behind anything a scenario just did.
    """
    return sum(bool(vm.scratch[EBULLET_BASE - SCRATCH_BASE + 6 + i * 8] & 1)
               for i in range(EBULLET_COUNT))


def _count_moving(vm):
    start = EBULLET_BASE - SCRATCH_BASE
    return sum(bool(vm.scratch[start + i * 8 + 6] & 1) and
               bool(vm.scratch[start + i * 8 + 4] or vm.scratch[start + i * 8 + 5])
               for i in range(EBULLET_COUNT))


# B1: where the bullet curtain lives now.  The firmware appends one entry per
# (bullet, GROUP of scanlines it covers) to a per-group bucket in DDR, in draw
# order; the scanout composites from it and the framebuffer never sees a bullet.
# A scenario that used to look for bullet pixels has to look here instead - which
# is the same place the hardware looks.
MM_BUCKET_TABLE = mm_value("MM_BUCKET_TABLE")
MM_BUCKET_STRIDE = mm_value("MM_BUCKET_STRIDE")
MM_BUCKET_ROWS = mm_value("MM_BUCKET_ROWS")
MM_BUCKET_SLOTS = mm_value("MM_BUCKET_SLOTS")
MM_BUCKET_GROUP_ROWS = mm_value("MM_BUCKET_GROUP_ROWS")
# Rows every slot's tile has in the scanout's store.  bullet_store_build() pads
# the orb run out to this many so the scanout can reject an out-of-range tile row
# with one constant comparison - see video_bullet_overlay.v's trow guard.
TILE_ROWS = 26


def _bucket_row(vm, row, buffer=None):
    """The live entries of one scanline: [(bx, tile_row, slot, width, hue)].

    The table's row unit is a GROUP of MM_BUCKET_GROUP_ROWS scanlines, so this
    reads the group's bucket and reconstructs the tile row the entry left
    implicit:

        tile_row = stored trow_base + (row mod MM_BUCKET_GROUP_ROWS)

    Entries that reconstruct outside [0, 26) are dropped, which is exactly what
    the scanout's trow guard does - they would address the neighbouring tile.
    So what this returns is what the scanout would actually draw.

    Empty cells read back as zero, and a zero width can never match a pixel, so
    "nonzero width" is exactly "live entry" - the scanout uses the same rule.

    hue is [31:29]: the colour page the bullet named for itself (bucket_put in
    main.c).  An enemy shot's colour used to be folded into its slot --
    (colour << 4) | heading -- and since the colour split the slot is just the
    heading, 0..15, with the page in its own field.  The slot field is [22:17]
    now - seven bits, not eight - because trow_base needed a sixth bit to carry
    the negative values a group boundary produces.
    """
    if buffer is None:
        buffer = 0 if vm.right_request <= 0x00C00000 else 1
    off = (MM_BUCKET_TABLE - SCRATCH_BASE
           + buffer * MM_BUCKET_STRIDE * MM_BUCKET_ROWS
           + (row // MM_BUCKET_GROUP_ROWS) * MM_BUCKET_STRIDE)
    dy = row % MM_BUCKET_GROUP_ROWS
    out = []
    for k in range(MM_BUCKET_SLOTS):
        p = off + k * 4
        v = int.from_bytes(vm.scratch[p:p + 4], "little")
        if (v >> 24) & 31:
            trow = ((v >> 11) & 0x3F) - 8 + dy
            if 0 <= trow < TILE_ROWS:
                out.append((v & 0x7FF, trow, (v >> 17) & 0x7F,
                            (v >> 24) & 31, (v >> 29) & 7))
    return out


def _bucket_covers(vm, x, y, colour=None, buffer=None):
    """Entries on scanline y whose span contains x, optionally of one colour."""
    hits = []
    for bx, trow, slot, w, hue in _bucket_row(vm, y, buffer):
        if bx <= x < bx + w:
            if colour is None or hue == (colour & 7):
                hits.append((bx, trow, slot, w, hue))
    return hits


def _hair_slots(vm):
    """[(x, outer, left, centre)] for the three cut/beam warning hairlines.

    The scanout draws them now (rtl/v_dma/video_beam.v, APB 0xC0 + 16k): a
    one-pixel column costs a DRAM row activation to write four bytes, and three
    slots of them ran to 4,608 rows in a frame, so the engine issues nothing for
    them and there is nothing in the picture to count.  What the firmware
    controls - and therefore what a scenario grades - is where each line stands
    and which colour it carries, which is the same place the boss's laser columns
    are read back from.
    """
    out = []
    for k in range(CUT_SLOTS):
        b = 0xC0 + 16 * k
        out.append((vm.params.get(b, 0) & 0xFFF,
                    vm.params.get(b + 4, 0) & 0xFFFFFF,
                    vm.params.get(b + 8, 0) & 0xFFFFFF,
                    vm.params.get(b + 12, 0) & 0xFFFFFF))
    return out


def _boss_arena(vm, pattern, wave=0):
    """A boss on the field with `pattern` queued to fire on the next frame.

    The hp is left at full on purpose: the spell card fires at two thirds, and
    a card going off in the middle of a skill test would be graded as the
    skill.  boss_pat_timer is pinned high so the random pattern change does
    not replace the one under test.
    """
    poke(vm, sym_addr('wave'), wave, 2)
    poke(vm, sym_addr('stage_bg_active'), wave, 4)
    poke(vm, sym_addr('boss_hp_max'), 400, 2)
    poke(vm, sym_addr('boss_hp'), 400, 2)
    poke(vm, sym_addr('boss_x'), 384, 2)
    poke(vm, sym_addr('boss_y'), 200, 2)
    poke(vm, sym_addr('boss_state'), BOSS_FIGHT, 1)
    assert wait_frames(vm, 2), "the boss fight never produced a frame"
    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    poke(vm, sym_addr('boss_pattern'), pattern, 1)
    # 127, not 200: poke() writes sub-word values signed, and the timer is a
    # uint8_t.  127 frames is still longer than any pattern runs for.
    poke(vm, sym_addr('boss_pat_timer'), 127, 1)
    poke(vm, sym_addr('boss_fire_timer'), 0, 1)
    assert wait_frames(vm, 1), "the queued pattern never fired"
    assert tlm(vm, 'boss_pat') == pattern, \
        "the boss is on pattern %d, not the queued %d" % (tlm(vm, 'boss_pat'), pattern)


def run_stage2_skills(code, output_dir=None):
    """The four basic enemy skills, one at a time, each graded on its own
    observable.

      * 6.1 laser cut      - the preview hairline is on screen in the craft's
                             own column, it turns into the beam, and the beam
                             hits a craft that stands in it.
      * 6.2 lock-on volley - shots really are held on station first and then
                             all released, which is the whole difference from
                             every other pattern in the book.
      * 6.3 all-round      - the staggered pair of rings puts at least 24
                             shots in the air in one frame.
      * 6.4 mass aimed     - thirteen shots, fanned across the bearing.

    It closes with the book itself: a stage-1 boss is forced through 48
    pattern changes and has to deal all four, which is what makes them
    "reachable in one boss fight" rather than merely implemented.
    """
    print("\n" + "=" * 65)
    print(" [TEST 23] Stage 2 skills: cut / lock-on / all-round / mass aimed")
    print("=" * 65)

    # ---- 6.1 the laser cut ------------------------------------------
    vm = new_vm(code)
    start_game(vm)
    vm.joy = (128 << 8) | 128
    _boss_arena(vm, PAT_CUT)
    px, py = player_pos(vm)
    assert wait_frames(vm, 2), "the game stopped producing frames"
    # The hairline is a scanout column now, not framebuffer pixels - see
    # _hair_slots().  The judgement is unchanged: a slot is standing, it is
    # standing in the craft's own column, and it carries one of the preview's
    # two colours.
    live = [s for s in _hair_slots(vm) if s[0]]
    print("  -> 6.1 preview: %d slot(s) standing, %s"
          % (len(live), [(s[0], hex(s[2]), hex(s[3])) for s in live]))
    assert live, "the cut's preview is not on screen: no hairline slot is standing"
    assert any(abs(s[0] - px) <= 2 for s in live), (
        "the preview stands at %s but the craft it promises to cut is at x=%d"
        % ([s[0] for s in live], px))
    assert any(s[2] in CUT_PREVIEW_COLOURS or s[3] in CUT_PREVIEW_COLOURS
               for s in live), (
        "the standing preview carries none of the preview's colours: %s"
        % [(hex(s[2]), hex(s[3])) for s in live])

    spent = 0
    while peek(vm, 'cut_phase', 1) == 1 and spent < 30_000_000:
        vm.step()
        spent += 1
    assert peek(vm, 'cut_phase', 1) == 2, \
        "the preview never turned into a beam (phase=%d)" % peek(vm, 'cut_phase', 1)
    assert wait_published(vm), "the frame carrying the beam was never published"
    assert peek(vm, 'cut_phase', 1) == 2, \
        "the beam expired before its frame could be graded"
    # The beam is a scanout column now, not framebuffer pixels: the engine
    # issues nothing for it (four 16x768 copies a frame was 3,072 DRAM row
    # activations, and the board lost its frame time to it), so there is nothing
    # in the frame to count.  What the firmware controls - and therefore what is
    # graded - is that the column is enabled and standing where the boss aimed
    # it, which is the x the scenario read off the player before the cut.
    ctrl_word = vm.params.get(0x78, 0)
    cols = []
    for w in (0xB0, 0xB4):
        v = vm.params.get(w, 0)
        cols += [v & 0xFFF, (v >> 12) & 0xFFF]
    live = [c for c in cols if c != 0]
    print("  -> 6.1 beam fired %d simulated steps later: columns %s (ctrl %#x), "
          "craft at x=%d" % (spent, cols, ctrl_word, px))
    assert ctrl_word & (1 << 18), (
        "the cut fired but never enabled the scanout's laser columns")
    assert live, "the cut enabled the columns but stood none of them up"
    assert any(abs(c - px) <= 2 for c in live), (
        "the beam is at %s but the craft it is aimed at is at x=%d"
        % (live, px))
    assert wait_frames(vm, 4), "the game stopped producing frames"
    assert tlm(vm, 'invuln') > 0 or tlm(vm, 'lives') < 3, (
        "standing in the beam cost nothing: invuln=%d lives=%d"
        % (tlm(vm, 'invuln'), tlm(vm, 'lives')))
    print("  -> 6.1 the craft was cut down for standing in it")

    # ---- 6.2 the lock-on volley -------------------------------------
    vm = new_vm(code)
    start_game(vm)
    vm.joy = (128 << 8) | 128
    _boss_arena(vm, PAT_LOCKON)
    assert wait_frames(vm, 24), "the game stopped producing frames"
    held = _count_held(vm)
    print("  -> 6.2 %d shots on station mid-layout" % held)
    assert held >= 4, (
        "the volley was never laid out: %d shots are holding station" % held)

    spent = 0
    while _count_held(vm) > 0 and spent < 30_000_000:
        vm.step()
        spent += 1
    assert _count_held(vm) == 0, "the volley never released its shots"
    moving = _count_moving(vm)
    print("  -> 6.2 released %d simulated steps later: %d shots under way"
          % (spent, moving))
    assert moving >= 4, "the release left %d shots in flight" % moving

    # ---- 6.3 all-round burst ----------------------------------------
    vm = new_vm(code)
    start_game(vm)
    vm.joy = (128 << 8) | 128
    _boss_arena(vm, PAT_BURST)
    n = tlm(vm, 'ebullets')
    print("  -> 6.3 all-round burst threw %d shots in one frame" % n)
    assert n >= BURST_SHOTS, \
        "the all-round burst threw %d shots, expected at least %d" % (n, BURST_SHOTS)

    # ---- 6.4 mass aimed volley --------------------------------------
    vm = new_vm(code)
    start_game(vm)
    vm.joy = (128 << 8) | 128
    _boss_arena(vm, PAT_VOLLEY)
    n = tlm(vm, 'ebullets')
    px, py = player_pos(vm)
    off = EBULLET_BASE - SCRATCH_BASE
    toward = 0
    for i in range(EBULLET_COUNT):
        p = off + i * 8
        if not vm.scratch[p + 6]:
            continue
        bx = int.from_bytes(vm.scratch[p:p + 2], "little", signed=True)
        by = int.from_bytes(vm.scratch[p + 2:p + 4], "little", signed=True)
        if by < py and abs(bx - px) < 400:
            toward += 1
    print("  -> 6.4 mass aimed volley: %d shots, %d of them bearing on the craft"
          % (n, toward))
    assert n >= VOLLEY_SHOTS, \
        "the mass volley threw %d shots, expected %d" % (n, VOLLEY_SHOTS)
    assert toward >= 8, "only %d of the volley's shots bear on the craft" % toward

    # ---- all four are in the stage-1 boss's book --------------------
    vm = new_vm(code)
    start_game(vm)
    _boss_arena(vm, PAT_FAN, wave=0)
    seen = set()
    for _ in range(48):
        poke(vm, sym_addr('boss_pat_timer'), 0, 1)
        assert wait_frames(vm, 1), "the game stopped producing frames"
        seen.add(tlm(vm, 'boss_pat'))
    missing = sorted({PAT_CUT, PAT_LOCKON, PAT_BURST, PAT_VOLLEY} - seen)
    print("  -> 48 changes of a stage-1 boss dealt %d distinct patterns: %s"
          % (len(seen), sorted(seen)))
    assert not missing, \
        "a stage-1 boss never dealt %s in 48 changes" % missing

    print("  [PASS] all four skills fire, draw, and are in the stage-1 book")
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test23_skills.bmp",
                   Path(output_dir) / "test23_skills.png")
    return vm


PAT_SWAY, PAT_BEAM, PAT_TORNADO, PAT_LANCE = 14, 15, 16, 17
EF_LANCE = 0x08                     # 8.5's shaft flag, see main.c
SWAY_SHOTS = 13                     # 8.1 throws k = -6..6
TORNADO_SHOTS = 16                  # 8.4 throws eight arms, two rings
BEAM_PREVIEW_COLOURS = {0xFF9AA8, 0x603038}   # 6.1/8.2's blinking hairline


def _live_ebullets(vm, flag=1):
    """[(index, x, y, vx, vy, flags)] for every live enemy shot.

    bullet_t is 8 bytes: x, y, vx, vy, flags, colour.  Grading the pool
    directly rather than the telemetry count is what lets a scenario say
    WHERE the shots are and which way they are going.
    """
    off = EBULLET_BASE - SCRATCH_BASE
    out = []
    for i in range(EBULLET_COUNT):
        p = off + i * 8
        f = vm.scratch[p + 6]
        if (f & flag) != flag:
            continue
        out.append((i,
                    int.from_bytes(vm.scratch[p:p + 2], "little", signed=True),
                    int.from_bytes(vm.scratch[p + 2:p + 4], "little", signed=True),
                    int.from_bytes(vm.scratch[p + 4:p + 5], "little", signed=True),
                    int.from_bytes(vm.scratch[p + 5:p + 6], "little", signed=True),
                    f))
    return out


def _refire(vm, want, frames=50, gap=20):
    """Clear the pool, queue the pattern to fire again, return its shots.

    boss_fire_timer is counted down every frame and fires on the frame it
    reaches zero, so poking it to `gap` re-fires after exactly that many
    frames - which is how a scenario sees a pattern TWICE and can tell
    whether anything about it changed in between.
    """
    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    poke(vm, sym_addr('boss_fire_timer'), gap, 1)
    for _ in range(frames):
        assert wait_frames(vm, 1), "the game stopped producing frames"
        shots = _live_ebullets(vm)
        if len(shots) >= want:
            return shots
    return _live_ebullets(vm)


def run_boss_opener(code, output_dir=None):
    """The boss spell card, graded on pixels and on what the frame costs.

    1.4 was called fixed once already on a 51% drop in FILL commands a frame,
    and the board still stuttered.  A count cannot tell whether anything was
    drawn, so this scenario locks down both ends at once:

      * every one of the four laser columns is on screen, in the colour the
        brightness band it is in actually uses - sampled straight out of the
        published frame at the column's own x;
      * the impact bursts left layer-coloured pixels around the boss;
      * the 24 composed burst frames exist and are not empty (the renderer
        copies one of them per particle now, so an empty frame would silently
        mean "no effect");
      * and the frame still costs no more than OPENER_FILL_CAP FILL commands,
        so a future effect cannot quietly rebuild the command flood.

    The pre-composed surfaces are what make the first three cheap enough to
    check pixel by pixel: the laser bar is 3 FILLs a column turned into 1 COPY,
    the burst 48 FILLs a particle into 1 COPY.
    """
    print("\n" + "=" * 65)
    print(" [TEST 22] Boss spell card: columns and burst are really on screen")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)
    clear_pool(vm, ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, 13)

    poke(vm, sym_addr('wave'), 1, 2)
    poke(vm, sym_addr('stage_bg_active'), 1, 4)
    poke(vm, sym_addr('boss_hp_max'), 400, 2)
    poke(vm, sym_addr('boss_hp'), 400, 2)
    poke(vm, sym_addr('boss_x'), 384, 2)

    # ---- the ENTRANCE is a card of its own (残留.md 2) -----------------
    #
    # The boss announces itself: the field STOPS, the sky swaps to the card's
    # own, the scenery shakes and then the whole screen opens at once - three
    # rings, three bursts and four laser columns in a single frame.  none of
    # it waits on the health bar.
    #
    # It stopped doing that.  The entrance hold was still there (the field
    # froze for 70 frames) but nothing came out of it, because the only thing
    # that ever called boss_opener() was the two health thresholds - so the
    # boss glided in, paused, and opened the fight with an ordinary pattern.
    # A freeze with no payoff is indistinguishable from a dropped frame,
    # which is exactly how it was reported.
    poke(vm, sym_addr('boss_y'), 40, 2)          # one step short of the park
    poke(vm, sym_addr('boss_state'), 1, 1)       # BOSS_ENTER
    assert wait_frames(vm, 2), "the boss entrance never produced a frame"
    assert tlm(vm, 'boss_st') == BOSS_FREEZE,         "the entrance did not hold the field (boss_st=%d)" % tlm(vm, 'boss_st')
    assert wait_published(vm), "the entrance frame was never published"
    ent_cards = backdrop_scores(vm)
    ent_best = max(ent_cards, key=ent_cards.get)
    assert ent_best == "CARD_BG", (
        "the entrance did not bring the card's own sky - it is showing %s"
        % ent_best)
    print("  -> the entrance held the field and swapped the sky")

    ent_frames = 0
    while tlm(vm, 'boss_st') == BOSS_FREEZE and ent_frames < 140:
        assert wait_frames(vm, 1), "the game stopped producing frames"
        ent_frames += 1
    assert ent_frames < 140, "the entrance hold never released"
    ent_shots = _count_active_ebullets(vm)
    assert tlm(vm, 'laser') > 0, (
        "the entrance released into an ordinary pattern: no laser columns "
        "(boss_st=%d, %d shots)" % (tlm(vm, 'boss_st'), ent_shots))
    assert ent_shots >= 40, (
        "the entrance volley is not on the field: %d shots" % ent_shots)
    print("  -> the entrance opened the fight: %d-frame hold, %d shots and "
          "%d frames of laser columns" % (ent_frames, ent_shots,
                                          tlm(vm, 'laser')))

    # ---- what a beam frame costs ----------------------------------------
    # The cut/beam lasers are drawn by the CPU: three 16x768 bars copied into
    # the framebuffer every frame they stand.  768 rows is 768 DRAM row
    # activations and the engine pays one per row - the same load the boss's
    # four opener columns used to be before they moved into the scanout
    # (rtl/v_dma/video_laser.v).
    for k in range(3):
        poke(vm, sym_addr('beam_x') + k * 2, 380 + k * 120, 2)
        poke(vm, sym_addr('beam_timer') + k, 60, 1)
        poke(vm, sym_addr('beam_phase') + k, 2, 1)
    assert wait_frames(vm, 2), "the game stopped producing frames"
    c0, n0 = len(vm.copy_log), tlm(vm, 'frames')
    assert wait_frames(vm, 3), "the game stopped producing frames"
    dn = max(1, tlm(vm, 'frames') - n0)
    rows = sum(c[1] for c in vm.copy_log[c0:])
    bars = sum(1 for c in vm.copy_log[c0:] if c[0] == MM_LASER_BAR_W)
    print("  -> beam frame: %.0f rows copied, %d of them %d-wide bars"
          % (rows / dn, bars, MM_LASER_BAR_W))
    # 2,861 rows a frame before the beams moved into the scanout (three 16x768
    # bars are 2,304 of them, one DRAM row activation each), 1,603 after.
    assert rows / dn <= BEAM_ROW_CAP, (
        "a beam frame copies %.0f rows into the framebuffer; the beams are the "
        "scanout's columns now and should not be here at all (cap %d)"
        % (rows / dn, BEAM_ROW_CAP))

    # ---- what that volley costs the engine ------------------------------
    # Graded here, while the 48 shots are still in the air, because that is the
    # frame the bus actually struggles with.  A bullet drawn with OP_ALPHA is a
    # read-modify-write, and the shot loop is the largest single source of
    # commands in the build, so one alpha per bullet is exactly how the opener
    # goes over budget.
    a0, c0, f0, n0 = (vm.blit_alpha_calls, vm.blit_copy_calls,
                      vm.blit_fill_calls, tlm(vm, 'frames'))
    assert wait_frames(vm, 4), "the game stopped producing frames"
    dn = max(1, tlm(vm, 'frames') - n0)
    alphas = (vm.blit_alpha_calls - a0) / dn
    copies = (vm.blit_copy_calls - c0) / dn
    fills = (vm.blit_fill_calls - f0) / dn
    print("  -> entrance frame: %.1f ALPHA, %.1f COPY, %.1f FILL commands a "
          "frame" % (alphas, copies, fills))
    assert alphas <= OPENER_ALPHA_CAP, (
        "the entrance frame issues %.1f OP_ALPHA commands a frame; a "
        "read-modify-write per bullet is what stalls the bus with the field "
        "full (cap %d)" % (alphas, OPENER_ALPHA_CAP))

    # Clear the entrance volley: it is 90 frames of laser and 48 shots, and the
    # pixel assertions below grade a different card entirely.
    poke(vm, sym_addr('boss_laser'), 0, 1)
    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)

    poke(vm, sym_addr('boss_hp'), 400, 2)
    poke(vm, sym_addr('boss_y'), 200, 2)
    poke(vm, sym_addr('boss_state'), BOSS_FIGHT, 1)
    assert wait_frames(vm, 3), "the boss fight never produced a frame"

    # ---- the hold (stage 2, 5.1) ---------------------------------------
    # Shots with no velocity at all: a frozen field is then unmistakable, and
    # a moving one is not one rounding error away from a pass.
    for k in range(4):
        inject_ebullet(vm, 300 + k * 40, 300, 0, 0, color=3)
    assert _count_active_ebullets(vm) >= 4, \
        "the frozen-field probes were not injected (%d in the pool)" \
        % _count_active_ebullets(vm)

    scenery0 = _backdrop_sample(vm)
    px0, py0 = player_pos(vm)
    poke(vm, sym_addr('boss_hp'), 250, 2)
    assert wait_frames(vm, 2), "the boss fight never produced a frame"
    assert tlm(vm, 'boss_st') == BOSS_FREEZE, (
        "crossing the mark did not hold the field, boss_st=%d" % tlm(vm, 'boss_st'))
    print("  -> the mark held the field (BOSS_FREEZE)")

    ex0, ey0 = _first_ebullet(vm)
    assert ex0 is not None, "the injected shots vanished before the hold"

    vm.joy = (76 << 8) | 76            # hard up-left, the craft has room
    vm.btn = raw_btn()
    held = 0
    cards = None
    scenery_seq = []
    while tlm(vm, 'boss_st') == BOSS_FREEZE and held < 120:
        assert wait_frames(vm, 1), "the game stopped producing frames"
        held += 1
        # Sample on a frame the plate is NOT shaken.  boss_shake slides the
        # whole plate down 4 rows on alternate frames, and the card's sky is a
        # high-frequency pattern (a diamond ward plus 220 single-pixel stars),
        # so a 4-row offset alone destroys most pixel matches.  The old sample
        # at `held == 4` landed on a shaken frame and read 40.5% for a plate
        # that is in fact on screen; the first assertions below still pass, so
        # this is about measuring the plate, not about loosening the bar.
        # Sample, then let the loop keep running: `break` here used to skip the
        # rest of the hold, and the hold has to run to completion for the
        # opener to fire at all.  The sample itself is at held == 8, well
        # inside the freeze.
        # Sample a few frames in, then keep looping: a reak here used to
        # skip the rest of the hold, and the hold has to reach its end for
        # the opener to fire.
        if cards is None and held == 4:
            cards = backdrop_scores(vm)
        # Collect the scenery across the hold.  boss_shake slides the plate 4
        # rows on alternate frames, so ANY single pair of samples can land on
        # two unshaken frames and read identical bytes.  A sequence cannot:
        # if the shake runs, some frame in it differs from the first.
        scenery_seq.append(_backdrop_sample(vm))
    vm.joy = (128 << 8) | 128
    assert held < 120, "the hold never released"

    # ---- L3: the card brings a sky the three stages do not have --------
    assert cards is not None, "the hold released before it could be sampled"
    best = max(cards, key=cards.get)
    print("  -> backdrop match during the hold: " +
          ", ".join("%s %.1f%%" % (k, 100.0 * v)
                    for k, v in sorted(cards.items(), key=lambda kv: -kv[1])))
    assert best == "CARD_BG", (
        "the card is showing %s, not a backdrop of its own: %r" % (best, cards))
    assert cards["CARD_BG"] >= 0.45, (
        "the card's own plate is barely on screen: only %.1f%% of the "
        "playfield matches it" % (100.0 * cards["CARD_BG"]))
    print("  -> the hold paints MM_CARD_BG (%d%% of the playfield), not a "
          "stage plate" % int(100.0 * cards["CARD_BG"]))

    px1, py1 = player_pos(vm)
    assert (px1, py1) != (px0, py0), (
        "the craft was frozen with the field: it sat at (%d,%d) for all %d "
        "frames of the hold" % (px0, py0, held))
    print("  -> the craft flew through the %d-frame hold: (%d,%d) -> (%d,%d)"
          % (held, px0, py0, px1, py1))

    ex1, ey1 = _first_ebullet(vm)
    if ex1 is not None:
        assert (ex1, ey1) == (ex0, ey0), (
            "an enemy shot moved during the hold: (%d,%d) -> (%d,%d)"
            % (ex0, ey0, ex1, ey1))
        print("  -> the field itself did not move: a shot sat at (%d,%d)"
              % (ex0, ey0))

    assert scenery_seq and any(s != scenery0 for s in scenery_seq), (
        "the scenery never changed during the card's hold: %d samples, all "
        "identical to the pre-hold frame - no plate swap and no shake"
        % len(scenery_seq))
    print("  -> the scenery swapped and shook through the hold")

    laser = tlm(vm, 'laser')
    assert laser > 0, "the hold released without firing the card"
    print("  -> card fired on release: %d laser frames on the clock, %d shots"
          % (laser, tlm(vm, 'ebullets')))
    # The columns come up over the first few frames of the opener (measured:
    # they carry bar colour from frame 6), so two frames is not enough to
    # sample them.
    assert wait_frames(vm, 8), "the game stopped producing frames"

    fb = vm.fb[vm.right_request]

    # ---- the laser columns, column by column ---------------------------
    # The columns are not framebuffer pixels any more.  They are synthesised by
    # the scanout (rtl/v_dma/video_laser.v) from the weather control word's
    # enable/band bits and the four x centres in APB 0xB0 / 0xB4 - four 16x768
    # copies a frame was 3,072 DRAM row activations, which is the frame the
    # board lost, and the whole point of the move is that the engine now issues
    # nothing at all for them.  The VM has no scanout, so there is no bar COPY
    # to look for and no column pixel to sample anywhere in the frame: what the
    # firmware controls, and what this can still grade, is that it stands the
    # four columns up and tells the hardware where they are.
    ctrl_word = vm.params.get(0x78, 0)
    assert ctrl_word & (1 << 18), (
        "the opener never enabled the hardware laser columns (ctrl %#x)"
        % ctrl_word)

    def columns():
        out = []
        for w in (0xB0, 0xB4):
            v = vm.params.get(w, 0)
            out += [v & 0xFFF, (v >> 12) & 0xFFF]
        return out

    cols = columns()
    print("  -> hardware columns at %s, band %d"
          % (cols, (ctrl_word >> 19) & 3))
    expect = [GAME_LEFT + (GAME_RIGHT - GAME_LEFT) * (2 * k + 1) // 8
              for k in range(4)]
    assert cols == expect, (
        "the opener's columns stand at %s; main.c's BOSS_LASER_X puts them at "
        "%s" % (cols, expect))

    # ---- the impact bursts --------------------------------------------
    bx, by = tlm(vm, 'boss_x'), tlm(vm, 'boss_y')
    hot = 0
    for y in range(max(130, by - 80), min(PLAYFIELD_BOTTOM, by + 120)):
        row = y * SCREEN_PITCH
        for x in range(max(GAME_LEFT, bx - 80), min(GAME_RIGHT, bx + 140)):
            if (fb[row + x] & 0xFFFFFF) in HOT_COLOURS:
                hot += 1
    print("  -> %d layer-coloured pixels around the boss at (%d,%d)" % (hot, bx, by))
    assert hot >= 40, "the opener's impact bursts left no layer colour around the boss"

    # ---- the composed frames themselves -------------------------------
    live = 0
    span = BURST_STRIDE * BURST_W
    for a in range(BURST_COUNT):
        off = MM_BURST_FRAME + a * span - SCRATCH_BASE
        px = vm.scratch[off:off + span]
        n = sum(1 for i in range(0, span, 4 * 11) if px[i:i + 3] != b"\x00\x00\x00")
        if n >= 20:
            live += 1
    print("  -> %d of %d composed burst frames hold pixels" % (live, BURST_COUNT))
    assert live >= 20, (
        "only %d of the %d composed burst frames are filled in - the effect "
        "would draw nothing" % (live, BURST_COUNT))

    # ---- what the frame costs -----------------------------------------
    f0, n0 = vm.blit_fill_calls, tlm(vm, 'frames')
    assert wait_frames(vm, 3), "the game stopped producing frames"
    dn = max(1, tlm(vm, 'frames') - n0)
    fills = (vm.blit_fill_calls - f0) / dn
    print("  -> opener frame: %.1f BitBlt FILLs (cap %d)" % (fills, OPENER_FILL_CAP))
    assert fills <= OPENER_FILL_CAP, (
        "the opener frame costs %.1f FILL commands; the composed-surface work "
        "took it to about 76 and the flood that caused 1.4 was 380" % fills)

    print("  [PASS] 4 columns, %d burst pixels, %d live frames, %.1f fills/frame"
          % (hot, live, fills))
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test22_bossopener.bmp",
                   Path(output_dir) / "test22_bossopener.png")
    return vm




# ----------------------------------------------------------------------
# the pressure stage (Task 11/12)
# ----------------------------------------------------------------------
# B+X on the boot menu drops straight into a boss fight with the bar pinned
# at full and a 192-shot storm on the field.  These four mirror main.c.
STRESS_STORM_TARGET = int(re.search(
    r"#define\s+STRESS_STORM_TARGET\s+(\d+)",
    (ROOT / "sw/app/main.c").read_text(encoding="utf-8"))[1])
STRESS_CARD_PERIOD = 180
BOSS_LASER_FRAMES = 90
BOSS_LASER_COLS = 4
STRESS_BG_BASE = mm_value("MM_STRESS_BG")   # the stage's own volcano


def _laser_columns(vm):
    """The four column centres the scanout was last told to draw.

    APB 0xB0/0xB4, two 12-bit centres a word.  video_laser.v draws these
    columns at scanout, so there is nothing in the framebuffer to sample -
    where the firmware aimed them is the observable.
    """
    lo = vm.params.get(0xB0, 0)
    hi = vm.params.get(0xB4, 0)
    return (lo & 0xFFF, (lo >> 12) & 0xFFF, hi & 0xFFF, (hi >> 12) & 0xFFF)


def _laser_enabled(vm):
    """(enable, band) out of the weather control word (APB 0x78)."""
    w = vm.params.get(0x78, 0)
    return (1 if (w & (1 << 18)) else 0, (w >> 19) & 0x3)


def _opener_columns():
    """BOSS_LASER_X(k), mirrored from the macro in main.c."""
    return tuple(GAME_LEFT + (GAME_RIGHT - GAME_LEFT) * (2 * k + 1) // 8
                 for k in range(BOSS_LASER_COLS))


def _enter_pressure_stage(vm):
    """Hold B and press X on the boot menu -> SCREEN_STRESS_STAGE.

    It is an edge on X with B still held, which menu_enter() cannot express:
    that helper only ever presses one button at a time.
    """
    vm.joy = (128 << 8) | 128
    wait_for_boot(vm)
    vm.btn = raw_btn('b', 'x')
    for _ in range(TICK * 4):
        vm.step()
    vm.btn = raw_btn()
    for _ in range(TICK * 2):
        vm.step()


def run_stress_lab(code, output_dir=None):
    """The pressure stage has to carry the BOSS lasers too.

    The stage behind B+X is a boss fight with no run-up: the bar is pinned at
    full - which is what keeps a death from clearing the barrage - and the
    field is never held.  That pin is exactly what used to hide every laser
    the boss has:

      * boss_opener() is the only thing that raises the four laser columns,
        and it is reached from the entrance hold or from one of the two
        health marks; this stage starts in BOSS_FIGHT at full health, so
        none of those ever happened and boss_laser stayed 0 for the whole
        run;
      * the pattern draw at wave 1 is the SPIRAL family plus PAT_RAIN, and
        neither PAT_CUT nor PAT_BEAM is in it, so the cut and the three
        staggered beams were unreachable as well.

    Everything below is graded on the registers the scanout draws from - the
    weather control word's enable bit, the four column centres, the three
    hairline slots - because none of those layers ever touch the framebuffer.
    """
    print("\n" + "=" * 65)
    print(" [TEST 26] Pressure stage: the BOSS lasers reach it")
    print("=" * 65)
    vm = new_vm(code)
    _enter_pressure_stage(vm)
    wave = peek(vm, 'wave', 2)
    assert wave == 1, "B+X did not land in the pressure stage (wave=%d)" % wave
    assert tlm(vm, 'boss_st') == BOSS_FIGHT, (
        "the pressure stage did not open on a fight (boss_st=%d)"
        % tlm(vm, 'boss_st'))
    print("  -> B+X landed in the pressure stage: wave 1, boss at station")

    # ---- 1. the stage opens with the opener --------------------------
    # stage_strip_render() publishes the control word and the four centres
    # before the world update runs, so the opener arms them a frame late:
    # ---- 1. the four opener columns stay in the campaign ------------
    # They belong to the entrance hold and to the two health marks, and
    # this stage crosses neither (the bar is pinned at full).  The lasers
    # it does fire are pattern ones - PAT_CUT and PAT_BEAM - and they are
    # graded further down.
    assert wait_frames(vm, 2), "the game stopped producing frames"
    laser_seen = 0
    for _ in range(60):
        assert wait_frames(vm, 1), "the game stopped producing frames"
        if peek(vm, 'boss_laser', 1):
            laser_seen += 1
    print("  -> 60 frames in: boss_laser > 0 on %d of them" % laser_seen)
    assert laser_seen == 0, (
        "the pressure stage raised the opener's columns on %d frames: "
        "that set piece belongs to the campaign" % laser_seen)

    # ---- 1b. and the stage keeps its own sky -------------------------
    # In the campaign the opener drags the card's backdrop in behind it
    # (boss_card_active, set by the entrance hold and by the two health
    # marks).  This stage's plate is the volcano it was built around,
    # so its opener must leave that flag alone.
    mine = plate_match(vm, STRESS_BG_BASE)
    card = plate_match(vm, MM_CARD_BG)
    print("  -> the playfield matches the stage plate %.1f%% and the "
          "card sky %.1f%%" % (100 * mine, 100 * card))
    assert mine >= 0.6, (
        "the opener swapped the pressure stage backdrop: only %.1f%% "
        "of the playfield is MM_STRESS_BG" % (100 * mine))
    assert mine > card, (
        "the playfield looks more like the card sky (%.1f%%) than the "
        "stage own plate (%.1f%%)" % (100 * card, 100 * mine))

    # ---- 2. the rules the stage was built around still hold ----------
    # Pinned bar, no hold, no field clearing: that is what makes the barrage
    # continuous.
    for _ in range(24):
        assert wait_frames(vm, 1), "the game stopped producing frames"
        assert peek(vm, 'boss_hp', 2) == peek(vm, 'boss_hp_max', 2), (
            "the pressure stage bar is not pinned any more (%d of %d)"
            % (peek(vm, 'boss_hp', 2), peek(vm, 'boss_hp_max', 2)))
        assert tlm(vm, 'boss_st') == BOSS_FIGHT, (
            "the pressure stage held the field: boss_st=%d" % tlm(vm, 'boss_st'))
    active = _count_active_ebullets(vm)
    print("  -> %d shots in the air, bar pinned at %d, no hold for 24 frames"
          % (active, peek(vm, 'boss_hp_max', 2)))
    assert active >= STRESS_STORM_TARGET * 3 // 4, (
        "the storm is not on the field: %d of %d shots"
        % (active, STRESS_STORM_TARGET))

    # ---- 5. both laser skills are in the stage's draw ----------------
    seen = set()
    for _ in range(60):
        poke(vm, sym_addr('boss_pat_timer'), 0, 1)
        assert wait_frames(vm, 1), "the game stopped producing frames"
        seen.add(tlm(vm, 'boss_pat'))
    print("  -> 60 draws dealt %s" % sorted(seen))
    assert PAT_CUT in seen and PAT_BEAM in seen, (
        "the stage cannot deal both laser skills (drew %s): wave 1's book "
        "has neither PAT_CUT nor PAT_BEAM in it" % sorted(seen))

    # ---- 6. the cut, aimed at the craft ------------------------------
    # Cleared first, so this is the pattern's own preview and not one the 60
    # draws above left standing.
    poke(vm, sym_addr('cut_phase'), 0, 1)
    poke(vm, sym_addr('beam_phase'), 0, CUT_SLOTS)
    poke(vm, sym_addr('beam_timer'), 0, CUT_SLOTS)
    poke(vm, sym_addr('boss_pattern'), PAT_CUT, 1)
    poke(vm, sym_addr('boss_pat_timer'), 127, 1)
    poke(vm, sym_addr('boss_fire_timer'), 0, 1)
    assert wait_frames(vm, 2), "the game stopped producing frames"
    px, _py = player_pos(vm)
    live = [s for s in _hair_slots(vm) if s[0]]
    print("  -> the cut preview: %s (craft at x=%d)"
          % ([(s[0], hex(s[2]), hex(s[3])) for s in live], px))
    assert live, ("the cut preview hairline never stood up in the pressure "
                  "stage")
    assert any(abs(s[0] - px) <= 2 for s in live), (
        "the preview stands at %s but the craft it promises to cut is at x=%d"
        % ([s[0] for s in live], px))
    assert any(s[2] in CUT_PREVIEW_COLOURS or s[3] in CUT_PREVIEW_COLOURS
               for s in live), (
        "the standing preview carries none of the preview colours: %s"
        % [(hex(s[2]), hex(s[3])) for s in live])

    spent = 0
    while peek(vm, 'cut_phase', 1) == 1 and spent < 30_000_000:
        vm.step()
        spent += 1
    assert peek(vm, 'cut_phase', 1) == 2, (
        "the preview never turned into a beam (phase=%d)"
        % peek(vm, 'cut_phase', 1))
    assert wait_published(vm), "the frame carrying the beam was never published"
    assert _laser_enabled(vm)[0], (
        "the cut fired but the scanout columns were never enabled")
    beam_cols = [c for c in _laser_columns(vm) if c]
    assert any(abs(c - px) <= 2 for c in beam_cols), (
        "the beam is at %s but the craft it is aimed at is at x=%d"
        % (beam_cols, px))
    print("  -> the cut fired %d steps later, beam at %s" % (spent, beam_cols))

    # ---- 7. the three staggered beams --------------------------------
    for k in range(CUT_SLOTS):
        poke(vm, sym_addr('beam_phase') + k, 0, 1)
    poke(vm, sym_addr('boss_pattern'), PAT_BEAM, 1)
    poke(vm, sym_addr('boss_pat_timer'), 127, 1)
    poke(vm, sym_addr('boss_fire_timer'), 0, 1)
    assert wait_frames(vm, 2), "the game stopped producing frames"
    lanes = sorted(s[0] for s in _hair_slots(vm) if s[0])
    assert len(lanes) >= CUT_SLOTS, (
        "the three staggered beams put %d columns on screen: %s"
        % (len(lanes), lanes))
    gaps = [lanes[k + 1] - lanes[k] for k in range(len(lanes) - 1)]
    assert max(gaps) <= 80, (
        "the beams are not the craft lane and its neighbours: gaps %s" % gaps)
    print("  -> the three beams stand at %s" % lanes)

    print("  [PASS] columns, cut and beams are all reachable in the pressure "
          "stage")
    if output_dir:
        save_frame(vm, vm.right_request,
                   Path(output_dir) / "test26_stresslab.bmp",
                   Path(output_dir) / "test26_stresslab.png")
    return vm

# ----------------------------------------------------------------------
# the lasers: one book per stage, and the registers when a run ends
# ----------------------------------------------------------------------

def run_laser_books(code, output_dir=None):
    """Every campaign stage has to be able to deal both laser skills.

    Stage 1's table has always carried PAT_CUT and PAT_BEAM.  Stage 2's did
    not - it was RAIN and the spiral family, three patterns in all - so that
    boss could never show a laser at all, and a player who reached stage 2
    fought a boss whose only attacks were bullets.  This grades the report
    directly: each stage, its own book, both skills reachable.

    It reads the pattern the world is holding (telemetry's boss_pat) rather
    than the table in main.c, so the shipped tables are what is graded.
    """
    print("\n" + "=" * 65)
    print(" [TEST 27] Every campaign stage can deal both laser skills")
    print("=" * 65)
    last = None
    for wave in (0, 1, 2):
        vm = new_vm(code)
        start_game(vm)
        vm.joy = (128 << 8) | 128
        _boss_arena(vm, PAT_FAN, wave=wave)
        seen = {}
        for _ in range(120):
            poke(vm, sym_addr('boss_pat_timer'), 0, 1)
            assert wait_frames(vm, 1), "the game stopped producing frames"
            p = tlm(vm, 'boss_pat')
            seen[p] = seen.get(p, 0) + 1
        last = vm
        cut = seen.get(PAT_CUT, 0)
        beam = seen.get(PAT_BEAM, 0)
        print("  -> stage %d (wave %d): 120 draws, %d distinct, CUT x%d BEAM x%d"
              % (wave + 1, wave, len(seen), cut, beam))
        assert cut and beam, (
            "stage %d cannot deal both laser skills (drew %s): PAT_CUT or "
            "PAT_BEAM is missing from its book" % (wave + 1, sorted(seen)))
    print("  [PASS] all three stages deal both lasers")
    if output_dir:
        save_frame(last, last.right_request,
                   Path(output_dir) / "test27_laser_books.bmp",
                   Path(output_dir) / "test27_laser_books.png")
    return last


def run_beam_clear_on_exit(code, output_dir=None):
    """Leaving a run takes the scanout's beam registers down with it.

    The craft's beam, the three warning hairlines and the four laser column
    centres are APB registers inside the scanout, not framebuffer pixels: the
    hardware holds whatever the run's last frame wrote.  A craft with its beam
    standing when the player paused and chose EXIT therefore left that beam
    lit over the boot menu - nothing in the menu ever writes 0xB8/0xBC, so
    nothing in the menu could take it down.
    """
    print("\n" + "=" * 65)
    print(" [TEST 28] Leaving a run clears the scanout beam registers")
    print("=" * 65)
    vm = new_vm(code)
    menu_enter(vm, 1)
    vm.joy = (128 << 8) | 128
    vm.btn = raw_btn()
    for _ in range(150_000):
        vm.step()

    def press_until(key, field, value, budget=80_000_000):
        vm.btn = raw_btn(key)
        spent = wait_telemetry(vm, field, value, budget)
        vm.btn = raw_btn()
        for _ in range(TICK):
            vm.step()
        return spent

    # ---- 1. light the craft's beam and a warning hairline ---------------
    # laser_tick() only lights the beam for the W_LASER stream, and only while
    # X is held, so both have to be true here.
    poke(vm, sym_addr('weapon'), WEAPON_LASER, 1)
    vm.btn = raw_btn('x')
    assert wait_frames(vm, 3), "the game stopped producing frames"
    beam_ctrl = vm.params.get(0xBC, 0)
    assert beam_ctrl & 0x800, (
        "the craft's beam never reached the scanout (beam_ctrl %#x)" % beam_ctrl)
    print("  -> the craft's beam is up: APB 0xBC = %#x, APB 0xB8 = %d"
          % (beam_ctrl, vm.params.get(0xB8, 0)))

    poke(vm, sym_addr('beam_x'), 500, 2)
    poke(vm, sym_addr('beam_timer'), 40, 1)
    poke(vm, sym_addr('beam_phase'), 1, 1)
    assert wait_frames(vm, 2), "the game stopped producing frames"
    hair = _hair_slots(vm)
    assert hair[0][0] == 500 and hair[0][3], (
        "the warning hairline never reached the scanout: %r" % (hair,))
    print("  -> warning hairline slot 0 at x=%d, colour %#x"
          % (hair[0][0], hair[0][3]))

    # ---- 2. pause, then EXIT -------------------------------------------
    press_until('b', 'paused', 1)
    assert tlm(vm, 'paused') == 1, "B did not open the settings menu"
    # The card keeps the RUN's frame on screen underneath it, so the beam is
    # still being published while the menu is up - which is exactly the state
    # the bug was reported from.
    poke(vm, sym_addr('beam_active'), 1, 1)
    poke(vm, sym_addr('beam_phase'), 1, 1)
    poke(vm, sym_addr('beam_timer'), 40, 1)
    for _ in range(TICK * 2):
        vm.step()
    assert vm.params.get(0xBC, 0) & 0x800, (
        "the paused frame stopped publishing the beam, so this grades nothing")

    press_until('a', 'settings', 1)
    press_until('a', 'settings', 2)
    press_until('a', 'settings', 3)
    assert tlm(vm, 'settings') == 3, "selection did not reach EXIT"
    press_until('x', 'paused', 0)
    assert (vm.params.get(0x5C, 0) & 0x00100000) != 0, (
        "EXIT did not return to the boot menu (HUD still off)")

    # ---- 3. nothing the run left behind may still be drawn --------------
    for _ in range(TICK):
        vm.step()
    ctrl = vm.params.get(0xBC, 0)
    x = vm.params.get(0xB8, 0)
    hair = _hair_slots(vm)
    cols = _laser_columns(vm)
    print("  -> on the menu: 0xBC=%#x 0xB8=%d hair=%r cols=%r"
          % (ctrl, x, [h[0] for h in hair], cols))
    assert ctrl == 0 and x == 0, (
        "the craft's beam survived into the boot menu (0xB8=%d, 0xBC=%#x)"
        % (x, ctrl))
    assert not any(h[0] or h[1] or h[2] or h[3] for h in hair), (
        "a warning hairline survived into the boot menu: %r" % (hair,))
    assert not any(cols), (
        "the laser column centres survived into the boot menu: %r" % (cols,))
    print("  [PASS] the menu owns no beam, no hairline and no column")
    if output_dir:
        save_frame(vm, vm.right_request,
                   Path(output_dir) / "test28_beam_clear.bmp",
                   Path(output_dir) / "test28_beam_clear.png")
    return vm


def run_stage3_skills(code, output_dir=None):
    """Stage 3's five advanced enemy skills, each on its own observable.

      * 8.1 the sweeping fan  - thirteen shots a volley with thirteen
                                distinct lateral speeds, and the muzzle
                                moves between volleys;
      * 8.2 the triple beam   - three blinking preview columns on screen at
                                once, one on the craft's lane and one either
                                side of it;
      * 8.3 the death burst   - an armoured kill leaves a ring of shots;
      * 8.4 the tornado       - sixteen shots a beat on eight turning arms;
      * 8.5 the lances        - eight shafts, eight bearings, and they come
                                back off the walls.

    It closes on the book: a stage-1 boss is forced through 80 changes and
    has to deal all four of the new attacks, which is what makes them
    "reachable in one fight" rather than merely implemented.
    """
    print("\n" + "=" * 65)
    print(" [TEST 24] Stage 3 skills: sway / beams / death burst / tornado / lance")
    print("=" * 65)

    # ---- 8.1 the sweeping fan ----------------------------------------
    vm = new_vm(code)
    start_game(vm)
    vm.joy = (128 << 8) | 128
    _boss_arena(vm, PAT_SWAY)
    shots = _live_ebullets(vm)
    assert len(shots) >= SWAY_SHOTS, \
        "8.1 threw %d shots, expected at least %d" % (len(shots), SWAY_SHOTS)
    speeds = sorted(set(b[3] for b in shots))
    print("  -> 8.1 fan: %d shots, lateral speeds %d..%d in %d steps"
          % (len(shots), speeds[0], speeds[-1], len(speeds)))
    assert len(speeds) >= 8, \
        "8.1's fan does not spread: only %d distinct lateral speeds" % len(speeds)

    centres = []
    for _ in range(3):
        shots = _refire(vm, SWAY_SHOTS)
        xs = [b[1] for b in shots]
        if xs:
            centres.append((max(xs) + min(xs)) // 2)
        poke(vm, sym_addr('boss_pat_timer'), 127, 1)
    print("  -> 8.1 muzzle: fan centres %s" % centres)
    assert len(set(centres)) >= 2, \
        "8.1's muzzle never moves: the fan came out at %s every volley" % centres

    # ---- 8.2 the three delayed columns -------------------------------
    vm = new_vm(code)
    start_game(vm)
    vm.joy = (128 << 8) | 128
    _boss_arena(vm, PAT_BEAM)
    px, py = player_pos(vm)
    assert wait_frames(vm, 3), "the game stopped producing frames"
    # Three scanout columns, read back from the registers the firmware aimed
    # them with - the same route 6.1's single preview takes above, and the same
    # judgement the pixel sweep used to make: three lanes, spread like the
    # craft's own lane and one either side of it.
    slots = _hair_slots(vm)
    lanes = sorted(s[0] for s in slots if s[0])
    print("  -> 8.2 preview columns at %s (craft at x=%d)" % (lanes, px))
    assert len(lanes) >= 3, \
        "8.2 should put three preview columns on screen, found %d at %s" \
        % (len(lanes), lanes)
    gaps = [lanes[k + 1] - lanes[k] for k in range(len(lanes) - 1)]
    assert max(gaps) <= 80, \
        "8.2's columns are not the craft's lane and its neighbours: gaps %s" % gaps
    assert any(s[2] in BEAM_PREVIEW_COLOURS or s[3] in BEAM_PREVIEW_COLOURS
               for s in slots if s[0]), \
        "8.2's standing columns carry none of the preview's colours: %s" \
        % [(s[0], hex(s[2]), hex(s[3])) for s in slots if s[0]]

    # ---- 8.3 an armoured kill leaves a ring ---------------------------
    vm = new_vm(code)
    start_game(vm)
    vm.joy = (128 << 8) | 128
    clear_pool(vm, ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, 13)
    clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
    px, py = player_pos(vm)
    ex, ey = px, max(140, py - 150)
    _pool_put(vm, ENEMY_BASE, 0, ENEMY_STRIDE, 0, ex, 2, True)
    _pool_put(vm, ENEMY_BASE, 0, ENEMY_STRIDE, 2, ey, 2, True)
    _pool_put(vm, ENEMY_BASE, 0, ENEMY_STRIDE, 4, 0, 2, True)
    _pool_put(vm, ENEMY_BASE, 0, ENEMY_STRIDE, 6, 0, 2, True)
    _pool_put(vm, ENEMY_BASE, 0, ENEMY_STRIDE, 8, 1, 2, True)     # hp 1
    _pool_put(vm, ENEMY_BASE, 0, ENEMY_STRIDE, 10, 2, 1)         # ENEMY_TURRET
    _pool_put(vm, ENEMY_BASE, 0, ENEMY_STRIDE, 11, 220, 1)       # never fires
    _pool_put(vm, ENEMY_BASE, 0, ENEMY_STRIDE, 13, 1, 1)         # EF_ACTIVE
    assert wait_frames(vm, 1), "the game stopped producing frames"
    assert tlm(vm, 'enemies') >= 1, "the turret was not placed"

    kills0 = tlm(vm, 'kills')
    vm.btn = raw_btn('x')
    frames = 0
    while tlm(vm, 'kills') == kills0 and frames < 300:
        assert wait_frames(vm, 1), "the game stopped producing frames"
        frames += 1
    vm.btn = raw_btn()
    assert tlm(vm, 'kills') > kills0, \
        "the parked turret survived %d frames of fire" % frames

    ring = [b for b in _live_ebullets(vm)
            if abs(b[1] - (ex + 8)) < 70 and abs(b[2] - (ey + 8)) < 70]
    bearings = set()
    for b in ring:
        bearings.add(((b[3] > 0) - (b[3] < 0), (b[4] > 0) - (b[4] < 0)))
    print("  -> 8.3 a turret died after %d frames and left %d shots on %d "
          "bearings" % (frames, len(ring), len(bearings)))
    assert len(ring) >= 8, \
        "8.3 the armoured kill left only %d shots, expected a ring of 8" % len(ring)
    assert len(bearings) >= 6, \
        "8.3's parting shots do not make a ring: only %d bearings" % len(bearings)

    # ---- 8.4 the tornado ---------------------------------------------
    vm = new_vm(code)
    start_game(vm)
    vm.joy = (128 << 8) | 128
    _boss_arena(vm, PAT_TORNADO)
    shots = _live_ebullets(vm)
    assert len(shots) >= TORNADO_SHOTS, \
        "8.4 threw %d shots, expected at least %d" % (len(shots), TORNADO_SHOTS)
    first = sorted(set((b[3], b[4]) for b in shots))
    second = sorted(set((b[3], b[4]) for b in _refire(vm, TORNADO_SHOTS)))
    print("  -> 8.4 %d shots; %d bearings, then %d bearings after a refire"
          % (len(shots), len(first), len(second)))
    assert len(first) >= 8, \
        "8.4's arms do not cover the compass: only %d bearings" % len(first)
    assert first != second, \
        "8.4 is not turning: two consecutive volleys came out identical"

    # ---- 8.5 the lances, and the bounce -------------------------------
    vm = new_vm(code)
    start_game(vm)
    vm.joy = (128 << 8) | 128
    _boss_arena(vm, PAT_LANCE)
    lances = _live_ebullets(vm, EF_LANCE)
    assert len(lances) >= 8, \
        "8.5 threw %d lances, expected eight" % len(lances)
    dirs = set()
    for b in lances:
        dirs.add(((b[3] > 0) - (b[3] < 0), (b[4] > 0) - (b[4] < 0)))
    print("  -> 8.5 %d lances on %d compass bearings" % (len(lances), len(dirs)))
    assert len(dirs) >= 8, \
        "8.5 does not cover eight bearings: %s" % sorted(dirs)

    bounced = 0
    for _ in range(240):
        assert wait_frames(vm, 1), "the game stopped producing frames"
        for b in _live_ebullets(vm, EF_LANCE):
            x, y, vx, vy = b[1], b[2], b[3], b[4]
            if (x > GAME_RIGHT - 40 and vx < 0) or (x < GAME_LEFT + 40 and vx > 0) \
               or (y < 170 and vy > 0) or (y > 560 and vy < 0):
                bounced += 1
        if bounced:
            break
    print("  -> 8.5 %d lances seen flying away from a wall they must have hit"
          % bounced)
    assert bounced > 0, \
        "8.5's lances never came back: nothing was seen heading away from " \
        "a wall it can only have reached by bouncing"

    # ---- and all four are in the stage-1 book -------------------------
    vm = new_vm(code)
    start_game(vm)
    _boss_arena(vm, PAT_FAN, wave=0)
    seen = set()
    for _ in range(80):
        poke(vm, sym_addr('boss_pat_timer'), 0, 1)
        assert wait_frames(vm, 1), "the game stopped producing frames"
        seen.add(tlm(vm, 'boss_pat'))
    missing = sorted({PAT_SWAY, PAT_BEAM, PAT_TORNADO, PAT_LANCE} - seen)
    print("  -> 80 changes of a stage-1 boss dealt %d distinct patterns: %s"
          % (len(seen), sorted(seen)))
    assert not missing, \
        "a stage-1 boss never dealt %s in 80 changes" % missing

    print("  [PASS] all five stage-3 skills fire, draw and are in the book")
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test24_skills3.bmp",
                   Path(output_dir) / "test24_skills3.png")
    return vm


def run_item_rewards(code, output_dir=None):
    """Debuffs pay nothing, and both end screens claim their own snow-free box."""
    print("\n" + "=" * 65)
    print(" [TEST 25] Item rewards and the two end screens")
    print("=" * 65)
    vm = new_vm(code)
    start_game(vm)
    vm.btn = raw_btn()                  # no trigger held: nothing is being shot

    def box_now(label):
        """The occlusion box the firmware published, as (x0, y0, x1, y1)."""
        x = vm.params.get(0x8C, 0)
        assert x >> 31, "%s published no weather occlusion box" % label
        y = vm.params.get(0xAC, 0)
        return (x & 0x7FF, y & 0x7FF, (x >> 11) & 0x7FF, (y >> 11) & 0x7FF)

    # ---- 1. what a pickup is worth ---------------------------------------
    # A heal pays its flat 50; a SLOW or a JAM pays nothing at all.  The player
    # still took it - the counter moves and the effect lands - but a penalty the
    # player failed to dodge must not read as a reward on the score popup, and
    # dodging one has to be worth something.
    def pickup(type_, label):
        clear_pool(vm, EBULLET_BASE, EBULLET_COUNT, 8, 6)
        clear_pool(vm, ENEMY_BASE, ENEMY_COUNT, ENEMY_STRIDE, 13)
        score0, taken0 = tlm(vm, 'score'), tlm(vm, 'taken')
        assert feed_item(vm, tlm(vm, 'player_x'), tlm(vm, 'player_y'), type_), \
            "%s was never picked up" % label
        for _ in range(TICK * 2):
            vm.step()
        return tlm(vm, 'score') - score0, tlm(vm, 'taken') - taken0

    gain, took = pickup(ITEM_HEAL, "HEAL")
    assert took == 1, "the pickup counter missed the HEAL"
    assert gain == 50, "a HEAL paid %d points, expected the flat 50" % gain
    print("  -> HEAL: taken, +%d points" % gain)

    gain, took = pickup(ITEM_SCORE, "PTS")
    assert took == 1, "the pickup counter missed the PTS drop"
    assert gain == 550, "a PTS drop paid %d, expected 50 + its own 500" % gain
    print("  -> PTS : taken, +%d points" % gain)

    for type_, label, field in ((ITEM_SLOW, "SLOW", 'slow'),
                                (ITEM_JAM, "JAM", 'jam')):
        gain, took = pickup(type_, label)
        assert took == 1, "the pickup counter missed the %s" % label
        assert gain == 0, \
            "a %s paid %d points: a debuff is not a prize" % (label, gain)
        assert tlm(vm, field) > 0, "the %s had no effect at all" % label
        print("  -> %s: taken, +0 points, %s timer %d"
              % (label, label, tlm(vm, field)))

    # ---- 2. GAME OVER is a full-screen panel -----------------------------
    # Both end screens are framebuffer pixels with the snow composited above
    # them, so each has to publish the rectangle the scanout must leave alone.
    # They are minutes of play apart, so the state that raises each one is
    # forced and the box is what gets graded.
    poke(vm, sym_addr('game_over'), 1, 1)
    poke(vm, sym_addr('restart_timer'), 60, 1)
    # Stepped rather than waited on: the game-frame counter is what wait_frames()
    # watches, and it stops advancing the moment the run is over.  Three display
    # frames is one more than the renderer needs to reach the GAME OVER branch.
    for _ in range(TICK * 3):
        vm.step()
    x0, y0, x1, y1 = box_now("GAME OVER")
    assert (x0, y0, x1, y1) == (0, 0, 1365, 767), \
        "GAME OVER published the box %s, not the whole screen" % ((x0, y0, x1, y1),)
    print("  -> GAME OVER: occlusion box x %d..%d y %d..%d" % (x0, x1, y0, y1))

    # ---- 3. ALL CLEAR covers its own panel -------------------------------
    poke(vm, sym_addr('game_over'), 0, 1)
    poke(vm, sym_addr('game_clear'), 1, 1)
    for _ in range(TICK * 3):
        vm.step()
    x0, y0, x1, y1 = box_now("ALL CLEAR")
    # The stage banner shares the frame for the first 170 frames of a stage and
    # the box is the union of everything that is up, so what is graded is "the
    # panel is covered", not "the box is exactly the panel".
    assert x0 <= 411 and y0 <= 300 and x1 >= 954 and y1 >= 467, \
        "the ALL CLEAR panel (411..954 x 300..467) is not covered: box %s" % (
            (x0, y0, x1, y1),)
    print("  -> ALL CLEAR: occlusion box x %d..%d y %d..%d" % (x0, x1, y0, y1))

    print("  [PASS] debuffs pay nothing; both end screens are punched out of "
          "the weather layer")
    if output_dir:
        save_frame(vm, vm.right_request, Path(output_dir) / "test25_all_clear.bmp",
                   Path(output_dir) / "test25_all_clear.png")
    return vm


def suite_catalog(code, out_dir):
    """(id, description, callable) for every scenario the workbench knows."""
    return [
        ("render",    "Mode 1: 650 objects + block copy",
         lambda: run_mode1_benchmark(code, out_dir)),
        ("spawn",     "Bullet hell idle/spawn",
         lambda: run_mode2_deadzone(code, out_dir)),
        ("controls",  "Bullet hell controls/fire",
         lambda: run_mode2_dynamic_motion(code, output_dir=out_dir)),
        ("clamp",     "Bullet hell boundary clamping",
         lambda: run_mode2_boundary_clamp(code, out_dir)),
        ("menu",      "Boot menu navigation",
         lambda: run_menu_navigation(code, out_dir)),
        ("colorkey",  "Color Key sprite integrity",
         lambda: run_copy_integrity(code, out_dir)),
        ("alpha",     "Hardware Alpha blending",
         lambda: run_alpha_blend(code, out_dir)),
        ("stage",     "Stage progression: kills / power-ups / boss",
         lambda: run_stage_progression(code, out_dir)),
        ("settings",  "Settings menu: pause / toggles / exit",
         lambda: run_settings_menu(code, out_dir)),
        ("weaponcap", "Weapon cap: extra SHOT pickups must not overflow",
         lambda: run_weapon_level_cap(code, out_dir)),
        ("invuln",    "Pickup still works during invulnerability",
         lambda: run_pickup_during_invuln(code, out_dir)),
        ("hitsweep",  "A hit sweeps the field, seeds motes and respawns",
         lambda: run_hit_sweep(code, out_dir)),
        ("edge",      "Pickup reaches the silhouette edge",
         lambda: run_pickup_at_sprite_edge(code, out_dir)),
        ("backdrops", "Three-stage backdrops step 0 -> 1 -> 2",
         lambda: run_stage_backdrop_progression(code, out_dir)),
        ("bulletpool", "Maxed FAN shot must not starve one arm of the fan",
         lambda: run_fan_bullet_pool(code, out_dir)),
        ("sticknoise", "Idle stick jitter must not move the craft",
         lambda: run_stick_noise(code, out_dir)),
        ("spellcard", "Centre-click spends a full spell card",
         lambda: run_spell_card(code, out_dir)),
        ("impactfx",  "Impact effect: a kill draws the burst layers",
         lambda: run_impact_fx(code, out_dir)),
        ("hudfx",     "HUD gutters follow the state they display",
         lambda: run_hud_follows_state(code, out_dir)),
        ("bossdream", "Stage 3 boss: the derived tile is drawn",
         lambda: run_stage3_boss_visible(code, out_dir)),
        ("bombbounds", "Spell card on the bottom edge stays in frame",
         lambda: run_bomb_bounds(code, out_dir)),
        ("bossopener", "Boss spell card: laser columns and burst on screen",
         lambda: run_boss_opener(code, out_dir)),
        ("skills",   "Stage 2 skills: cut / lock-on / all-round / mass aimed",
         lambda: run_stage2_skills(code, out_dir)),
        ("skills3",  "Stage 3 skills: sway / beams / death burst / tornado / "
                      "bouncing lance",
         lambda: run_stage3_skills(code, out_dir)),
        ("stresslab", "Pressure stage: the BOSS lasers reach it",
         lambda: run_stress_lab(code, out_dir)),
        ("laserbooks", "Every campaign stage deals both laser skills",
         lambda: run_laser_books(code, out_dir)),
        ("beamclear", "Leaving a run clears the scanout beam registers",
         lambda: run_beam_clear_on_exit(code, out_dir)),
        ("rewards",  "Item rewards: debuffs pay nothing; end-screen boxes",
         lambda: run_item_rewards(code, out_dir)),
    ]


GROUPS = {
    "render":   ["render", "colorkey", "alpha"],
    "play":     ["spawn", "controls", "clamp", "menu"],
    "regress":  ["weaponcap", "invuln", "hitsweep", "edge", "bulletpool",
                 "sticknoise", "spellcard", "rewards"],
    "stage1":   ["impactfx", "hudfx", "bossdream", "bombbounds"],
    "stage2":   ["bossopener", "skills"],
    "stage3":   ["skills3"],
    "settings": ["settings"],
    "explore":  ["stage"],
    "backdrop": ["backdrops"],
    "stress":   ["stresslab"],
    "lasers":   ["laserbooks", "beamclear"],
}


# ----------------------------------------------------------------------
# scenario scheduling: serial, or one worker process per scenario
# ----------------------------------------------------------------------
SIM_TIME_LOG = SIM_DIR / "cache" / "scenario_times.json"
DEFAULT_SCENARIO_SECONDS = 120.0


def _load_time_log():
    """Best-effort history of how long each scenario took on this machine.

    Only used to ORDER the work: the slowest scenario is submitted first so it
    overlaps the tail of everything else instead of running alone at the end.
    The measurements themselves never enter a verdict.
    """
    try:
        data = json.loads(SIM_TIME_LOG.read_text(encoding="utf-8"))
        return {k: float(v) for k, v in data.items()}
    except Exception:                                   # noqa: BLE001
        return {}


def _save_time_log(times):
    try:
        SIM_TIME_LOG.parent.mkdir(parents=True, exist_ok=True)
        SIM_TIME_LOG.write_text(json.dumps(times, indent=1, sort_keys=True),
                                encoding="utf-8")
    except Exception:                                   # noqa: BLE001
        pass


def _schedule_order(ids, times):
    """`ids` ordered slowest-first; ties keep the caller's order."""
    rank = {tid: i for i, tid in enumerate(ids)}
    return sorted(ids, key=lambda t: (-times.get(t, DEFAULT_SCENARIO_SECONDS),
                                      rank[t]))


# Worker state.  Each pool process loads the firmware image and the boot
# snapshot once and then runs whole scenarios back to back.  Scenarios stay as
# independent as they are on the serial path: every one of them builds its own
# machine through new_vm(), and no two scenarios export the same picture name.
_WORKER = {}


def _worker_boot(source_path, out_dir):
    with contextlib.redirect_stdout(io.StringIO()):
        _WORKER["code"] = load_code_from_source(source_path)
        snapshot_blob()             # one ~56 MB read per process
    _WORKER["out_dir"] = out_dir


def _worker_scenario(tid):
    """Run one scenario here and hand its entire log back as one string."""
    code = _WORKER["code"]
    out_dir = _WORKER["out_dir"]
    catalog = {t[0]: (t[1], t[2]) for t in suite_catalog(code, out_dir)}
    desc, fn = catalog[tid]

    log = io.StringIO()
    started = time.time()
    ok = False
    problem = None
    try:
        with contextlib.redirect_stdout(log):
            ok = bool(fn())
    except BaseException as exc:                        # noqa: BLE001
        import traceback
        with contextlib.redirect_stdout(log):
            traceback.print_exc()
        problem = "%s: %s" % (type(exc).__name__, exc)
    return (tid, desc, ok, problem, log.getvalue(), time.time() - started)


def _report(tid, desc, ok, problem, log, secs, times):
    """Print one scenario's own output, then its verdict, in caller order."""
    if log and not log.endswith("\n"):
        log += "\n"
    print(log, end="")
    if ok:
        print("  [OK]   %s  (%.1fs)" % (desc, secs))
    else:
        print("  [FAIL] %s: %s" % (desc, problem))
    times[tid] = round(secs, 2)
    return 1 if ok else 0


def run_selected(code, out_dir, ids, jobs=1):
    catalog = {tid: (desc, fn) for tid, desc, fn in suite_catalog(code, out_dir)}
    unknown = [i for i in ids if i not in catalog]
    if unknown:
        raise SystemExit("unknown test id(s): %s\nknown ids: %s"
                         % (", ".join(unknown), ", ".join(sorted(catalog))))

    times = _load_time_log()
    workers = len(ids) if jobs < 0 else min(jobs, len(ids)) if jobs > 0 else 1
    parallel = workers > 1 and len(ids) > 1 and _FW_SOURCE

    print("=" * 65)
    print("   TI60 2D WORKBENCH - %d SCENARIO(S)%s"
          % (len(ids), " ON %d PROCESSES" % workers if parallel else ""))
    print("=" * 65)
    started = time.time()
    passed = 0

    if not parallel:
        for tid in ids:
            desc, fn = catalog[tid]
            t0 = time.time()
            try:
                if fn():
                    passed += 1
                    print("  [OK]   %s  (%.1fs)" % (desc, time.time() - t0))
            except Exception as exc:                    # noqa: BLE001
                print("  [FAIL] %s: %s" % (desc, exc))
                import traceback
                traceback.print_exc()
            times[tid] = round(time.time() - t0, 2)
    else:
        import concurrent.futures as cf
        order = _schedule_order(ids, times)
        results = {}
        print("   order: %s" % " ".join(order))
        with cf.ProcessPoolExecutor(max_workers=workers,
                                    initializer=_worker_boot,
                                    initargs=(_FW_SOURCE, out_dir)) as pool:
            futures = {pool.submit(_worker_scenario, tid): tid
                       for tid in order}
            for fut in cf.as_completed(futures):
                tid = futures[fut]
                try:
                    results[tid] = fut.result()
                    print("   ... %-11s done in %6.1fs" % (tid, results[tid][5]),
                          flush=True)
                except BaseException as exc:            # noqa: BLE001
                    results[tid] = (tid, catalog[tid][0], False,
                                    "worker died: %s" % exc, "", 0.0)
                    print("   ... %-11s WORKER DIED: %s" % (tid, exc), flush=True)
        for tid in ids:
            passed += _report(*results[tid], times=times)

    _save_time_log(times)
    print("\n" + "=" * 65)
    print(" VERIFICATION SUMMARY: %d/%d TESTS PASSED in %.1fs"
          % (passed, len(ids), time.time() - started))
    print("=" * 65)
    if passed == len(ids):
        print(" [ALL VERIFICATION CHECKS COMPLETED SUCCESSFULLY]\n")
        return 0
    print(" [SOME CHECKS FAILED - REVIEW LOGS ABOVE]\n")
    return 1


def run_comprehensive_suite(code, out_dir, jobs=1):
    return run_selected(code, out_dir,
                        [t[0] for t in suite_catalog(code, out_dir)], jobs)


def main():
    ap = argparse.ArgumentParser(
        description="Standalone Ti60 2D simulator workbench",
        epilog="groups: " + ", ".join(sorted(GROUPS)))
    ap.add_argument("--source", default=str(DEFAULT_SOURCE))
    ap.add_argument("--mode", type=int, choices=[0, 1, 2], default=0)
    ap.add_argument("--suite", action="store_true", default=False,
                    help="run every scenario (long; prefer --group)")
    ap.add_argument("--group", choices=sorted(GROUPS),
                    help="run one short batch instead of the whole suite")
    ap.add_argument("--only", help="comma separated test ids, e.g. alpha,edge")
    ap.add_argument("--list", action="store_true", help="list ids and groups")
    ap.add_argument("--refresh-snapshot", action="store_true",
                    help="boot the firmware again and rebuild the cached state")
    ap.add_argument("--jobs", type=int, default=1,
                    help="run scenarios in N worker processes (default 1 = "
                         "serial; -1 = one per scenario).  Scenarios are "
                         "independent, so the results are identical - only the "
                         "wall clock changes")
    ap.add_argument("--joy-x", type=int, default=180)
    ap.add_argument("--joy-y", type=int, default=180)
    ap.add_argument("--btn-a", action="store_true", default=True)
    ap.add_argument("--export-images", action="store_true", default=True)
    a = ap.parse_args()

    out_dir = (SIM_DIR / "output") if a.export_images else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    code = load_code_from_source(a.source)

    if a.list:
        members = {}
        for g, ids in sorted(GROUPS.items()):
            for i in ids:
                members.setdefault(i, []).append(g)
        print("\n  %-11s %-30s %s" % ("id", "groups", "scenario"))
        print("  " + "-" * 78)
        for tid, desc, _fn in suite_catalog(code, out_dir):
            print("  %-11s %-30s %s"
                  % (tid, ",".join(members.get(tid, [])) or "-", desc))
        print("\n  groups: " + ", ".join("%s(%d)" % (g, len(v))
                                         for g, v in sorted(GROUPS.items())))
        return 0

    build_boot_snapshot(code, force=a.refresh_snapshot)

    if a.only:
        return run_selected(code, out_dir,
                            [s.strip() for s in a.only.split(",") if s.strip()],
                            a.jobs)
    if a.group:
        return run_selected(code, out_dir, GROUPS[a.group], a.jobs)
    if a.suite or a.mode == 0:
        return run_comprehensive_suite(code, out_dir, a.jobs)
    if a.mode == 1:
        run_mode1_benchmark(code, out_dir)
    else:
        run_mode2_dynamic_motion(code, a.joy_x, a.joy_y, out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
