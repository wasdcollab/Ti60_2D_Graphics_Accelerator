"""Linked-RV32 regressions for the November 3 bullet and pressure-stage fixes."""
import argparse
import hashlib
import json
import os
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'simulator'), str(ROOT / 'tools')]
os.environ.setdefault('SIM_PURE_PYTHON', '1')
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func


def main():
    ap = argparse.ArgumentParser(__doc__)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--full-cycle', action='store_true', help='run all 2880 pressure frames without time jumps')
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    binary = ROOT / 'sw/build/firmware.bin'
    sym = _symtab(binary.with_suffix('.elf'))
    code = T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    v = T.new_vm(code)
    v.r[2] = 0xf900ffc0
    pad, state = 0x04901800, T.mm_value('MM_BOSS23_CAST')
    front = T.EBULLET_COUNT - 128
    v.store(pad, 0x8080)
    v.store(pad + 4, 0)

    def put(n, x, size=1):
        v.store(sym[n], x, size)

    def call(n, *a):
        return call_func(v, sym[n], a, budget=30_000_000)

    def record(i):
        return struct.unpack('<hhbbBB', bytes(v.load(T.EBULLET_BASE+i*8+j, 1) for j in range(8)))

    def inject(i, x, y, vx, vy, flags):
        for j, b in enumerate(struct.pack('<hhbbBB', x, y, vx, vy, flags, 0)):
            v.store(T.EBULLET_BASE+i*8+j, b, 1)

    def blank(pressure):
        put('is_stress_stage', 0, 4)
        call('game_init')
        put('is_stress_stage', pressure, 4)
        put('stress_target', 0, 2)
        put('boss_state', 0)
        put('invuln', 255)
        put('spawn_timer', 255, 2)
        # game_init intentionally clears only the ordinary campaign prefix.
        for i in range(T.EBULLET_COUNT):
            v.store(T.EBULLET_BASE+i*8+6, 0, 1)

    def tick(frame=0):
        put('invuln', 255)
        steps = call('game_update', pad)
        call('bucket_build_start', frame & 1)
        call('bucket_build_finish')
        return steps

    # Integer quantization must never leave a freely emitted shot at (0,0).
    for pressure in [0, 1]:
        blank(pressure)
        call('spawn_ebullet', 500, 300, 0, 0, 0)
        call('spawn_ebullet_orb', 600, 300, 0, 0, 0)
        inject(1, 700, 300, 0, 0, 5)  # explicitly held bullet remains intentional
        put('eb_hi', 2, 4)
        tick()
        assert record(0)[1] == 301, (pressure, record(0))
        assert record(front)[1] == 301, (pressure, record(front))
        assert record(1)[:2] == (700, 300), record(1)
    print('PASS zero-speed normal/orb shots move; explicit held shot stays held', flush=True)

    for pressure in [0, 1]:
        blank(pressure)
        for i in range(128):
            call('spawn_ebullet_orb', 250+i%16*50, 60+i//16*70, 2, 1, i&7)
        before = [record(front+i) for i in range(128)]
        tick()
        after = [record(front+i) for i in range(128)]
        assert all(b[:2] == (a[0]+2, a[1]+1) for a, b in zip(before, after))
        assert v.load(sym['active_count'], 2) == 128
        counts = [v.load(T.mm_value('MM_BUCKET_USED')+g*2, 2) for g in range(96)]
        assert sum(counts) >= 128 and v.load(sym['bt_dropped']) == 0
    print('PASS all 128 reserved orbs move once and enter the bucket tables', flush=True)

    blank(1)
    inject(0, 500, 300, 24, -8, 33)  # Q4: +1.5, -0.5 pixels per tick
    inject(1, 600, 300, 98, 0, 129)  # vx is a timer, not a velocity
    put('eb_hi', 2, 4)
    put('eb_lance_count', 2, 4)
    index = T.mm_value('MM_LANCE_INDEX')
    v.store(index, 0, 2)
    v.store(index+2, 1, 2)
    v.store(T.mm_value('MM_BULLET_FRAC'), 0, 1)
    tick()
    assert record(0)[:2] == (501, 299), record(0)
    assert record(1)[:3] == (600, 300, 97), record(1)
    tick(1)
    assert record(0)[:2] == (503, 299), record(0)
    assert record(1)[:3] == (600, 300, 96), record(1)
    print('PASS pressure Q4/timed laser: CPU advances once, DMA does not advance twice', flush=True)

    blank(1)
    for i in range(4100):
        inject(i, 250+i%100*8, 40+i%90*8, 16, 0, 33)
        v.store(T.mm_value('MM_BULLET_FRAC')+i, 0, 1)
    put('eb_hi', 4100, 4)
    put('eb_lance_count', 4096, 4)
    tail = record(4099)
    tick()
    assert record(4099)[:2] == (tail[0]+1, tail[1]), record(4099)
    assert v.load(sym['eb_lance_count'], 2) == 4096
    print('PASS full special index falls back to pool scan, including index 4099', flush=True)

    # Both minion waves must end before the third/final phase (BOSS).
    blank(0)
    put('round_spawned', 75)
    tick()
    assert v.load(sym['campaign_round'], 1) == 1 and v.load(sym['boss_state'], 1) == 0
    put('round_spawned', 75)
    tick()
    assert v.load(sym['campaign_round'], 1) == 2 and v.load(sym['boss_state'], 1) == 4
    print('PASS campaign enters BOSS after exactly two minion waves (three phases)', flush=True)

    put('is_stress_stage', 0, 4)
    call('stress_stage_init')
    sequence, metrics = [], []
    # Exercise every integrated cast with natural game updates and DMA motion.
    # Jump only the quiet tail of each cast; boundary checks use real boss_update.
    for stage in [1, 2]:
        for kind in range(3):
            assert (v.load(sym['wave'], 2), v.load(state+2, 1), v.load(state, 2)) == (stage, kind, 0)
            sequence.append([stage+1, kind+1])
            peak, beam_peak, cost = 0, 0, 0
            beam_uploaded = False
            for f in range(480 if args.full_cycle else 190):
                cost = max(cost, tick(f))
                assert v.load(sym['bt_dropped']) == 0, (stage, kind, f, 'bucket drop')
                peak = max(peak, v.load(sym['active_count'], 2))
                beam_peak = max(beam_peak, sum(v.load(state+12+i*16+8, 1)>0 for i in range(6)))
                if kind == 2 and f == 150:
                    v.active = v.request = v.right_active = v.right_request = 0x800000
                    call('game_render', 0xe00000)
                    beam_uploaded = any(v.params.get(0x400+16*i, 0)&0x80000000 for i in range(6))
            assert peak > 192
            if kind == 2:
                assert beam_peak > 0 and beam_uploaded
            assert v.load(sym['boss_hp'], 2) == v.load(sym['boss_hp_max'], 2)
            assert sum(bool(v.load(T.ENEMY_BASE+i*16+13, 1)&1) for i in range(T.ENEMY_COUNT)) == 50
            metrics.append(dict(boss=stage+1, skill=kind+1, peak_bullets=peak, beam_peak=beam_peak, peak_update_instructions=cost))
            print('PASS pressure cast', metrics[-1], flush=True)
            if not args.full_cycle:
                v.store(state, 479, 2)
                call('boss_update')
    assert (v.load(sym['wave'], 2), v.load(state+2, 1), v.load(state, 2)) == (1, 0, 0)
    assert v.min_sp >= 0xf900fd00, hex(v.min_sp)
    report = dict(firmware_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), pressure_sequence=sequence,
                  metrics=metrics, orb_slots=128, special_index_overflow=4100,
                  campaign_phases=3, natural_pressure_frames=2880 if args.full_cycle else 1140,
                  min_sp=hex(v.min_sp), board_fps='not measured')
    (args.out/'verification.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')


if __name__ == '__main__':
    main()
