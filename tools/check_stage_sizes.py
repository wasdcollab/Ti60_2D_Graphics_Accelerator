from PIL import Image
import os
d = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\assets\processed"
for n in ("stage_dream.png", "stage_ice.png", "stage_lava.png", "cloud_a.png", "cloud_b.png", "snow.png", "ember.png"):
    p = os.path.join(d, n)
    if os.path.exists(p):
        im = Image.open(p)
        print("  %-18s %s" % (n, im.size))
