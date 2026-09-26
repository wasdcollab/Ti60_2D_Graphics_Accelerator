import re, sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\sw\app\main.c"
data = open(P, "rb").read()
crlf = data.count(b"\r\n") > 0
print("main.c line endings: %s (%d bytes)" % ("CRLF" if crlf else "LF", len(data)))
NL = "\r\n" if crlf else "\n"

# ---- the same arithmetic the VDMA uses, recomputed here ----
HALF_BYTES  = 2560                 # VDMA HALF_OFFSET
HALF_PIXELS = HALF_BYTES // 4      # 640
SCREEN_W    = 1366
print()
print("VDMA half split : %d B = %d px" % (HALF_BYTES, HALF_PIXELS))
print("code paints     : left 0..%d, right %d..%d" % (512 - 1, HALF_PIXELS, HALF_PIXELS + 512 - 1))
print("NEVER PAINTED   : x %d..%d  (%d px)  and  x %d..%d  (%d px)"
      % (512, HALF_PIXELS - 1, HALF_PIXELS - 512,
         HALF_PIXELS + 512, SCREEN_W - 1, SCREEN_W - HALF_PIXELS - 512))
print()

def patch(data, old, new, tag):
    ob, nb = old.encode("utf-8"), new.encode("utf-8")
    n = data.count(ob)
    if n != 1:
        print("FAIL %-34s : %d matches" % (tag, n)); sys.exit(1)
    data = data.replace(ob, nb, 1)
    open(P, "wb").write(data)
    print("OK   %-34s : %d bytes" % (tag, len(data)))
    return data

# ---- 1. name the two halves so they cannot drift apart again ----
data = patch(
    data,
    "#define GAME_LEFT       128",
    "/* The scanout is split at the VDMA HALF_OFFSET (2560 B = 640 px): everything" + NL +
    " * left of it is scanned from the left buffer, everything right of it from the" + NL +
    " * right buffer.  A renderer that only covers part of its own half leaves the" + NL +
    " * rest of that half showing the PREVIOUS frame, which is what the two garbage" + NL +
    " * strips down the sides of the 1366x768 screen were.  These two must always" + NL +
    " * add up to SCREEN_WIDTH. */" + NL +
    "#define SCAN_HALF_PIXELS   640u" + NL +
    "#define SCAN_RIGHT_PIXELS  (SCREEN_WIDTH - SCAN_HALF_PIXELS)" + NL +
    "#define GAME_LEFT       128",
    "add SCAN_HALF_PIXELS",
)

# ---- 2. the right half was cleared 512 wide instead of SCAN_RIGHT_PIXELS ----
data = patch(
    data,
    "            gpu2d_fill(right_back + 2560, 512, SCREEN_HEIGHT, 0x00000000u, SCREEN_STRIDE);",
    "            gpu2d_fill(right_back + 2560, SCAN_RIGHT_PIXELS, SCREEN_HEIGHT, 0x00000000u, SCREEN_STRIDE);",
    "right-half clear width",
)

# ---- 3. the left half was cleared 512 wide instead of SCAN_HALF_PIXELS ----
data = patch(
    data,
    "                cpu_software_fill(left_back, 0, 0, 512, SCREEN_HEIGHT / 2u, 0x00000000u);",
    "                cpu_software_fill(left_back, 0, 0, SCAN_HALF_PIXELS, SCREEN_HEIGHT / 2u, 0x00000000u);",
    "left-half clear (top)",
)
data = patch(
    data,
    "                cpu_software_fill(left_back, 0, SCREEN_HEIGHT / 2u, 512, SCREEN_HEIGHT / 2u, 0x00000000u);",
    "                cpu_software_fill(left_back, 0, SCREEN_HEIGHT / 2u, SCAN_HALF_PIXELS, SCREEN_HEIGHT / 2u, 0x00000000u);",
    "left-half clear (bottom)",
)
