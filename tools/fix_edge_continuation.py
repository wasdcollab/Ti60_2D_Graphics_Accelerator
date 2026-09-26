import sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\sw\app\main.c"
data = open(P, "rb").read()
NL = "\r\n"

def patch(data, old, new, tag):
    ob, nb = old.encode("utf-8"), new.encode("utf-8")
    n = data.count(ob)
    if n != 1:
        print("FAIL %-26s : %d matches" % (tag, n)); sys.exit(1)
    data = data.replace(ob, nb, 1)
    open(P, "wb").write(data)
    print("OK   %-26s : %d bytes" % (tag, len(data)))
    return data

old = (
"    cpu_fill(MM_VISUAL_BACKGROUND + 1024u * 4u," + NL +
"             SCREEN_WIDTH - 1024u, SCREEN_HEIGHT, BACKDROP_PANEL, SCREEN_STRIDE);" + NL +
"    /* Bottom strip, split exactly where the backdrop's own gutters are:" + NL +
"     * left gutter | stage | right gutter. */" + NL +
"    cpu_fill(MM_VISUAL_BACKGROUND + 600u * SCREEN_STRIDE," + NL +
"             (uint32_t)GAME_LEFT, SCREEN_HEIGHT - 600u, BACKDROP_PANEL, SCREEN_STRIDE);" + NL +
"    cpu_fill(MM_VISUAL_BACKGROUND + 600u * SCREEN_STRIDE + (uint32_t)(GAME_LEFT * 4)," + NL +
"             (uint32_t)(GAME_RIGHT - GAME_LEFT), SCREEN_HEIGHT - 600u," + NL +
"             BACKDROP_STAGE, SCREEN_STRIDE);" + NL +
"    cpu_fill(MM_VISUAL_BACKGROUND + 600u * SCREEN_STRIDE + (uint32_t)(GAME_RIGHT * 4)," + NL +
"             (uint32_t)(1024 - GAME_RIGHT), SCREEN_HEIGHT - 600u," + NL +
"             BACKDROP_PANEL, SCREEN_STRIDE);")

new = (
"    /* Continue the backdrop along its OWN last column and last row instead of" + NL +
"     * guessing a colour: whatever the artwork actually paints at its edge is" + NL +
"     * what the new strips receive, so the join is exact for any palette - and" + NL +
"     * it stays right if the artwork is ever redrawn.  (Filling with a sampled" + NL +
"     * constant looked continuous in the VM but not on the panel.)" + NL +
"     *" + NL +
"     * The strips are painted here in normal C rather than through r_fill: this" + NL +
"     * runs at boot before anything has proved the engine usable, and if it does" + NL +
"     * not land nothing else ever covers those edges. */" + NL +
"    {" + NL +
"        volatile uint32_t *bg = (volatile uint32_t *)MM_VISUAL_BACKGROUND;" + NL +
"        const unsigned pitch  = SCREEN_STRIDE / 4u;   /* framebuffer row in pixels */" + NL +
"        const unsigned edge_x = 1023u;                /* backdrop decodes 1024 wide */" + NL +
"        const unsigned edge_y = 599u;                 /* and 600 tall                 */" + NL +
"        unsigned x, y;" + NL +
"" + NL +
"        for (y = 0; y < SCREEN_HEIGHT; y++) {" + NL +
"            uint32_t c = bg[y * pitch + edge_x];" + NL +
"            volatile uint32_t *row = bg + y * pitch;" + NL +
"            for (x = edge_x + 1u; x < SCREEN_WIDTH; x++) row[x] = c;" + NL +
"        }" + NL +
"        for (x = 0; x < 1024u; x++) {" + NL +
"            uint32_t c = bg[edge_y * pitch + x];" + NL +
"            for (y = edge_y + 1u; y < SCREEN_HEIGHT; y++) bg[y * pitch + x] = c;" + NL +
"        }" + NL +
"    }")

data = patch(data, old, new, "edge-continuation fill")

# the two sampled constants are no longer used
data = patch(data,
"/* Sampled straight out of assets/processed/background.png: the flat colour the" + NL +
" * left/right gutters are painted in, and the stage's bottom colour.  The" + NL +
" * backdrop is only 1024x600, so the rest of the 1366x768 scan is filled with" + NL +
" * these two rather than with a colour of their own. */" + NL +
"#define BACKDROP_PANEL     0x0048566Bu" + NL +
"#define BACKDROP_STAGE     0x000B111Bu" + NL,
"", "drop sampled constants")
