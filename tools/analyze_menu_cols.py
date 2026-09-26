from PIL import Image
import numpy as np
p = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\simulator\output\test9_menu_exit.png"
im = np.asarray(Image.open(p).convert("RGB")).astype(np.int32)
h, w, _ = im.shape

# per-column mean colour, grouped into bands of 32 px
print("=== column profile (mean over all rows), band = 32 px ===")
print("  x-range     mean rgb                 note")
prev = None
for x0 in range(0, w, 32):
    x1 = min(x0 + 32, w)
    m = im[:, x0:x1].reshape(-1, 3).mean(axis=0)
    tag = ""
    if m.max() < 2:
        tag = "  <-- ALL BLACK"
    print("  %4d-%4d   (%6.1f,%6.1f,%6.1f)%s" % (x0, x1 - 1, m[0], m[1], m[2], tag))

# how much of each column is pure black?
print()
print("=== fraction of pure-black pixels per column ===")
blk = (im.sum(axis=2) == 0)
runs = []
cur = None
for x in range(w):
    frac = blk[:, x].mean()
    isblack = frac > 0.95
    if isblack and cur is None:
        cur = x
    elif not isblack and cur is not None:
        runs.append((cur, x - 1)); cur = None
if cur is not None:
    runs.append((cur, w - 1))
print("  fully-black column runs:", runs if runs else "(none)")
