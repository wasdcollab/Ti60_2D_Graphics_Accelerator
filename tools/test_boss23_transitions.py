"""Check new procedural layers are disabled on exit and game re-entry."""
import argparse,hashlib,json,os,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'simulator'),str(ROOT/'tools')];os.environ['SIM_PURE_PYTHON']='1'
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func


def main():
    ap=argparse.ArgumentParser(__doc__);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
    binary=ROOT/'sw/build/firmware.bin';sym=_symtab(binary.with_suffix('.elf'));code=T.load_code_from_source(binary);T.build_boot_snapshot(code)
    v=T.new_vm(code);v.r[2]=0xf900ffc0
    def call(n,*args):return call_func(v,sym[n],args,budget=30_000_000)
    call('game_init')
    for i in range(6):v.params[0x400+16*i]=0x80000000|683|(600<<11)
    for i in range(4):v.params[0x200+16*i]=0xc0000000|683|(600<<11)|(64<<21)
    v.active=v.request=v.right_active=v.right_request=0xe00000
    call('resync_scanout',0x04901810,0x04901814,1)
    assert all(v.params[0x400+i*16]==0 for i in range(6))
    assert all(v.params[0x200+i*16]==0 for i in range(4))
    assert v.params[0x45c]==0
    call('game_init');state=T.mm_value('MM_BOSS23_CAST')
    assert v.load(state,2)==0 and v.load(state+2,1)==0
    assert all(v.load(state+12+i*16+8,1)==0 for i in range(6))
    assert v.min_sp>=0xf900fd00,hex(v.min_sp)
    a.out.parent.mkdir(parents=True,exist_ok=True)
    a.out.write_text(json.dumps(dict(firmware_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),menu_exit='six beams and four FX slots disabled',reentry='clean cast and disabled beams',min_sp=hex(v.min_sp)),indent=2)+'\n')
    print('PASS game exit/re-entry: no frozen spell beams or procedural rings on the menu',flush=True)


if __name__=='__main__':main()
