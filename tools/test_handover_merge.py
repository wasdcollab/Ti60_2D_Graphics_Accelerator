"""Linked RV32 firmware regression for the teammate merge, not board FPS."""
import os,sys,json,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'simulator'),str(ROOT/'tools')]
os.environ.setdefault('SIM_PURE_PYTHON','1')
import test_runner as T
from firmware_syms import _symtab
from profile_stress_frame import call_func
from test_visual_upgrade import check_effect_descriptors
OUT=ROOT/'work_sim/merge_20261029'
def main():
 binary=ROOT/'sw/build/firmware.bin';sym=_symtab(binary.with_suffix('.elf'));code=T.load_code_from_source(binary);T.build_boot_snapshot(code);vm=T.new_vm(code)
 def put(n,v,size=1):vm.store(sym[n],v,size)
 def live():return sum(bool(vm.load(T.ENEMY_BASE+i*16+13,1)&1) for i in range(T.ENEMY_COUNT))
 def update(btn=0):
  vm.store(0xF900FFE0,0x8080);vm.store(0xF900FFE4,btn);put('invuln',250);return call_func(vm,sym['game_update'],(0xF900FFE0,),budget=30000000)
 vm.r[2]=0xF900FFC0;call_func(vm,sym['game_init']);assert T.ENEMY_COUNT==75
 births=[]
 for stage in range(3):
  for rnd in range(5):
   assert vm.load(sym['campaign_round'],1)==rnd
   born=0
   for tick in range(260):
    prev=vm.load(sym['round_spawned'],1);update();now=vm.load(sym['round_spawned'],1);born+=now-prev
    assert live()<=75 and vm.load(sym['boss_state'],1)==0
    if now==75:break
   assert born==75 and live()==75,(stage,rnd,born,live())
   if stage==0 and rnd==0:
    vm.active=vm.request=vm.right_active=vm.right_request=0x800000
    call_func(vm,sym['game_render'],(0xE00000,));vm.save_frame_bmp(str(OUT/'campaign75.bmp'),0xE00000)
   put('atk',20);put('bomb_charge',8);update(1<<16);assert live()==0
   assert vm.load(sym['kills'],2)==75*(rnd+1)
   assert vm.load(sym['campaign_round'],1)==rnd+1
   assert vm.load(sym['boss_state'],1)==(4 if rnd==4 else 0)
   T.clear_pool(vm,T.PBULLET_BASE,T.PBULLET_COUNT,8,6)
   births.append(born)
  put('boss_state',3);put('boss_dead_timer',0);call_func(vm,sym['boss_update'])
 assert vm.load(sym['game_clear'],1)==1
 print('PASS campaign: 3 stages x 5 waves x 75 natural births; real bomb kills; boss transitions',flush=True)
 call_func(vm,sym['stress_stage_init']);put('stress_target',0,2);assert live()==50
 y=[vm.load(T.ENEMY_BASE+i*16+2,2) for i in range(50)]
 for _ in range(8):update()
 assert live()==50 and y==[vm.load(T.ENEMY_BASE+i*16+2,2) for i in range(50)]
 vm.store(T.ENEMY_BASE+13,0,1);update();assert live()==49
 put('boss_pattern',5);put('boss_pat_timer',255);put('boss_fire_timer',0);update();assert live()==49,'summon bypassed batch'
 put('bomb_charge',8);update(1<<16);assert live()==50,'empty batch did not refill'
 assert vm.load(sym['kills'],2)==49
 update();put('bomb_charge',8);update(1<<16);assert live()==50 and vm.load(sym['kills'],2)==99
 call_func(vm,sym['telemetry_write']);assert T.tlm(vm,'enemies')==50
 names=('enemies','pbullets','ebullets','items');expected=sum(T.tlm(vm,n) for n in names)+2
 assert T.tlm(vm,'sprites')==expected,(T.tlm(vm,'sprites'),expected)
 observed_sprites=T.tlm(vm,'sprites');components={n:T.tlm(vm,n) for n in names}
 vm.active=vm.request=vm.right_active=vm.right_request=0x800000
 call_func(vm,sym['game_render'],(0xE00000,));vm.save_frame_bmp(str(OUT/'boss_stage50.bmp'),0xE00000)
 print('PASS BOSS STAGE: 50 hovering enemies, no partial refill, summon bounded, repeated kill/refill, exact SPRITES aggregate',flush=True)
 # Fill all 75 slots to exercise the expanded DDR collision list and its guards.
 call_func(vm,sym['game_init']);put('spawn_timer',1000,2);end=T.ENEMY_BASE+75*16;vm.store(end,0x12345678)
 for i in range(75):
  at=T.ENEMY_BASE+i*16;vm.store(at,500|(200<<16));vm.store(at+4,0);vm.store(at+8,1000|(255<<24));vm.store(at+12,1<<8)
 guard=T.mm_value('MM_ENEMY_WORK')+75*4;vm.store(guard,0xAABBCCDD);update();assert vm.load(guard)==0xAABBCCDD and vm.load(end)==0x12345678
 call_func(vm,sym['game_init']);check_effect_descriptors(vm,sym)
 assert vm.min_sp>=0xF900FD00,hex(vm.min_sp)
 result=dict(firmware_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),wave_births=births,boss_stage_enemies=50,sprites=observed_sprites,sprite_components=components,min_sp=hex(vm.min_sp),board_fps='not measured')
 (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print('PASS DDR guards, player spell anchoring/36-frame effect and stack floor',flush=True)
if __name__=='__main__':main()
