#!/usr/bin/env python
# -*- coding: utf-8 -*-
r"""Dump the firmware's own laser sheet: the reference the scanout must match.

A3 moved the craft's beam out of the engine and into the scanout's lookup
(video_beam.v).  The lookup was written from laser_glow_build(), and "written
from" is not evidence of anything - so tests/tb_video_beam.sv does not compare
against a table somebody retyped.  It compares against the bytes the FIRMWARE
laid down in MM_LASER_GLOW at boot, which is the exact surface the engine blit
into the framebuffer until A3.

Writes simulator/output/laser_glow.hex: one 32-bit word per line, row major,
16 columns x 768 rows, at the sheet's own 64-byte stride.  $readmemh reads it
straight into the testbench.

Run:  python tools\dump_beam_ref.py
"""
import sys
from pathlib import Path

ROOT = Path(r"E:\FPGA\Ti60_2D_Graphics_Accelerator")
sys.path.insert(0, str(ROOT / "simulator"))

import test_runner as T                                          # noqa: E402
from rv32i_soc_vm import SCRATCH_BASE                            # noqa: E402

MM_LASER_GLOW = T.mm_value("MM_LASER_GLOW")
GLOW_W, GLOW_H, GLOW_STRIDE = 16, 768, 64
MAGENTA_KEY = 0x00FF00FF


def main():
    code = T.load_code_from_source(ROOT / "sw" / "build" / "firmware.bin")
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    vm.joy = (128 << 8) | 128
    T.wait_for_boot(vm)

    off = MM_LASER_GLOW - SCRATCH_BASE
    words = []
    keyed = 0
    for y in range(GLOW_H):
        base = off + y * GLOW_STRIDE
        for dx in range(GLOW_W):
            w = int.from_bytes(vm.scratch[base + dx * 4: base + dx * 4 + 4],
                               "little")
            if w == MAGENTA_KEY:
                keyed += 1
            words.append("%08x" % w)

    out = ROOT / "simulator" / "output" / "laser_glow.hex"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(words) + "\n", encoding="ascii")
    print("  sheet: %s  (%d words, %dx%d, stride %d)"
          % (out.name, len(words), GLOW_W, GLOW_H, GLOW_STRIDE))
    print("  magenta-keyed pixels: %d of %d (the columns the blit skipped)"
          % (keyed, len(words)))

    # The two row forms the sheet repeats every 16 rows, printed row by row so
    # the table in video_beam.v can be read against it by eye as well.
    for y in (0, 1, 2, 3, 15):
        base = off + y * GLOW_STRIDE
        row = [int.from_bytes(vm.scratch[base + dx * 4: base + dx * 4 + 4],
                              "little") & 0xFFFFFF for dx in range(GLOW_W)]
        print("    y=%2d  %s" % (y, " ".join("%06x" % c for c in row)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
