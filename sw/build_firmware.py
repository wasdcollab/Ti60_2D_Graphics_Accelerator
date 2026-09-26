#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
sw/build_firmware.py
====================
Industrial RISC-V build for the Ti60 2D graphics accelerator, replacing the
legacy "assemble raw machine code from Python" flow (sw/generate_firmware.py).

    C / S  ->  riscv-none-elf-gcc  ->  firmware.elf
           ->  riscv-none-elf-objcopy -> firmware.bin
           ->  tools/elf_to_bram.py   -> four BRAM byte-lane init files

The build is deliberately strict:

  * -march=rv32im -mabi=ilp32: the Sapphire core does carry multiply/divide
    hardware - the four DSP48 multipliers inside the CPU and the
    MulDivIterativePlugin are both instantiated in ip/soc/soc.v - so the M
    extension is safe to enable.  Still no A, no C.
  * -Werror                  : warnings are build failures.
  * hard size gate           : the linked image must end at or below
    0xF900FC00, because the SoC has 64 KiB of RAM and the top 1 KiB is
    the stack.  The linker script enforces it; this script re-checks the
    symbol so a link that silently overflows can never ship.

Environment
-----------
    RISCV_GCC_DIR   toolchain root (default E:\\FPGA\\toolchain\\riscv-gcc)
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DEFAULT_GCC_DIR = os.environ.get("RISCV_GCC_DIR", r"E:\FPGA\toolchain\riscv-gcc")

IMAGE_LIMIT = 0xF900FC00          # 64 KiB OCR; preserve the 1 KiB stack
STACK_TOP = 0xF9010000

# Symbols the simulation workbench writes to set up a situation it cannot
# reach by playing - a stage-3 boss is minutes of simulation away, and the
# HUD assertions have to force a field to a value on a chosen frame.  This
# is a contract, not a convenience: the build fails if one of these leaves
# the link, because the alternative is a scenario that silently pokes a
# stale address after .bss moves.
HARNESS_SYMBOLS = (
    "stage_bg_active", "player_x", "player_y", "wave",
    "lives", "weapon", "weapon_level", "score", "atk", "fire_cd",
    "boss_state", "boss_hp", "boss_hp_max", "boss_x", "boss_y",
    "bomb_charge", "invuln", "kills", "hw_accel",
    # stage 2: the skills scenario drives the boss's pattern state
    # directly, and reads the laser cut's phase back out.
    "boss_pattern", "boss_pat_timer", "boss_fire_timer", "cut_phase",
    # the boss's entrance volley: the scenario that grades "the boss announced
    # itself" has to be able to clear the 90-frame laser it leaves behind
    # before it grades the next card.
    "boss_laser",
    # the boot menu is seven rows now and the workbench has to know which row
    # the D-pad is on to drive it.
    "menu_sel",
    # phase 2 task 02: a hit now clears the field and leaves a mote of light on
    # every shot it removed.  The motes are the only evidence that the sweep ran
    # rather than the bullets merely expiring, and the ring they live in is a
    # static array, so the scenario reads it by name.
    "game_particles",
    # phase 2 task 03: the impact shockwave.  It is anchored on the point the
    # shot CONNECTED, and the craft is thrown back to the spawn point on the
    # same frame - so "the ring is in the right place" can only be graded by
    # reading the anchor back, not by looking for the craft near it.
    "hit_ring_timer", "hit_ring_x", "hit_ring_y",
    # the two end screens.  "GAME OVER" and "ALL CLEAR" are minutes of play
    # apart, and what a scenario has to grade is the panel's weather occlusion
    # box - so the state that raises the panel is forced, not played to.
    "game_over", "restart_timer", "game_clear",
    # the cut/beam lasers: a scenario has to raise one on demand to price what a
    # beam frame costs the engine, without waiting for the boss to roll that
    # attack.
    "beam_x", "beam_timer", "beam_phase",
)

SOURCES = [
    "startup/crt0.S",
    "driver/gpu2d.c",
    "driver/gamepad.c",
    "app/main.c",
    "app/visual_assets.c",
    # The three stage plates are back, re-proportioned for 1366x768 and trimmed
    # to v6's compositions.  Palette + RLE is 12510 bytes for all three, and
    # main.c's stage_bg_decode() unpacks them into DDR at boot.
    "app/stage_bg.c",
]

