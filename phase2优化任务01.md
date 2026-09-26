# Phase 2 优化与特效增强任务书（任务卡 01）

> **文档定位**：本文档为《Ti60 2D 弹幕图形加速器》Phase 2 阶段的视觉特效强化、操作手感重构与性能稳定性终极优化指导书。任何 AI 助手在读取本文档后，均具备完整的上下文与精准的技术指令，可**直接开始执行代码修改、固件编译与比特流全流程构建**，无需用户额外补充说明。

---

## 一、工程背景与底层架构现状

### 1.1 硬件与固件核心规格
* **FPGA 芯片**：Efinix Titanium Ti60F225（16nm工艺，约 60K LE，时序敏感）。
* **时钟体系**：
  * `core_clk`: 100 MHz（SoC 系统时钟、BitBlt 2D 绘图引擎时钟，Fmax ≈ 136 MHz）。
  * `sdram_clk`: 400 MHz（LPDDR3 物理控制器时钟，Fmax ≈ 437 MHz）。
  * `hdmi_tx_slow_clk`: 85.71 MHz（像素扫描时钟，驱动 1366x768 @ 75 Hz）。
* **视频处理链路**：
  `u_video_dma` $\to$ `u_bloom_filter`（SRL8 2D 高斯外发光） $\to$ `u_color_matrix`（9 个 DSP 3x3 色彩矩阵） $\to$ `u_video_weather`（全屏动态天气） $\to$ `u_dvi_encoder`（HDMI 输出）。
* **最高红线纪律**：
  1. **稳锁 75 FPS 零退化**：单帧渲染时间预算为 $13.33\text{ ms}$。任何效果绝不可引起掉帧、卡顿或微卡。
  2. **DDR3 带宽控制**：BitBlt 写入受到 `video_write_guard` 的防抖保护（HDMI 活跃扫描期间严格避让）。严禁在普通高频小弹或密集粒子上使用带 DDR 回读的 RMW 操作（如 `OP_ADD`、`OP_ALPHA`），否则必定引发总线活锁和断崖式掉帧。
  3. **画质纯净度**：HDMI 扫描端 Bloom 必须严格锁定自发光阈值，严禁让背景（冰雪、熔岩、天空、UI）卷入模糊发光而导致“画面发灰、蒙白雾”。

---

## 二、本次优化任务清单总览

| 序号 | 任务模块 | 核心目标 | 涉及主要文件 |
| :---: | :--- | :--- | :--- |
| **01** | **BOSS 开大卡顿彻底消除** | 消除 `boss_opener()` 瞬间 16 颗加法大玉与全屏背景置换带来的 DDR 拥塞 | `sw/app/main.c` |
| **02** | **受击机制与全屏消弹重构** | 受击闪白 + 清除全屏敌弹 + 自机重置至底边安全位 + 短暂无敌 | `sw/app/main.c` |
| **03** | **全屏闪白特效质感升级** | 告别突兀生硬的死白；引入非线性平滑衰减与全屏消弹能量冲击波 | `sw/app/main.c`, `rtl/v_dma/video_color_matrix.v` |
| **04** | **暂停菜单天气遮挡屏蔽** | 按下暂停（Pause）或呼出菜单时，瞬时关闭天气层，保证菜单界面纯净无雪花覆盖 | `sw/app/main.c`, `rtl/v_dma/video_weather.v` |
| **05** | **子弹特效全面华丽升级** | 自机子弹增加高亮粒子拖尾与判定光环；小怪子弹优化为白心高光米弹/能量玉 | `sw/app/main.c`, `rtl/v_dma/video_bloom_filter.v` |
| **06** | **Phase 2 遗留特效全面补齐** | 补齐 BOSS 加法激光柱、微光加法预警线、高亮爆裂粒子与道具拾取辉光 | `sw/app/main.c` |

---

## 三、各任务详细技术方案与实施指导

