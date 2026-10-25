"""Functional bucket/motion model; intentionally not an AXI timing model."""
import struct
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from mm import mm_eval

CAPACITY = mm_eval('MM_EBULLET_COUNT')
FRONT = CAPACITY - 32
CAND_BASE = mm_eval('EB_CAND_LIST_BASE')


def run(vm, control):
    if control & 0x40000000:
        vm.bucket_used = [[0]*96 for _ in range(2)]
        return
    if not control & 0x80000000:
        return
    if not hasattr(vm, 'bucket_used'):
        vm.bucket_used = [[0]*96 for _ in range(2)]
    buf = control & 1
    table = 0x04800000 + buf*96*4096
    counts, drops, live, candidates = [0]*96, 0, 0, []
    spans = [647,647,710,742,742,742,710,647,647,647,677,676,676,676,677,647,832,481,832] + [768]*8
    xy = vm.params.get(0x124, 0x020002AB)
    px, py = xy & 65535, xy >> 16
    motion = bool(control & 0x20000000)

    def aim(dx, dy):
        ax, ay = abs(dx), abs(dy)
        if not (ax or ay):
            return 4
        q = 0 if 5*ay <= ax else 1 if 3*ay <= 2*ax else 2 if 2*ay <= 3*ax else 3 if ay <= 5*ax else 4
        if dx < 0:
            q = 8-q
        return (-q if dy < 0 else q) & 15

    pools = [(0x01620000, range(min((control >> 4) & 1023, 512)), True),
             (0x01675400, range(min(((control >> 16) & 8191) | ((control & 16384) >> 1), FRONT)), False),
             (0x01675400, range(FRONT, CAPACITY), False)]
    for base, indices, pb in pools:
        for i in indices:
            off = base + i*8 - 0x01600000
            x,y,vx,vy,flags,color = struct.unpack_from('<hhbbBB', vm.scratch, off)
            if not flags & 1:
                continue
            if not pb and motion and i < FRONT and not flags & 8:
                x = ((x+vx+32768) & 65535)-32768
                y = ((y+vy+32768) & 65535)-32768
                if not (182 <= x <= 1169 and 1 <= y <= 767):
                    vm.scratch[off+6] = flags & ~1
                    continue
                struct.pack_into('<hh', vm.scratch, off, x, y)
                if abs(x-px) <= 15 and abs(y-py) <= 15:
                    candidates.append(i)
            if not pb:
                live += 1
            if pb:
                slot = 18 if flags & 2 else 16
                width, row, bx = (13 if slot == 18 else 7), y, x
            elif flags & 8:
                slot, width, row, bx = 19 + (aim(vx, vy) >> 1), 24, y-12, x-12
            elif flags & 64:
                slot, width, row, bx = 17, 16, y-8, x-8
            else:
                slot = aim(px-x, py-y) if flags & 4 or not (vx or vy) else ((color >> 3) & 15) if color & 128 else aim(vx, vy)
                width, row, bx = 26, y-13, x-13
            lo, hi = max(row+(spans[slot] & 31), 0), min(row+(spans[slot] >> 5), 768)
            if lo >= hi:
                continue
            last = lo//8 if getattr(vm, 'bucket_single_group', False) else (hi-1)//8
            for g in range(lo//8, last+1):
                if counts[g] == 1024:
                    drops += 1
                    continue
                word = ((color & 7) << 29) | (width << 24) | (slot << 17) | (((g*8-row+8) & 63) << 11) | (bx & 2047)
                vm.store(table+g*4096+counts[g]*4, word, 4)
                counts[g] += 1
    for g in range(96):
        for k in range(counts[g], vm.bucket_used[buf][g]):
            vm.store(table+g*4096+k*4, 0, 4)
        vm.bucket_used[buf][g] = counts[g]
        vm.store(0x048C1000+buf*192+g*2, counts[g], 2)
    if motion:
        for i, c in enumerate(candidates[:512]):
            vm.store(CAND_BASE+i*2, c, 2)
        vm.params[0x128] = (min(len(candidates), 65535) << 16) | live
    vm.params[0x120] = 0x20000000 | min(drops, 65535)
