import sys
sys.path.insert(0, r"E:\FPGA\Ti60_2D_Graphics_Accelerator\simulator")
import numpy as np
from PIL import Image
import test_runner as T
from rv32i_soc_vm import SCRATCH_BASE

FW = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\sw\build\firmware.bin"
code = T.load_code_from_source(FW)
print("firmware loaded")
T.build_boot_snapshot(code)
vm = T.new_vm(code)
print("vm ready")

MM_VISUAL_BACKGROUND = 0x03800000
off = MM_VISUAL_BACKGROUND - SCRATCH_BASE
pitch, w, h = T.SCREEN_STRIDE, T.SCREEN_W, T.SCREEN_H
out = np.zeros((h, w, 3), dtype=np.uint8)
for y in range(h):
    b = off + y * pitch
    row = np.frombuffer(bytes(vm.scratch[b:b + w * 4]), dtype=np.uint8).reshape(w, 4)
    out[y] = row[:, :3][:, ::-1]
p = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\simulator\output\_backdrop.png"
Image.fromarray(out).save(p)
print("dumped MM_VISUAL_BACKGROUND -> %s\n" % p)

def band(name, x0, x1, y0, y1):
    blk = out[y0:y1, x0:x1].astype(np.int32)
    m = blk.reshape(-1, 3).mean(axis=0)
    uq = len({tuple(v) for v in blk.reshape(-1, 3)[::37]})
    print("  %-40s mean(%5.1f,%5.1f,%5.1f)  distinct~%d" % (name, m[0], m[1], m[2], uq))
band("decoded backdrop  x0..1023 y0..599", 0, 1024, 0, 600)
band("RIGHT strip       x1024..1365", 1024, 1366, 0, 768)
band("BOTTOM strip      y600+ x0..127", 0, 128, 600, 768)
band("BOTTOM strip      y600+ x128..767", 128, 768, 600, 768)
band("BOTTOM strip      y600+ x768..1023", 768, 1024, 600, 768)
print("\n=== seam across x=1024 ===")
for y in (10, 200, 400, 700):
    print("   y=%-4d x1020=%s x1023=%s x1024=%s x1100=%s"
          % (y, tuple(int(v) for v in out[y,1020]), tuple(int(v) for v in out[y,1023]),
             tuple(int(v) for v in out[y,1024]), tuple(int(v) for v in out[y,1100])))
print("\n=== seam across y=600 ===")
for x in (10, 200, 700, 1000, 1200):
    print("   x=%-5d y597=%s y599=%s y600=%s y700=%s"
          % (x, tuple(int(v) for v in out[597,x]), tuple(int(v) for v in out[599,x]),
             tuple(int(v) for v in out[600,x]), tuple(int(v) for v in out[700,x])))
