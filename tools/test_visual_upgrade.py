"""Real firmware visual acceptance, benchmark guard and backend comparison."""
from pathlib import Path
import sys
import re
import json
import zipfile
import subprocess
import copy

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'simulator'))
import test_runner as t


def symbols():
    nm = ROOT.parent/'toolchain/riscv-gcc/bin/riscv-none-elf-nm.exe'
    out = subprocess.check_output([str(nm),str(ROOT/'sw/build/firmware.elf')],text=True)
    return {p[2]:int(p[0],16) for line in out.splitlines() if len(p:=line.split())==3}


def logic_guard():
    with zipfile.ZipFile(ROOT/'backups/before_visual_upgrade_20260916.zip') as z:
        old = z.read('main.c').decode('utf-8-sig')
    new = (ROOT/'sw/app/main.c').read_text(encoding='utf-8-sig')
    # The game rules are intentionally changed by the stage upgrade. The
    # independent CPU-vs-FPGA benchmark and shared collision primitives must
    # remain byte-identical to the pre-art baseline.
    names = ('entities_init','entities_update','cpu_software_fill','aim_index',
             'count_active','pool_clear','alloc_bullet','spawn_pbullet',
             'spawn_ebullet','aimed_shot','take_hit','bullets_update',
             'items_update','settings_input')
    checked = []
    for name in names:
        pattern = r'^static [^\n]+\b'+name+r'\([^\n]*\)[^\n]*\n\{.*?^\}'
        a,b = re.search(pattern,old,re.M|re.S),re.search(pattern,new,re.M|re.S)
        assert bool(a)==bool(b), name+' signature changed'
        if a is None:
            continue
        clean = re.sub(r'^.*(?:visual_burst\(|visual_step\(|fx_cursor =|visual_fx\[i\]\.active = 0).*\n','',b[0],flags=re.M)
        assert a[0]==clean, name+' benchmark/shared logic changed'
        checked.append(name)
    assert len(checked)>=10
    print('PASS unchanged benchmark/shared source:',len(checked),'functions',flush=True)


