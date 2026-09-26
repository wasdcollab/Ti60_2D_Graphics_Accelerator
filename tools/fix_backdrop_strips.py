import re, sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\sw\app\main.c"
data = open(P, "rb").read()
NL = "\r\n"

def patch(data, old, new, tag):
    ob, nb = old.encode("utf-8"), new.encode("utf-8")
    n = data.count(ob)
    if n != 1:
        print("FAIL %-32s : %d matches" % (tag, n)); sys.exit(1)
    data = data.replace(ob, nb, 1)
    open(P, "wb").write(data)
    print("OK   %-32s : %d bytes" % (tag, len(data)))
    return data

data = patch(
    data,
    "    r_fill(MM_VISUAL_BACKGROUND + 1024u * 4u," + NL +
    "           SCREEN_WIDTH - 1024u, SCREEN_HEIGHT, 0x00101828u, SCREEN_STRIDE);" + NL +
    "    r_fill(MM_VISUAL_BACKGROUND + 600u * SCREEN_STRIDE," + NL +
    "           1024u, SCREEN_HEIGHT - 600u, 0x00101828u, SCREEN_STRIDE);",
    "    /* cpu_fill, not r_fill: this comment used to say \"r_fill takes the" + NL +
    "     * software path here (hw_accel is still 0 at boot)\", but hw_accel has" + NL +
    "     * defaulted to 1 for a long time, so the engine was really being used." + NL +
    "     * These two strips are the ONLY thing that paints the backdrop's right" + NL +
    "     * and bottom edges; if the fill does not land, nothing else ever covers" + NL +
    "     * them, and the strips are scanned out as DDR residue.  Take the path" + NL +
    "     * this code always meant to take. */" + NL +
    "    cpu_fill(MM_VISUAL_BACKGROUND + 1024u * 4u," + NL +
    "             SCREEN_WIDTH - 1024u, SCREEN_HEIGHT, 0x00101828u, SCREEN_STRIDE);" + NL +
    "    cpu_fill(MM_VISUAL_BACKGROUND + 600u * SCREEN_STRIDE," + NL +
    "             1024u, SCREEN_HEIGHT - 600u, 0x00101828u, SCREEN_STRIDE);",
    "backdrop strips -> cpu_fill",
)
