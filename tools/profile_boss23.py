"""Two uninterrupted three-cast cycles on linked firmware, with per-frame buckets."""
import argparse,hashlib,json,os,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'simulator'),str(ROOT/'tools')];os.environ['SIM_PURE_PYTHON']='1'
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func
from bucket_demand import snapshot


def main():
    ap=argparse.ArgumentParser(__doc__);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
    binary=ROOT/'sw/build/firmware.bin';sym=_symtab(binary.with_suffix('.elf'));code=T.load_code_from_source(binary);T.build_boot_snapshot(code)
    v=T.new_vm(code);v.r[2]=0xf900ffc0;pad=0x04901800;v.store(pad,0x8080);v.store(pad+4,0)
    def put(n,x,s=1):v.store(sym[n],x,s)
    def call(n,*args):return call_func(v,sym[n],args,budget=30_000_000)
    state=T.mm_value('MM_BOSS23_CAST');results=[]
    for stage in [1,2]:
        call('game_init')
        for n,x,s in [('wave',stage,2),('stage_bg_active',stage,4),('boss_state',2,1),('boss_hp',1000,2),('boss_hp_max',1000,2),('boss_opener_stage',2,1),('boss_signature_used',1,1),('boss_x',651,2),('boss_y',147,2),('boss_fire_timer',0,1)]:put(n,x,s)
        metrics=[dict(boss=stage+1,skill=i+1,peak_bullets=0,peak_bucket_entries=0,peak_update_instructions=0) for i in range(3)]
        for frame in range(1440):
            kind=v.load(state+2,1);put('invuln',255)
            steps=call('game_update',pad)
            call('bucket_build_start',frame&1);call('bucket_build_finish')
            assert v.load(sym['bt_dropped'])==0,(stage,frame,'DROP')
            counts=[v.load(T.mm_value('MM_BUCKET_USED')+(frame&1)*192+g*2,2) for g in range(96)]
            m=metrics[kind];m['peak_bullets']=max(m['peak_bullets'],v.load(sym['active_count'],2));m['peak_bucket_entries']=max(m['peak_bucket_entries'],max(counts));m['peak_update_instructions']=max(m['peak_update_instructions'],steps)
            if frame%120==0:snapshot(v,sym,T)
        assert v.load(state,2)==0 and v.load(state+2,1)==0,'three-cast cycle did not wrap at 1440 frames'
        results.extend(metrics);print('PASS uninterrupted three-cast cycle:',metrics,flush=True)
        # Bomb and death must clear hardware beams and procedural lightfields.
        v.store(state+12+8,38,1);v.store(state+108+8,30,1)
        put('bomb_charge',8);v.store(pad+4,1<<16);call('game_update',pad);v.store(pad+4,0);assert all(v.load(state+12+i*16+8,1)==0 for i in range(6))
        v.store(state+12+8,38,1);put('boss_hp',0,2);call('boss_update')
        assert all(v.load(state+12+i*16+8,1)==0 for i in range(6)) and v.load(state,2)==0
    assert v.min_sp>=0xf900fd00,hex(v.min_sp)
    a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(dict(firmware_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),frames=2880,metrics=results,min_sp=hex(v.min_sp),board_fps='not measured'),indent=2)+'\n')


if __name__=='__main__':main()
