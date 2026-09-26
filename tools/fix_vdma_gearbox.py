import re, sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\rtl\v_dma\video_dma_read.v"
data = open(P, "rb").read()
print("CRLF=%d LF=%d  (%d bytes)" % (data.count(b"\r\n"), data.count(b"\n"), len(data)))

def patch(data, pattern, new, tag):
    pb = pattern.encode("utf-8")
    hits = re.findall(pb, data, re.M)
    if len(hits) != 1:
        print("FAIL %-26s : %d matches" % (tag, len(hits))); sys.exit(1)
    nb = new.encode("utf-8")
    data = re.sub(pb, lambda m: nb, data, count=1, flags=re.M)
    open(P, "wb").write(data)
    print("OK   %-26s : %d bytes" % (tag, len(data)))
    return data

# ===== FIX 1: declare the two line-budget constants ==========================
data = patch(
    data,
    "^    localparam \\[14:0\\] TOTAL_BURSTS[^\\r\\n]*$",
    "    localparam [14:0] TOTAL_BURSTS   = 15'd16896;           // 22 * 768\n"
    "    // Word budget of ONE scan line, and what the tail burst must deliver.\n"
    "    // 1366 px = 5464 B = 341.5 x 128-bit words, so a line needs 342 words,\n"
    "    // while the first 21 full bursts only supply 336 - hence a 6-beat tail.\n"
    "    // 1024 -> 256 and 1280 -> 320 are exact multiples of 16, so for those the\n"
    "    // tail evaluates to a full 16-beat burst and nothing changes.\n"
    "    // INVARIANT: WORDS_PER_ROW must equal the pops word_fetch performs per\n"
    "    // line (see the pop threshold below), and the tail must be 1..16 beats.\n"
    "    localparam [8:0]  WORDS_PER_ROW  = (H_ACT + 3) / 4;                    // 1366 -> 342\n"
    "    localparam [8:0]  TAIL_BEATS     = WORDS_PER_ROW -\n"
    "                                       (BURSTS_PER_ROW - 5'd1) * 9'd16;    // 1366 -> 6",
    "line-budget localparams",
)

# ===== FIX 2: trim the tail burst of every row ==============================
data = patch(
    data,
    "^    assign m_axi_arlen[^\\r\\n]*$",
    "    // The tail burst of a row is TRIMMED to the beats the line really needs.\n"
    "    // Reading all 22 bursts full would deliver 352 words for a line that pops\n"
    "    // 342: the 10 extra words are never consumed by the pixel gearbox, so they\n"
    "    // stay in the FIFO and push every following row 10 words (40 px) sideways -\n"
    "    // an error that accumulates down the screen as diagonal garbage.  Reading\n"
    "    // exactly WORDS_PER_ROW keeps READ == CONSUME.\n"
    "    assign m_axi_arlen   = last_burst ? (TAIL_BEATS[7:0] - 8'd1) : 8'd15;",
    "m_axi_arlen tail trim",
)

# ===== FIX 3: pop one more word per line ====================================
data = patch(
    data,
    "^    // During an active line \\(t_de\\) the pops stop four pixels early[^\\r\\n]*\\n"
    "^    // \\(partially consumed\\) word is picked up by the next line's prefetch\\.$",
    "    // The pop threshold decides how many words a scan line CONSUMES, and it has\n"
    "    // to equal the words that row read DELIVERS (WORDS_PER_ROW).  A line of\n"
    "    // H_ACT pixels spans ceil(H_ACT/4) words: 1024 -> 256 and 1280 -> 320 are\n"
    "    // whole numbers, but 1366 needs 342 while stopping at H_ACT-4 pops only 341.\n"
    "    // One short word per line is invisible on its own - but it accumulates into\n"
    "    // a per-row skew, which is exactly what the 1366 screen showed.\n"
    "    wire word_fetch    = (sub_pix_cnt == 2'd2) && (h_cnt < H_ACT - 2) && t_de && !fifo_rempty;",
    "word_fetch threshold",
)
