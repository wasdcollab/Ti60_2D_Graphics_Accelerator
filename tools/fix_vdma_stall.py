import re, sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\rtl\v_dma\video_dma_read.v"
data = open(P, "rb").read()

def patch(data, pattern, new, tag):
    pb = pattern.encode("utf-8")
    hits = re.findall(pb, data, re.M)
    if len(hits) != 1:
        print("FAIL %-28s : %d matches" % (tag, len(hits))); sys.exit(1)
    data = re.sub(pb, lambda m: new.encode("utf-8"), data, count=1, flags=re.M)
    open(P, "wb").write(data)
    print("OK   %-28s : %d bytes" % (tag, len(data)))
    return data

# ---- 1. the defect: an empty FIFO advances the phase and shifts the whole line
data = patch(
    data,
    "^    assign fifo_rinc   = line_prefetch \\|\\| word_fetch;$",
    "    // An underrun must FREEZE the pixel phase, not let it run on.  word_fetch\n"
    "    // already refuses to pop when the FIFO is empty, but sub_pix_cnt kept\n"
    "    // counting, so at sub==3 cur_word latched the STALE head and from that pixel\n"
    "    // on the whole scan line was displaced by one word (4 px).  A displacement\n"
    "    // that small is invisible on the menu's large glyphs and destroys the\n"
    "    // backdrop's fine striping - \"the menu is fine, the sides are garbage\".\n"
    "    wire word_stall    = (sub_pix_cnt == 2'd2) && (h_cnt < H_ACT - 2) && t_de && fifo_rempty;\n"
    "    assign fifo_rinc   = line_prefetch || word_fetch;",
    "add word_stall",
)

data = patch(
    data,
    "^            end else if \\(t_de\\) begin\\n"
    "                sub_pix_cnt <= sub_pix_cnt \\+ 2'd1;\\n"
    "\\n"
    "                case \\(sub_pix_cnt\\)\\n"
    "                    2'd0: cur_pixel <= cur_word\\[31:0\\];\\n"
    "                    2'd1: cur_pixel <= cur_word\\[63:32\\];\\n"
    "                    2'd2: cur_pixel <= cur_word\\[95:64\\];\\n"
    "                    2'd3: begin\\n"
    "                        cur_pixel <= cur_word\\[127:96\\];\\n"
    "                        cur_word  <= fifo_rempty \\? 128'd0 : fifo_rdata;\\n"
    "                    end\\n"
    "                endcase\\n"
    "            end else begin$",
    "            end else if (t_de) begin\n"
    "                // Hold the phase while the FIFO cannot feed the next word: the\n"
    "                // current word's remaining lanes are still valid, so repeating a\n"
    "                // pixel for a cycle or two is recoverable, whereas advancing the\n"
    "                // phase is not (it shifts every remaining pixel of the line).\n"
    "                if (!word_stall) begin\n"
    "                    sub_pix_cnt <= sub_pix_cnt + 2'd1;\n"
    "\n"
    "                    case (sub_pix_cnt)\n"
    "                        2'd0: cur_pixel <= cur_word[31:0];\n"
    "                        2'd1: cur_pixel <= cur_word[63:32];\n"
    "                        2'd2: cur_pixel <= cur_word[95:64];\n"
    "                        2'd3: begin\n"
    "                            cur_pixel <= cur_word[127:96];\n"
    "                            cur_word  <= fifo_rempty ? 128'd0 : fifo_rdata;\n"
    "                        end\n"
    "                    endcase\n"
    "                end\n"
    "            end else begin",
    "guard the gearbox",
)

# ---- 2. the underrun counter watched a different window than word_fetch
data = patch(
    data,
    "^                 \\(sub_pix_cnt == 2'd2 && h_cnt < H_ACT - 12'd4 && t_de\\)\\) &&$",
    "                 (sub_pix_cnt == 2'd2 && h_cnt < H_ACT - 12'd2 && t_de)) &&",
    "align underrun window",
)
