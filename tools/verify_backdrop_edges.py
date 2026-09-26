from PIL import Image
import numpy as np
im = np.asarray(Image.open(r"E:\FPGA\Ti60_2D_Graphics_Accelerator\simulator\output\test9_menu_exit.png").convert("RGB")).astype(np.int32)
h, w, _ = im.shape
PANEL = (0x48, 0x56, 0x6B)
STAGE = (0x0B, 0x11, 0x1B)
def region(name, x0, x1, y0, y1, want, wname):
    blk = im[y0:y1, x0:x1]
    m = blk.reshape(-1, 3).mean(axis=0)
    hit = int(((blk[:, :, 0] == want[0]) & (blk[:, :, 1] == want[1]) & (blk[:, :, 2] == want[2])).sum())
    tot = (x1 - x0) * (y1 - y0)
    print("  %-38s mean(%5.1f,%5.1f,%5.1f)  = %-6s %5.1f%%"
          % (name, m[0], m[1], m[2], wname, 100.0 * hit / tot))
print("=== the four strips that used to be near-black ===")
region("right strip  x1024..1365 (full height)", 1024, 1366, 0, 768, PANEL, "PANEL")
region("bottom strip y600..767, x 0..127",        0,  128, 600, 768, PANEL, "PANEL")
region("bottom strip y600..767, x128..767",     128,  768, 600, 768, STAGE, "STAGE")
region("bottom strip y600..767, x768..1023",    768, 1024, 600, 768, PANEL, "PANEL")
print()
print("=== for reference: the old colour 0x00101828 should now be gone ===")
old = ((im[:, :, 0] == 0x10) & (im[:, :, 1] == 0x18) & (im[:, :, 2] == 0x28)).sum()
print("  pixels still equal to the OLD near-black fill: %d" % int(old))
print()
print("=== seam check: does the new right strip match the backdrop next to it? ===")
for x in (1010, 1020, 1024, 1030, 1100, 1300, 1365):
    print("   x=%-5d rgb=%s" % (x, tuple(int(v) for v in im[400, x])))
