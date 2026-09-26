from PIL import Image
import numpy as np
p = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\simulator\output\test9_menu_exit.png"
im = np.asarray(Image.open(p).convert("RGB")).astype(np.int32)
h, w, _ = im.shape

FILL = (0x10, 0x18, 0x28)     # 0x00101828, the colour both r_fill strips use
print("=== region check: is the backdrop complete, or are the two fill strips missing? ===")
def region(name, x0, x1, y0, y1):
    blk = im[y0:y1, x0:x1]
    m = blk.reshape(-1, 3).mean(axis=0)
    hit = int(((blk[:, :, 0] == FILL[0]) & (blk[:, :, 1] == FILL[1]) & (blk[:, :, 2] == FILL[2])).sum())
    tot = (x1 - x0) * (y1 - y0)
    print("  %-34s mean rgb (%5.1f,%5.1f,%5.1f)   fill-colour %5.1f%%"
          % (name, m[0], m[1], m[2], 100.0 * hit / tot))

region("backdrop image x 0..1023, y 0..599", 0, 1024, 0, 600)
region("FILL STRIP 1 (right) x1024..1365", 1024, 1366, 0, 768)
region("FILL STRIP 2 (bottom) x0..1023 y600+", 0, 1024, 600, 768)
print()
print("=== and on the screen the menu occupies x 160..864, so the sides show: ===")
region("left side  x 0..159", 0, 160, 0, 768)
region("right side x 865..1365", 865, 1366, 0, 768)
