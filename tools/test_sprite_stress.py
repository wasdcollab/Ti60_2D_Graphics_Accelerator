"""Execute real RV32I firmware. Synthetic timing injections test decisions,
NOT hardware FPS or the board's sprite limit. Includes one honest cold boot.
"""
from pathlib import Path
import sys
import copy
import json
import hashlib
import pickle

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'simulator'))
sys.path.insert(0, str(ROOT / 'tools'))
import test_runner as t
import test_visual_upgrade as visual
from rv32i_soc_vm import SapphireSoCVM, APB_BASE, SCRATCH_BASE

class ProbeVM(SapphireSoCVM):
    trace_stress = False
    frames_override = None
    inject_fault = 0
    inject_after = None
    fault_seen = False

    def load(self, addr, size=4, signed=False):
        result = super().load(addr, size, signed)
        if addr == APB_BASE + 0x3C and self.frames_override is not None:
            return self.frames_override
        if (addr == APB_BASE and self.inject_fault and not self.fault_seen and
            self.inject_after is not None and self.blit_alpha_calls > self.inject_after and
            not result & 1):
            self.fault_seen = True
            return result | self.inject_fault
        return result

    def blit_alpha(self, dst, src, w, h, ss, ds, global_alpha=255, colorkey=None):
        super().blit_alpha(dst, src, w, h, ss, ds, global_alpha, colorkey)
        if not self.trace_stress:
            return
        assert global_alpha == 160 and colorkey == 0xFFFF00FF
        assert w == h and w in (16, 32, 48, 64) and ss == 256 and ds == 4096
        x, y, _, _ = self.last_alpha_rect
        assert 0 <= x <= 1024-w and 136 <= y <= 600-h
        base = self.frame_of(dst)
        # Independent per-byte blend check at EVERY sprite, before a later
        # overlapping sprite can modify that rectangle.
        keyed = partial = 0
        for row in range(h):
            raw = self._region_read(src+row*ss, w*4)
            before = self.last_alpha_before[row]
            for px in range(w):
                s, d = raw[px*4:px*4+4], before[px*4:px*4+4]
                if int.from_bytes(s, 'little') == colorkey:
                    assert s[3] == 255
                    expected = d
                    keyed += 1
                else:
                    a = (s[3]*160+127)//255
                    expected = bytes((s[k]*a+d[k]*(255-a)+127)//255 for k in range(3))+d[3:4]
                    partial += 0 < a < 255
                actual = self.fb[base][(y+row)*1024+x+px].to_bytes(4, 'little')
                assert actual == expected
        assert keyed and partial, 'must exercise opaque key priority and real blending'

def until(vm, condition, budget=4_000_000):
    start = vm.steps
    while not condition() and vm.steps-start < budget:
        vm.step()
    assert condition(), 'firmware deadline exceeded at '+hex(vm.pc)

def run():
    visual.logic_guard()
    sy = visual.symbols()
    code = t.load_code_from_source(t.DEFAULT_SOURCE)
    vm = ProbeVM(code, bss=t._FW_BSS)
    cache_dir = ROOT/'work_sim/sprite_stress'
    cache_dir.mkdir(parents=True,exist_ok=True)
    cache = cache_dir/'cold_boot.local.pickle'
    stamp = cache_dir/'cold_boot.local.json'
    digest = hashlib.sha256(t.DEFAULT_SOURCE.read_bytes()).hexdigest()
    resumed = False
    # Opt-in reuse ONLY of a trusted project-local checkpoint produced below,
    # with exact firmware and payload hashes. Never load downloaded pickles.
    if '--resume' in sys.argv and cache.exists() and stamp.exists():
        meta=json.loads(stamp.read_text())
        blob=cache.read_bytes()
        if meta['firmware_sha256']==digest and meta['checkpoint_sha256']==hashlib.sha256(blob).hexdigest():
            vm=pickle.loads(blob)
            resumed=True
            print('reusing exact locally cold-booted firmware checkpoint',flush=True)
    # One real cold reset: no injected art, skipped decoder or made-up menu.
    for chunk in range(0 if resumed else 18):
        until_budget = vm.steps+5_000_000
        while not vm.published and vm.steps < until_budget:
            vm.step()
        print('cold boot steps:', vm.steps, flush=True)
        if vm.published:
            break
    assert vm.published, 'no cold boot menu'
    cold = copy.deepcopy(vm)
    if not resumed:
        blob=pickle.dumps(cold,protocol=pickle.HIGHEST_PROTOCOL)
        cache.write_bytes(blob)
        stamp.write_text(json.dumps({'firmware_sha256':digest,
            'checkpoint_sha256':hashlib.sha256(blob).hexdigest()}),encoding='utf-8')
    # Wait for menu to complete before injecting button press.
    vm.btn = t.raw_btn('y', 'x')
    off = 0x01CA7000-SCRATCH_BASE
    until(vm, lambda: int.from_bytes(vm.scratch[off:off+4], 'little') == 64)
    vm.btn = t.raw_btn()
    state = sy['stress']-t.RAM_BASE
    def get(q, i):
        return int.from_bytes(q.ram[state+i*4:state+i*4+4], 'little')
    def put(q, i, value):
        q.ram[state+i*4:state+i*4+4] = (value & 0xFFFFFFFF).to_bytes(4, 'little')
    def frame(q):
        n = len(q.published)
        until(q, lambda: len(q.published) > n)
        return q.right_request
    frame(vm)                         # release entry buttons
    assert get(vm, 0) == get(vm, 1) == 64
    pools = bytes(vm.scratch[0x5000:0x5B6C])
    for size in (16,32,48,64):
        q = copy.deepcopy(vm)
        put(q,0,4); put(q,1,size); put(q,16,1023); put(q,19,1)
        q.trace_stress = True
        n = q.blit_alpha_calls
        fb = frame(q)
        assert q.blit_alpha_calls-n == 4
        assert bytes(q.scratch[0x5000:0x5B6C]) == pools
        out = ROOT/'simulator/output/stress'
        q.save_frame_bmp(out/('size_%d.bmp'%size),fb)
        from PIL import Image
        Image.open(out/('size_%d.bmp'%size)).save(out/('size_%d.png'%size))
        print('PASS size, bounds, opaque key priority and blend:',size,flush=True)
    q = copy.deepcopy(vm)
    q.btn = t.raw_btn('ok'); frame(q)
    assert get(q,21) == 1
    q.btn = t.raw_btn(); frame(q)
    before = get(q,0); q.joy = (128<<8)|255; frame(q)
    assert get(q,0) == before+1
    frame(q); assert get(q,0) == before+1, 'stick must latch until neutral'
    q.joy = 0x8080; q.btn = t.raw_btn(); frame(q)
    q.btn = t.raw_btn('y'); frame(q); assert get(q,1) == 16
    q.btn = t.raw_btn(); frame(q)
    q.btn = t.raw_btn('a'); frame(q); assert get(q,0) == 64
    print('PASS input edges, fine step, size and reset',flush=True)
    # Explicitly inject timing/counters to verify logic, NOT performance.
    for passing, automatic in ((True,False),(True,True),(False,True)):
        q = copy.deepcopy(vm)
        put(q,0,1); put(q,2,int(automatic)); put(q,3,1); put(q,4,0)
        now = q.load(0xF8B0BFF8)
        put(q,14,now-1_000_000_000); put(q,15,0)
        q.frames_override = 600 if passing else 400
        frame(q)
        if passing and automatic:
            assert get(q,0)==33 and get(q,5)==1 and get(q,3)==0
        else:
            assert get(q,4)==(1 if passing else 2) and get(q,2)==0
        print('PASS injected decision:',passing,automatic,flush=True)
    # A failed performance grade must NOT silently reduce workload next frame.
    q = copy.deepcopy(vm); put(q,0,4); put(q,4,2)
    n=q.blit_alpha_calls; frame(q); assert q.blit_alpha_calls-n == 4
    for fault in (4,8):
        q=copy.deepcopy(vm); put(q,0,4)
        q.inject_fault=fault; q.inject_after=q.blit_alpha_calls
        frame(q)
        assert q.fault_seen and get(q,9)==1 and get(q,4)==2 and get(q,2)==0
        assert get(q,10 if fault==4 else 11)==1
        print('PASS injected hardware fault counted before next START:',fault,flush=True)
    q=copy.deepcopy(vm); q.btn=t.raw_btn('b')
    until(q,lambda:q.params.get(0x60)==0x00FF00FF and q.params.get(0x6C)==255)
    print('PASS exit restores game key and alpha',flush=True)
    assert vm.min_sp >= vm.stack_floor
    # Reuse the honestly executed reset checkpoint for unchanged game/demo
    # regressions; no second decoder run and no invented game state.
    original_boot = t.wait_for_boot
    def checkpoint_boot(q, budget=80_000_000):
        if q.steps == 0:
            q.__dict__ = copy.deepcopy(cold.__dict__)
        original_boot(q, budget)
    t.wait_for_boot = checkpoint_boot
    assert t.run_comprehensive_suite(code, None) == 0
    print('PASS original demo/game regression 9/9',flush=True)
    report={'result':'PASS','sizes':[16,32,48,64],
        'cold_boot_steps':cold.steps,'minimum_sp':hex(vm.min_sp),'game_regression':'9/9',
        'board_fps':None,'board_sprite_limit':None,
        'note':'Timing/fault injections verify decisions only; board measurements still required.'}
    out=ROOT/'simulator/output/stress'; out.mkdir(parents=True,exist_ok=True)
    (out/'results.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('PASS SPRITE STRESS FIRMWARE; hardware limit NOT measured',flush=True)

if __name__ == '__main__':
    run()
