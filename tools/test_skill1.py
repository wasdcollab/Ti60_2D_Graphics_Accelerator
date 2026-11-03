"""Check HTML trajectories, denser BOSS1 casts and the dedicated glow tiles."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'simulator'), str(ROOT/'tools')]
os.environ.setdefault('SIM_PURE_PYTHON', '1')
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func


def main():
    ap = argparse.ArgumentParser(__doc__)
    ap.add_argument('--out', type=Path, default=ROOT/'work_sim/skill1_20261031')
    args = ap.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
    binary = ROOT/'sw/build/firmware.bin'
    sym = _symtab(binary.with_suffix('.elf'))
    code = T.load_code_from_source(binary); T.build_boot_snapshot(code)
    vm = T.new_vm(code); vm.r[2] = 0xF900FFC0
    state = T.mm_value('MM_BOSS1_CAST'); pad = 0x04901800
    vm.store(pad, 0x8080); vm.store(pad+4, 0)

    def put(n, v, size=1): vm.store(sym[n], v, size)
    def call(n, *a): return call_func(vm, sym[n], a, budget=30_000_000)
    def setup(kind):
        call('game_init')
        for n, v, size in [('wave',0,2),('stage_bg_active',0,4),('boss_state',2,1),
                           ('boss_hp_max',1000,2),('boss_hp',1000,2),('boss_opener_stage',2,1),
                           ('boss_signature_used',1,1),('boss_x',600,2),('boss_y',280,2),
                           ('player_x',683,2),('player_y',600,2),('invuln',255,1)]: put(n,v,size)
        vm.store(state, 0, 2); vm.store(state+2,kind,1)
    def records():
        bound = vm.load(sym['eb_hi'])
        return [struct.unpack('<hhbbBB', bytes(vm.load(T.EBULLET_BASE+i*8+j,1) for j in range(8)))
                for i in range(bound) if vm.load(T.EBULLET_BASE+i*8+6,1)&1]
    def update(): return call('game_update', pad)
    def picture(name):
        put('stage_banner',0,2)
        vm.active=vm.request=vm.right_active=vm.right_request=0x800000
        call('game_render',0xE00000)
        assert vm.load(T.TLM_BASE+58*4)==0, 'scanline bucket overflow'
        from PIL import Image
        bmp=args.out/(name+'.bmp'); vm.save_frame_bmp(str(bmp),0xE00000)
        im=Image.open(bmp); im.save(bmp.with_suffix('.png'))
        if name in ('boss1_all_angles','boss1_lasers'):
            x = 450 if name=='boss1_all_angles' else 683
            assert im.convert('RGB').getpixel((x,200))==(255,255,255), 'beam missing from composed image'

    # The 8 oriented sparks use the existing tile RAM's tail.  Check their
    # visible core and additive halo, including slots beyond the old 5-bit limit.
    for direction in range(8):
        tile = bytes(vm.btile[22688+direction*832:22688+(direction+1)*832])
        assert tile[13*32+13] == 1, 'white core missing'
        assert {1,2,3}.issubset(tile), 'solid core layers missing'
        assert len(set(tile) & set(range(9,27))) >= 12, 'halo lost its falloff'
        assert all(vm.bpal[role+5*32] >> 24 == 254 for role in set(tile) if 9 <= role <= 26)
        assert vm.load(sym['bt_tile_rows']+(29+direction)*2,2) == 832
    assert not any(vm.btile[29344:]), 'spark tiles exceed reserved tail'
    print('PASS eight HTML glow/tail tiles: white cores, additive falloff, existing 32 KiB store',flush=True)

    # Cold streams in the existing ROM gap must match their canonical bytes.
    src=(ROOT/'sw/build/visual_assets_rom_source.c').read_text()
    header=(ROOT/'sw/app/asset_rom_extra.h').read_text()
    rom=(ROOT/'sw/build/asset_unpack.bin').read_bytes()
    moved=0
    for name, offset in re.findall(r'#define ([pr]_\w+).*MM_ASSET_UNPACK \+ (\d+)u',header):
        m=re.search(r'static const (uint8_t|uint32_t) '+name+r'\[\] = \{(.*?)\};',src,re.S)
        values=[int(x.strip().rstrip('uU'),0) for x in m[2].split(',') if x.strip()]
        expected=bytes(values) if m[1]=='uint8_t' else struct.pack('<%dI'%len(values),*values)
        at=int(offset)
        assert rom[at:at+len(expected)]==expected
        assert bytes(vm.load(T.mm_value('MM_ASSET_UNPACK')+at+i,1) for i in range(len(expected)))==expected
        moved+=len(expected)
    print('PASS cold asset relocation: %d bytes, ROM and boot DDR byte-exact'%moved,flush=True)

    setup(0)
    for _ in range(162): call('boss_update')
    arc=records(); assert len(arc)==54
    angles=[]
    for i,b in enumerate(arc):
        angle=math.pi*.75+math.pi*.75*i/53
        vx,vy=round(math.cos(angle)*89.6),round(-math.sin(angle)*89.6)
        assert b[2:4]==(vx,vy) and b[4]&32,(i,b)
        assert b[:2]==(632+int(vx*34/90),308+int(vy*34/90))
        angles.append(math.degrees(math.atan2(-vy,vx))%360)
    assert all(a<b for a,b in zip(angles,angles[1:]))
    vm.store(state,200,2)
    for _ in range(10): put('invuln',255);update()
    for a,b in zip(arc,records()):
        assert b[:2]==(a[0]+a[2]*10//16,a[1]+a[3]*10//16)
    setup(0)
    for _ in range(90):put('invuln',255);update()
    picture('boss1_arc')
    print('PASS arc: 54 distinct directions, 135..270 degrees, 3-tick gap, Q4 integration',flush=True)

    setup(2)
    for _ in range(162): call('boss_update')
    dna=records(); assert len(dna)==108
    ax,ay=struct.unpack('<bb',bytes(vm.load(state+8+j,1) for j in range(2)))
    for i in range(54):
        side=round(math.sin(i/53*4*math.pi)*120)
        for j,sign in enumerate((-1,1)):
            b=dna[i*2+j]
            assert b[:2]==(632-int(ay*side*sign/90),308+int(ax*side*sign/90))
            assert b[2:4]==(ax,ay) and b[4]&32
    assert ax*(683-632)+ay*(600-308)>0
    setup(2)
    for _ in range(90):put('invuln',255);update()
    picture('boss1_dna')
    print('PASS DNA: 54 symmetric pairs, two sine periods, common player-directed axis',flush=True)

    setup(1)
    laser_counts=[]
    for i in range(18):
        old=len(records());vm.store(state,i*9,2)
        px,py=450+i*18,350+i*7;put('player_x',px,2);put('player_y',py,2)
        call('boss_update');new=records()[old:];assert new
        angle=math.pi/2+math.pi/2*i/17
        dx,dy=round(math.cos(angle)*256),round(-math.sin(angle)*256)
        assert all(abs((b[0]-px)*dy-(b[1]-py)*dx)<=512 for b in new)
        assert all(b[4]&128 and b[2]==98 and b[5]==6 for b in new)
        assert any((b[0]-px)*dx+(b[1]-py)*dy>0 for b in new)
        assert any((b[0]-px)*dx+(b[1]-py)*dy<0 for b in new)
        laser_counts.append(len(new))
    vm.store(state,162,2)
    peak_update=0
    for i in range(36):put('invuln',255);peak_update=max(peak_update,update())
    assert all(b[5]&128 for b in records())
    picture('boss1_all_angles')
    for _ in range(62):put('invuln',255);update()
    assert not records(),'expired lasers remain'
    print('PASS 18 laser angles: frozen origins, 36 warning + 62 active ticks, both-sided lines, expiry; no bucket drops',flush=True)

    setup(1)
    for _ in range(90):put('invuln',255);update()
    picture('boss1_lasers')

    setup(1);put('player_y',500,2);call('boss_update');vm.store(state,162,2)
    picture('boss1_warning')
    for _ in range(35):put('invuln',0);update()
    assert vm.load(sym['hits_taken'],2)==0,'warning damaged the player'
    put('invuln',0);update()
    assert vm.load(sym['hits_taken'],2)==1,'active beam did not damage the player'
    print('PASS laser collision: harmless warning, active beam hits, normal rescue clear preserved',flush=True)
    setup(1);call('boss_update');put('boss_hp',0,2);call('boss_update')
    assert not records() and vm.load(state,2)==0,'boss death left skill state alive'
    assert vm.min_sp>=0xF900FD00,hex(vm.min_sp)
    (args.out/'skill1_verification.json').write_text(json.dumps(dict(
        firmware_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),arc_shots=54,
        dna_pairs=54,laser_samples=laser_counts,warning_ticks=36,beam_ticks=62,
        peak_update_instructions=peak_update,min_sp=hex(vm.min_sp),
        board_fps='not measured'),indent=2)+'\n')


if __name__=='__main__':main()