CFLAGS = [
    "-march=rv32im", "-mabi=ilp32",
    "-Oz",
    "-flto",
    "-ffreestanding", "-fno-builtin", "-fno-common",
    "-ffunction-sections", "-fdata-sections",
    "-fno-strict-aliasing",
    "-Wall", "-Wextra", "-Werror",
    "-g",
]
LDFLAGS = [
    "-nostdlib", "-nostartfiles",
    "-flto",
    "-Wl,--gc-sections",
    "-Wl,--build-id=none",
    "-Wl,--no-relax",
    "-Wl,--no-warn-rwx-segments",
    "-lgcc",
]


def log(msg):
    print("[fw] %s" % msg, flush=True)


def find_tool(gcc_dir, name):
    exe = os.path.join(gcc_dir, "bin", name + ".exe")
    if os.path.exists(exe):
        return exe
    found = shutil.which(name)
    if found:
        return found
    raise SystemExit("cannot find %s - set RISCV_GCC_DIR (tried %s)" % (name, exe))


def run(cmd, **kw):
    shown = " ".join('"%s"' % c if " " in c else c for c in cmd)
    log(shown)
    return subprocess.run(cmd, **kw)


def nm_value(nm, elf, symbol):
    out = subprocess.run([nm, elf], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[2] == symbol:
            return int(parts[0], 16)
    return None


def main():
    # Checked-in downloads, no network access needed during a build.
    if run([sys.executable, os.path.join(ROOT,"tools","build_visual_assets.py")]).returncode != 0:
        raise SystemExit("visual asset conversion failed (requires Pillow)")
    # The stage plates produce two things that must agree: the RLE bytes that go
    # into the bitstream's asset ROM, and the per-plate offsets the firmware
    # indexes that ROM with.  One generator, so they cannot drift - regenerating
    # only one of them would leave the decoder decoding another plate's stream.
    if run([sys.executable, os.path.join(ROOT,"tools","build_stage_backgrounds.py")]).returncode != 0:
        raise SystemExit("stage background generation failed (requires Pillow)")
    # B2: the HUD table in main.c must not collide with the labels the asset
    # build just baked into the backdrop.
    if run([sys.executable, os.path.join(ROOT,"tools","check_hud_layout.py")]).returncode != 0:
        raise SystemExit("HUD layout collision (see the report above)")
    # Every DDR scratch surface must own a disjoint range.  Two that overlap do
    # not fail loudly at run time - the later writer just silently destroys the
    # earlier one - so the build is the only place this can be caught cheaply.
    if run([sys.executable, os.path.join(ROOT,"tools","check_ddr_layout.py")]).returncode != 0:
        raise SystemExit("DDR surface collision (see the report above)")
    gcc = find_tool(DEFAULT_GCC_DIR, "riscv-none-elf-gcc")
    objcopy = find_tool(DEFAULT_GCC_DIR, "riscv-none-elf-objcopy")
    objdump = find_tool(DEFAULT_GCC_DIR, "riscv-none-elf-objdump")
    size_tool = find_tool(DEFAULT_GCC_DIR, "riscv-none-elf-size")
    nm = find_tool(DEFAULT_GCC_DIR, "riscv-none-elf-nm")

    build = os.path.join(HERE, "build")
    objdir = os.path.join(build, "obj")
    os.makedirs(objdir, exist_ok=True)

    elf = os.path.join(build, "firmware.elf")
    bin_ = os.path.join(build, "firmware.bin")
    map_ = os.path.join(build, "firmware.map")
    lst = os.path.join(build, "firmware.lst")

    log("toolchain: %s" % gcc)
    ver = subprocess.run([gcc, "--version"], capture_output=True, text=True).stdout
    log(ver.splitlines()[0])

    objs = []
    for src in SOURCES:
        path = os.path.join(HERE, src)
        if not os.path.exists(path):
            raise SystemExit("missing source %s" % path)
        obj = os.path.join(objdir, os.path.basename(src).rsplit(".", 1)[0] + ".o")
        cmd = [gcc] + CFLAGS + ["-I" + os.path.join(HERE, "driver"), "-c", path, "-o", obj]
        if run(cmd).returncode != 0:
            raise SystemExit("compile failed: %s" % src)
        objs.append(obj)

    ld = [gcc] + CFLAGS + ["-T", os.path.join(HERE, "linker", "ti60_sapphire.ld"),
                           "-Wl,-Map=" + map_, "-o", elf] + objs + LDFLAGS
    if run(ld).returncode != 0:
        raise SystemExit("link failed")

    if run([objcopy, "-O", "binary", elf, bin_]).returncode != 0:
        raise SystemExit("objcopy failed")

    with open(lst, "w", encoding="utf-8") as fh:
        subprocess.run([objdump, "-d", "-S", elf], stdout=fh, text=True)

    # ---- size report and hard gate -------------------------------------
    image_end = nm_value(nm, elf, "__image_end")
    bss_start = nm_value(nm, elf, "__bss_start")
    bss_end = nm_value(nm, elf, "__bss_end")
    sz = subprocess.run([size_tool, elf], capture_output=True, text=True).stdout
    log("size:\n" + sz.strip())

    if image_end is None:
        raise SystemExit("__image_end symbol missing from the link")
    used = image_end - 0xF9000000
    log("linked image ends at 0x%08X (%d bytes of %d usable, stack top 0x%08X)"
        % (image_end, used, IMAGE_LIMIT - 0xF9000000, STACK_TOP))
    if image_end > IMAGE_LIMIT:
        raise SystemExit("IMAGE OVERFLOWS: 0x%08X > 0x%08X - shrink the firmware"
                         % (image_end, IMAGE_LIMIT))
    if bss_start is not None and bss_end is not None:
        log("bss: 0x%08X..0x%08X (%d bytes)" % (bss_start, bss_end, bss_end - bss_start))

    # ---- symbol sidecar -------------------------------------------------
    # The simulation workbench loads the raw .bin, which carries no section
    # information, so it cannot tell writable RAM (.data and the zero
    # initialised .bss, both at the tail of the linked image) from real code.
    # Publish the few addresses it needs next to the binary.
    data_start = nm_value(nm, elf, "__data_start")
    data_end = nm_value(nm, elf, "__data_end")
    sym_path = os.path.join(build, "firmware.sym")
    with open(sym_path, "w", encoding="ascii", newline="\n") as fh:
        fh.write("image_end 0x%08X\n" % image_end)
        if data_start is not None:
            fh.write("data_start 0x%08X\n" % data_start)
        if data_end is not None:
            fh.write("data_end 0x%08X\n" % data_end)
        if bss_start is not None:
            fh.write("bss_start 0x%08X\n" % bss_start)
        if bss_end is not None:
            fh.write("bss_end 0x%08X\n" % bss_end)
        # A couple of game-state addresses as well.  The workbench switches
        # stages directly in the scenarios that grade scenery, because playing
        # through two boss fights to see the third backdrop costs several
        # minutes more than the entire rest of the suite - and every one of
        # those scenarios has a five-minute budget.
        for name in HARNESS_SYMBOLS:
            value = nm_value(nm, elf, name)
            if value is None:
                raise SystemExit(
                    "harness symbol %r is not in the link - the workbench\n"
                    "grades rendered pixels through it, so a scenario would\n"
                    "otherwise poke a stale address" % name)
            fh.write("%s 0x%08X\n" % (name, value))
    log("OK  sym=%s" % os.path.relpath(sym_path, ROOT))

    # ---- BRAM byte lanes ------------------------------------------------
    bram = os.path.join(ROOT, "tools", "elf_to_bram.py")
    r = run([sys.executable, bram, "--bin", bin_, "--gcc-dir", DEFAULT_GCC_DIR,
             "--ram-bytes", "65536", "--verify"])
    if r.returncode != 0:
        raise SystemExit("BRAM image generation failed")

    log("OK  elf=%s" % os.path.relpath(elf, ROOT))
    log("OK  bin=%s (%d bytes)" % (os.path.relpath(bin_, ROOT), os.path.getsize(bin_)))
    log("OK  map=%s" % os.path.relpath(map_, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
