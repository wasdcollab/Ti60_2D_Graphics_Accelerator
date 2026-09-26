# scratch/build_and_sim.py
from pathlib import Path

regs = {
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4,
    't0': 5, 't1': 6, 't2': 7, 's0': 8, 's1': 9,
    'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13, 'a4': 14, 'a5': 15, 'a6': 16, 'a7': 17,
    's2': 18, 's3': 19, 's4': 20, 's5': 21, 's6': 22, 's7': 23, 's8': 24, 's9': 25, 's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31
}

def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37

def addi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0x13

def andi(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b111 << 12) | (rd << 7) | 0x13

def slli(rd, rs1, shamt):
    return ((shamt & 0x1F) << 20) | (rs1 << 15) | (0b001 << 12) | (rd << 7) | 0x13

def srli(rd, rs1, shamt):
    return ((shamt & 0x1F) << 20) | (rs1 << 15) | (0b101 << 12) | (rd << 7) | 0x13

def add(rd, rs1, rs2):
    return (0 << 25) | (rs2 << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0x33

def sub(rd, rs1, rs2):
    return (0x20 << 25) | (rs2 << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0x33

def xor_inst(rd, rs1, rs2):
    return (0 << 25) | (rs2 << 20) | (rs1 << 15) | (0b100 << 12) | (rd << 7) | 0x33

def sw(rs2, rs1, imm12):
    imm12 = imm12 & 0xFFF
    imm_11_5 = (imm12 >> 5) & 0x7F
    imm_4_0 = imm12 & 0x1F
    return (imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (0b010 << 12) | (imm_4_0 << 7) | 0x23

def lw(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | 0x03

def lbu(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b100 << 12) | (rd << 7) | 0x03

def _b_type(rs1, rs2, offset, funct3):
    offset = offset & 0x1FFF
    b12 = (offset >> 12) & 1
    b10_5 = (offset >> 5) & 0x3F
    b4_1 = (offset >> 1) & 0xF
    b11 = (offset >> 11) & 1
    return (b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (b4_1 << 8) | (b11 << 7) | 0x63

def beq(rs1, rs2, offset):
    return _b_type(rs1, rs2, offset, 0b000)

def bne(rs1, rs2, offset):
    return _b_type(rs1, rs2, offset, 0b001)

def blt(rs1, rs2, offset):
    return _b_type(rs1, rs2, offset, 0b100)

def bge(rs1, rs2, offset):
    return _b_type(rs1, rs2, offset, 0b101)

def bltu(rs1, rs2, offset):
    return _b_type(rs1, rs2, offset, 0b110)

def bgeu(rs1, rs2, offset):
    return _b_type(rs1, rs2, offset, 0b111)

def jal(rd, offset):
    offset = offset & 0x1FFFFF
    b20 = (offset >> 20) & 1
    b10_1 = (offset >> 1) & 0x3FF
    b11 = (offset >> 11) & 1
    b19_12 = (offset >> 12) & 0xFF
    return (b20 << 31) | (b10_1 << 21) | (b11 << 20) | (b19_12 << 12) | (rd << 7) | 0x6F

def jalr(rd, rs1, imm12):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | 0x67

class Assembler:
    def __init__(self):
        self.instructions = []
        self.labels = {}

    def label(self, name):
        assert name not in self.labels, f"Duplicate label {name}"
        self.labels[name] = True
        self.instructions.append(('label_def', name))

    def emit(self, inst):
        self.instructions.append(inst)

    def branch(self, b_fn, rs1, rs2, target_label):
        self.instructions.append(('branch', b_fn, rs1, rs2, target_label))

    def jump(self, j_fn, rd, target_label):
        self.instructions.append(('jump', j_fn, rd, target_label))

    def load_label_addr(self, rd, target_label):
        # Placeholder for 2 instructions: lui rd, %hi(label); addi rd, rd, %lo(label)
        self.instructions.append(('label_addr', rd, target_label))

    def load_imm(self, rd, val):
        val = val & 0xFFFFFFFF
        hi = (val + 0x800) >> 12
        lo = val - (hi << 12)
        if (hi & 0xFFFFF) == 0:
            self.instructions.append(addi(rd, regs['zero'], lo))
        else:
            self.instructions.append(lui(rd, hi & 0xFFFFF))
            if lo != 0:
                self.instructions.append(addi(rd, rd, lo))

    def build(self):
        # Two-pass build to resolve label addresses
        # First calculate lengths with label_addr expanded to 2 instructions
        final_items = []
        labels = {}
        curr_pc = 0
        for item in self.instructions:
            if isinstance(item, tuple) and item[0] == 'label_def':
                labels[item[1]] = curr_pc
            elif isinstance(item, tuple) and item[0] == 'label_addr':
                curr_pc += 8
                final_items.append(item)
            else:
                curr_pc += 4
                final_items.append(item)
        self.labels = labels

        code = []
        curr_pc = 0
        for item in final_items:
            if isinstance(item, int):
                code.append(item)
                curr_pc += 4
            elif item[0] == 'branch':
                _, b_fn, rs1, rs2, target = item
                offset = self.labels[target] - curr_pc
                code.append(b_fn(rs1, rs2, offset))
                curr_pc += 4
            elif item[0] == 'jump':
                _, j_fn, rd, target = item
                offset = self.labels[target] - curr_pc
                code.append(j_fn(rd, offset))
                curr_pc += 4
            elif item[0] == 'label_addr':
                _, rd, target = item
                # ROM address is 0xF900_0000 + self.labels[target]
                addr = 0xF9000000 + self.labels[target]
                hi = (addr + 0x800) >> 12
                lo = addr - (hi << 12)
                code.append(lui(rd, hi))
                code.append(addi(rd, rd, lo))
                curr_pc += 8
        return code

BOX_TABLE_60 = [
    #  x,   y,  vx, vy,  w,  h, color
    ( 70, 372,  2, -3, 20, 20, 0x00FF0000), # 0: Red
    (267, 150, -2,  3, 23, 23, 0x0000FF00), # 1: Green
    (462, 159,  3, -1, 26, 26, 0x00FFFF00), # 2: Yellow
    (468, 352, -3,  2, 29, 29, 0x0000FFFF), # 3: Cyan
    (328, 329,  1, -4, 32, 32, 0x00FF00FF), # 4: Magenta
    (225, 547, -1,  3, 20, 20, 0x00FFA500), # 5: Orange
    (394, 496,  4, -2, 23, 23, 0x00FFFFFF), # 6: White
    (132,  46, -4,  2, 26, 26, 0x0000FF7F), # 7: SpringGreen
    (324,  86,  2, -3, 29, 29, 0x00FF1493), # 8: DeepPink
    ( 66, 192, -2,  3, 32, 32, 0x007FFF00), # 9: Chartreuse
    (428, 145,  3, -1, 20, 20, 0x00FF4500), # 10: OrangeRed
    (240,  56, -3,  2, 23, 23, 0x0000CED1), # 11: DarkTurquoise
    (427, 501,  1, -4, 26, 26, 0x00FFD700), # 12: Gold
    (360, 296, -1,  3, 29, 29, 0x00ADFF2F), # 13: GreenYellow
    (357, 205,  4, -2, 32, 32, 0x00FF69B4), # 14: HotPink
    (117, 451, -4,  2, 20, 20, 0x00E0FFFF), # 15: LightCyan
    (138, 401,  2, -3, 23, 23, 0x009370DB), # 16: MediumPurple
    (192, 457, -2,  3, 26, 26, 0x0032CD32), # 17: LimeGreen
    (272, 371,  3, -1, 29, 29, 0x00FF6347), # 18: Tomato
    ( 49, 415, -3,  2, 32, 32, 0x0040E0D0), # 19: Turquoise
    (184, 136,  1, -4, 20, 20, 0x00EE82EE), # 20: Violet
    (295, 344, -1,  3, 23, 23, 0x00F0E68C), # 21: Khaki
    (157, 279,  4, -2, 26, 26, 0x0087CEEB), # 22: SkyBlue
    ( 82, 493, -4,  2, 29, 29, 0x00FFB6C1), # 23: LightPink
    (340, 405,  2, -3, 32, 32, 0x0098FB98), # 24: PaleGreen
    (376, 361, -2,  3, 20, 20, 0x00DDA0DD), # 25: Plum
    ( 22, 422,  3, -1, 23, 23, 0x00FFA07A), # 26: LightSalmon
    (196, 281, -3,  2, 26, 26, 0x0020B2AA), # 27: LightSeaGreen
    (226,  91,  1, -4, 29, 29, 0x0087CEFA), # 28: LightSkyBlue
    (214, 501, -1,  3, 32, 32, 0x00FF8C00), # 29: DarkOrange
    (294, 255,  2,  2, 26, 26, 0x00FF4500), # 30
    (407, 433,  1,  2, 28, 28, 0x00DA70D6), # 31
    (157, 140,  1, -3, 18, 18, 0x0000FA9A), # 32
    (138, 218, -1,  1, 24, 24, 0x001E90FF), # 33
    ( 55, 325,  2, -1, 22, 22, 0x00FFD700), # 34
    (305, 198, -3,  3, 28, 28, 0x00FF1493), # 35
    (442, 255,  2,  1, 22, 22, 0x0000FFFF), # 36
    (275, 452, -3,  2, 26, 26, 0x007CFC00), # 37
    (402, 106, -3,  3, 20, 20, 0x00FF69B4), # 38
    (464, 383, -3,  3, 26, 26, 0x00BA55D3), # 39
    (229, 280, -2,  1, 26, 26, 0x0048D1CC), # 40
    (138, 326,  1,  3, 26, 26, 0x00FF6347), # 41
    (160, 465, -1, -3, 20, 20, 0x007B68EE), # 42
    (112, 173,  3,  1, 22, 22, 0x0032CD32), # 43
    (349, 504, -3, -1, 26, 26, 0x00FFA500), # 44
    (376, 441,  2, -1, 28, 28, 0x009370DB), # 45
    (103, 535,  1,  3, 24, 24, 0x003CB371), # 46
    ( 42, 372, -1,  1, 24, 24, 0x00FF00FF), # 47
    ( 59, 139,  3,  1, 22, 22, 0x0000CED1), # 48
    (241, 125,  2, -2, 18, 18, 0x00FF8C00), # 49
    ( 12, 200,  3,  2, 20, 20, 0x0066CDAA), # 50
    ( 79, 319, -2,  1, 28, 28, 0x00CD5C5C), # 51
    (158,  83,  1,  3, 26, 26, 0x008A2BE2), # 52
    (220, 239, -2,  2, 26, 26, 0x0020B2AA), # 53
    (202,  47, -3,  1, 20, 20, 0x00FF7F50), # 54
    ( 23, 527, -1,  3, 18, 18, 0x0000BFFF), # 55
    (240, 206, -3,  1, 22, 22, 0x009932CC), # 56
    (244, 346, -2,  3, 22, 22, 0x0032CD32), # 57
    (288, 516, -3,  1, 28, 28, 0x00FA8072), # 58
    (106, 287,  3,  3, 28, 28, 0x0040E0D0), # 59
]
BOX_DDR_BASE = 0x01600000
NUM_BOXES = 650
BOX_TABLE_30 = BOX_TABLE_60[:30]
GLOBALS_RAM = 0xF9000FA0
STACK_BOTTOM = 0xF9000FB0
RAM_BASE = 0xF9000000
RAM_SIZE = 4096

PALETTE = [
    0x00FF3333, 0x0033FF33, 0x003366FF, 0x00FFFF33,
    0x00FF33FF, 0x0033FFFF, 0x00FFA500, 0x00FF1493,
    0x007FFF00, 0x009370DB, 0x0000CED1, 0x00FFD700,
    0x00FF4500, 0x0000FF7F, 0x00FF69B4, 0x00FFFFFF,
]

VX_TABLE = [-2, 2, -3, 3, -1, 1, -2, 2]
VY_TABLE = [3, -3, 2, -2, 1, -1, 3, -3]

def generate_code():
    a = Assembler()

    # Jump over lookup tables
    a.jump(jal, regs['zero'], "main_init")

    a.label("color_palette")
    for c in PALETTE:
        a.emit(c)

    a.label("vx_table")
    for v in VX_TABLE:
        a.emit(v & 0xFFFFFFFF)

    a.label("vy_table")
    for v in VY_TABLE:
        a.emit(v & 0xFFFFFFFF)

    a.label("main_init")
    # 1. Setup Stack Pointer
    a.emit(lui(regs['sp'], 0xF9001))
    a.emit(addi(regs['sp'], regs['sp'], -16))

    # s0 = 0x0160_0000 (650 Boxes State Array in DDR3)
    a.emit(lui(regs['s0'], 0x01600))

    # s1 = Left Back Buffer (0x0130_0000)
    a.emit(lui(regs['s1'], 0x01300))

    # s2 = Right Back Buffer (0x0130_0000)
    a.emit(lui(regs['s2'], 0x01300))

    # s3 = Sub-frame slice index (0..5)
    a.emit(addi(regs['s3'], regs['zero'], 0))

    # s11 = APB Base (0xF810_0000)
    a.emit(lui(regs['s11'], 0xF8100))

    # s6 = Current Mode (0: Benchmark Mode 1, 1: Gamepad Mode 2)
    a.emit(addi(regs['s6'], regs['zero'], 0))

    # s7, s8 = Mode 2 Box (X=492, Y=280)
    a.load_imm(regs['s7'], 492)
    a.load_imm(regs['s8'], 280)

    # 2. Wait for DDR calibration stabilization
    a.emit(lui(regs['t0'], 20))
    a.label("ddr_wait")
    a.emit(addi(regs['t0'], regs['t0'], -1))
    a.branch(bne, regs['t0'], regs['zero'], "ddr_wait")

    # 3. Procedurally generate 650 boxes in DDR3 at 0x0160_0000
    # Seed = 0x12345678
    a.emit(lui(regs['t0'], 0x12345))
    a.emit(addi(regs['t0'], regs['t0'], 0x678))

    a.emit(addi(regs['s4'], regs['zero'], NUM_BOXES))
    a.emit(addi(regs['s5'], regs['s0'], 0))
    a.load_label_addr(regs['a0'], "color_palette")

    a.label("init_box_loop")
    # xorshift32
    a.emit(slli(regs['t1'], regs['t0'], 13))
    a.emit(xor_inst(regs['t0'], regs['t0'], regs['t1']))
    a.emit(srli(regs['t1'], regs['t0'], 17))
    a.emit(xor_inst(regs['t0'], regs['t0'], regs['t1']))
    a.emit(slli(regs['t1'], regs['t0'], 5))
    a.emit(xor_inst(regs['t0'], regs['t0'], regs['t1']))

    # w, h: sizes 28, 32, 36, 40 (multiples of 4)
    a.emit(andi(regs['t1'], regs['t0'], 3))
    a.emit(slli(regs['t1'], regs['t1'], 2))
    a.emit(addi(regs['t4'], regs['t1'], 28))  # w
    a.emit(addi(regs['t5'], regs['t4'], 0))   # h = w

    # x = (t0 >> 4) & 0x1FF
    a.emit(srli(regs['t2'], regs['t0'], 4))
    a.emit(andi(regs['t2'], regs['t2'], 0x1FF))
    a.emit(addi(regs['t6'], regs['zero'], 512))
    a.emit(sub(regs['t6'], regs['t6'], regs['t4']))  # 512 - w
    a.branch(blt, regs['t6'], regs['t2'], "x_init_fix")
    a.jump(jal, regs['zero'], "x_init_ok")
    a.label("x_init_fix")
    a.emit(andi(regs['t1'], regs['t2'], 0x3F))
    a.emit(sub(regs['t2'], regs['t6'], regs['t1']))
    a.branch(bge, regs['t2'], regs['zero'], "x_init_ok")
    a.emit(addi(regs['t2'], regs['zero'], 0))
    a.label("x_init_ok")

    # y = ((t0 >> 13) & 0x1FF) + 36
    a.emit(srli(regs['t3'], regs['t0'], 13))
    a.emit(andi(regs['t3'], regs['t3'], 0x1FF))
    a.emit(addi(regs['t3'], regs['t3'], 36))
    a.emit(addi(regs['t6'], regs['zero'], 600))
    a.emit(sub(regs['t6'], regs['t6'], regs['t5']))  # 600 - h
    a.branch(blt, regs['t6'], regs['t3'], "y_init_fix")
    a.jump(jal, regs['zero'], "y_init_ok")
    a.label("y_init_fix")
    a.emit(andi(regs['t1'], regs['t3'], 0x3F))
    a.emit(sub(regs['t3'], regs['t6'], regs['t1']))
    a.emit(addi(regs['t6'], regs['zero'], 36))
    a.branch(bge, regs['t3'], regs['t6'], "y_init_ok")
    a.emit(addi(regs['t3'], regs['zero'], 36))
    a.label("y_init_ok")

    # vx from vx_table
    a.emit(srli(regs['t1'], regs['t0'], 22))
    a.emit(andi(regs['t1'], regs['t1'], 7))
    a.emit(slli(regs['t1'], regs['t1'], 2))
    a.load_label_addr(regs['a1'], "vx_table")
    a.emit(add(regs['a1'], regs['a1'], regs['t1']))
    a.emit(lw(regs['a2'], regs['a1'], 0))

    # vy from vy_table
    a.emit(srli(regs['t1'], regs['t0'], 25))
    a.emit(andi(regs['t1'], regs['t1'], 7))
    a.emit(slli(regs['t1'], regs['t1'], 2))
    a.load_label_addr(regs['a1'], "vy_table")
    a.emit(add(regs['a1'], regs['a1'], regs['t1']))
    a.emit(lw(regs['a3'], regs['a1'], 0))

    # color from palette
    a.emit(srli(regs['t1'], regs['t0'], 8))
    a.emit(andi(regs['t1'], regs['t1'], 15))
    a.emit(slli(regs['t1'], regs['t1'], 2))
    a.emit(add(regs['a1'], regs['a0'], regs['t1']))
    a.emit(lw(regs['a4'], regs['a1'], 0))

    # Write 7 words
    a.emit(sw(regs['t2'], regs['s5'], 0))   # x
    a.emit(sw(regs['t3'], regs['s5'], 4))   # y
    a.emit(sw(regs['a2'], regs['s5'], 8))   # vx
    a.emit(sw(regs['a3'], regs['s5'], 12))  # vy
    a.emit(sw(regs['t4'], regs['s5'], 16))  # w
    a.emit(sw(regs['t5'], regs['s5'], 20))  # h
    a.emit(sw(regs['a4'], regs['s5'], 24))  # color

    a.emit(addi(regs['s5'], regs['s5'], 28))
    a.emit(addi(regs['s4'], regs['s4'], -1))
    a.branch(bne, regs['s4'], regs['zero'], "init_box_loop")

    a.jump(jal, regs['ra'], "flush_dcache")

    # =========================================================================
    # MAIN FRAME LOOP (Tick-Decoupled Dual-Rate Pipeline)
    # Right Side: 60 FPS BitBlt Hardware Full Redraw
    # Left Side:  10 FPS CPU Software 6-Slice Redraw
    # =========================================================================
    a.label("frame_loop")

    # Poll SW0 and SW2 buttons at APB + 0x58
    a.emit(lw(regs['t0'], regs['s11'], 0x58))
    a.emit(andi(regs['t1'], regs['t0'], 1))
    a.branch(beq, regs['t1'], regs['zero'], "check_sw2")
    a.emit(addi(regs['s6'], regs['zero'], 0)) # Mode 1
    a.load_imm(regs['t2'], 0x0001005A)
    a.emit(sw(regs['t2'], regs['s11'], 0x5C)) # HUD enable, slave addr 0x5A
    a.jump(jal, regs['zero'], "mode_check_done")

    a.label("check_sw2")
    a.emit(andi(regs['t1'], regs['t0'], 2))
    a.branch(beq, regs['t1'], regs['zero'], "mode_check_done")
    a.emit(addi(regs['s6'], regs['zero'], 1)) # Mode 2
    a.load_imm(regs['t2'], 0x0011005A)
    a.emit(sw(regs['t2'], regs['s11'], 0x5C)) # HUD disable, slave addr 0x5A

    a.label("mode_check_done")
    a.branch(bne, regs['s6'], regs['zero'], "mode2_gamepad")

    # --- Step 1: Wait for 60Hz VSync Tick ---
    a.label("vsync_wait")
    a.emit(lw(regs['t0'], regs['s11'], 0x24))  # REG_VSYNC_STS
    a.branch(beq, regs['t0'], regs['zero'], "vsync_wait")

    # --- Step 2: Unified Physics Update for ALL 650 boxes (~0.1ms) ---
    a.emit(addi(regs['s4'], regs['zero'], NUM_BOXES))
    a.emit(addi(regs['s5'], regs['s0'], 0))

    a.label("phys_loop")
    a.emit(lw(regs['t0'], regs['s5'], 0))   # x
    a.emit(lw(regs['t1'], regs['s5'], 4))   # y
    a.emit(lw(regs['t2'], regs['s5'], 8))   # vx
    a.emit(lw(regs['t3'], regs['s5'], 12))  # vy
    a.emit(lw(regs['t4'], regs['s5'], 16))  # w
    a.emit(lw(regs['t5'], regs['s5'], 20))  # h

    # Update X
    a.emit(add(regs['t0'], regs['t0'], regs['t2']))
    a.branch(blt, regs['t0'], regs['zero'], "phys_x_min")
    a.emit(addi(regs['t6'], regs['zero'], 512))
    a.emit(sub(regs['t6'], regs['t6'], regs['t4']))
    a.branch(blt, regs['t6'], regs['t0'], "phys_x_max")
    a.jump(jal, regs['zero'], "phys_x_done")
    a.label("phys_x_min")
    a.emit(addi(regs['t0'], regs['zero'], 0))
    a.emit(sub(regs['t2'], regs['zero'], regs['t2']))
    a.jump(jal, regs['zero'], "phys_x_done")
    a.label("phys_x_max")
    a.emit(addi(regs['t0'], regs['t6'], 0))
    a.emit(sub(regs['t2'], regs['zero'], regs['t2']))
    a.label("phys_x_done")

    # Update Y
    a.emit(add(regs['t1'], regs['t1'], regs['t3']))
    a.emit(addi(regs['t6'], regs['zero'], 36))
    a.branch(blt, regs['t1'], regs['t6'], "phys_y_min")
    a.emit(addi(regs['t6'], regs['zero'], 600))
    a.emit(sub(regs['t6'], regs['t6'], regs['t5']))
    a.branch(blt, regs['t6'], regs['t1'], "phys_y_max")
    a.jump(jal, regs['zero'], "phys_y_done")
    a.label("phys_y_min")
    a.emit(addi(regs['t1'], regs['zero'], 36))
    a.emit(sub(regs['t3'], regs['zero'], regs['t3']))
    a.jump(jal, regs['zero'], "phys_y_done")
    a.label("phys_y_max")
    a.emit(addi(regs['t1'], regs['t6'], 0))
    a.emit(sub(regs['t3'], regs['zero'], regs['t3']))
    a.label("phys_y_done")

    # Store back updated state
    a.emit(sw(regs['t0'], regs['s5'], 0))
    a.emit(sw(regs['t1'], regs['s5'], 4))
    a.emit(sw(regs['t2'], regs['s5'], 8))
    a.emit(sw(regs['t3'], regs['s5'], 12))

    a.emit(addi(regs['s5'], regs['s5'], 28))
    a.emit(addi(regs['s4'], regs['s4'], -1))
    a.branch(bne, regs['s4'], regs['zero'], "phys_loop")

    # --- Step 3: BitBlt Right Half Complete Redraw (FPGA 60 FPS, ~3.5ms) ---
    # Atomic Swap Handshake: Wait until VDMA hardware has switched away from s2
    a.label("wait_right_swap")
    a.emit(lw(regs['t0'], regs['s11'], 0x2C))  # REG_VDMA_RIGHT_ACTIVE
    a.branch(beq, regs['t0'], regs['s2'], "wait_right_swap")

    # Clear Right Half (512x600 black)
    a.load_imm(regs['t1'], 2048)
    a.emit(add(regs['t0'], regs['s2'], regs['t1'])) # right half starts at byte offset 2048
    a.emit(sw(regs['t0'], regs['s11'], 0x04))   # REG_DST_ADDR
    a.emit(addi(regs['t0'], regs['zero'], 512))
    a.emit(sw(regs['t0'], regs['s11'], 0x08))   # REG_RECT_W = 512
    a.emit(addi(regs['t0'], regs['zero'], 600))
    a.emit(sw(regs['t0'], regs['s11'], 0x0C))   # REG_RECT_H = 600
    a.emit(sw(regs['zero'], regs['s11'], 0x10)) # REG_COLOR = 0
    a.emit(addi(regs['t0'], regs['zero'], 1))
    a.emit(sw(regs['t0'], regs['s11'], 0x14))   # REG_START = 1

    a.label("bb_wait_clear")
    a.emit(lw(regs['t0'], regs['s11'], 0x00))   # REG_STATUS
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(bne, regs['t0'], regs['zero'], "bb_wait_clear")

    # Draw 650 boxes using BitBlt
    a.emit(addi(regs['s4'], regs['zero'], NUM_BOXES))
    a.emit(addi(regs['s5'], regs['s0'], 0))

    a.label("bb_draw_loop")
    a.emit(lw(regs['t0'], regs['s5'], 0))   # x
    a.emit(lw(regs['t1'], regs['s5'], 4))   # y
    a.emit(lw(regs['t4'], regs['s5'], 16))  # w
    a.emit(lw(regs['t5'], regs['s5'], 20))  # h
    a.emit(lw(regs['a4'], regs['s5'], 24))  # color

    # dst = s2 + 2048 + (y << 12) + (x << 2)
    a.emit(slli(regs['t2'], regs['t1'], 12))
    a.emit(slli(regs['t3'], regs['t0'], 2))
    a.emit(add(regs['t2'], regs['t2'], regs['t3']))
    a.emit(add(regs['t2'], regs['t2'], regs['s2']))
    a.load_imm(regs['t3'], 2048)
    a.emit(add(regs['t2'], regs['t2'], regs['t3']))

    a.emit(sw(regs['t2'], regs['s11'], 0x04))   # REG_DST_ADDR
    a.emit(sw(regs['t4'], regs['s11'], 0x08))   # REG_RECT_W
    a.emit(sw(regs['t5'], regs['s11'], 0x0C))   # REG_RECT_H
    a.emit(sw(regs['a4'], regs['s11'], 0x10))   # REG_COLOR
    a.emit(addi(regs['t3'], regs['zero'], 1))
    a.emit(sw(regs['t3'], regs['s11'], 0x14))   # REG_START

    a.label("bb_wait_box")
    a.emit(lw(regs['t0'], regs['s11'], 0x00))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(bne, regs['t0'], regs['zero'], "bb_wait_box")

    a.emit(addi(regs['s5'], regs['s5'], 28))
    a.emit(addi(regs['s4'], regs['s4'], -1))
    a.branch(bne, regs['s4'], regs['zero'], "bb_draw_loop")

    # Publish Right Buffer Swap & Toggle (Always 60 FPS!)
    a.emit(sw(regs['s2'], regs['s11'], 0x40))   # REG_RIGHT_VDMA_BASE
    a.emit(lui(regs['t6'], 0x00300))
    a.emit(xor_inst(regs['s2'], regs['s2'], regs['t6']))

    # --- Step 4: Left Half CPU Sliced Rendering (10 Slices -> 6 FPS) ---
    # Slice 0: Wait left swap done & clear top half (y: 0..300)
    a.branch(bne, regs['s3'], regs['zero'], "check_slice_1")
    a.label("wait_left_swap")
    a.emit(lw(regs['t0'], regs['s11'], 0x28))  # REG_VDMA_ACTIVE_BASE
    a.branch(beq, regs['t0'], regs['s1'], "wait_left_swap")
    a.emit(addi(regs['a0'], regs['zero'], 0))
    a.emit(addi(regs['a1'], regs['zero'], 0))
    a.emit(addi(regs['a2'], regs['zero'], 512))
    a.emit(addi(regs['a3'], regs['zero'], 300))
    a.emit(addi(regs['a4'], regs['zero'], 0))
    a.jump(jal, regs['ra'], "draw_rect")
    a.jump(jal, regs['zero'], "slice_done")

    a.label("check_slice_1")
    # Slice 1: Clear bottom half (y: 300..600)
    a.emit(addi(regs['t0'], regs['zero'], 1))
    a.branch(bne, regs['s3'], regs['t0'], "check_slice_2")
    a.emit(addi(regs['a0'], regs['zero'], 0))
    a.emit(addi(regs['a1'], regs['zero'], 300))
    a.emit(addi(regs['a2'], regs['zero'], 512))
    a.emit(addi(regs['a3'], regs['zero'], 300))
    a.emit(addi(regs['a4'], regs['zero'], 0))
    a.jump(jal, regs['ra'], "draw_rect")
    a.jump(jal, regs['zero'], "slice_done")

    box_slices = [
        (2, 82, 0 * 28),
        (3, 82, 82 * 28),
        (4, 81, 164 * 28),
        (5, 81, 245 * 28),
        (6, 81, 326 * 28),
        (7, 81, 407 * 28),
        (8, 81, 488 * 28),
        (9, 81, 569 * 28),
    ]

    for s_id, count, offset in box_slices:
        a.label(f"check_slice_{s_id}")
        if s_id < 9:
            a.emit(addi(regs['t0'], regs['zero'], s_id))
            a.branch(bne, regs['s3'], regs['t0'], f"check_slice_{s_id+1}")
        a.emit(addi(regs['s4'], regs['zero'], count))
        if offset == 0:
            a.emit(addi(regs['s5'], regs['s0'], 0))
        else:
            a.load_imm(regs['t1'], offset)
            a.emit(add(regs['s5'], regs['s0'], regs['t1']))
        if s_id < 9:
            a.jump(jal, regs['zero'], "draw_box_slice")

    a.label("draw_box_slice")
    a.emit(lw(regs['a0'], regs['s5'], 0))
    a.emit(lw(regs['a1'], regs['s5'], 4))
    a.emit(lw(regs['a2'], regs['s5'], 16))
    a.emit(lw(regs['a3'], regs['s5'], 20))
    a.emit(lw(regs['a4'], regs['s5'], 24))
    a.jump(jal, regs['ra'], "draw_rect")
    a.emit(addi(regs['s5'], regs['s5'], 28))
    a.emit(addi(regs['s4'], regs['s4'], -1))
    a.branch(bne, regs['s4'], regs['zero'], "draw_box_slice")

    # If slice 9 just completed, flush dcache and publish left buffer!
    a.emit(addi(regs['t0'], regs['zero'], 9))
    a.branch(bne, regs['s3'], regs['t0'], "slice_done")

    a.jump(jal, regs['ra'], "flush_dcache")
    a.emit(sw(regs['s1'], regs['s11'], 0x20))   # REG_VDMA_BASE
    a.emit(lui(regs['t6'], 0x00300))
    a.emit(xor_inst(regs['s1'], regs['s1'], regs['t6']))

    a.label("slice_done")
    # Increment sub-frame counter (0..9)
    a.emit(addi(regs['s3'], regs['s3'], 1))
    a.emit(addi(regs['t0'], regs['zero'], 10))
    a.branch(bne, regs['s3'], regs['t0'], "slice_no_wrap")
    a.emit(addi(regs['s3'], regs['zero'], 0))
    a.label("slice_no_wrap")

    a.jump(jal, regs['zero'], "frame_loop")

    # =========================================================================
    # MODE 2: I2C GAMEPAD INTERACTIVE CONTROLLER (White Canvas, Black Square, HUD)
    # =========================================================================
    a.label("mode2_gamepad")
    # Wait for 60Hz VSync
    a.label("m2_vsync_wait")
    a.emit(lw(regs['t0'], regs['s11'], 0x24))
    a.branch(beq, regs['t0'], regs['zero'], "m2_vsync_wait")

    # Wait until hardware flipped away from s2
    a.label("m2_wait_swap")
    a.emit(lw(regs['t0'], regs['s11'], 0x2C))
    a.branch(beq, regs['t0'], regs['s2'], "m2_wait_swap")

    # Read Gamepad Joystick at APB + 0x50
    a.emit(lw(regs['t0'], regs['s11'], 0x50))
    a.emit(andi(regs['t1'], regs['t0'], 0xFF))
    a.emit(srli(regs['t2'], regs['t0'], 8))
    a.emit(andi(regs['t2'], regs['t2'], 0xFF))

    # dx = joy_x - 128
    a.emit(addi(regs['t3'], regs['t1'], -128))
    a.emit(addi(regs['t4'], regs['zero'], 0))
    a.emit(addi(regs['t5'], regs['zero'], 15))
    a.branch(blt, regs['t5'], regs['t3'], "m2_dx_pos")
    a.emit(addi(regs['t5'], regs['zero'], -15))
    a.branch(blt, regs['t3'], regs['t5'], "m2_dx_neg")
    a.jump(jal, regs['zero'], "m2_dx_done")
    a.label("m2_dx_pos")
    a.emit(addi(regs['t4'], regs['t3'], -15))
    a.emit(srli(regs['t4'], regs['t4'], 3))
    a.emit(addi(regs['t4'], regs['t4'], 1))
    a.jump(jal, regs['zero'], "m2_dx_done")
    a.label("m2_dx_neg")
    a.emit(addi(regs['t4'], regs['t3'], 15))
    a.emit(sub(regs['t4'], regs['zero'], regs['t4']))
    a.emit(srli(regs['t4'], regs['t4'], 3))
    a.emit(addi(regs['t4'], regs['t4'], 1))
    a.emit(sub(regs['t4'], regs['zero'], regs['t4']))
    a.label("m2_dx_done")

    # The joystick's physical Y polarity is opposite to screen coordinates:
    # pushing up raises the raw value, while increasing screen Y moves down.
    # Compute the existing speed curve from (joy_y - 128), then negate vy.
    a.emit(addi(regs['t3'], regs['t2'], -128))
    a.emit(addi(regs['t5'], regs['zero'], 0))
    a.emit(addi(regs['t6'], regs['zero'], 15))
    a.branch(blt, regs['t6'], regs['t3'], "m2_dy_pos")
    a.emit(addi(regs['t6'], regs['zero'], -15))
    a.branch(blt, regs['t3'], regs['t6'], "m2_dy_neg")
    a.jump(jal, regs['zero'], "m2_dy_done")
    a.label("m2_dy_pos")
    a.emit(addi(regs['t5'], regs['t3'], -15))
    a.emit(srli(regs['t5'], regs['t5'], 3))
    a.emit(addi(regs['t5'], regs['t5'], 1))
    a.jump(jal, regs['zero'], "m2_dy_done")
    a.label("m2_dy_neg")
    a.emit(addi(regs['t5'], regs['t3'], 15))
    a.emit(sub(regs['t5'], regs['zero'], regs['t5']))
    a.emit(srli(regs['t5'], regs['t5'], 3))
    a.emit(addi(regs['t5'], regs['t5'], 1))
    a.emit(sub(regs['t5'], regs['zero'], regs['t5']))
    a.label("m2_dy_done")
    a.emit(sub(regs['t5'], regs['zero'], regs['t5']))

    # Update s7 (box_x) with t4 (vx), clamp [0, 984]
    a.emit(add(regs['s7'], regs['s7'], regs['t4']))
    a.branch(bge, regs['s7'], regs['zero'], "m2_x_min_ok")
    a.emit(addi(regs['s7'], regs['zero'], 0))
    a.label("m2_x_min_ok")
    a.load_imm(regs['t6'], 984)
    a.branch(blt, regs['s7'], regs['t6'], "m2_x_max_ok")
    a.emit(addi(regs['s7'], regs['t6'], 0))
    a.label("m2_x_max_ok")

    # Update s8 (box_y) with t5 (vy), clamp [48, 560]
    a.emit(add(regs['s8'], regs['s8'], regs['t5']))
    a.emit(addi(regs['t6'], regs['zero'], 48))
    a.branch(bge, regs['s8'], regs['t6'], "m2_y_min_ok")
    a.emit(addi(regs['s8'], regs['zero'], 48))
    a.label("m2_y_min_ok")
    a.load_imm(regs['t6'], 560)
    a.branch(blt, regs['s8'], regs['t6'], "m2_y_max_ok")
    a.emit(addi(regs['s8'], regs['t6'], 0))
    a.label("m2_y_max_ok")

    # 1. Clear full canvas to white (0x00FFFFFF) with BitBlt
    a.label("m2_bb_wait1")
    a.emit(lw(regs['t0'], regs['s11'], 0x00))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(bne, regs['t0'], regs['zero'], "m2_bb_wait1")

    a.emit(sw(regs['s2'], regs['s11'], 0x04))
    a.load_imm(regs['t0'], 1024)
    a.emit(sw(regs['t0'], regs['s11'], 0x08))
    a.load_imm(regs['t0'], 600)
    a.emit(sw(regs['t0'], regs['s11'], 0x0C))
    a.load_imm(regs['t0'], 0x00FFFFFF)
    a.emit(sw(regs['t0'], regs['s11'], 0x10))
    a.emit(sw(regs['zero'], regs['s11'], 0x18)) # OP_FILL
    a.load_imm(regs['t0'], 4096)
    a.emit(sw(regs['t0'], regs['s11'], 0x48))
    a.emit(addi(regs['t0'], regs['zero'], 1))
    a.emit(sw(regs['t0'], regs['s11'], 0x14))

    # 2. Draw black square (40x40) at (s7, s8)
    a.label("m2_bb_wait2")
    a.emit(lw(regs['t0'], regs['s11'], 0x00))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(bne, regs['t0'], regs['zero'], "m2_bb_wait2")

    a.emit(slli(regs['t0'], regs['s8'], 12))
    a.emit(slli(regs['t1'], regs['s7'], 2))
    a.emit(add(regs['t0'], regs['t0'], regs['t1']))
    a.emit(add(regs['t0'], regs['t0'], regs['s2']))
    a.emit(sw(regs['t0'], regs['s11'], 0x04))
    a.emit(addi(regs['t0'], regs['zero'], 40))
    a.emit(sw(regs['t0'], regs['s11'], 0x08))
    a.emit(sw(regs['t0'], regs['s11'], 0x0C))
    a.emit(sw(regs['zero'], regs['s11'], 0x10)) # OP_FILL Black (0x00000000)
    a.emit(addi(regs['t0'], regs['zero'], 1))
    a.emit(sw(regs['t0'], regs['s11'], 0x14))

    # 3. Draw ABXY buttons indicator at top (Y=14, X=600, 640, 680, 720)
    a.emit(lw(regs['a5'], regs['s11'], 0x54)) # buttons

    # Button A
    a.label("m2_bb_wait3")
    a.emit(lw(regs['t0'], regs['s11'], 0x00))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(bne, regs['t0'], regs['zero'], "m2_bb_wait3")
    a.load_imm(regs['t1'], 59744)
    a.emit(add(regs['t1'], regs['t1'], regs['s2']))
    a.emit(sw(regs['t1'], regs['s11'], 0x04))
    a.emit(addi(regs['t0'], regs['zero'], 24))
    a.emit(sw(regs['t0'], regs['s11'], 0x08))
    a.emit(addi(regs['t0'], regs['zero'], 16))
    a.emit(sw(regs['t0'], regs['s11'], 0x0C))
    a.emit(andi(regs['t0'], regs['a5'], 1))
    a.branch(beq, regs['t0'], regs['zero'], "m2_btn_a_off")
    a.load_imm(regs['t0'], 0x0000AA00)
    a.jump(jal, regs['zero'], "m2_btn_a_col")
    a.label("m2_btn_a_off")
    a.load_imm(regs['t0'], 0x00CCCCCC)
    a.label("m2_btn_a_col")
    a.emit(sw(regs['t0'], regs['s11'], 0x10))
    a.emit(addi(regs['t0'], regs['zero'], 1))
    a.emit(sw(regs['t0'], regs['s11'], 0x14))

    # Button B
    a.label("m2_bb_wait4")
    a.emit(lw(regs['t0'], regs['s11'], 0x00))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(bne, regs['t0'], regs['zero'], "m2_bb_wait4")
    a.load_imm(regs['t1'], 59872)
    a.emit(add(regs['t1'], regs['t1'], regs['s2']))
    a.emit(sw(regs['t1'], regs['s11'], 0x04))
    a.emit(srli(regs['t0'], regs['a5'], 1))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(beq, regs['t0'], regs['zero'], "m2_btn_b_off")
    a.load_imm(regs['t0'], 0x00CC0000)
    a.jump(jal, regs['zero'], "m2_btn_b_col")
    a.label("m2_btn_b_off")
    a.load_imm(regs['t0'], 0x00CCCCCC)
    a.label("m2_btn_b_col")
    a.emit(sw(regs['t0'], regs['s11'], 0x10))
    a.emit(addi(regs['t0'], regs['zero'], 1))
    a.emit(sw(regs['t0'], regs['s11'], 0x14))

    # Button X
    a.label("m2_bb_wait5")
    a.emit(lw(regs['t0'], regs['s11'], 0x00))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(bne, regs['t0'], regs['zero'], "m2_bb_wait5")
    a.load_imm(regs['t1'], 60000)
    a.emit(add(regs['t1'], regs['t1'], regs['s2']))
    a.emit(sw(regs['t1'], regs['s11'], 0x04))
    a.emit(srli(regs['t0'], regs['a5'], 2))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(beq, regs['t0'], regs['zero'], "m2_btn_x_off")
    a.load_imm(regs['t0'], 0x000000CC)
    a.jump(jal, regs['zero'], "m2_btn_x_col")
    a.label("m2_btn_x_off")
    a.load_imm(regs['t0'], 0x00CCCCCC)
    a.label("m2_btn_x_col")
    a.emit(sw(regs['t0'], regs['s11'], 0x10))
    a.emit(addi(regs['t0'], regs['zero'], 1))
    a.emit(sw(regs['t0'], regs['s11'], 0x14))

    # Button Y
    a.label("m2_bb_wait6")
    a.emit(lw(regs['t0'], regs['s11'], 0x00))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(bne, regs['t0'], regs['zero'], "m2_bb_wait6")
    a.load_imm(regs['t1'], 60128)
    a.emit(add(regs['t1'], regs['t1'], regs['s2']))
    a.emit(sw(regs['t1'], regs['s11'], 0x04))
    a.emit(srli(regs['t0'], regs['a5'], 3))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(beq, regs['t0'], regs['zero'], "m2_btn_y_off")
    a.load_imm(regs['t0'], 0x00CCCC00)
    a.jump(jal, regs['zero'], "m2_btn_y_col")
    a.label("m2_btn_y_off")
    a.load_imm(regs['t0'], 0x00CCCCCC)
    a.label("m2_btn_y_col")
    a.emit(sw(regs['t0'], regs['s11'], 0x10))
    a.emit(addi(regs['t0'], regs['zero'], 1))
    a.emit(sw(regs['t0'], regs['s11'], 0x14))

    # Wait final idle
    a.label("m2_bb_wait_final")
    a.emit(lw(regs['t0'], regs['s11'], 0x00))
    a.emit(andi(regs['t0'], regs['t0'], 1))
    a.branch(bne, regs['t0'], regs['zero'], "m2_bb_wait_final")

    # Publish dual swap
    a.emit(sw(regs['s2'], regs['s11'], 0x40))
    a.emit(sw(regs['s2'], regs['s11'], 0x20))
    a.emit(lui(regs['t6'], 0x00300))
    a.emit(xor_inst(regs['s2'], regs['s2'], regs['t6']))
    a.emit(xor_inst(regs['s1'], regs['s1'], regs['t6']))

    a.jump(jal, regs['zero'], "frame_loop")

    # =========================================================================
    # SUBROUTINE: draw_rect(x=a0, y=a1, w=a2, h=a3, color=a4)
    # Target address = s1 + (y << 12) + (x << 2)
    # Row stride = 4096 bytes
    # =========================================================================
    a.label("draw_rect")
    a.emit(slli(regs['t0'], regs['a1'], 12))  # y * 4096
    a.emit(slli(regs['t3'], regs['a0'], 2))   # x * 4
    a.emit(add(regs['t0'], regs['t0'], regs['t3']))
    a.emit(add(regs['t0'], regs['t0'], regs['s1']))
    a.emit(addi(regs['t1'], regs['a3'], 0))   # row counter = h
    a.emit(lui(regs['t4'], 1))                # row stride = 4096

    a.label("dr_row_loop")
    a.emit(addi(regs['t3'], regs['t0'], 0))   # current pixel pointer in row
    a.emit(addi(regs['t2'], regs['a2'], 0))   # col counter = w

    a.label("dr_col_loop")
    a.emit(sw(regs['a4'], regs['t3'], 0))
    a.emit(sw(regs['a4'], regs['t3'], 4))
    a.emit(addi(regs['t3'], regs['t3'], 8))
    a.emit(addi(regs['t2'], regs['t2'], -2))
    a.branch(bne, regs['t2'], regs['zero'], "dr_col_loop")

    a.emit(add(regs['t0'], regs['t0'], regs['t4']))
    a.emit(addi(regs['t1'], regs['t1'], -1))
    a.branch(bne, regs['t1'], regs['zero'], "dr_row_loop")
    a.emit(jalr(regs['zero'], regs['ra'], 0))

    # Invalidate dcache read and drain write buffer
    a.label("flush_dcache")
    a.emit(0x0000500F)
    a.emit(lw(regs['t0'], regs['s1'], 0))
    a.emit(jalr(regs['zero'], regs['ra'], 0))

    return a.build()


def validate_layout(code):
    image_end = RAM_BASE + len(code) * 4
    assert image_end <= GLOBALS_RAM, f"Image ends at {image_end:#x}, overlaps globals at {GLOBALS_RAM:#x}"
    assert GLOBALS_RAM + 12 <= STACK_BOTTOM
    assert STACK_BOTTOM + 64 <= RAM_BASE + RAM_SIZE
    return image_end


def write_image():
    code = generate_code()
    image_end = validate_layout(code)
    root = Path(__file__).resolve().parents[1]
    for directory in (root / 'ip/soc', root / 'ip/soc/source/hardware/netlist'):
        for lane in range(4):
            values = [f'{((code[i] if i < len(code) else 0) >> (lane * 8)) & 255:08b}' for i in range(1024)]
            path = directory / f'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{lane}.bin'
            path.write_text('\n'.join(values) + '\n', encoding='ascii')
    print(f'Generated {len(code)} words (code + constants), end={image_end:#x}; globals={GLOBALS_RAM:#x}, stack>={STACK_BOTTOM:#x}')


if __name__ == '__main__':
    write_image()

