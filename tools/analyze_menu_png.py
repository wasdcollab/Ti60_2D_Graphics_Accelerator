from PIL import Image
import numpy as np
p = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\simulator\output\test9_menu_exit.png"
im = np.asarray(Image.open(p).convert("RGB")).astype(np.int32)
h, w, _ = im.shape
print("image: %d x %d" % (w, h))

# 1) vertical seams: columns where the picture jumps
d = np.abs(np.diff(im, axis=1)).sum(axis=(0, 2))
order = np.argsort(d)[::-1]
print("\n=== biggest column-to-column jumps (column -> jump) ===")
for i in order[:12]:
    print("   x=%-5d jump=%-12d  %s" % (i, d[i], "<-- CANDIDATE SEAM" if d[i] > 200000 else ""))

# 2) horizontal self-similarity: is the picture periodic?
print("\n=== period search: mean abs diff between x and x+P ===")
best = []
for P in (640, 683, 686, 700, 1024, 1366 // 2, 1366 // 2 + 40):
    if P < w:
        a = im[:, :w - P]
        b = im[:, P:]
        best.append((float(np.abs(a - b).mean()), P))
for v, P in sorted(best):
    print("   period %-6d mean|diff| = %.2f  %s" % (P, v, "<-- near-identical" if v < 6 else ""))

# 3) what is actually at the two half-screen boundaries?
print("\n=== pixel columns around x=640 (VDMA HALF_OFFSET = 2560 B = 640 px) ===")
for x in range(636, 645):
    px = im[300, x]
    print("   x=%-4d rgb=%s" % (x, tuple(px)))

# 4) is there a flat fill band on the right (x >= 1024) as main.c promises?
print("\n=== row 300, sampled every 64 px ===")
for x in range(0, w, 64):
    print("   x=%-5d rgb=%s" % (x, tuple(im[300, x])))
