"""Compare Scanout with a full-depth oracle and emit streaming RTL vectors.

Run after gen_bullet_tiles.py. The palette/shape data come from real firmware.
The generated vectors also exercise hue, DE, bucket-ready and mask transitions.
"""
from pathlib import Path
import random
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
from scanout_model import Scanout, SCRATCH_BASE  # noqa: E402


def main():
    out = ROOT / "simulator/output"
    tiles = [int(v, 16) for v in (out / "bullet_tiles.hex").read_text().split()]
    pal = [int(v, 16) for v in (out / "bullet_palette.hex").read_text().split()]
    assert max(tiles) <= 31, "tile roles no longer fit the five-bit RAM contract"
    for hue in range(8):
        for role in (1, 2, 3):
            assert pal[hue * 32 + role] >> 24 == 255, "tip and spine stay opaque"
        wing = pal[hue * 32 + 31]
        neon = pal[hue * 32 + 2]
        assert wing >> 24 == 210, "enemy wings blend at 210"
        assert (wing & 0xFFFFFF) == (neon & 0xFFFFFF), "wings share the neon hue"
        for role in range(9, 27):
            assert pal[hue * 32 + role] >> 24 == 254, "enemy halo must add"
    rng = random.Random(20261010)
    vectors = []
    checked = 0
    width, height, bg = 1366, 8, 0x21354B
    for case in range(64):
        entries = []
        for k in range(3):
            slot = rng.randrange(19)
            row0 = rng.randrange(-7, 27)
            bx = 700 + rng.randrange(-8, 9)
            tw = 7 if slot == 16 else 16 if slot == 17 else 13 if slot == 18 else 26
            hue = (case + k * 3) & 7
            if case % 8 == 0:
                slot, row0, bx, tw = (16, 0, 714, 7) if k == 0 else (0, 0, 700, 26)
            if case % 8 == 1:
                slot, row0, bx, tw = (0, 8, 11)[k], 10, 700, 26
            if case % 8 == 2:
                slot, row0, bx, tw = (0, 11, 11)[k], 10, 700, 26
            if case % 8 == 3 and k == 2:
                slot = 127  # invalid top candidate still consumes one priority position
            entry = bx | ((row0 + 8) << 11) | (slot << 17) | (tw << 24) | (hue << 29)
            entries.append(entry)
        ready = case % 13 != 0
        mx = (1 << 31) | 709 | (712 << 11) if case % 4 == 0 else 0
        my = 2 | (5 << 11)
        # One group is MM_BUCKET_STRIDE bytes (1024 slots).  The old 384-word
        # buffer made Scanout.bucket_ok false, so the model drew the backdrop
        # and every overlapping bullet failed the compare.
        scratch = [0] * (256 + 1024)
        for idx, entry in zip((0, 126, 127), entries):
            scratch[256 + idx] = entry
        params = {0xF0: SCRATCH_BASE + 1024 if ready else 0,
                  0x5C: 0, 0x8C: mx, 0xAC: my}
        model = Scanout([bg] * (width * height), params, scratch, tiles, pal,
                        0, width, height, width)
        actual = model.compose([0] * (width * height))
        for y in range(height):
            for x in range(width):
                selected = None
                masked = bool(mx >> 31) and 709 <= x <= 712 and 2 <= y <= 5
                if ready and 181 <= x < 1185 and not masked:
                    # Search all entries; transparent cells never occlude.
                    hits = [e for e in reversed(entries)
                            if (e & 2047) <= x < (e & 2047) + ((e >> 24) & 31)]
                    for e in hits:
                        slot = (e >> 17) & 127
                        row = ((e >> 11) & 63) - 8 + y
                        if slot >= 19 or not 0 <= row < 26:
                            continue
                        base, stride = ((slot * 832, 32) if slot < 16 else
                                        ((13312, 8), (13520, 16), (13936, 16))[slot - 16])
                        role = tiles[base + row * stride + x - (e & 2047)]
                        if role:
                            selected = pal[((e >> 29) & 7) * 32 + role]
                            break
                expected = bg
                if selected is not None:
                    alpha = selected >> 24
                    expected = 0
                    for shift in (0, 8, 16):
                        b, f = (bg >> shift) & 255, (selected >> shift) & 255
                        c = min(255, b + f) if alpha == 254 else (f * alpha + b * (255 - alpha) + 127) // 255
                        expected |= c << shift
                assert actual[y * width + x] == expected | 0xFF000000, (case, x, y)
                checked += 1
                # Continuous pixels around the overlap: changing all metadata
                # between cases catches a stationary-input bench's blind spot.
                if 688 <= x < 740:
                    de = (x + y + case) % 11 != 0
                    visible = de and selected is not None
                    result = ((1 << 33) | (int(selected >> 24 == 254) << 32) | selected) if visible else 0
                    v = result
                    for value, bits in ((my, 32), (mx, 32), (ready, 1), (de, 1),
                                        (y, 11), (x, 12), (entries[2], 32),
                                        (entries[1], 32), (entries[0], 32)):
                        v = (v << bits) | int(value)
                    vectors.append(f"{v:055x}\n")
    (out / "bullet_stream.hex").write_text("".join(vectors), encoding="ascii")
    print(f"PASS Scanout fallback: {checked} pixels; {len(vectors)} streaming RTL vectors")


if __name__ == "__main__":
    main()
