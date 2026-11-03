"""Campaign motion and dense-shot regression on the linked RV32 firmware.

Instruction counts compare CPU work only; they do not predict board FPS.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'simulator'), str(ROOT / 'tools')]
os.environ.setdefault('SIM_PURE_PYTHON', '1')
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func


def main():
    ap = argparse.ArgumentParser(__doc__)
    ap.add_argument('--source', type=Path, default=ROOT/'sw/build/firmware.bin')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--baseline', action='store_true')
    ap.add_argument('--preview', action='store_true')
    args = ap.parse_args()
    sym = _symtab(args.source.with_suffix('.elf'))
    code = T.load_code_from_source(args.source)
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    vm.r[2] = 0xF9010000

    def put(name, value, size=1):
        vm.store(sym[name], value, size)

    def call(name, *values):
        return call_func(vm, sym[name], values, budget=30_000_000)

    pad = 0x04901800
    vm.store(pad, 0x8080); vm.store(pad+4, 0)

    def update():
        put('invuln', 255)
        return call('game_update', pad)

    def enemy(i, x, y, hp=30000):
        a = T.ENEMY_BASE + i*16
        for j in range(0, 16, 4):
            vm.store(a+j, 0)
        vm.store(a, x, 2); vm.store(a+2, y, 2)
        vm.store(a+8, hp, 2); vm.store(a+11, 255, 1)
        vm.store(a+13, 1, 1)

    def shot(i, x, y, vx=0, vy=-9):
        a = T.PBULLET_BASE+i*8
        vm.store(a, (x & 65535) | ((y & 65535) << 16))
        vm.store(a+4, (vx & 255) | ((vy & 255) << 8) | (1 << 16))

    metrics = {}
    # Identical populations in both binaries, no impacts: isolate broad phase.
    for count in (8, 128, 512):
        call('game_init'); put('invuln', 255)
        for i in range(75):
            enemy(i, 210+(i % 15)*62, 100+(i//15)*52)
        for i in range(count):
            shot(i, 210+(i % 15)*62, 600+(i//15)%80)
        put('pb_hi', count, 4)
        put('spawn_timer', 1000, 2)
        cost = update()
        assert all(vm.load(T.PBULLET_BASE+i*8+2, 2) == 591+(i//15)%80
                   for i in range(count)), 'shot movement changed'
        metrics[str(count)] = cost
        print('dense no-hit: %d shots, %d instructions' % (count, cost), flush=True)

    # Independent substep oracle, including overlaps, slot priority, high speed,
    # diagonal motion and boundary culling.  One hit removes one shot.
    rng = random.Random(20261031)
    for trial in range(140):
        call('game_init'); put('invuln', 255); put('atk', 1)
        bx, by = rng.randrange(185, 1170), rng.randrange(5, 740)
        vx, vy = rng.randrange(-24, 25), rng.randrange(-24, 25)
        targets = [(rng.randrange(185, 1160), rng.randrange(10, 700)) for _ in range(75)]
        if trial % 2 == 0:
            for k in rng.sample(range(75), 6):
                targets[k] = (bx+rng.randrange(-28, 29), by+rng.randrange(-28, 29))
        targets = [(max(185, min(1157, x)), y) for x, y in targets]
        for i, (x, y) in enumerate(targets):
            enemy(i, x, y)
        shot(0, bx, by, vx, vy); put('pb_hi', 1, 4)
        sub = min(8, max(1, (max(abs(vx), abs(vy))+2)//3))
        sx, sy = int(vx/sub), int(vy/sub)
        px, py, expected, alive = bx, by, None, True
        for s in range(sub):
            px += vx-sx*(sub-1) if s == sub-1 else sx
            py += vy-sy*(sub-1) if s == sub-1 else sy
            if not (1 <= py <= 742 and 181 <= px <= 1185-7):
                alive = False; break
            expected = next((i for i, (x, y) in enumerate(targets)
                             if x-2 <= px <= x+26 and y-2 <= py <= y+26), None)
            if expected is not None:
                alive = False; break
        put('spawn_timer', 1000, 2)
        update()
        changed = [i for i in range(75) if vm.load(T.ENEMY_BASE+i*16+8, 2) != 30000]
        assert changed == ([] if expected is None else [expected]), (trial, changed, expected)
        assert bool(vm.load(T.PBULLET_BASE+6, 1)&1) == alive, trial
        assert vm.load(T.PBULLET_BASE, 2) == px & 65535
        assert vm.load(T.PBULLET_BASE+2, 2) == py & 65535
    print('PASS 140 collision oracle cases (substeps, overlaps, priority, bounds)', flush=True)

    # Dead enemies in the x index must not absorb another shot in this tick.
    call('game_init'); put('spawn_timer', 1000, 2); put('atk', 1)
    enemy(0, 500, 200, hp=1); enemy(1, 500, 200, hp=1)
    for i in range(3):
        shot(i, 510, 227)
    put('pb_hi', 3, 4); update()
    assert [vm.load(T.ENEMY_BASE+i*16+13, 1)&1 for i in range(2)] == [0, 0]
    assert [vm.load(T.PBULLET_BASE+i*8+6, 1)&1 for i in range(3)] == [0, 0, 1]
    assert vm.load(sym['kills'], 2) == 2
    print('PASS simultaneous kills: dead indexed targets skipped, two scores, third shot survives', flush=True)

    for level, expected in ((0, 3), (1, 3), (2, 5), (3, 7), (4, 9), (5, 9)):
        call('game_init'); put('spawn_timer', 1000, 2)
        put('weapon', 3); put('weapon_level', level)
        vm.store(pad+4, 1, 1); update(); vm.store(pad+4, 0, 1)
        live = [i for i in range(T.PBULLET_COUNT) if vm.load(T.PBULLET_BASE+i*8+6, 1)&1]
        assert len(live) == expected, (level, len(live), expected)
    print('PASS fan levels: 3/5/7/9 symmetric shots and clamped bounds', flush=True)

    call('game_init'); put('spawn_timer', 0, 2)
    previews = []
    args.out.parent.mkdir(parents=True, exist_ok=True)
    for tick in range(400):
        update()
        if not args.baseline:
            visible = [(vm.load(T.ENEMY_BASE+i*16, 2), vm.load(T.ENEMY_BASE+i*16+2, 2))
                       for i in range(75) if vm.load(T.ENEMY_BASE+i*16+13, 1)&128
                       and vm.load(T.ENEMY_BASE+i*16+2, 2) < 745]
            assert all(abs(x-u) >= 24 or abs(y-v) >= 24
                       for i, (x, y) in enumerate(visible) for u, v in visible[i+1:]), tick
        if args.preview and tick in (30, 75, 135, 220):
            put('stage_banner', 0, 2)
            vm.active = vm.request = vm.right_active = vm.right_request = 0x800000
            call('game_render', 0xE00000)
            from PIL import Image
            bmp = args.out.parent / ('formation_%03d.bmp' % tick)
            vm.save_frame_bmp(str(bmp), 0xE00000)
            im = Image.open(bmp).convert('RGB')
            im.save(bmp.with_suffix('.png'))
            previews.append(im.resize((956, 538)))
    assert vm.load(sym['round_spawned'], 1) == 75
    before = [(vm.load(T.ENEMY_BASE+i*16, 2), vm.load(T.ENEMY_BASE+i*16+2, 2)) for i in range(75)]
    moved = [False]*75
    for tick in range(400, 416):
        update()
        for i in range(75):
            at = T.ENEMY_BASE+i*16
            moved[i] |= (vm.load(at, 2), vm.load(at+2, 2)) != before[i]
    after = [(vm.load(T.ENEMY_BASE+i*16, 2), vm.load(T.ENEMY_BASE+i*16+2, 2)) for i in range(75)]
    stationary = moved.count(False)
    if not args.baseline:
        assert stationary == 0, stationary
        assert all(vm.load(T.ENEMY_BASE+i*16+13, 1)&1 for i in range(75))
    print('settled wave: %d stationary enemies / 75' % stationary, flush=True)
    if not args.baseline:
        assert all(vm.load(T.ENEMY_BASE+i*16+13, 1)&64 for i in range(75))
        assert all(185 <= x <= 1157 and 48 <= y <= 460 for x, y in after)
        assert any(y != before[i][1] for i, (_, y) in enumerate(after))
        print('PASS non-overlapping formation entry followed by bounded 2D free flight', flush=True)
    if previews:
        previews[0].save(args.out.parent/'formation.gif', save_all=True,
                         append_images=previews[1:], duration=650, loop=0)
    args.out.write_text(json.dumps(dict(sha256=hashlib.sha256(args.source.read_bytes()).hexdigest(),
        instructions=metrics, stationary=stationary, min_sp=hex(vm.min_sp),
        board_fps='not measured'), indent=2)+'\n')
    assert vm.min_sp >= 0xF900FD00, hex(vm.min_sp)


if __name__ == '__main__':
    main()
