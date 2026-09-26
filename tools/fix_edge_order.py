import sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\sw\app\main.c"
data = open(P, "rb").read()
NL = "\r\n"

old = (
"        for (y = 0; y < SCREEN_HEIGHT; y++) {" + NL +
"            uint32_t c = bg[y * pitch + edge_x];" + NL +
"            volatile uint32_t *row = bg + y * pitch;" + NL +
"            for (x = edge_x + 1u; x < SCREEN_WIDTH; x++) row[x] = c;" + NL +
"        }" + NL +
"        for (x = 0; x < 1024u; x++) {" + NL +
"            uint32_t c = bg[edge_y * pitch + x];" + NL +
"            for (y = edge_y + 1u; y < SCREEN_HEIGHT; y++) bg[y * pitch + x] = c;" + NL +
"        }")

new = (
"        /* Bottom strip FIRST.  The right strip below reads one pixel out of" + NL +
"         * every row - including the rows this loop is about to fill - so those" + NL +
"         * rows have to hold their final colour before it reads them.  Doing it" + NL +
"         * the other way round left the lower half of the right strip black," + NL +
"         * because it copied the still-untouched tail of column 1023. */" + NL +
"        for (x = 0; x < 1024u; x++) {" + NL +
"            uint32_t c = bg[edge_y * pitch + x];" + NL +
"            for (y = edge_y + 1u; y < SCREEN_HEIGHT; y++) bg[y * pitch + x] = c;" + NL +
"        }" + NL +
"        for (y = 0; y < SCREEN_HEIGHT; y++) {" + NL +
"            uint32_t c = bg[y * pitch + edge_x];" + NL +
"            volatile uint32_t *row = bg + y * pitch;" + NL +
"            for (x = edge_x + 1u; x < SCREEN_WIDTH; x++) row[x] = c;" + NL +
"        }")

ob, nb = old.encode("utf-8"), new.encode("utf-8")
n = data.count(ob)
if n != 1:
    print("FAIL: %d matches" % n); sys.exit(1)
data = data.replace(ob, nb, 1)
open(P, "wb").write(data)
print("OK  bottom strip now painted before the right strip : %d bytes" % len(data))
