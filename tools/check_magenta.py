from PIL import Image
import numpy as np
p = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\simulator\output\test9_menu_exit.png"
im = np.asarray(Image.open(p).convert("RGB")).astype(np.int32)
h, w, _ = im.shape

mag = (im[:, :, 0] == 255) & (im[:, :, 1] == 0) & (im[:, :, 2] == 255)
print("magenta (255,0,255) pixels in the exported frame: %d" % int(mag.sum()))
blk = (im.sum(axis=2) == 0)
print("pure black pixels: %d (%.2f%%)" % (int(blk.sum()), 100.0 * blk.sum() / (w * h)))
print()
print("column-wise pure-black fraction, band = 64 px  (a never-written strip shows as black here)")
for x0 in range(0, w, 64):
    x1 = min(x0 + 64, w)
    print("   x %4d-%4d : black %5.2f%%   mean rgb (%5.1f,%5.1f,%5.1f)"
          % (x0, x1 - 1, 100.0 * blk[:, x0:x1].mean(),
             im[:, x0:x1].reshape(-1, 3).mean(axis=0)[0],
             im[:, x0:x1].reshape(-1, 3).mean(axis=0)[1],
             im[:, x0:x1].reshape(-1, 3).mean(axis=0)[2]))
