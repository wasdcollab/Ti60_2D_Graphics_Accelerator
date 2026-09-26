import sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\sw\app\main.c"
data = open(P, "rb").read()
NL = "\r\n"

old = (
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
"             1024u, SCREEN_HEIGHT - 600u, 0x00101828u, SCREEN_STRIDE);")

new = (
"    /* The backdrop source decodes to 1024x600 but the scan is 1366x768, so the" + NL +
"     * right 342 columns and the bottom 168 rows have no backdrop at all." + NL +
"     * Fill them with the backdrop's OWN colours so the panels and the stage" + NL +
"     * simply run off the edge of the screen, instead of with the flat" + NL +
"     * near-black they used to get (0x00101828, four times darker than the" + NL +
"     * 0x0048566B gutters) - that mismatch is what read as two big dead bands." + NL +
"     *" + NL +
"     * cpu_fill, not r_fill: this used to say \"r_fill takes the software path" + NL +
"     * here (hw_accel is still 0 at boot)\", but hw_accel has defaulted to 1 for" + NL +
"     * a long time.  These strips are the ONLY thing that paints those edges;" + NL +
"     * if the fill does not land, nothing else ever covers them.  Take the path" + NL +
"     * this code always meant to take. */" + NL +
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

ob, nb = old.encode("utf-8"), new.encode("utf-8")
n = data.count(ob)
if n != 1:
    print("FAIL: %d matches" % n); sys.exit(1)
data = data.replace(ob, nb, 1)

# define the two sampled colours next to the other screen geometry constants
anchor = "#define SCAN_HALF_PIXELS   640u"
ob2 = anchor.encode("utf-8")
nb2 = ("/* Sampled straight out of assets/processed/background.png: the flat colour the" + NL +
       " * left/right gutters are painted in, and the stage's bottom colour.  The" + NL +
       " * backdrop is only 1024x600, so the rest of the 1366x768 scan is filled with" + NL +
       " * these two rather than with a colour of their own. */" + NL +
       "#define BACKDROP_PANEL     0x0048566Bu" + NL +
       "#define BACKDROP_STAGE     0x000B111Bu" + NL +
       anchor).encode("utf-8")
if data.count(ob2) != 1:
    print("FAIL: anchor"); sys.exit(1)
data = data.replace(ob2, nb2, 1)

open(P, "wb").write(data)
print("OK  backdrop edges now continue the backdrop : %d bytes" % len(data))
