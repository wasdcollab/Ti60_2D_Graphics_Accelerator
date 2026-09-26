#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
tools/elf_to_bram.py
====================
Converts a linked firmware image into the four BRAM initialisation files that
the Efinix Sapphire SoC instance loads into its on-chip system RAM.

The generated Verilog netlist instantiates

    EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{0..3}.bin

one file per byte lane: lane i holds bit-plane (word >> (8*i)) & 0xFF of every
32-bit word, written as one byte per RAM word.  This
replaces sw/generate_firmware.py::write_image(), which used to emit exactly the
same format from the hand-assembled Python firmware.

Two copies are produced (the IP keeps a netlist copy of the same files):

    ip/soc/
    ip/soc/source/hardware/netlist/

Usage
-----
    python tools/elf_to_bram.py --bin sw/build/firmware.bin
    python tools/elf_to_bram.py --elf sw/build/firmware.elf --verify
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANE_DIRS = (
    os.path.join(ROOT, "ip", "soc"),
    os.path.join(ROOT, "ip", "soc", "source", "hardware", "netlist"),
)
DEFAULT_RAM_BYTES = 64 * 1024
LANE_FMT = "EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol%d.bin"


def elf_to_bin(elf_path, bin_path, gcc_dir=None):
    """ELF -> raw binary with riscv-none-elf-objcopy."""
    objcopy = "riscv-none-elf-objcopy"
    if gcc_dir:
        objcopy = os.path.join(gcc_dir, "bin", "riscv-none-elf-objcopy.exe")
    subprocess.run([objcopy, "-O", "binary", elf_path, bin_path], check=True)
    return bin_path


def load_words(bin_path, ram_bytes):
    with open(bin_path, "rb") as fh:
        data = fh.read()
    if ram_bytes <= 0 or ram_bytes % 4:
        raise SystemExit("RAM size must be a positive multiple of four bytes")
    if len(data) > ram_bytes:
        raise SystemExit("firmware image is %d bytes, the SoC RAM only holds %d"
                         % (len(data), ram_bytes))
    words_total = ram_bytes // 4
    words = []
    for i in range(0, len(data), 4):
        chunk = data[i:i + 4]
        chunk = chunk + b"\x00" * (4 - len(chunk))
        words.append(int.from_bytes(chunk, "little"))
    words += [0] * (words_total - len(words))
    return words, len(data)


def write_lanes(words, dirs=LANE_DIRS):
    words_total = len(words)
    for directory in dirs:
        os.makedirs(directory, exist_ok=True)
        for lane in range(4):
            values = [format((words[i] >> (lane * 8)) & 0xFF, "08b") for i in range(words_total)]
            path = os.path.join(directory, LANE_FMT % lane)
            with open(path, "w", encoding="ascii", newline="\r\n") as fh:
                fh.write("\n".join(values) + "\n")


def read_lanes(directory, words_total):
    lanes = []
    for lane in range(4):
        path = os.path.join(directory, LANE_FMT % lane)
        with open(path, "r", encoding="ascii") as fh:
            bits = [int(line.strip(), 2) for line in fh if line.strip()]
        if len(bits) != words_total:
            raise SystemExit("%s has %d lines, expected %d" % (path, len(bits), words_total))
        lanes.append(bits)
    return [sum(lanes[j][i] << (j * 8) for j in range(4)) for i in range(words_total)]


def verify(words, dirs=LANE_DIRS):
    words_total = len(words)
    for directory in dirs:
        back = read_lanes(directory, words_total)
        for i in range(words_total):
            if back[i] != words[i]:
                raise SystemExit("lane readback mismatch in %s at word %d: %08X != %08X"
                                 % (directory, i, back[i], words[i]))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=None, help="raw firmware binary")
    ap.add_argument("--elf", default=None, help="linked ELF (converted with objcopy)")
    ap.add_argument("--gcc-dir", default=None, help="toolchain root for objcopy")
    ap.add_argument("--ram-bytes", type=int, default=DEFAULT_RAM_BYTES,
                    help="configured Sapphire on-chip RAM size (default: %(default)s)")
    ap.add_argument("--verify", action="store_true", help="read the lanes back and compare")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    if a.elf and not a.bin:
        a.bin = os.path.splitext(a.elf)[0] + ".bin"
        elf_to_bin(a.elf, a.bin, a.gcc_dir)
    if not a.bin:
        ap.error("give --bin or --elf")

    words, nbytes = load_words(a.bin, a.ram_bytes)
    write_lanes(words)
    if a.verify:
        verify(words)
    if not a.quiet:
        print("BRAM image: %d bytes of firmware -> %d words, 4 lanes x %d lines"
              % (nbytes, len(words), len(words)))
        for d in LANE_DIRS:
            print("  wrote %s" % os.path.relpath(d, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
