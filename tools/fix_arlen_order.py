import re, sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\rtl\v_dma\video_dma_read.v"
data = open(P, "rb").read()

def patch(data, pattern, new, tag):
    pb = pattern.encode("utf-8")
    hits = re.findall(pb, data, re.M)
    if len(hits) != 1:
        print("FAIL %-26s : %d matches" % (tag, len(hits))); sys.exit(1)
    data = re.sub(pb, lambda m: new.encode("utf-8"), data, count=1, flags=re.M)
    open(P, "wb").write(data)
    print("OK   %-26s : %d bytes" % (tag, len(data)))
    return data

# 1) remove the forward reference: last_burst is declared ~170 lines further down,
#    so referencing it here would create an implicit 1-bit net AND a duplicate decl.
data = patch(
    data,
    "^    // The tail burst of a row is TRIMMED[\\s\\S]*?^    assign m_axi_arlen[^\\r\\n]*\\n",
    "    // m_axi_arlen is driven further down, next to last_burst - it depends on the\n"
    "    // per-row burst index, which is declared together with the read state machine.\n",
    "drop forward reference",
)

# 2) put it where every identifier it uses is already declared
data = patch(
    data,
    "^    wire \\[27:0\\] next_row   = last_burst \\? \\(row_addr \\+ ROW_STRIDE\\) : row_addr;$",
    "    wire [27:0] next_row   = last_burst ? (row_addr + ROW_STRIDE) : row_addr;\n"
    "\n"
    "    // The tail burst of a row is TRIMMED to the beats the line really needs.\n"
    "    // Reading all 22 bursts full would deliver 352 words for a line that pops\n"
    "    // 342: the 10 extra words are never consumed by the pixel gearbox, so they\n"
    "    // stay in the FIFO and push every following row 10 words (40 px) sideways -\n"
    "    // an error that accumulates down the screen as diagonal garbage.  Reading\n"
    "    // exactly WORDS_PER_ROW keeps READ == CONSUME, and that equality is what\n"
    "    // makes row N of the framebuffer land on row N of the screen.\n"
    "    assign m_axi_arlen   = last_burst ? (TAIL_BEATS[7:0] - 8'd1) : 8'd15;",
    "place after last_burst",
)
print()
for n, line in enumerate(open(P, encoding="utf-8").read().splitlines(), 1):
    if "m_axi_arlen" in line or "last_burst" in line or "WORDS_PER_ROW" in line or "TAIL_BEATS" in line:
        print("  %4d  %s" % (n, line.rstrip()))
