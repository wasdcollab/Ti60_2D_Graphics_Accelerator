# -*- coding: utf-8 -*-
r"""Dump the scanout's inputs out of the firmware, so a Verilator bench can
composite the SAME frame the board would show.

Every layer that went missing on the board - the boss laser columns, the
warning hairlines, the player beam, and the B1 bullet curtain - is synthesised
by the SCANOUT.  The RV32 VM has no scanout, so it can only prove the firmware
wrote the right registers; whether those registers reach the picture is an RTL
question.  This dumps the state so tests/tb_scanout_layers.sv can answer it
with the firmware's OWN values, and writes scanout.ppm out of the bench.

Usage:  python tools\dump_scanout_state.py <case>
    menu    - the boot menu (the bucket tables are empty)
    game    - a live campaign run with the curtain up
    stress  - the pressure stage with the opener laser columns standing
    exit    - leave a run with the curtain up, then sample the menu
    beampause - the craft's beam with the pause card up
    beamfree  - the craft's beam with nothing in front of it
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))

import test_runner as T

OUT = ROOT / "work_sim" / "scanout"
BUCKET = T.mm_value("MM_BUCKET_TABLE")
STRIDE = T.mm_value("MM_BUCKET_STRIDE")
ROWS = T.mm_value("MM_BUCKET_ROWS")
TABLES = 2
SLOTS = T.mm_value("MM_BUCKET_SLOTS")

REG_NAMES = [
    "weather_ctrl", "laser_colx_lo", "laser_colx_hi", "beam_x", "beam_ctrl",
    "hair_x0", "hair_x1", "hair_x2",
    "hair_out0", "hair_out1", "hair_out2",
    "hair_lft0", "hair_lft1", "hair_lft2",
    "hair_mid0", "hair_mid1", "hair_mid2",
    "bucket_base", "hud_enable", "frames",
    "weather_mask_x", "weather_mask_y",
]


def blank(vm, n):
    for _ in range(n):
        T.wait_frames(vm, 1, budget=8_000_000)


def enter_stress(vm):
    vm.joy = (128 << 8) | 128
    T.wait_for_boot(vm)
    vm.btn = T.raw_btn("b", "x")
    for _ in range(T.TICK * 4):
        vm.step()
    vm.btn = T.raw_btn()
    for _ in range(T.TICK * 2):
        vm.step()


def play_and_leave(vm):
    T.start_game(vm)
    vm.btn = T.raw_btn("x")
    blank(vm, 30)
    vm.btn = T.raw_btn()
    vm.board_keys = 1
    for _ in range(T.TICK * 40):
        vm.step()
    vm.board_keys = 0
    blank(vm, 8)


def collect(vm, hud):
    regs = []
    regs.append(vm.params.get(0x78, 0))
    regs.append(vm.params.get(0xB0, 0))
    regs.append(vm.params.get(0xB4, 0))
    regs.append(vm.params.get(0xB8, 0))
    regs.append(vm.params.get(0xBC, 0))
    for k in range(T.CUT_SLOTS):
        regs.append(vm.params.get(0xC0 + 16 * k + 0, 0))
    for k in range(T.CUT_SLOTS):
        regs.append(vm.params.get(0xC0 + 16 * k + 4, 0))
    for k in range(T.CUT_SLOTS):
        regs.append(vm.params.get(0xC0 + 16 * k + 8, 0))
    for k in range(T.CUT_SLOTS):
        regs.append(vm.params.get(0xC0 + 16 * k + 12, 0))
    regs.append(vm.params.get(0xF0, 0))
    regs.append(hud)
    regs.append(3)
    # The scanout occlusion box: the pause card, the stage banner and the
    # boss dialogue publish it, and both scanout layers have to honour it.
    regs.append(vm.params.get(0x8C, 0))
    regs.append(vm.params.get(0xAC, 0))
    return regs


def write_regs(path, regs):
    with open(path, "w") as f:
        for v in regs:
            f.write("%08x\n" % (v & 0xFFFFFFFF))


def write_bucket(vm, path):
    off = BUCKET - T.SCRATCH_BASE
    raw = bytes(vm.scratch[off:off + STRIDE * ROWS * TABLES])
    with open(path, "w") as f:
        for i in range(0, len(raw), 4):
            f.write("%08x\n" % int.from_bytes(raw[i:i + 4], "little"))
    live = 0
    for r in range(ROWS * TABLES):
        base = r * STRIDE
        for k in range(SLOTS):
            w = int.from_bytes(raw[base + k * 4:base + k * 4 + 4], "little")
            if (w >> 24) & 31:
                live += 1
    return live


def write_fb(vm, path):
    """The framebuffer the scanout is reading right now, as hex words.

    RTL reads this through the same AXI port as everything else, so the
    bench has to serve it byte for byte; without it the composed frame has
    the scanout layers but no stage behind them.  Both buffers are handed
    the same image - the bench composites one frame of one buffer."""
    fb = vm.fb[vm.right_active]
    with open(path, "w") as f:
        for w in fb:
            f.write("%08x\n" % (w & 0xFFFFFFFF))
    return len(fb)


def main():
    case = (sys.argv[1] if len(sys.argv) > 1 else "menu").lower()
    OUT.mkdir(parents=True, exist_ok=True)
    code = T.load_code_from_source(ROOT / "sw" / "build" / "firmware.bin")
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    hud = 1

    if case == "menu":
        T.wait_for_boot(vm)
        blank(vm, 6)
        vm.params[0x78] = 0      # the menu writes the weather word to zero
        hud = 0                  # board_set_hud_disable(1) on the menu
    elif case == "game":
        T.start_game(vm)
        vm.btn = T.raw_btn("x")
        blank(vm, 30)
        vm.btn = T.raw_btn()
    elif case == "exit":
        play_and_leave(vm)
        hud = 0
    elif case == "pause":
        # A run with the pause card up: the barrage is still being built
        # (game_render runs under the card), so this is the frame the board
        # used to show bullets over.
        T.start_game(vm)
        vm.btn = T.raw_btn("x")
        blank(vm, 20)
        vm.btn = T.raw_btn()
        T.press(vm, "b", frames=5)
        blank(vm, 4)
    elif case == "stress":
        enter_stress(vm)
        # Hold the fire button.  The pressure stage's two wing missiles only
        # exist while the craft is shooting - stress_player_fire() is the only
        # caller of spawn_pbullet_lockon() - and they are the ONE shape in the
        # build that blends its body and adds its trail at the same time.  A
        # frame with the button up has no missiles in it at all, so the bench
        # could not show either mix.  They re-aim every frame and fly at 7
        # pixels a frame, so the last salvo is still well inside the playfield.
        vm.btn = T.raw_btn("x")
        blank(vm, 30)
    elif case == "cut":
        # A campaign boss with its CUT laser lit.  "stress" shows the opener's
        # four fixed columns; here the centre is wherever the boss aimed, which
        # is the path the pattern lasers take.
        T.start_game(vm)
        vm.joy = (128 << 8) | 128
        T.clear_pool(vm, T.ENEMY_BASE, T.ENEMY_COUNT, T.ENEMY_STRIDE, 13)
        T.poke(vm, T.sym_addr("kills"), 999, 2)
        for _ in range(400):
            T.wait_frames(vm, 1, budget=8_000_000)
            if T.tlm(vm, "boss_st") == 2:
                break
        T._boss_arena(vm, 10, wave=0)          # PAT_CUT queued, hp held
        off = T.sym_addr("beam_phase") - T.RAM_BASE
        for _ in range(240):
            T.wait_frames(vm, 1, budget=8_000_000)
            if vm.ram[off] == 2:
                break
        print("  cut laser: phase=%r cols=%r ctrl=%#x"
              % (list(vm.ram[off:off + 3]), T._laser_columns(vm),
                 vm.params.get(0x78, 0)))
    elif case == "cutpause":
        # The same lit cut laser with the pause card up: this is the frame the
        # laser layer used to draw straight over the card.
        T.start_game(vm)
        vm.joy = (128 << 8) | 128
        T.clear_pool(vm, T.ENEMY_BASE, T.ENEMY_COUNT, T.ENEMY_STRIDE, 13)
        T.poke(vm, T.sym_addr("kills"), 999, 2)
        for _ in range(400):
            T.wait_frames(vm, 1, budget=8_000_000)
            if T.tlm(vm, "boss_st") == 2:
                break
        T._boss_arena(vm, 10, wave=0)
        off = T.sym_addr("beam_phase") - T.RAM_BASE
        for _ in range(240):
            T.wait_frames(vm, 1, budget=8_000_000)
            if vm.ram[off] == 2:
                break
        T.press(vm, "b", frames=5)
        blank(vm, 4)
        print("  cut laser (paused): phase=%r cols=%r box=%#x/%#x"
              % (list(vm.ram[off:off + 3]), T._laser_columns(vm),
                 vm.params.get(0x8C, 0), vm.params.get(0xAC, 0)))
    elif case == "beampause":
        # The craft's OWN beam with the pause card up.  laser_tick() only lights
        # it for the W_LASER stream and only while X is held, and opening the
        # menu releases X - so the flag is put back after the card is up, which
        # is also the state the bug was reported from: the card keeps drawing
        # the run's own frame underneath it, beam and all.
        T.start_game(vm)
        vm.joy = (128 << 8) | 128
        T.poke(vm, T.sym_addr("weapon"), T.WEAPON_LASER, 1)
        vm.btn = T.raw_btn("x")
        blank(vm, 6)
        T.press(vm, "b", frames=5)
        blank(vm, 2)
        T.poke(vm, T.sym_addr("beam_active"), 1, 1)
        blank(vm, 3)
        print("  pause: beam_ctrl=%#x beam_x=%d box=%#x/%#x"
              % (vm.params.get(0xBC, 0), vm.params.get(0xB8, 0),
                 vm.params.get(0x8C, 0), vm.params.get(0xAC, 0)))
    elif case == "beamfree":
        # The craft's own beam with NOTHING in front of it: no pause card, no
        # stage banner, no dialogue box.  "beampause" puts the card over the
        # craft, so the beam's last rows are behind the occlusion box and the
        # picture cannot answer the question this case exists for - where does
        # the beam stop relative to the craft?  The craft is drawn into the
        # framebuffer and the beam is composited above it, so the rows between
        # the craft's top edge and its centre are the only place the two are
        # visible together.
        T.start_game(vm)
        T.poke(vm, T.sym_addr("weapon"), T.WEAPON_LASER, 1)
        vm.btn = T.raw_btn("x")
        blank(vm, 8)
        print("  beamfree: beam_ctrl=%#x beam_x=%d player=(%d,%d)"
              % (vm.params.get(0xBC, 0), vm.params.get(0xB8, 0),
                 T.tlm(vm, "player_x"), T.tlm(vm, "player_y")))
    else:
        raise SystemExit("unknown case %r" % case)

    regs = collect(vm, hud)
    write_regs(OUT / "regs.hex", regs)
    live = write_bucket(vm, OUT / "bucket.hex")
    nfb = write_fb(vm, OUT / "fb.hex")

    # The bench's phase B draws bullets only when it has a second bucket table
    # of its own, and it reads that from bucket2.hex.  Nothing in the project
    # writes one any more: the two files that used to sit in work_sim/scanout
    # were 2026/09/29 leftovers bound to the slot encoding of that week, and
    # deleting them was right.  So this case's own table is written twice, once
    # per phase - without it phase B composites an empty curtain, and the frame
    # the bench exports has no bullets in it at all.
    (OUT / "bucket2.hex").write_bytes((OUT / "bucket.hex").read_bytes())
    (OUT / "regs2.hex").write_bytes((OUT / "regs.hex").read_bytes())

    # The tile store and the palette the scanout reads are generated by
    # tools/gen_bullet_tiles.py into simulator/output.  The bench reads them
    # from work_sim/scanout by relative path, and until now the only way they
    # got there was somebody copying them by hand - so a clean work_sim meant a
    # bench that either failed to start or ran on last week (s tile bytes.
    for name in ("bullet_tiles.hex", "bullet_palette.hex"):
        src = ROOT / "simulator" / "output" / name
        if not src.exists():
            raise SystemExit(
                "%s is missing - run python tools/gen_bullet_tiles.py first"
                % src)
        (OUT / name).write_bytes(src.read_bytes())

    print("case %s" % case)
    for n, v in zip(REG_NAMES, regs):
        print("  %-14s %#010x" % (n, v))
    print("  bucket live entries: %d" % live)
    print("  framebuffer words: %d (from %#x)" % (nfb, vm.right_active))
    print("  wrote %s" % OUT)


if __name__ == "__main__":
    main()
