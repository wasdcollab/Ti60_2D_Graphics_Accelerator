from PIL import Image
import numpy as np
im = np.asarray(Image.open(r"E:\FPGA\Ti60_2D_Graphics_Accelerator\assets\processed\background.png").convert("RGB"))
h, w, _ = im.shape
print("backdrop source: %d x %d   (x2 -> %d x %d on screen)" % (w, h, w*2, h*2))
print()
def px(x, y, note):
    r, g, b = im[y, x]
    v = (int(r) << 16) | (int(g) << 8) | int(b)
    print("  src(%3d,%3d) -> screen(%4d,%4d)  rgb=(%3d,%3d,%3d)  0x00%06Xu   %s"
          % (x, y, x*2, y*2, r, g, b, v, note))
px(500, 150, "right panel, blank area")
px(500, 290, "right panel, near bottom")
px(506,  10, "right panel, top")
px( 10, 150, "left panel, blank area")
px( 10, 290, "left panel, near bottom")
px(200, 296, "stage, bottom row")
px(100, 296, "stage left, bottom row")
px(350, 296, "stage right, bottom row")
print()
print("=== column x=511 (the right-most source column) ===")
col = im[:, 511]
print("  unique colours:", sorted({tuple(int(v) for v in c) for c in col}))
print()
print("=== row y=299 (the bottom source row), sampled every 32 px ===")
for x in range(0, 512, 32):
    r, g, b = im[299, x]
    print("  src x=%3d (screen %4d)  rgb=(%3d,%3d,%3d) 0x00%02X%02X%02Xu" % (x, x*2, r, g, b, r, g, b))
