"""Linked RV32 checks for scattered glow fill and complete SPRITE accounting."""
import argparse
import hashlib
import json
import math
import os
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'simulator'), str(ROOT/'tools')]
os.environ.setdefault('SIM_PURE_PYTHON', '1')
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func


def main():
    ap = argparse.ArgumentParser(__doc__)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    binary = ROOT/'sw/build/firmware.bin'
    sym = _symtab(binary.with_suffix('.elf'))
    code = T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    v = T.new_vm(code)
    v.r[2] = 0xf900ffc0
    pad, state = 0x04901800, T.mm_value('MM_BOSS23_CAST')
    v.store(pad, 0x8080)
    v.store(pad+4, 0)

    def put(n, x, size=1):
        v.store(sym[n], x, size)

    def call(n, *args):
        return call_func(v, sym[n], args, budget=30_000_000)

    def records():
        return {i:struct.unpack_from('<hhbbBB', v.scratch, T.EBULLET_BASE-T.SCRATCH_BASE+i*8)
                for i in range(T.EBULLET_COUNT) if v.load(T.EBULLET_BASE+i*8+6, 1)&1}

    def accounting():
        call('telemetry_write')
        shots = len(records())
        assert shots == v.load(sym['active_count'], 2)
        assert v.load(T.TLM_BASE+12*4) == shots  # TLM_EBULLETS
        beams = v.load(T.TLM_BASE+59*4)
        actors = sum(bool(v.load(T.ENEMY_BASE+i*16+13,1)&1) for i in range(T.ENEMY_COUNT))
        player_shots = sum(bool(v.load(T.PBULLET_BASE+i*8+6,1)&1) for i in range(T.PBULLET_COUNT))
        items = v.load(T.TLM_BASE+13*4)
        expected = actors+player_shots+shots+items+(v.load(sym['lives'],1)!=0)+(v.load(sym['boss_state'],1)!=0 and v.load(sym['boss_hp'],2)>0)+beams
        actual = v.load(T.TLM_BASE+57*4)
        assert actual == expected, (actual, expected, shots, beams)
        return actual

    def tick(f):
        put('invuln', 255)
        cost = call('game_update', pad)
        call('bucket_build_start', f&1)
        call('bucket_build_finish')
        assert v.load(sym['bt_dropped']) == 0, ('DROP', f)
        return cost

    call('stress_stage_init')
    put('boss_state', 0)
    for i in range(T.ENEMY_COUNT):
        v.store(T.ENEMY_BASE+i*16+11, 255, 1)
    tick(0)
    first = records()
    assert len(first) >= 185
    assert all(b[4] == 1 and b[5]&192 == 64 and (b[2] or b[3]) for b in first.values())
    assert len({b[2:4] for b in first.values()}) >= 20
    assert len({b[1]&7 for b in first.values()}) == 8
    xs, ys = [b[0] for b in first.values()], [b[1] for b in first.values()]
    mx, my = sum(xs)/len(xs), sum(ys)/len(ys)
    corr = sum((x-mx)*(y-my) for x,y in zip(xs,ys))/math.sqrt(sum((x-mx)**2 for x in xs)*sum((y-my)**2 for y in ys))
    assert abs(corr) < .2, corr
    tick(1)
    second = records()
    for i,b in first.items():
        if 200 < b[0] < 1150 and 10 < b[1] < 750:
            assert second[i][:2] == (b[0]+b[2], b[1]+b[3]), (i,b,second[i])
    # Verify the packed buckets actually select slots 29..36 for ordinary fill.
    table = T.mm_value('MM_BUCKET_TABLE')+96*4096
    slots = set()
    for g in range(96):
        n = v.load(T.mm_value('MM_BUCKET_USED')+192+g*2, 2)
        slots.update((v.load(table+g*4096+k*4)>>17)&63 for k in range(n))
    assert slots and slots <= set(range(29,37)), slots
    print('PASS scattered fill: independent headings/speeds, all subrows, glow atlas and one DMA move',flush=True)

    call('stress_stage_init')
    put('stress_target', 8000, 2)
    peak = peak_bucket = peak_update = 0
    for f in range(360):
        peak_update = max(peak_update, tick(f))
        if f%8 == 0:
            accounting()
        peak = max(peak, v.load(sym['active_count'],2))
        peak_bucket = max(peak_bucket, max(v.load(T.mm_value('MM_BUCKET_USED')+(f&1)*192+g*2,2) for g in range(96)))
    assert peak >= 7900
    print('PASS LOAD 8000: raw pool and SPRITE count agree, DROP=0', peak, peak_bucket,flush=True)

    # Isolate six procedural BOSS beams: warning and live phases each count
    # once, not once per white core/glow layer and not zero because no DDR shot.
    put('wave', 2, 2)
    for i in range(6):
        v.store(state+12+i*16+8, 100 if i&1 else 30, 1)
    without = accounting()-6
    assert v.load(T.TLM_BASE+59*4) == 6
    for i in range(6):
        v.store(state+12+i*16+8, 0, 1)
    assert accounting() == without and v.load(T.TLM_BASE+59*4) == 0
    # Legacy bars share the column renderer. Its opener fallback is hidden
    # while a live cut occupies it and must not be counted a second time.
    put('boss_laser', 20)
    v.store(sym['beam_phase'], 2, 1)
    accounting()
    assert v.load(T.TLM_BASE+59*4) == 1
    v.store(sym['beam_phase'], 0, 1)
    accounting()
    assert v.load(T.TLM_BASE+59*4) == 4
    put('boss_laser', 0)
    # Show a natural judgment cast and confirm the on-screen sampled value.
    v.store(state, 44, 2)
    v.store(state+2, 2, 1)
    tick(360)
    expected = accounting()
    put('frame_tick', 368, 4)
    v.active = v.request = v.right_active = v.right_request = 0x800000
    call('game_render', 0xe00000)
    assert v.load(sym['hud_sig']+8*4)&65535 == expected
    v.save_frame_bmp(str(a.out/'free_barrage.bmp'), 0xe00000)
    from PIL import Image
    Image.open(a.out/'free_barrage.bmp').save(a.out/'free_barrage.png')
    assert v.min_sp >= 0xf900fd00, hex(v.min_sp)
    report = dict(firmware_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        load=8000,frames=360,peak_bullets=peak,peak_bucket_entries=peak_bucket,
        peak_update_instructions=peak_update,spawn_xy_correlation=corr,
        velocity_pairs=len({b[2:4] for b in first.values()}),beam_count=6,
        hud_sprites=expected,min_sp=hex(v.min_sp),board_fps='not measured')
    (a.out/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print('PASS six scanout beams, expiry, legacy overlap and actual HUD count',flush=True)


if __name__ == '__main__':
    main()
