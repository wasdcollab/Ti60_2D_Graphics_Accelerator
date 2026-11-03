"""Check the real HUD glyphs and BOSS STAGE spells at LOAD 8000 on linked RV32."""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'simulator'), str(ROOT/'tools')]
os.environ.setdefault('SIM_PURE_PYTHON', '1')
import test_runner as T
from check_hud_layout import hud_boxes
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

    call('game_init')
    x, y, _, _ = hud_boxes()['ROUND']
    atlas = v.load(T.mm_value('MM_FONT_TABLE'))
    for phase in range(3):
        put('campaign_round', phase)
        # Rebuild a fresh plate so the rendered text really comes from the HUD.
        v.active = v.request = v.right_active = v.right_request = 0x800000
        call('game_render', 0xe00000)
        v.drain()
        for k, ch in enumerate(f'{phase+1}/3'):
            g = ord(ch)-32
            for row in range(8):
                for col in range(6):
                    expected = v.load(atlas+(g//16*8+row)*512+(g%16*8+col)*4)
                    if expected == 0xffffff:
                        pixel = int(v.fb[0xe00000][(y+row)*T.SCREEN_PITCH+x+k*7+col])
                        assert pixel&0xffffff == 0xffffff, (phase, ch, row, col, hex(pixel))
        v.save_frame_bmp(str(a.out/f'hud_{phase+1}_of_3.bmp'), 0xe00000)
    print('PASS framebuffer HUD glyphs: 1/3, 2/3, 3/3', flush=True)

    call('stress_stage_init')
    put('stress_target', 8000, 2)
    # Keep the first cast quiet while filling the ordinary DMA-driven storm.
    for f in range(100):
        v.store(state, 370, 2)
        put('invuln', 255)
        call('game_update', pad)
        call('bucket_build_start', f&1)
        call('bucket_build_finish')
    assert v.load(sym['active_count'], 2) >= 7900
    metrics = []
    for kind in [1, 2]:
        put('wave', 2, 2)
        v.store(state, 0, 2)
        v.store(state+2, kind, 1)
        peak = peak_bucket = cost = 0
        for f in range(190):
            put('invuln', 255)
            cost = max(cost, call('game_update', pad))
            call('bucket_build_start', f&1)
            call('bucket_build_finish')
            assert v.load(sym['bt_dropped']) == 0, (kind, f, 'bucket drop')
            peak = max(peak, v.load(sym['active_count'], 2))
            peak_bucket = max(peak_bucket, max(v.load(T.mm_value('MM_BUCKET_USED')+(f&1)*192+g*2, 2) for g in range(96)))
        metrics.append(dict(boss=3, skill=kind+1, peak_bullets=peak, peak_bucket_entries=peak_bucket, peak_update_instructions=cost))
        print('PASS LOAD 8000:', metrics[-1], flush=True)
    assert v.min_sp >= 0xf900fd00, hex(v.min_sp)
    (a.out/'verification.json').write_text(json.dumps(dict(firmware_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        hud=['1/3', '2/3', '3/3'], metrics=metrics, min_sp=hex(v.min_sp), board_fps='not measured'), indent=2)+'\n', encoding='utf-8')


if __name__ == '__main__':
    main()
