import re, sys

P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\rtl\v_dma\video_dma_read.v"
with open(P, "rb") as f:
    data = f.read()
print("line endings before: CRLF=%d  LF=%d  -> %s" % (data.count(b"\r\n"), data.count(b"\n"), "CRLF" if data.count(b"\r\n") else "LF"))

def patch(data, pattern, new, tag):
    hits = re.findall(pattern, data, re.M)
    if len(hits) != 1:
        print("FAIL %-28s : %d matches (expected exactly 1)" % (tag, len(hits)))
        sys.exit(1)
    nb = new.encode("utf-8")
    data = re.sub(pattern, lambda m: nb, data, count=1, flags=re.M)
    with open(P, "wb") as f:          # flush to disk immediately after EVERY patch
        f.write(data)
    print("OK   %-28s : %d bytes now on disk" % (tag, len(data)))
    return data

# ---- 1. THE FIX: ROW_STRIDE needs 14 bits (8192 == 2^13 does not fit in 13) ----
data = patch(
    data,
    rb"^    localparam \[12:0\] ROW_STRIDE[^\r\n]*$",
    "    // 14 BITS, NOT 13.  The pitch is 8192 B = 2^13, and a 13-bit literal is\n"
    "    // silently truncated to 0: row_addr then never advances, every scan line\n"
    "    // re-reads row 0, and all 768 lines of the screen show the same 5632\n"
    "    // bytes.  The 1024x600 pitch (4096) and the 1280x720 pitch (5120) both\n"
    "    // fitted in 13 bits - which is exactly why this only appeared at 1366x768.\n"
    "    // INVARIANT: ROW_STRIDE >= H_ACT*4 and ROW_STRIDE is a multiple of 16.\n"
    "    localparam [13:0] ROW_STRIDE     = 14'd8192;            // framebuffer row pitch (bytes)",
    "ROW_STRIDE width 13 -> 14",
)

# ---- 2. stale comment: pitch is 8192, not 5472 ----
data = patch(
    data,
    rb"^    // framebuffer row pitch is 5472 B \(1368 px\) because BitBlt rejects any stride$",
    "    // framebuffer row pitch is 8192 B (a power of two, so the firmware's\n"
    "    // y * SCREEN_STRIDE stays a shift) because BitBlt rejects any stride",
    "stale 5472 comment",
)

# ---- 3. stale comment: a row is 22 bursts, not 32 ----
data = patch(
    data,
    rb"^    // 32 bursts' worth of row at an 8192 B pitch: 21 x 256 B = 5376 B of real\n"
    rb"    // that runs 168 B past the end of the row\.  Those bytes are read and dropped;\n"
    rb"    // the framebuffer has to tolerate the read at the very last line, which the\n"
    rb"    // DDR layout in section 12\.4 of the plan accounts for\.$",
    "    // A row is 22 bursts: 21 x 256 B = 5376 B of real pixels (a scan line is\n"
    "    // 5464 B) plus one 6-beat tail burst that runs 168 B past the end of the\n"
    "    // row.  Those bytes are read and dropped; the framebuffer has to tolerate\n"
    "    // the read at the very last line, which the DDR layout accounts for.",
    "stale 32-burst comment",
)

with open(P, "rb") as f:
    chk = f.read()
print("line endings after : CRLF=%d  LF=%d" % (chk.count(b"\r\n"), chk.count(b"\n")))
