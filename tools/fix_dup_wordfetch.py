import re, sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\rtl\v_dma\video_dma_read.v"
data = open(P, "rb").read()

old = "    wire word_fetch    = (sub_pix_cnt == 2'd2) && (h_cnt < H_ACT - 4) && t_de && !fifo_rempty;\n"
n = data.count(old.encode("utf-8"))
print("stale word_fetch lines found: %d" % n)
if n != 1:
    print("FAIL: expected exactly 1"); sys.exit(1)
data = data.replace(old.encode("utf-8"), b"", 1)
open(P, "wb").write(data)
print("OK   removed stale line : %d bytes" % len(data))

# ---- structural sanity: every driver/declaration must appear the right number of times
txt = open(P, encoding="utf-8").read()
print()
print("=== duplicate-declaration check ===")
for name in ("wire word_fetch", "assign m_axi_arlen", "wire [4:0] last_burst",
             "localparam [8:0]  WORDS_PER_ROW", "localparam [8:0]  TAIL_BEATS",
             "localparam [13:0] ROW_STRIDE", "localparam [14:0] TOTAL_BURSTS",
             "localparam [4:0]  BURSTS_PER_ROW"):
    c = txt.count(name)
    print("  %-34s x%d  %s" % (name, c, "OK" if c == 1 else "<-- CHECK"))

print()
print("=== declaration-before-use order (line numbers) ===")
for name in ("localparam [4:0]  BURSTS_PER_ROW", "localparam [8:0]  WORDS_PER_ROW",
             "localparam [8:0]  TAIL_BEATS", "localparam [13:0] ROW_STRIDE",
             "wire [4:0] last_burst", "assign m_axi_arlen", "wire word_fetch"):
    line = next((i for i, l in enumerate(txt.splitlines(), 1) if name in l), None)
    print("  %-34s line %d" % (name, line))
