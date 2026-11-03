"""Execute the linked RV32 game; compare six casts to independent HTML math."""
import argparse,hashlib,json,math,os,struct,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'simulator'),str(ROOT/'tools')]
os.environ['SIM_PURE_PYTHON']='1'
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func


def main():
    ap=argparse.ArgumentParser(__doc__);ap.add_argument('--out',type=Path,required=True);args=ap.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    binary=ROOT/'sw/build/firmware.bin';sym=_symtab(binary.with_suffix('.elf'))
    code=T.load_code_from_source(binary);T.build_boot_snapshot(code)
    vm=T.new_vm(code);vm.r[2]=0xf900ffc0;state=T.mm_value('MM_BOSS23_CAST');pad=0x04901800
    vm.store(pad,0x8080);vm.store(pad+4,0)
    def put(n,v,size=1):vm.store(sym[n],v,size)
    def call(n,*a):return call_func(vm,sym[n],a,budget=30_000_000)
    def setup(stage,kind):
        call('game_init')
        for n,v,s in [('wave',stage,2),('stage_bg_active',stage,4),('boss_state',2,1),('boss_hp_max',1000,2),('boss_hp',1000,2),('boss_opener_stage',2,1),('boss_signature_used',1,1),('boss_x',651,2),('boss_y',147,2),('player_x',683,2),('player_y',600,2),('invuln',255,1),('boss_fire_timer',0,1)]:put(n,v,s)
        vm.store(state,0,2);vm.store(state+2,kind,1)
    def records():
        n=vm.load(sym['eb_hi']);return [struct.unpack('<hhbbBB',bytes(vm.load(T.EBULLET_BASE+i*8+j,1) for j in range(8))) for i in range(n) if vm.load(T.EBULLET_BASE+i*8+6,1)&1]
    def expected(stage,kind):
        out=[]
        def shot(x,y,a,s,h):out.append((x,y,math.cos(a)*s*16/75,math.sin(a)*s*16/75,h))
        if stage==1 and kind==0:
            for i in range(8):
                for arm in range(6):
                    for k in range(6):
                        a=arm*math.tau/6+i*.095+(k-2.5)*.065
                        shot(683,175,a,130+k*15,6 if i%2 else 0);shot(683,175,a+.03,245+k*8,3)
        elif stage==1 and kind==2:
            events=sorted((.65+i*.65+k*.35,i,k) for i in range(3) for k in range(3))
            for _,i,k in events:
                a=math.tau*i/3-math.pi/2;x=683+170*math.cos(a);y=295+100*math.sin(a)
                for j in range(39):shot(x,y,math.tau*j/39+k*.08,150+k*35,6 if k%2 else 0)
        elif stage==2 and kind==0:
            for i in range(44):
                for j in range(3):
                    a=i*.085+j*math.tau/3;x=683+125*math.cos(a);y=175+65*math.sin(a)
                    for k in range(3):shot(x,y,a+math.pi/2+(k-1)*.09,180+(i%3)*18,4 if j%2 else 6)
                    shot(x,y,-a+math.pi/2,250,2)
        elif stage==2 and kind==1:
            for w in range(6):
                for i in range(144):
                    a=math.tau*i/144;s=145+65*math.cos(8*a)
                    shot(683,175,a+w*.09,s,4);shot(683,175,a+w*.09+.025,s*.67+28,6)
        elif stage==2 and kind==2:
            # The fixed-point gap comparison is checked geometrically below.
            return None
        return out
    payload=(ROOT/'sw/build/asset_unpack.bin').read_bytes();base=T.mm_value('MM_ASSET_UNPACK')-T.SCRATCH_BASE
    assert bytes(vm.scratch[base:base+len(payload)])==payload,'RV32 LZ boot decode differs from canonical assets'
    bg=bytes(int(x,16) for x in (ROOT/'rtl/bitblt/bg_rle.hex').read_text().split());assert payload[:len(bg)]==bg
    print('PASS lossless boot unpack: backgrounds, all palettes/streams, skill LUTs byte-exact',flush=True)
    # Real DDR is uninitialized on power-up. Clearing only the TTL must still
    # publish disabled descriptors even if stale coordinates are negative.
    off=state-T.SCRATCH_BASE;vm.scratch[off:off+512]=b'\xff'*512
    call('game_init');vm.active=vm.request=vm.right_active=vm.right_request=0x800000
    call('game_render',0xe00000)
    assert all(not vm.params.get(0x400+16*i,0)&0x80000000 for i in range(6))
    print('PASS dirty-DDR reset: no accidentally enabled beam descriptors',flush=True)
    results=[]
    for stage,kind in [(1,0),(1,2),(2,0),(2,1),(2,2)]:
        setup(stage,kind);births=[];last=0;beam_peak=0
        for frame in range(1,361):
            call('boss_update');n=vm.load(sym['active_count'],2)
            if n!=last:births.append((frame,n-last));last=n
            beam_peak=max(beam_peak,sum(vm.load(state+12+i*16+8,1)>0 for i in range(6)))
        actual=records();want=expected(stage,kind)
        if want is not None:
            assert len(actual)==len(want),(stage,kind,len(actual),len(want))
            for i,(a,e) in enumerate(zip(actual,want)):
                assert max(abs(a[0]-e[0]),abs(a[1]-e[1]))<2,(stage,kind,i,'position',a,e)
                assert max(abs(a[2]-e[2]),abs(a[3]-e[3]))<1.1,(stage,kind,i,'velocity',a,e)
                assert a[5]&7==e[4] and a[4]&32,(stage,kind,i,'flags/hue',a,e)
        else:
            assert 780<len(actual)<840,len(actual)
            for b in actual:
                assert not (b[3]>0 and abs(b[2])*5.5<b[3]),'gap contains a projectile'
        if kind==2:assert beam_peak==(6 if stage==1 else 4),(stage,beam_peak)
        print(f'PASS BOSS{stage+1} skill{kind+1}: {len(actual)} shots; emissions {births}; beams peak {beam_peak}',flush=True)
        results.append(dict(boss=stage+1,skill=kind+1,shots=len(actual),births=births,beam_peak=beam_peak))
    setup(1,1)
    for _ in range(42):call('boss_update')
    seeds=records();assert len(seeds)==15 and all(b[4]&16 and b[1]==-22 for b in seeds)
    vm.store(state,360,2)
    def update():put('invuln',255);return call('game_update',pad)
    # Let the seeds cross the top boundary, then freeze. Later bursts must be
    # new children, rather than the old seeds resuming with stale metadata.
    for _ in range(80):update()
    frozen=records();assert len(frozen)==15
    pos=[b[:2] for b in frozen]
    for _ in range(10):update()
    assert [b[:2] for b in records()]==pos,'suspended embers moved'
    for _ in range(35):update()
    children=records();assert len(children)==75 and all(not b[4]&16 for b in children),len(children)
    assert vm.load(sym['active_count'],2)==75,'burst children missing from telemetry'
    print('PASS red rain: top entry, freeze, 15 x 5 child bursts, deferred updates and live counter',flush=True)
    # Warning/collision and rescue clear use the same Q8 geometry as the DSP.
    setup(2,2)
    for _ in range(45):call('boss_update')
    put('invuln',0);call('game_update',pad);assert vm.load(sym['hits_taken'],2)==0
    vm.store(state+12+8,38,1);put('invuln',0);call('game_update',pad)
    assert vm.load(sym['hits_taken'],2)==1
    assert all(vm.load(state+12+i*16+8,1)==0 for i in range(6))
    print('PASS DSP beam collision: harmless warning, active hit, rescue clears all six',flush=True)
    previews=[];peak=0
    for stage in [1,2]:
        for kind in range(3):
            setup(stage,kind)
            count=185 if stage==2 and kind==1 else 140
            for _ in range(count):peak=max(peak,update())
            put('stage_banner',0,2);vm.active=vm.request=vm.right_active=vm.right_request=0x800000
            call('game_render',0xe00000)
            assert vm.load(T.TLM_BASE+58*4)==0,'scanline bucket overflow'
            from PIL import Image
            name=f'boss{stage+1}_skill{kind+1}';bmp=args.out/(name+'.bmp');vm.save_frame_bmp(str(bmp),0xe00000)
            Image.open(bmp).save(bmp.with_suffix('.png'));previews.append(name)
            print('PASS rendered',name,'DROP=0',flush=True)
    assert vm.min_sp>=0xf900fd00,hex(vm.min_sp)
    (args.out/'verification.json').write_text(json.dumps(dict(firmware_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),skills=results,ember_seeds=15,ember_children=75,previews=previews,peak_update_instructions=peak,min_sp=hex(vm.min_sp),board_fps='not measured'),indent=2)+'\n')


if __name__=='__main__':main()