def assert_bank(vm):
    import build_visual_assets as bank
    # Verify bank placement and the complete boot-time decoder pixel result.
    meta=json.loads((ROOT/'assets/processed/manifest.json').read_text())
    regions=sorted((a['dst'],a['dst']+a['bytes'],a['name']) for a in meta)
    for a,b in zip(regions,regions[1:]):
        assert a[1]<=b[0], 'art regions overlap: '+str((a,b))
    from PIL import Image
    for a in meta:
        im=Image.open(ROOT/'assets/processed'/(a['name']+'.png')).convert('RGBA')
        colors,packed=bank.quantize(im,12 if a['name']=='background' else 32,
                                    a['name']=='laser_glow')
        expected=[]; i=0
        while i<len(packed):
            tag=packed[i];i+=1; n=(tag>>5)+1
            if n==8:
                n=packed[i]|packed[i+1]<<8;i+=2
            expected += [colors[tag&31]]*n
        scale=a['width']//im.width
        assert len(expected)==im.width*im.height
        off=a['dst']-t.SCRATCH_BASE
        for y in range(a['height']):
            row=vm.scratch[off+y*a['width']*4:off+(y+1)*a['width']*4]
            exp=b''.join(expected[(y//scale)*im.width+x//scale].to_bytes(4,'little') for x in range(a['width']))
            assert row==exp, 'boot decoder mismatch: '+a['name']+' row '+str(y)
    print('PASS licensed asset decode / non-overlap:',len(meta),'surfaces',flush=True)
    # Verify sampled glyph cells at every actual DDR atlas scale against the
    # rasterised licensed font, including transparent margins and last cell.
    sy=symbols(); font_addr=sy['visual_font']-t.RAM_BASE
    next_base=0x01A00000
    for scale in range(1,7):
        table=0x019B0000-t.SCRATCH_BASE+(scale-1)*4
        assert int.from_bytes(vm.scratch[table:table+4],'little')==next_base
        for glyph in (0,1,33,50,94,95):
            for y in range(8*scale):
                for x in range(8*scale):
                    ink=glyph<95 and x//scale<6 and (vm.ram[font_addr+glyph*8+y//scale] & (32>>(x//scale)))
                    addr=next_base+(glyph//16*8*scale+y)*512*scale+(glyph%16*8*scale+x)*4
                    off=addr-t.SCRATCH_BASE
                    assert int.from_bytes(vm.scratch[off:off+4],'little')==(0x00FFFFFF if ink else bank.KEY)
        next_base+=24576*scale*scale
    assert next_base==0x01C22000
    print('PASS six DDR font atlases / bounds / transparent margins',flush=True)


def run_to(vm,pc,budget=100_000_000):
    n=vm.steps
    while vm.pc!=pc and vm.steps-n<budget:
        vm.step()
    assert vm.pc==pc,'PC deadline exceeded at '+hex(vm.pc)


def copy_sentinel_guard():
    from rv32i_soc_vm import SapphireSoCVM,FRAME_BASES
    q=SapphireSoCVM([0]);key=0x00FF00FF
    rows=[b''.join(v.to_bytes(4,'little') for v in (key,1,2,key,3,4,5,key)),
          b''.join(v.to_bytes(4,'little') for v in range(8)),
          b'\x11'+key.to_bytes(4,'little')+b'\x22'*27,
          key.to_bytes(4,'little')*8]
    q.scratch[:128]=b''.join(rows);dst=FRAME_BASES[1]+10*4096+16
    q.blit_copy(dst,t.SCRATCH_BASE,8,4,32,4096,key)
    for y,row in enumerate(rows):
        for x in range(8):
            value=int.from_bytes(row[x*4:x*4+4],'little')
            assert q.fb[FRAME_BASES[1]][(10+y)*1024+4+x]==(0xDEADBEEF if value==key else value)
    q.blit_copy(dst,t.SCRATCH_BASE,8,4,32,4096,None)
    for y,row in enumerate(rows):
        assert q.fb[FRAME_BASES[1]][(10+y)*1024+4:(10+y)*1024+12].tobytes()==row
    print('PASS COPY fast / keyed / unaligned-substring / disabled-key sentinels',flush=True)


def accept(run_suite=False):
    logic_guard()
    copy_sentinel_guard()
    sy=symbols()
    code=t.load_code_from_source(t.DEFAULT_SOURCE)
    vm=t.new_vm(code)
    if run_suite:
        # Real reset/boot is executed once; independent tests clone its exact
        # post-boot checkpoint. Only repeated asset decompression is avoided.
        cold=copy.deepcopy(vm)
        t.wait_for_boot(cold)
        original=t.wait_for_boot
        initial=bytes(vm.ram)
        def checkpoint_boot(q,budget=80_000_000):
            if q.steps==0 and bytes(q.ram)==initial and q.latency==cold.latency:
                q.__dict__=copy.deepcopy(cold.__dict__)
            else:
                original(q,budget)
        t.wait_for_boot=checkpoint_boot
        assert t.run_comprehensive_suite(code,None)==0
        vm=copy.deepcopy(cold)
    t.menu_enter(vm,1)
    assert_bank(vm)
    assert t.press_until(vm,('b',),lambda:t.tlm(vm,'paused')==1,budget=100_000_000), 'B failed to pause'
    vm.btn=t.raw_btn()
    run_to(vm,sy['game_render'])
    fb,ret=vm.r[10],vm.r[1]
    out=ROOT/'simulator/output/visual';out.mkdir(parents=True,exist_ok=True)
    cases=[]
    for mode in (1,0):
        q=copy.deepcopy(vm);q.ram[sy['hw_accel']-t.RAM_BASE]=mode
        # Compare the new Alpha+ColorKey laser in both backends, not just the
        # older player aura. The paused snapshot keeps gameplay state fixed.
        q.ram[sy['weapon']-t.RAM_BASE]=2
        q.ram[sy['beam_active']-t.RAM_BASE]=1
        n,k=q.steps,q.starts
        q.step();run_to(q,ret)
        q.drain()
        cmds=q.starts-k
        assert (cmds>0) if mode else (cmds==0)
        cases.append(q)
        q.save_frame_bmp(out/('game_%s.bmp'%('fpga' if mode else 'cpu')),fb)
        from PIL import Image
        Image.open(out/('game_%s.bmp'%('fpga' if mode else 'cpu'))).save(out/('game_%s.png'%('fpga' if mode else 'cpu')))
        print('render backend',mode,'instructions',q.steps-n,'commands',cmds,flush=True)
    # Only the backend label is allowed to differ, not the rendered game.
    a,b=(q.fb[fb] for q in cases)
    diffs=[i for i,(x,y) in enumerate(zip(a,b)) if x!=y and not (790<=i%1024<900 and 550<=i//1024<575)]
    assert not diffs,'CPU/FPGA image mismatch '+str(diffs[:10])
    print('PASS CPU/FPGA full-frame pixel equality except explicit mode label',flush=True)
    # All six poses must actually render; pauses must freeze visual effects.
    pose_addr=sy['player_pose']-t.RAM_BASE
    images=set()
    for pose in range(6):
        q=copy.deepcopy(vm);q.ram[pose_addr]=pose;q.step();run_to(q,ret);q.drain()
        images.add(q.fb[fb].tobytes())
        q.save_frame_bmp(out/('pose_%d.bmp'%pose),fb)
    assert len(images)==6, 'poses are not visually distinct'
    print('PASS six distinct player poses',flush=True)
    # Exercise a complete bounded kill animation without writing game pools.
    bursts=set()
    for age in (0,6,12,18):
        q=copy.deepcopy(vm);off=0x01620000-t.SCRATCH_BASE
        q.scratch[off:off+8]=(448).to_bytes(2,'little')+(300).to_bytes(2,'little')+bytes((age,1,0,0))
        q.step();run_to(q,ret);q.drain();q.save_frame_bmp(out/('burst_%d.bmp'%age),fb)
        bursts.add(q.fb[fb].tobytes())
        assert q.scratch[off+4]==age, 'render advanced paused animation'
    assert len(bursts)==4,'kill phases are not visually distinct'
    print('PASS four kill animation phases rendered',flush=True)
    from PIL import Image,ImageDraw
    for name,indices in (('poses',range(6)),('bursts',(0,6,12,18))):
        count=len(indices);sheet=Image.new('RGB',(192*count,210),(12,15,34))
        for col,idx in enumerate(indices):
            path=out/('%s_%d.bmp'%('pose' if name=='poses' else 'burst',idx))
            image=Image.open(path)
            centre=(448,520) if name=='poses' else (448,300)
            image=image.crop((centre[0]-48,centre[1]-48,centre[0]+48,centre[1]+48)).resize((192,192),Image.Resampling.NEAREST)
            sheet.paste(image,(col*192,18));ImageDraw.Draw(sheet).text((col*192+8,3),str(idx),fill='white')
        sheet.save(out/(name+'.png'))
    # settings_render can be LTO-inlined. Execute through the caller's real
    # frame publication rather than relying on a private function symbol.
    q=copy.deepcopy(vm);published=len(q.published);start=q.steps
    while len(q.published)==published and q.steps-start<100_000_000:
        q.step()
    assert len(q.published)>published, 'paused frame was not published'
    q.drain();q.save_frame_bmp(out/'pause.bmp',fb)
    Image.open(out/'pause.bmp').save(out/'pause.png')
    print('PASS pause panel rendered; previews exported',flush=True)


if __name__=='__main__':
    accept('--suite' in sys.argv)
