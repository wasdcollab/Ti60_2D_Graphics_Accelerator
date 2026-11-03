from pathlib import Path
import os,sys
ROOT=Path(__file__).resolve().parents[1];sys.path[:0]=[str(ROOT/'simulator'),str(ROOT/'tools')];os.environ.setdefault('SIM_PURE_PYTHON','1')
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func
code=T.load_code_from_source(ROOT/'sw/build/firmware.bin');T.build_boot_snapshot(code);s=_symtab(ROOT/'sw/build/firmware.elf');v=T.new_vm(code);v.r[2]=0xF900FFC0;call_func(v,s['game_init']);v.active=v.request=v.right_active=v.right_request=0x800000
for n,val,size in [('player_x',683,2),('player_y',500,2),('bomb_x',683,2),('bomb_y',500,2),('stage_banner',0,2)]:v.store(s[n],val,size)
p=ROOT/'work_sim/merge_20261029/player_spell';p.mkdir(parents=True,exist_ok=True)
for age in range(0,36,3):
 v.store(s['bomb_flash'],36-age,1);call_func(v,s['game_render'],(0xE00000,));v.save_frame_bmp(str(p/('%02d.bmp'%age)),0xE00000)
print('Captured actual player spell: anchored opposite orbs and expanding wave; simulated scanout, not board capture',flush=True)
