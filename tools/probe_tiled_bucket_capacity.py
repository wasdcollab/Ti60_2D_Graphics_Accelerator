"""Explore 10k+ capacity with real boot-built tiles, NOT a board/FPS result.

Prototype layout: 96 vertical groups, eight 128-pixel horizontal bands, 64
entries per cell. Preserve entry order and duplicate cross-band sprites.
Two 64-entry scan banks would retain the current 128-entry register budget;
prefetch/CDC and scan scheduling still need RTL implementation and validation.
"""
import argparse
from array import array
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "simulator"))
os.environ.setdefault("SIM_PURE_PYTHON", "1")
import test_runner as T

LEFT, RIGHT, HEIGHT = 181, 1185, 768
BAND_WIDTH, BANDS, SLOTS = 128, 8, 64


def tiles_from_boot(vm):
    tiles = []
    for slot in range(19):
        if slot < 16:
            base = T.mm_value("MM_EBULLET_DIRTILE") + slot * 832
            pitch, width, height = 32, 26, 26
        else:
            key, pitch, width, height = (("MM_PBULLET_TILE", 8, 7, 26),
                                        ("MM_ORB_TILE", 16, 16, 16),
                                        ("MM_MISSILE_TILE", 16, 13, 26))[slot - 16]
            base = T.mm_value(key)
        off = base - T.SCRATCH_BASE
        pixels = [(x, y, int(vm.scratch[off+y*pitch+x]))
                  for y in range(height) for x in range(width)
                  if vm.scratch[off+y*pitch+x]]
        tiles.append((width, min(p[1] for p in pixels), max(p[1] for p in pixels)+1, pixels))
    return tiles


def probe(tiles, population, clustered=False):
    cells = [[] for _ in range(96*BANDS)]
    old_counts = [0]*96
    demand = [0]*len(cells)
    reference = array("I", [0]) * (1366*HEIGHT)
    actual = array("I", [0]) * (1366*HEIGHT)
    bullets = []
    inserted = set()
    for i in range(population):
        # Synthetic on-screen workload, explicitly not a captured game state.
        x = LEFT+2+(i*137 % 978) if not clustered else 600+(i%16)
        y = 2+(i*29 % 740) if not clustered else 300+(i%8)
        slot, hue = i%19, (i//19)%8
        width, first, end, pixels = tiles[slot]
        bullets.append((x,y,slot,hue))
        for dx,dy,role in pixels:
            if LEFT <= x+dx <= RIGHT and 0 <= y+dy < HEIGHT:
                reference[(y+dy)*1366+x+dx] = (hue<<5)|role
        for g in range(max(y+first,0)//8, (min(y+end,HEIGHT)-1)//8+1):
            old_counts[g] += 1
            for band in range(max(0,(x-LEFT)//BAND_WIDTH),min(BANDS-1,(x+width-1-LEFT)//BAND_WIDTH)+1):
                index=g*BANDS+band
                demand[index]+=1
                if len(cells[index]) < SLOTS:
                    cells[index].append(i)
                    inserted.add(i)
    for index, cell in enumerate(cells):
        group,band=divmod(index,BANDS)
        x0,x1=LEFT+band*BAND_WIDTH,min(RIGHT+1,LEFT+(band+1)*BAND_WIDTH)
        for i in cell:
            x,y,slot,hue=bullets[i]
            for dx,dy,role in tiles[slot][3]:
                if x0 <= x+dx < x1 and group*8 <= y+dy < group*8+8:
                    actual[(y+dy)*1366+x+dx]=(hue<<5)|role
    drops=sum(max(0,n-SLOTS) for n in demand)
    mismatch=sum(a!=b for a,b in zip(reference,actual))
    result=dict(population=population, workload="clustered" if clustered else "distributed",
                tile_types=19, bands=BANDS, slots_per_cell=SLOTS, peak=max(demand),
                entries=sum(demand), drops=drops, inserted_sprites=len(inserted),
                full_screen_pixel_mismatches=mismatch,
                legacy_128_slot_drops=sum(max(0,n-128) for n in old_counts),
                frame_sha256=hashlib.sha256(actual.tobytes()).hexdigest())
    if not clustered:
        assert drops == 0 and mismatch == 0 and len(inserted)==population, result
    else:
        assert drops > 0, "adversarial overflow must remain observable"
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report",type=Path,required=True)
    args=parser.parse_args()
    binary=ROOT/"sw/build/firmware.bin"
    code=T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    tiles=tiles_from_boot(T.new_vm(code))
    results=[]
    for count,clustered in ((4000,False),(10000,False),(12000,False),(10000,True)):
        result=probe(tiles,count,clustered)
        results.append(result)
        print(result,flush=True)
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(dict(
        status="SOFTWARE CAPACITY/PIXEL PROTOTYPE ONLY; NOT IN BITSTREAM; NO FPS CLAIM",
        binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),results=results),indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":
    main()
