# -*- coding: utf-8 -*-
import io, os

MD = """# 分辨率适配 · 总任务书（Ti60 2D 图形加速器 → 1366×768 原生版）

> 接手前**先读完本文档**，再读工程根目录的 `分辨率优化.md`（§12 是 1366 这一轮的完整记录）。
> 本任务**全部在笔记本上完成**开发、测试与 BUG 修复，不依赖上板；最后只上板验收一次。
> **允许跑仿真**，而且仿真就是主要验证手段。

---

## 0. 一句话目标

把 `E:\\FPGA\\Ti60_2D_Graphics_Accelerator` 从「1024×600 时代的素材硬塞进 1366×768 画布」
重构为**真正的 1366×768 原生版**，并在此之上完成**压力测试、性能优化、游戏性与美术 UI 全面升级**。
**目标：竞赛国一水平的作品。**

---

## 1. 最终验收标准（用户只做这三件事）

1. **看到完整铺满的画面** —— 1366×768 内**没有任何纯色补边**、没有靠拉伸凑数的区域，游戏画面是主体
2. **正常游玩** —— 关卡、菜单、操作、特效全部跑通，无卡顿、无撕裂、无残留
3. **明显更华丽** —— 视觉效果、UI 排版、菜单演出优于现在的版本

**达不到这三条 = 没做完。**

---

## 2. 工程概览

- 平台：Efinix **Ti60F225**（Titanium / I3）
- 处理器：**Sapphire RV32I** @100 MHz（`ip/soc/settings.json`：**MULDIV_EXT=0、BARREL_SHIFTER=0**）
- 自研 **BitBlt 2D 加速器**（`rtl/bitblt/`，APB 从机 + AXI4 读写主）
- **VDMA** 扫描输出（`rtl/v_dma/`）→ DVI/HDMI 编码
- 应用：东方风格弹幕游戏（`sw/app/main.c`，约 4000 行）
- 构建：`build_hw.bat`（重建固件 → map → interface → pnr → pgm → `outflow\\ti60_top.bit`）
- 仿真：`python simulator\\test_runner.py --list | --group <名> | --only <id> --export-images`
- 仿真用 **Python 行为级 VM**（`simulator/rv32i_soc_vm.py`），不跑 RTL 仿真

---

## 3. 硬参数（**已验证，不要推翻**）

| 项 | 值 |
|---|---|
| pixel clock | **85.714 MHz** |
| PLL `pll_hdmi`(PLL_BR0) | `FB out_divider=120`、`hdmi_tx_slow_clk=35`、`hdmi_tx_fast_clk=7`，**VCO = 3000 MHz** |
| 时序 H | 1366 / 70 / 143 / 213 / **1792** |
| 时序 V | 768 / 3 / 3 / 24 / **798** |
| 刷新率 | 59.94 Hz（一帧 = 1,429,616 像素周期 = **16.68 ms**） |
| `SCREEN_WIDTH / HEIGHT / STRIDE` | **1366 / 768 / 8192** |
| 帧缓冲 | 768 × 8192 = **0x600000**；`FB0=0x00800000`、`FB1=0x00E00000`；翻转 `^= 0x00600000` |
| VDMA 半屏分界 | `HALF_OFFSET = 2560 B = 640 px`（**必须** burst 对齐，改布局时守住这条） |
| 每行 word 预算 | 扫一行 = **342 个 128-bit word**；VDMA 读 21×16-beat + 1×6-beat burst |
| 地址上限 | AXI **28 位**，DDR 用到 `0x03E00000`（62 MB / 板载 256 MB） |
| 固件 BRAM | **64512 字节**，当前用 **63920**，**余量仅 592 字节** ⚠️ 最大障碍 |

**PLL 出不来 148.5 MHz**：3000 ÷ 148.5 = 20.2 非整数；最近 3000÷20 = 150 MHz 偏 **+1%**，
超出 HDMI ±0.5% 容差。**所以 1920×1080 输出不可行，别往这个方向设计。**

---

## 4. 当前布局 → 目标布局

**现在（问题所在）：**

```
x:  0 ─── 127 │ 128 ─────────── 767 │ 768 ─────────────── 1365
   左 HUD 栏  │   playfield 640 宽  │   右 HUD 栏 598 宽
              │  （游戏画面）        │  （底板右栏 + 纯色补边）
```

- playfield = `[GAME_LEFT=128, GAME_RIGHT=768) × [4, 600)` = **640×600**
- 游戏画面仅占 **46.9% 宽 / 78.1% 高**；playfield 中心 x=448，屏幕中心 x=683 → 严重偏左
- `x≥1024`、`y≥600` 目前靠「沿底板边缘像素延续」的**纯色**填充

**目标（自行设计，推荐方向）：**

- playfield **居中**并尽量加宽，让游戏画面成为绝对主体
- HUD 栏相应变窄；或采用东方正作那样的「上下结构」
- **整个 1366×768 都由真实图案构成，无纯色补边**

**改布局时必须全局同步的地方**（改一处就要 grep 一遍）：
- `GAME_LEFT` / `GAME_RIGHT` / `PLAYFIELD_TOP` / `PLAYFIELD_BOTTOM`
- `HUD_BOXES` 宏（`main.c` 里所有 HUD 元素的 x/y/w/h）
- `tools/build_visual_assets.py`（**烘焙标签的坐标**）
- `tools/check_hud_layout.py`（校验框）
- `simulator/test_runner.py`（**它复制了** `memory_map.h` 和布局的一部分常量）

---

## 5. 素材现状与重构范围

| 素材 | 现状 | 生成器 |
|---|---|---|
| 底板 backdrop | 源图 **512×300** → ×2 = **1024×600** | `tools/build_visual_assets.py` |
| 舞台底板 ×3（dream/ice/lava） | **640×600** | `tools/build_stage_backgrounds.py` |
| 视差条（cloud_a/b、snow、ember） | **128×600** | 同上 |
| 立绘 / 精灵 / 弹幕 | 各种小图 | `tools/build_visual_assets.py` |
| 源图 | `assets/source/`（Kenney UI、fumoreimu 立绘等） | 版权见 `assets/SOURCES.md` |
| 处理产物 | `assets/processed/*.png` | 生成器输出 |

**⚠️ 底板里烘焙了 16 个 HUD 标签**（PLAYER / LIVES / SCORE / SHOT TYPE / POWER /
REIMU HAKUREI / RENDER BACKEND / B SETTINGS …）。它们是**像素不是文字**，由
`build_visual_assets.py` 用 `d.textbbox()` 取源图坐标、×2 后写进底板位图，
并输出 `hud_labels.json` 给 `check_hud_layout.py` 校验。
**动 playfield = 动标签 = 底板必须重做。**

**源图不够大就重新找网图**（放进 `assets/source/`，更新 `SOURCES.md`）；
也可以**程序化生成**（§11.2 已有把 `rle_stage_lava` 2471 B 改成程序化派生的先例）。

---

## 6. 固件空间（**最大的技术障碍，必须先解决**）

**现在只剩 592 字节。** 底板从 1024×600 涨到 1366×768 是 **1.71 倍面积**；
若 RLE 按面积线性增长，底板会从 8030 B 涨到约 13700 B —— **远超预算**。

可行方向（自行组合评估）：
- **优化 RLE 编码器**（更多调色板位、更长的 run 逃逸、抖动/量化）
- **程序化派生**：大块平坦区域改成代码画，不存像素（§11.2 有先例）
- **降低颜色数**（像素画通常能压到 16 色以内）
- **小源图 + 运行期放大**
- **重新评估：哪些素材真的需要进固件**

**每改一次看 `build_hw.bat` 的 `linked image ends at 0x... (N bytes of 64512 usable)` 判断余量。**

---

## 7. 性能与容量预算（压力测试的基准）

| 资源 | 数值 | 含义 |
|---|---|---|
| 一帧时间 | **16.68 ms** @ 85.714 MHz | 硬实时，超了会撕裂 |
| CPU 每帧周期 | **1,668,000** @ 100 MHz | 实测固件只用 **~25,000 步/帧**，**余量巨大** |
| CPU 乘法 | **软件循环**（`__mulsi3`，约 41 条指令） | 主循环里**别写 `*`** |
| VDMA 读带宽 | **~252 MB/s**（768×5472 B×59.94） | 必须优先保障 |
| BitBlt 满屏 COPY | **262,656 write beats / 263,424 read beats** | 理想 ≥2.6 ms，含 DDR 延迟实际 5–15 ms |
| DDR 带宽 | 自行实测（`ddr3_parameter.vh`） | 所有者的总和不能超 |

**因此：一帧内做不了很多次全屏 COPY。** BitBlt 的每一次调用都要算进预算 ——
「650 个对象 = ~700 条命令」这种量级必须先量吞吐再定方案。

---

## 8. 初始菜单重设计（**要求做成东方正作排版**）

参照《东方红魔乡》《东方妖妖梦》《东方永夜抄》的标题画面：

- **顶部**：大号游戏标题（东方系惯用「東方○○○ ～ subtitle.」的格式），带轻微呼吸/位移动画
- **中部**：主菜单项**竖排**（Start / Extra Start / Practice / Replay / Music Room / Option / Quit）
- **选中项**：右侧或左侧有一个**小箭头标记 + 文字变色**（东方系惯用黄色/白色高亮）
- **底部**：版权行 + 版本号（小字）
- **背景**：**滚动/动画**的图案（弹幕纹样、星空、或标题插画），不能是静止纯色
- **侧边**：可放一张立绘/剪影

**注意**：菜单是**每帧全屏重绘**的（现在靠一次整屏 COPY + 若干 fill），
重设计后要注意别把每帧的 BitBlt 预算吃光 —— 用「预渲染到离屏 buffer + 一次 COPY」的方式。

---

## 9. 压力测试要求（理论推演 + 仿真实测，两者都要）

1. **弹幕 sprite 压力**：算出「同屏最多能有多少个 sprite/子弹」的上限，
   分别按 **BitBlt 吞吐**、**DDR 带宽**、**CPU 指令预算**三条约束推导，
   写成表格给数字；再用仿真验证极限场景不撕裂、不掉帧
2. **最坏帧分析**：找出游戏里最重的一帧（boss 弹幕 + 特效 + HUD 全开 + 窗口切换），
   列出该帧的所有 blit/fill 及其 cost，证明总和 < 16.68 ms
3. **仿真跑极限场景**：构造超量弹幕场景跑通，记录实际表现

---

## 10. 环境坑（**真实踩过，能省几小时**）

1. **新会话第一次工具调用可能报错**（spawn ENOENT 之类）—— 重试同一命令即可
2. **E 盘是 exFAT，`write` / `edit` 工具在这块盘上不可用**
   → 一律用 `pwsh` 调 Python 脚本落地；改既有文件用「断言原文只出现一次」的精确替换，
   且**每个替换后立刻落盘**（脚本最后才 write 的话，中途抛异常会整批丢失）
3. **换行风格每个文件不同**，用错会静默匹配失败：
   - **CRLF**：`sw/app/main.c`、`simulator/test_runner.py`、`sw/driver/memory_map.h`
   - **LF**：`simulator/rv32i_soc_vm.py`、`rtl/v_dma/video_dma_read.v`、`tools/*.py`、`分辨率优化.md`
   - 改之前先读二进制数 `\\r\\n`
4. **Python 正则处理 bytes 要统一**：`re.findall(str_pattern, bytes_data)` 抛 `TypeError`；
   pattern 要 `.encode()`，`re.sub` 的 repl 用 `lambda m: nb`
5. **改 `rtl/v_dma/video_dma_read.v` 的参数块**：参数列表末尾必须有逗号，
   替换行数数错会把后面的 `parameter` 吃掉（综合报 `syntax error near 'parameter'`）
6. **改任何文件前先备份进 `backups\\`**（工程**没有 git**），命名：`原名_before_<改动>_<日期>.ext`
7. **改完源码必须先重编译固件再跑仿真**（`sw\\build_firmware.bat`），
   否则 VM 会用**缓存 snapshot** 跑旧固件 —— 验证结果完全失真
8. **`build_hw.bat` 内部会先重建固件**，改完 C 代码直接跑它即可

---

## 11. 验证手段

1. **`build_hw.bat`** —— 全流程 PASS，时序报告 **0 违规**，固件**不溢出**
2. **`simulator/test_runner.py`** —— 24 场景全过（先读 `simulator/README.md`）
3. **导出 PNG 直接看图**：
   `python simulator\\test_runner.py --only backdrops --export-images` → `simulator\\output\\*.png`
4. **`tools/dump_backdrop.py`** —— dump VM 里 `MM_VISUAL_BACKGROUND` 的像素，
   确认底板到底写进了什么（这个工具抓到过两个真 bug）
5. **`tools/scan_widths.py`** —— 扫描全工程 sized literal 位宽截断
6. **`tools/sim_vdma_gearbox.py`** —— VDMA 逐周期对齐模型（查「每行 word 预算」是否配平）

---

## 12. 已修好的 bug（**不要重新踩，也不要推翻**）

1. **VDMA `ROW_STRIDE` 位宽截断**：`13'd8192` 是 2^13，放不进 13 位 → **静默截断成 0** → 每行读同一块。
   已改 **14 位**。
   > 教训：**sized literal 的截断发生在解析期，综合器连警告都不报**（535 条警告里一条都没指向它）。
   > 必须用脚本机械扫描所有 `N'd...`，不能靠眼睛看加法。
2. **VDMA 每行「读入」与「消费」的 word 数不等**：1366 px = 5464 B = **341.5 word**
   （1024→256、1280→320 都是整数，1366 不是）。修法**两处必须同时改**：
   - 尾 burst 截短（`m_axi_arlen = last_burst ? TAIL_BEATS-1 : 15`），1366 下是 **6 beat**
   - pop 阈值 `h_cnt < H_ACT-4` → **`H_ACT-2`**
   > 这类 bug **没有计数器越界**，错的是两个数字之间的**等式**，只能靠逐周期模型验证。
3. **BitBlt 累计 beat 计数器**扩到 **19 位**
4. **`main.c` 半屏渲染宽度** `512`（=1024/2）→ `SCAN_HALF_PIXELS=640` / `SCAN_RIGHT_PIXELS=726`
5. **底板解码目标地址漂移**：`build_visual_assets.py` 硬编码 `0x01640000`，
   而 `MM_VISUAL_BACKGROUND` 是 `0x03800000` → 写到 A 地址、从 B 地址读。
   已改成**从 `memory_map.h` 读取**（`mm_const()`），顺带修掉解码 stride 退化（`512*2*4=4096`）
6. **VDMA gearbox 欠载相位错位**：FIFO 空时 `word_fetch` 拒绝 pop 但 `sub_pix_cnt` 照走 → 整行错位 4 px。
   已改为**欠载时冻结相位**
7. **底板补边循环顺序**：右侧带逐行读 `x=1023`，必须**先**让下方带填好 `y≥600`，否则下半截是黑的

---

## 13. 显示器事实（影响设计决策）

- 显示器是 **1:1 点对点**，**不缩放**
- OSD「画面比例」只有 **宽屏 / 4:3**，**没有「全屏/拉伸」档**
- 原因：1366×768 的宽高比（1.779）≈ 16:9 面板 → 被当"原生模式"直接点对点；
  1024×600（1.707）宽高比不匹配才会被缩放铺满
- **所以本次只针对画面内容做重构，不要试图影响显示器行为**

---

## 14. 交付要求

1. 画面**真正铺满** 1366×768，无纯色补边、无拉伸凑数
2. `build_hw.bat` 全流程 **PASS**，时序 **0 违规**，固件**不溢出**
3. **24 个仿真场景全过**
4. 导出关键 PNG 自查，确认构图合理
5. 压力测试给**数字**（表格形式）
6. 更新 `分辨率优化.md`：新增一节记录本轮方案、踩坑、实测数字
7. 回报：改了什么 / 为什么这么设计 / 怎么验证的 / 仍需上板确认的部分

**放手去做，遇到取舍自行决定并记录理由。**
"""

P = r"E:\FPGA\Ti60_2D_Graphics_Accelerator\分辨率适配.提示词.md"
with io.open(P, "w", encoding="utf-8", newline="\n") as f:
    f.write(MD)
print("written: %s" % P)
print("bytes  : %d" % os.path.getsize(P))
print("lines  : %d" % MD.count("\n"))
