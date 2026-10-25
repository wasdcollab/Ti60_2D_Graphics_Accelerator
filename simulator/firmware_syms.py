# -*- coding: utf-8 -*-
r"""Firmware symbol addresses for the workbench and its diagnostics.

firmware.sym carries the handful of addresses sw/build_firmware.py publishes,
which is enough for the scenarios but not for a diagnostic that wants to poke a
file-static flag such as boss_shake or laser_columns_live: name that is not
published raises instead of silently writing to the wrong byte of .bss.  The
ELF in the same directory still has a full .symtab, so read it.

Lookup order: firmware.sym first (it is the published interface), then .symtab.
"""
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "sw" / "build"


def _symtab(path):
    """{name: address} from the ELF symbol table."""
    data = Path(path).read_bytes()
    if data[:4] != b"\x7fELF":
        raise SystemExit("%s is not an ELF file" % path)
    if data[4] != 1:
        raise SystemExit("%s is not a 32-bit ELF - this reader is 32-bit only"
                         % path)
    end = "<" if data[5] == 1 else ">"
    shoff, = struct.unpack_from(end + "I", data, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from(end + "HHH", data, 0x2E)
    secs = []
    for i in range(shnum):
        f = struct.unpack_from(end + "IIIIIIIIII", data, shoff + i * shentsize)
        secs.append({"name": f[0], "type": f[1], "off": f[4], "size": f[5],
                     "link": f[6], "entsize": f[9]})
    out = {}
    for s in secs:
        if s["type"] != 2:                    # SHT_SYMTAB
            continue
        stroff = secs[s["link"]]["off"]
        entsize = s["entsize"] or 16
        for k in range(s["size"] // entsize):
            o = s["off"] + k * entsize
            st_name, st_value = struct.unpack_from(end + "II", data, o)
            if not st_name or not st_value:
                continue
            raw = data[stroff + st_name:]
            out.setdefault(raw[:raw.index(b"\0")].decode("utf-8", "replace"),
                           st_value)
    return out


_ELF_CACHE = {}


def fw_symbol(name):
    """Address of a firmware symbol, published sidecar first, ELF second."""
    side = BUILD / "firmware.sym"
    if side.exists():
        for line in side.read_text(encoding="ascii").split("\n"):
            parts = line.split()
            if len(parts) == 2 and parts[0] == name:
                return int(parts[1], 16)
    elf = BUILD / "firmware.elf"
    if elf.exists():
        if elf not in _ELF_CACHE:
            _ELF_CACHE[elf] = _symtab(elf)
        if name in _ELF_CACHE[elf]:
            return _ELF_CACHE[elf][name]
    raise SystemExit("no address for firmware symbol %r: not in firmware.sym and"
                     " not in firmware.elf - rebuild the firmware (a dropped"
                     " static is a rename, and guessing is how a poke lands on"
                     " the wrong byte)" % name)


if __name__ == "__main__":
    import sys
    for arg in sys.argv[1:]:
        print("%-24s %#010x" % (arg, fw_symbol(arg)))
