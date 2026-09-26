from PIL import Image
import numpy as np
im = np.asarray(Image.open(r"E:\FPGA\Ti60_2D_Graphics_Accelerator\simulator\output\test13_stage3_bg.png").convert("RGB")).astype(np.int32)
print("=== a real GAME frame: what does each column band look like? ===")
print("  band        mean rgb                 panel-colour %%")
for x0 in range(0, 1366, 128):
    x1 = min(x0 + 128, 1366)
    blk = im[:, x0:x1]
    m = blk.reshape(-1, 3).mean(axis=0)
    hit = int(((blk[:,:,0]==0x48)&(blk[:,:,1]==0x56)&(blk[:,:,2]==0x6B)).sum())
    print("  x %4d-%4d  (%5.1f,%5.1f,%5.1f)     %5.1f%%" % (x0, x1-1, m[0], m[1], m[2], 100.0*hit/((x1-x0)*768)))
print()
print("=== row-by-row sample at the right strip (x = 1100, 1300) ===")
for y in (4, 200, 400, 596, 604, 700, 767):
    print("   y=%-4d  x1100=%s  x1300=%s" % (y, tuple(int(v) for v in im[y,1100]), tuple(int(v) for v in im[y,1300])))