### 任务 01：BOSS 开大卡顿彻底消除
* **根因定位**：
  在 [sw/app/main.c:2695](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c#L2695) 的 `boss_opener()` 中，开大瞬间发生三重高开销并发：
  1. 瞬间注入 16 颗加法大玉（`OP_ADD` 16x16，每颗都在执行读背景+读源+相加+写背景的 DDR3 RMW 操作）；
  2. `boss_shake` 激活导致背景切换到 `MM_CARD_BG`，触发了 1366x768（4.2 MB）全屏背景整屏重刷（`damage_full = 1`）；
  3. `video_write_guard` 阻断写入导致总线拥堵，单帧耗时突破 13.3ms，触发 CPU 累计多步逻辑循环造成严重卡顿。
* **优化实施**：
  1. **背景预刷与解耦（Phase Decoupling）**：
     BOSS 在开大前有 40 帧的蓄力定格期（`boss_state == BOSS_FREEZE`）。**在蓄力期的第 1~2 帧提前将符卡背景 `MM_CARD_BG` 刷入后台缓冲区**，而不要等到 `boss_opener()` 弹幕发射的那一帧去并发抢夺总线！
  2. **加法大玉波次平滑（Burst Shaping）**：
     开大爆发弹幕优化为“8 颗高阶加法大玉 + 8 颗高速单向发光弹幕”，或者将大玉以 2~3 帧的微小时间差（间隔 2 帧发射半圈）平滑发射，彻底削平 DDR 瞬间访问峰值。
  3. **严格保证 75 FPS**：实测开大过程中 FPS 指标不得低于 74.5 FPS。

---

### 任务 02：受击机制与全屏消弹重构
* **当前痛点**：
  当前测试版本开启无限复活（`infinite_respawn`），玩家中弹后仅扣命并闪白，自机仍停留在原处密集的弹幕堆中，容易连续多次中弹产生毫无规律的“频闪”，手感极其杂乱挫败。
* **重构方案**：
  1. 修改 [sw/app/main.c](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c) 中的 `take_hit(void)` 函数：
     * **全屏消弹**：遍历当前活跃的所有敌方子弹（`ebullets`），将 `flags` 清零。在每颗被消除的敌弹原坐标处生成一颗上升消散的消弹金色/蓝色光尘粒子（调用 `spawn_particle(..., PARTICLE_MOTE, ...)`）。
     * **自机位置重置**：将玩家坐标重置到屏幕底边经典出生位：
       ```c
       player_x = (int16_t)((GAME_LEFT + GAME_RIGHT) / 2);
       player_y = GAME_TOP + (GAME_BOTTOM - GAME_TOP) * 2 / 3;
       ```
     * **重置自机姿态与无敌保护**：赋予 120 帧（1.6 秒）的无敌时间 `invuln = 120;`，并开启自机受击闪烁与判定光环高频脉冲。
     * **触发优化的受击闪白**：重置 `color_matrix_flash_timer` 触发平滑退火的能量闪白。

---

### 任务 03：全屏闪白特效质感升级（解决“有点丑”）
* **当前痛点**：
  当前闪白直接将全屏强行线性拉向纯白（RGB=255），持续 5 帧，缺乏层次感和冲击波动态，视觉生硬且晃眼。
* **优化方案**：
  1. **非线性衰减曲线（指数退火）**：
     在 [sw/app/main.c](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c) 的 `update_screen_effects()` 中，将闪白强度映射为指数/高次衰减（例如前 2 帧强光，后 4 帧迅速退火），避免高亮度停留过久破坏沉浸感。
  2. **自机爆裂冲击波环（Shockwave Ring）**：
     中弹瞬间在自机原中弹点生成一道由小迅速扩散变大的全屏半透明/加法冲击波扩散环（复用 `bomb_flash` 或扩展 `visual_fx` 系统），配合全屏消弹化为漫天飞舞的光粒，呈现“护盾过载爆破，冲击波震散敌弹”的宏大视觉反馈。

---

### 任务 04：按下暂停时雪花/天气不覆盖菜单界面
* **当前痛点**：
  硬件天气发生器 `video_weather.v` 串联在视频流水线末端。按下暂停（Pause）呼出菜单时，天气层仍在工作，定格的雪花或飘落的杂质直接覆盖在菜单文本、设置选项与框体上，严重影响文字清晰度与观感。
* **优化实施**：
  1. 查看 [sw/app/main.c](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c#L1154) 与 [sw/app/main.c:5848](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c#L5848)：
     天气寄存器为 `GPU2D_REG_WEATHER`，其中 bit 15 控制天气开启（`1u << 15`）。
  2. 在 `paused` 激活且正在渲染菜单（`settings_render`）时，向 `GPU2D_REG_WEATHER` 写入关闭标志（将 bit 15 置 0，或将整个寄存器清零）：
     ```c
     if (paused) {
         GPU2D_REG_WEATHER = 0u; // 暂停菜单下彻底关闭天气遮挡
     }
     ```
  3. 恢复游戏（取消暂停）时，再重新开启天气位。确保暂停界面底板通透整洁，字符 100% 锐利清晰。

---

### 任务 05：自机与小怪子弹特效全面华丽升级
* **当前痛点**：
  玩家和杂兵的普通子弹在 DDR 中仅为 7x7/9x9 的单色小方块贴图，且 Bloom 扩散仅 2 像素，移动时视觉辨识度偏低、显得简陋。
* **优化方案**：
  1. **自机子弹华丽化（`pbullet_tile_build`）**：
     - 在 [sw/app/main.c:1183](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c#L1183) 中重构玩家子弹纹理合成逻辑。
     - **弹头圆形白心光环**：弹头由原先的 7x7 方块改为具有柔和渐变的双层圆形能量弹（中心 3x3 纯白 `0x00FFFFFF` 激发强光，外层为武器专属霓虹色）。
     - **高能离子尾迹拖尾**：尾部拖尾增加渐变透明过渡与羽化外沿，配合自机主炮呈现如流星般的射击质感。
  2. **小怪弹幕质感增强（`ebullet_tile_build`）**：
     - 在 [sw/app/main.c:1669](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c#L1669) 中重构敌弹贴图。
     - 将生硬方块弹改造为东方 STG 标志性的**尖锐指向性米弹**（Arrow/Rice Bullet）与**纯白内芯发光小玉**（Glow Orb）。
     - 确保弹丸核心像素满足 `min(R,G,B) >= 240`，外圈像素满足饱和色，使其在 HDMI 送显时**100% 激发扫描端 Bloom 滤镜的天然发光扩展**，脱胎换骨。

---

### 任务 06：Phase 2 遗留特效全面补齐
1. **BOSS 4 列大招激光柱接入加法高光**：
   - 现状：[main.c:4460](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c#L4460) 中激光柱使用的是普通贴图拷贝 `r_blit_nomark`。
   - 改造：替换为加法光效混合（`r_add` 或加法多层激光梁），激光中心呈现刺眼白心，边缘半透明叠加在活动背景之上。
2. **BOSS 切线激光预警细线升级**：
   - 现状：[main.c:4497](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c#L4497) 使用实心填充 `r_fill`。
   - 改造：改为高亮闪烁微光线，并在射出前 10 帧触发高频闪烁与能量收敛，呈现强烈的发射前摇警示感。
3. **战斗粒子反馈强化**：
   - 重新梳理 [main.c:1647](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c#L1647) 的 `particles_render`，优化粒子调色板（金色、青色、火红光粒），增强消弹、命中和擦弹时的光粒飞散数量与生命周期衰减。
4. **道具拾取辉光**：
   - 在 [main.c:3329](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/sw/app/main.c#L3329) 吃到道具时，触发专用的上升金色光尘粒子群。

---

## 四、技术实施红线与避坑规范

1. **总线安全第一**：
   所有高频出现的事物（普通子弹、常规火花粒子）**严禁使用 `OP_ADD`**！必须保持单向 Blit + ColorKey。只有低频关键演出（BOSS 激光柱、符卡专属大玉）才允许使用 `OP_ADD`。
2. **扫描防抖不可破坏**：
   [rtl/v_dma/video_write_guard.v](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/v_dma/video_write_guard.v) 中的严格防抖门控（`!video_priority`）不得改动，确保 HDMI 扫描 FIFO 不欠载，屏幕绝不产生横向晃动。
3. **防止画面发灰**：
   [rtl/v_dma/video_bloom_filter.v](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/v_dma/video_bloom_filter.v) 中的自发光判定（白心 `min_rgb >= 240` 与高饱和霓虹色提取）已通过验证，切勿重新加入无保护的低阈值背景发光。
4. **编译与验证闭环**：
   固件修改后必须执行 `sw\build_firmware.bat`，硬件修改必须执行 `build_hw.bat`。编译完成后必须检查 [outflow/ti60_top.timing.rpt](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/outflow/ti60_top.timing.rpt)，确保所有时钟域 Setup/Hold Slack 均为正值。

---

## 五、验收标准与交付物

* **比特流输出**：编译成功并生成全新的 [outflow/ti60_top.bit](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/outflow/ti60_top.bit) 与 [outflow/ti60_top.hex](file:///e:/FPGA/Ti60_2D_Graphics_Accelerator/outflow/ti60_top.hex)。
* **真机运行指标**：
  1. 角色受击后全屏优雅闪白一次，同屏所有敌弹化为金色光尘升空，角色重置至底边安全位置并处于无敌闪烁状态，无连续频闪。
  2. 按下暂停键进入设置菜单时，画面背景定格且**完全没有雪花/飞灰遮挡菜单文字**。
  3. 自机子弹与小怪子弹呈现清晰圆润的白心能量球/指向性光辉，辨识度显著提升。
  4. BOSS 开大宣告时红光脉冲正常，弹幕射出瞬间**丝滑无任何掉帧，帧率稳定 75 FPS**。
  5. 激光柱展现白心高光，全屏对比度鲜明、无发灰雾感。

---

## 六、AI 执行启动提示词（直接复制即可开工）

```markdown
请阅读并严格执行 E:\FPGA\Ti60_2D_Graphics_Accelerator\phase2优化任务01.md 中的全部技术规范与任务清单。

本次任务要求你完整落地以下工作：
1. 彻底根除 BOSS 开大卡顿（背景预加载与大玉平滑化），确保开大全程稳锁 75 FPS；
2. 重构受击机制（take_hit）：中弹后平滑闪白、清除全屏敌弹并爆出光尘、自机重置至底部安全位置并获 120 帧无敌；
3. 优化全屏闪白效果，消除生硬死白与频闪感；
4. 修复暂停菜单界面被雪花天气遮挡的问题（paused 期间关闭天气发生器）；
5. 升级自机与小怪子弹外观（圆形白心高光、能量拖尾、消除方块弹简陋感）；
6. 补齐 BOSS 加法激光柱、微光预警细线、道具拾取光尘等遗留特效。

请完成代码修改后，执行固件编译与 build_hw.bat 全流程综合，确保 timing report 时序全正收敛，最终交付 ti60_top.bit 与 ti60_top.hex。
```
