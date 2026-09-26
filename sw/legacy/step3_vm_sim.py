"""Strict RV32I regression; functional timing model, not an FPS measurement."""
import argparse
from array import array
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
RAM, APB = 0xF9000000, 0xF8100000
BASES = (0x01000000, 0x01300000)
FRAME_BYTES = 1024*600*4

BOX_DDR_BASE = 0x01600000
BOX_DDR_SIZE = 650 * 28

def sx(v, n):
    return (v & ((1 << n)-1)) - ((v & (1 << (n-1))) << 1)

def assemble(source):
    ns = {'__file__': str(source), '__name__': 'firmware_under_test'}
    exec(source.read_text(encoding='utf-8').split('\ncode = generate_code()')[0], ns)
    return ns['generate_code'](), ns

class VM:
    def __init__(self, code, ns, latency=10, stuck=False):
        self.ram = bytearray(4096)
        for i, w in enumerate(code): self.ram[i*4:i*4+4] = w.to_bytes(4, 'little')
        self.image_end = RAM + len(code)*4
        self.ddr_boxes = bytearray(BOX_DDR_SIZE)
        self.num_boxes = ns.get('NUM_BOXES', 650)
        self.stack_bottom = ns.get('STACK_BOTTOM', RAM+0xF00)
        self.r, self.pc, self.steps = [0]*32, RAM, 0
        self.fb = {b: array('I', [0xDEADBEEF])*(FRAME_BYTES//4) for b in BASES}
        self.pending, self.params = {}, {}
        self.active = self.request = BASES[0]
        self.right_active = self.right_request = BASES[0]
        self.published, self.right_published, self.positions = [], [], []
        self.starts = self.busy_until = 0
        self.done = self.vsync = self.auto_enabled = False
        self.latency, self.stuck = latency, stuck
        self.min_sp = RAM+4096

    def pixel_location(self, addr):
        for base in BASES:
            if base <= addr < base+FRAME_BYTES:
                assert addr % 4 == 0, f'unaligned pixel {addr:#x}'
                return base, (addr-base)//4
        regs_str = " ".join(f"r{i}={self.r[i]:#x}" for i in range(32))
        raise AssertionError(f'out-of-range DDR {addr:#x}, pc={self.pc:#x}, regs: {regs_str}')

    def check_owner(self, base):
        assert base != self.active, f'write to SCAN buffer {base:#x}, pc={self.pc:#x}'

    def load(self, addr, size=4):
        if RAM <= addr <= RAM+4096-size:
            return int.from_bytes(self.ram[addr-RAM:addr-RAM+size], 'little')
        if BOX_DDR_BASE <= addr <= BOX_DDR_BASE+BOX_DDR_SIZE-size:
            return int.from_bytes(self.ddr_boxes[addr-BOX_DDR_BASE:addr-BOX_DDR_BASE+size], 'little')
        assert size == 4
        if addr == 0xF8B0BFF8: return (self.steps*20) & 0xFFFFFFFF
        if addr == APB:
            busy = self.stuck or self.steps < self.busy_until
            return int(busy) | (int(self.done and not busy) << 1)
        if addr == APB+0x24:
            v, self.vsync = int(self.vsync), False
            return v
        if addr == APB+0x28: return self.active
        if addr == APB+0x2C: return self.right_active
        if addr == APB+0x40: return self.right_request
        if addr == APB+0x50: return getattr(self, 'joy', 0x00008080)
        if addr == APB+0x54: return getattr(self, 'btn', 0x00008000)
        if addr == APB+0x58: return getattr(self, 'board_keys', 0x00000000)
        if addr == APB+0x5C: return self.params.get(0x5C, 0x0001005A)
        base, pixel = self.pixel_location(addr)
        # Read/write direction change in the SoC DDR bridge drains writes.
        for a, value in self.pending.items():
            b, p = self.pixel_location(a)
            self.fb[b][p] = value
        self.pending.clear()
        return self.fb[base][pixel]

    def store(self, addr, val):
        assert addr % 4 == 0, f'unaligned SW {addr:#x}'
        if RAM <= addr < RAM+4096:
            assert addr >= self.image_end, f'CODE OVERWRITE: store={addr:#x}, image_end={self.image_end:#x}, pc={self.pc:#x}'
            self.ram[addr-RAM:addr-RAM+4] = val.to_bytes(4, 'little')
            return
        if BOX_DDR_BASE <= addr < BOX_DDR_BASE+BOX_DDR_SIZE:
            self.ddr_boxes[addr-BOX_DDR_BASE:addr-BOX_DDR_BASE+4] = val.to_bytes(4, 'little')
            return
        if APB <= addr < APB+0x100:
            off = addr-APB
            if off in (4, 8, 12, 16, 24, 28, 72): self.params[off] = val
            elif off == 20 and val & 1:
                assert self.steps >= self.busy_until, 'START while busy'
                dst, w, h, color = (self.params[x] for x in (4, 8, 12, 16))
                base, pixel = self.pixel_location(dst)
                x, y = pixel % 1024, pixel // 1024
                assert 0 <= x and x+w <= 1024 and y+h <= 600, (x,y,w,h)
                for row in range(y,y+h):
                    at = row*1024+x
                    self.fb[base][at:at+w] = array('I', [color])*w
                self.starts += 1
                self.done = True
                self.busy_until = self.steps+self.latency
            elif off == 0x30:
                self.auto_enabled = bool(val & 1)
            elif off == 0x40:
                assert val in BASES
                self.right_request = val
                self.right_published.append(val)
            elif off == 0x5C:
                self.params[0x5C] = val
            elif off == 0x20:
                assert not self.pending, 'published before DDR stores drained'
                assert val in BASES and val != self.active
                assert self.steps >= self.busy_until and not self.stuck
                self.request = val
                self.published.append(val)
            else: raise AssertionError(f'unknown APB write {off:#x}')
            return
        base, _ = self.pixel_location(addr)
        self.check_owner(base)
        assert ((addr-base)//4)%1024 < 512, 'CPU wrote FPGA half'
        self.pending[addr] = val

    def step(self):
        assert RAM <= self.pc < self.image_end and self.pc % 4 == 0, f'bad PC {self.pc:#x}'
        ins = self.load(self.pc)
        op,rd,f3,rs1,rs2,f7 = ins&127,(ins>>7)&31,(ins>>12)&7,(ins>>15)&31,(ins>>20)&31,ins>>25
        a,b = self.r[rs1],self.r[rs2]
        npc,result = self.pc+4,None
        if op == 0x37: result = ins & 0xFFFFF000
        elif op == 0x13:
            imm = sx(ins>>20,12)
            if f3 == 0: result = a+imm
            elif f3 == 7: result = a & imm
            elif f3 == 1 and f7 == 0: result = a << rs2
            elif f3 == 5 and f7 == 0: result = a >> rs2
            else: raise AssertionError(f'unknown OP-IMM {ins:#x}')
        elif op == 0x33:
            if f3 == 0 and f7 == 0: result = a+b
            elif f3 == 0 and f7 == 32: result = a-b
            elif f3 == 4 and f7 == 0: result = a^b
            else: raise AssertionError(f'unknown OP {ins:#x}')
        elif op == 3 and f3 in (2,4):
            addr = (a+sx(ins>>20,12)) & 0xFFFFFFFF
            assert f3 == 4 or addr % 4 == 0
            result = self.load(addr,1 if f3 == 4 else 4)
        elif op == 0x23 and f3 == 2:
            self.store((a+sx((ins>>25)<<5 | (ins>>7)&31,12)) & 0xFFFFFFFF,b)
        elif op == 0x63 and f3 in (0,1,4,5,6,7):
            imm = (ins>>31)<<12 | ((ins>>7)&1)<<11 | ((ins>>25)&63)<<5 | ((ins>>8)&15)<<1
            take = {0:a==b,1:a!=b,4:sx(a,32)<sx(b,32),5:sx(a,32)>=sx(b,32),6:a<b,7:a>=b}[f3]
            if take: npc = self.pc+sx(imm,13)
        elif op == 0x6F:
            imm = (ins>>31)<<20 | ((ins>>12)&255)<<12 | ((ins>>20)&1)<<11 | ((ins>>21)&1023)<<1
            result,npc = npc,self.pc+sx(imm,21)
        elif op == 0x67 and f3 == 0: result,npc = npc,(a+sx(ins>>20,12)) & ~1
        elif ins == 0x500F: pass  # invalidate; does NOT commit DDR stores
        else: raise AssertionError(f'illegal instruction {ins:#010x} at {self.pc:#x}')
        if result is not None and rd: self.r[rd] = result & 0xFFFFFFFF
        if RAM <= self.r[2] < RAM+4096:
            self.min_sp = min(self.min_sp,self.r[2])
            assert self.min_sp >= self.stack_bottom
        self.pc = npc & 0xFFFFFFFF
        self.steps += 1
        if self.steps % 25000 == 0:
            self.active = self.request
            self.right_active = self.right_request
            self.vsync = True

    def run(self, frames=2, limit=15_000_000):
        while len(self.published) < frames and self.steps < limit: self.step()
        assert len(self.published) == frames, f'TIMEOUT pc={self.pc:#x} starts={self.starts} left_swaps={len(self.published)} right_swaps={len(self.right_published)}'
        assert len(self.right_published) >= frames * 6, f'right side swaps insufficient: {len(self.right_published)}'
        assert self.starts > 0, 'No BitBlt commands issued'
        print(f'PASS actual RV32I: {self.steps} instructions, {frames} CPU frames ({len(self.right_published)} FPGA frames), {self.starts} BitBlt commands, min_sp={self.min_sp:#x}')

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--source',type=Path,default=ROOT/'sw/generate_firmware.py')
    p.add_argument('--latency',type=int,default=10)
    p.add_argument('--frames',type=int,default=2)
    p.add_argument('--negative',action='store_true',help='exercise failure gates without running full frames')
    args = p.parse_args()
    code,ns = assemble(args.source)
    if args.negative:
        def rejected(name, action, message):
            try:
                action(VM(code,ns))
            except AssertionError as error:
                assert message in str(error), error
                print(f'PASS negative gate {name}: {error}')
            else:
                raise AssertionError(f'failure gate did not fire: {name}')
        rejected('code overwrite', lambda v:v.store(RAM+0x400,0), 'CODE OVERWRITE')
        rejected('scan ownership', lambda v:(v.published.append(BASES[1]),v.store(BASES[0],0)), 'SCAN buffer')
        rejected('DDR drain', lambda v:(v.store(BASES[1],0),v.store(APB+0x20,BASES[1])), 'stores drained')
        rejected('illegal opcode', lambda v:(setattr(v,'ram',bytearray(4096)),v.step()), 'illegal instruction')
        def stuck(v):
            v.run(1,10)
        rejected('execution deadline', stuck, 'TIMEOUT')
    else:
        if args.source.resolve() == (ROOT/'sw/generate_firmware.py').resolve():
            ns['validate_layout'](code)
            for directory in (ROOT/'ip/soc', ROOT/'ip/soc/source/hardware/netlist'):
                lanes = [[int(x,2) for x in (directory/f'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{i}.bin').read_text().splitlines()] for i in range(4)]
                assert all(len(lane)==1024 for lane in lanes)
                actual = [sum(lanes[j][i]<<(j*8) for j in range(4)) for i in range(1024)]
                assert actual == code+[0]*(1024-len(code)), f'stale ROM: {directory}'
            code = actual[:len(code)]
        VM(code,ns,args.latency).run(args.frames)

