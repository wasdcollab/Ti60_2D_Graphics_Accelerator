import re, sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\分辨率优化.md"
with open(P, "rb") as f:
    data = f.read()

old = "13 位 `col_off`/`row_bytes`、26 位看门狗、11 位 `fifo_wusedw`）按 1366x768 实算都在范围内。"
hits = re.findall(old.encode("utf-8"), data)
if len(hits) != 1:
    print("FAIL: %d matches" % len(hits)); sys.exit(1)

new = old + """

**综合器不会帮你抓这个**：Efinity 对 sized literal 的截断是**静默**的 —— 本次 map 日志里 535 条警告
没有一条指向它（只有"表达式宽度截断"才报 `VERI-1209`）。所以"翻综合警告"这条路没有用，
**只能对字面量做机械扫描**。

顺带记录（本次一并核对）：map 日志里自有 RTL 的 3 条 `VERI-1209` 都是**既有的、值域已被证明安全**的 ——
`bitblt_stride_gen.v:291` 的 `row_bytes`（1366 宽下最大 5479 < 8192，13 位够，且 APB 白名单拦更大尺寸）、
`bitblt_alpha_blend.v:88` 的 `t`（最大 65407 < 2^16）、`hdmi/encode.v:167`（TMDS 模板，与分辨率无关）。"""
data = data.replace(old.encode("utf-8"), new.encode("utf-8"), 1)
with open(P, "wb") as f:
    f.write(data)
print("OK  doc note appended: %d bytes on disk" % len(data))

# safety re-check of the three VERI-1209 sites against the 1366x768 numbers
print()
print("=== VERI-1209 site safety check (1366x768) ===")
row_bytes = 15 + 4 * 1366
print("  stride_gen row_bytes  = 15 + 4*1366 = %d   13-bit max 8191 -> %s (margin %d)"
      % (row_bytes, row_bytes <= 8191, 8191 - row_bytes))
print("                        APB whitelist rejects rect_w > 1366, so 8191 can never be reached")
t_max = 65152 + 1 + (65152 >> 8)
print("  alpha_blend t         = 65152 + 1 + 254 = %d   18-bit reg, true value < 2^16 -> safe" % t_max)
print("  encode.v:167          TMDS template, no resolution dependence -> unchanged")
print()
print("=== and the one that DID matter, for contrast ===")
print("  video_dma_read ROW_STRIDE: 13'd8192 -> 0  (sized literal, truncated at PARSE time,")
print("                             which is why map reported no warning about it)")
