import sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\sw\app\main.c"
data = open(P, "rb").read()
NL = "\r\n"
old = ("static void r_blit(uint32_t dst, uint32_t src, uint32_t w, uint32_t h," + NL +
       "                   uint32_t sstride, uint32_t dstride);")
new = ("/* sprites_build() paints the backdrop's right and bottom edge strips with" + NL +
       " * cpu_fill: nothing else ever covers them, so they must not depend on the" + NL +
       " * engine being usable that early.  Declared here because the definition" + NL +
       " * sits far below the call site. */" + NL +
       "static void cpu_fill(uint32_t dst, uint32_t w, uint32_t h, uint32_t color," + NL +
       "                     uint32_t stride);" + NL +
       old)
ob, nb = old.encode("utf-8"), new.encode("utf-8")
n = data.count(ob)
if n != 1:
    print("FAIL: %d matches" % n); sys.exit(1)
data = data.replace(ob, nb, 1)
open(P, "wb").write(data)
print("OK  forward declaration added : %d bytes" % len(data))
