from PIL import Image
src = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\simulator\output\test9_menu_exit.png"
im = Image.open(src).convert("RGB")
w, h = im.size
# menu content lives in x 160..864 (MENU_X=212, MENU_W=600, title bar 160..863)
left  = im.crop((0, 0, 160, h))
right = im.crop((864, 0, w, h))
canvas = Image.new("RGB", (left.width + right.width + 16, h), (255, 0, 0))
canvas.paste(left, (0, 0))
canvas.paste(right, (left.width + 16, 0))
out = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\simulator\output\_sides.png"
canvas.save(out)
print("saved %s  (left 160 px | 16 px red gap | right %d px)" % (out, right.width))
