import re, sys

P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\分辨率优化.md"
with open(P, "rb") as f:
    data = f.read()
print("markdown: CRLF=%d LF=%d" % (data.count(b"\r\n"), data.count(b"\n")))
orig_len = len(data)

def patch(data, pattern_str, new, tag):
    pattern = pattern_str.encode("utf-8")
    hits = re.findall(pattern, data, re.M)
    if len(hits) != 1:
        print("FAIL %-30s : %d matches (expected 1)" % (tag, len(hits)))
        sys.exit(1)
    nb = new.encode("utf-8")
    data = re.sub(pattern, lambda m: nb, data, count=1, flags=re.M)
    with open(P, "wb") as f:
        f.write(data)
    print("OK   %-30s : %d bytes on disk" % (tag, len(data)))
    return data

NEW_SECTION = """### 12.6d 第三处位宽溢出：VDMA 的 `ROW_STRIDE` 被截断成 0（整屏花屏的最终根因）

**现象**：修完 §12.6c 的两处后重新出比特流上板 —— 显示器锁定、画面不闪，但**整屏彩色错乱条纹**，无可辨认画面。

**根因**：`rtl/v_dma/video_dma_read.v` 的 `localparam [12:0] ROW_STRIDE = 13'd8192;`

1366 这一轮把帧缓冲行距定成了 **8192 字节**，而 8192 = 2^13，**13 位无符号数的上限是 8191**。
`13'd8192` 被 Verilog **静默截断成 0**（8192 mod 8192 = 0），于是

```
row_addr <= last_burst ? (row_addr + ROW_STRIDE) : row_addr;   // ROW_STRIDE == 0
```

`row_addr` 永远停在 0，**每一行的 22 个 burst 都从同一个地址读**：

| | 每行读的地址 | 768 行的 `row_addr` 取值个数 |
|---|---|---|
| 修复前 | `base + 0 + col_off`（col_off = 0, 256, ..., 5376） | **1**（全是 0） |
| 修复后 | `base + n*8192 + col_off` | **768**（0, 8192, ..., 6283264） |

一帧仍然读满 `TOTAL_BURSTS = 16896` 个 burst，所以 FIFO 不断流、扫描时序正常、屏幕不抖 ——
但读回来的永远是同一段 5632 字节，**屏幕 768 行全是同一份数据**。这就是"整屏花屏线条"。

> **为什么前两次没暴露**：1024x600 的行距是 4096、1280x720 是 5120，都 **< 8192**，13 位放得下。
> 只有 1366 这一轮把行距推到 8192（= 2^13），正好越过 13 位的悬崖。这与 §12.6c 的两处是同一个剧本。

**修法**：`localparam [13:0] ROW_STRIDE = 14'd8192;`
—— **声明宽度和字面量宽度必须一起改**，只改一个没用：字面量自己会先被截断。
同时顺手修掉了紧邻两段已经过时的注释（还写着行距 5472、"32 bursts' worth of row"）。

**这一类错误的查法（可复用）**：把全工程所有 sized literal 按 `值 >= 2^宽度` **机械扫一遍**，
不要只盯着加法看 —— 本例里 `row_addr + ROW_STRIDE` 的上下文宽度是对的（28 位），
**错的是常量自己在上游就已经没值了**。本次全工程扫描结论：**唯一的字面量溢出就是这一处**；
其余 `rtl/v_dma` 与 `rtl/bitblt` 的每个计数器（15/19 位 burst 与 beat 累加器、9 位 per-row burst、
13 位 `col_off`/`row_bytes`、26 位看门狗、11 位 `fifo_wusedw`）按 1366x768 实算都在范围内。
**上板确认点**：帧率是否回到 60 FPS（行距 8192 让每次跨行跳跃变大，DDR 行局部性略降）。

---

"""

data = patch(data, "^### 12\\.6 执行顺序$", NEW_SECTION + "### 12.6 执行顺序", "insert 12.6d")

data = patch(
    data,
    "^\\| 一帧 \\| 768 x 5472 = \\*\\*0x401A00\\*\\* \\| 4,202,496 B \\|$",
    "| 一帧 | 768 x 8192 = **0x600000** | 6,291,456 B（行距 8192，不是 5472 —— 见下） |",
    "fix 12.2 frame size",
)
print("growth: %d -> %d bytes" % (orig_len, len(data)))
