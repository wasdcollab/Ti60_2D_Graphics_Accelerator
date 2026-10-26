"""Linked-firmware regression for five-digit load control and spell-background transitions."""
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'simulator'))
os.environ.setdefault('SIM_PURE_PYTHON', '1')
import test_runner as T
from profile_stress_frame import symbols, call_func
from test_recovery_menu import publish


def main():
    binary = ROOT / 'sw/build/firmware.bin'
    sym = symbols(binary.with_suffix('.elf'))
    code = T.load_code_from_source(binary)
    T.build_boot_snapshot(code)
    vm = T.new_vm(code)
    card = T.mm_value('MM_CARD_BG')
    colours = {vm.load(card+y*8192+x*4) for y in range(0,768,17) for x in range(0,1366,19)}
    assert len(colours) > 24 and vm.load(card+384*8192+683*4) == 0xFFD6D2
    T.start_game(vm)
    for stage in (0,1,2):
        for name,value,size in (('stage_bg_active',stage,4), ('wave',stage,2),
                                ('boss_hp_max',400,2),('boss_hp',400,2),
                                ('boss_x',600,2),('boss_y',40,2),('boss_state',1,1),
                                ('boss_opener_stage',0,1)):
            vm.store(sym[name],value,size)
        call_func(vm,sym['boss_update'])
        assert vm.load(sym['boss_card_active'],1) == 1
        vm.store(sym['paused'],1,1)
        for _ in range(2):
            publish(vm,1)
            assert T.plate_match(vm,card) > .69
        T.save_frame(vm,vm.right_request,ROOT/'work_sim'/('card_stage%d.bmp'%stage),
                     ROOT/'work_sim'/('card_stage%d.png'%stage))
        vm.store(sym['boss_state'],2,1)
        vm.store(sym['boss_laser'],1,1)
        vm.store(sym['boss_pat_timer'],255,1)
        vm.store(sym['boss_fire_timer'],255,1)
        call_func(vm,sym['boss_update'])
        assert vm.load(sym['boss_card_active'],1) == 0
        for _ in range(2):
            publish(vm,1)
            # 0.698 on both this tree and HEAD under the pure-Python VM
            # (sprites and weather). The card gate above is 0.69; a wrong
            # plate scores 0.
            assert T.plate_match(vm,T.BACKGROUND_PLANE+stage*T.BACKGROUND_PLATE) > .69
        print('PASS stage %d: entrance switches to card, laser end restores stage, both buffers'%stage,flush=True)
        vm.store(sym['paused'],0,1)
    vm = T.new_vm(code)
    T._enter_pressure_stage(vm)
    vm.store(sym['stress_target'],19872,2)
    vm.store(sym['stress_prev_y'],0,1)
    assert T.press_until(vm,['y'],lambda: vm.load(sym['stress_target'],2)==20000,budget=20_000_000)
    publish(vm,2)
    assert vm.load(sym['stress_target'],2)==20000
    atlas = vm.load(T.mm_value('MM_FONT_TABLE')+8)
    fb = vm.fb[vm.right_request]
    for pos,ch in enumerate('20000'):
        g=ord(ch)-32
        source=atlas+(g//16)*4096*9+(g%16)*96
        for y in range(24):
            for x in range(18):
                pixel=vm.load(source+y*1536+x*4)
                if pixel != 0xFF00FF:
                    assert fb[(648+y)*2048+68+pos*21+x] == pixel, ('LOAD glyph',pos,x,y)
    T.save_frame(vm,vm.right_request,ROOT/'work_sim/load10000.bmp',ROOT/'work_sim/load10000.png')
    assert T.press_until(vm,['y'],lambda: vm.load(sym['stress_target'],2)==192,budget=20_000_000)
    print('PASS Y control: 19872 -> 20000 -> 192; five visible LOAD digits; min SP=%#x'%vm.min_sp,flush=True)


if __name__ == '__main__':
    main()
