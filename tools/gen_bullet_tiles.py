"""Dump the linked firmware's initialized APB tile store for RTL verification."""
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
os.environ.setdefault("SIM_PURE_PYTHON", "1")
import test_runner as T

SETS = [
    ("ebullet", 0, 16, 26, 26, 32),
    ("pbullet", 16, 1, 7, 26, 8),
    ("orb", 17, 1, 16, 16, 16),
    ("missile", 18, 1, 13, 26, 16),
    ("lance", 19, 8, 24, 26, 32),
    ("skill_warning", 27, 1, 16, 26, 32),
    ("skill_beam", 28, 1, 16, 26, 32),
    ("skill_spark", 29, 8, 26, 26, 32),
]


def main():
    code = T.load_code_from_source(ROOT / "sw/build/firmware.bin")
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    store, pal = bytes(vm.btile), list(vm.bpal)
    assert len(store) == 32768 and len(pal) == 256
    assert any(store[:13312]) and any(store[14368:21024])
    assert any(c >> 24 == 254 for c in pal)
    assert all(0 <= b < 32 for b in store)
    out = ROOT / "simulator/output"
    out.mkdir(parents=True, exist_ok=True)
    (out / "bullet_tiles.hex").write_text(
        "\n".join("%02x" % b for b in store) + "\n", encoding="ascii")
    (out / "bullet_palette.hex").write_text(
        "\n".join("%08x" % c for c in pal) + "\n", encoding="ascii")
    (out / "bullet_kinds.txt").write_text(
        "# name slot0 count w h rowstride\n" +
        "\n".join("%s %d %d %d %d %d" % k for k in SETS) + "\n",
        encoding="ascii")
    print("PASS firmware fixtures: 32768 tile bytes, 256 ARGB palette entries, 37 kinds")


if __name__ == "__main__":
    main()
