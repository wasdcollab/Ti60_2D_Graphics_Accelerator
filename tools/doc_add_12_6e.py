import re, sys
P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\分辨率优化.md"
data = open(P, "rb").read()

NEW = """### 12.6e 整屏花屏的真正主因：VDMA 每行「读入」与「消费」的 word 数不相等（2026-09-21 追加）

**现象**：修完 §12.6d 的 `ROW_STRIDE` 后上板，**依旧整屏花屏**（显示器锁定、不闪、画面无可辨认）。

**根因**：`rtl/v_dma/video_dma_read.v` 里**一行从 DDR 读进来多少 128-bit word，必须等于一行从 FIFO pop 出去多少 word**，
而 1366 这个宽度让它们差了 11。

| | 数值 | 出处 |
|---|---|---|
| 一行**需要**的 word | ceil(1366 x 4 / 16) = **342** | 1366 px = 5464 B = **341.5** word |
| 一行**读入**的 word | 22 burst x 16 beat = **352** | `assign m_axi_arlen = 8'd15;`（硬编码 16 beat） |
| 一行**消费**的 word | 1(prefetch) + 340 = **341** | `word_fetch = ... && (h_cnt < H_ACT - 4)` |

**每行净泄漏 11 个 word**（读 352、pop 341）。但它不是"溢出"这么简单，而是**累积错位**：
屏幕第 N 行拿到的数据来自 FIFO 的第 N x 341 个 word，而 DDR 里第 N 行的数据在第 N x 352 个 word 上
—— **每行偏 11 word = 44 像素**，画面于是沿对角线方向错开，看起来就是满屏彩色乱条纹。
（768 行累计 8448 word 灌进 1024 深的 FIFO，还会把读通道反压到满。）

**两处必须同时改，只改任意一处仍然是花屏**（三种组合都实测过）：

1. **尾 burst 要截短**：`m_axi_arlen` 从常量改成
   `last_burst ? (TAIL_BEATS[7:0] - 8'd1) : 8'd15;`，并新增
   `WORDS_PER_ROW = (H_ACT+3)/4`、`TAIL_BEATS = WORDS_PER_ROW - (BURSTS_PER_ROW-1)*16`。
   1366 下尾 burst 是 **6 beat**（21x16 + 6 = 342 ✅）；1024/1280 下算回来仍是 16 beat，**无回归**。
   ⚠️ 这个 assign **必须放在 `last_burst` 声明之后** —— 它现在依赖 `wire [4:0] last_burst`，
   放到文件顶部会变成"隐式 1 位网线 + 重复声明"，综合直接报错。
2. **pop 阈值改一格**：`h_cnt < H_ACT - 4` → **`h_cnt < H_ACT - 2`**。
   1024/1280 是 4 的倍数，两个阈值给出相同的 pop 数；1366 需要多 pop 一个 word。

**为什么前两次没事**（"第三次放大才暴露"的老剧本第四次上演）：

| 宽度 | 一行需要 word | 读入 | pop（旧阈值） | 结果 |
|---|---|---|---|---|
| 1024 | 256 | 256 | 256 | ✅ |
| 1280 | 320 | 320 | 320 | ✅ |
| **1366** | **342** | **352** | **341** | ❌ 每行错位 11 word |

`1024/4 = 256`、`1280/4 = 320` 都是整数，而 **`1366/4 = 341.5` 不是**。
这是 1366 **独有的算术性质** —— 前面三处是"某计数器太小"，这一处**两个计数器本身都合法**。

**怎么验证的（本次唯一有效的手段）**：写了一个**逐周期** Python 模型 `tools/sim_vdma_gearbox.py`，
把 pixel gearbox 的每个寄存器、以及 `async_fifo` 的**同步读延迟**
（`rdata` 是 `rinc` 之后一拍才更新，**不是** first-word-fall-through）全部照搬，
再检查「屏幕像素 (x,y) 是否来自 FIFO 第 `y*WORDS_PER_ROW + x/4` 个 word 的第 `x%4` 条 lane」：

```
CURRENT RTL   pops/line=[341] read/line=352
   row 0: FIRST MISMATCH at x=1364
   row 1: FIRST MISMATCH at x=0  got word 341  want 352
   row 2:                        got word 682  want 704
PROPOSED      pops/line=[342] read/line=342
   row 0..5: OK  (all 1366 pixels come from the right word + lane)
```

这种"每行差一点点"的 bug **算不出来也看不出来，只能逐周期对齐**。
注意 `async_fifo` 不是 FWFT 这一点很关键：gearbox 之所以能work，靠的正是
`word_fetch` 提前一拍拉高 `rinc`，让 `fifo_rdata` 在 `sub_pix_cnt==3` 时正好是新 word。

> **教训（比前面几条更值钱）**：改分辨率时除了问「位宽够不够」，还要问一句 ——
> **「每行读进来的 word 数 == 每行 pop 出去的 word 数 == ceil(H_ACT/4) 吗？」**
> 这三个数在 1024/1280 下天然相等，在 1366 下不等。

---

"""

pb = "^### 12\\.6 执行顺序$".encode("utf-8")
if len(re.findall(pb, data, re.M)) != 1:
    print("FAIL: anchor not unique"); sys.exit(1)
data = re.sub(pb, lambda m: (NEW + "### 12.6 执行顺序").encode("utf-8"), data, count=1, flags=re.M)
open(P, "wb").write(data)
print("OK  inserted 12.6e : %d bytes on disk" % len(data))
