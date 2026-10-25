# BOSS STAGE 2000+ 弹幕压力测试交接

更新日期：2026-10-15  
工程目录：`E:\FPGA\Ti60_2D_Graphics_Accelerator`  
平台：Ti60F225 / Efinity 2026.1.132 / RISC-V 固件 / 1366×768@75 Hz HDMI

## 1. 接手结论

本轮用户要求：解释 DROP，将 BOSS STAGE 压力测试提升至 2000+，消除密集弹幕重叠时的透明方框。

代码、仿真、全量构建和 JTAG 下载均已完成。用户对本版给出的实板反馈是：

> SPRITES 2212，FPS 37，DROP 560，透明方框消失，音乐连续。

当前结论：

- 已达到 2000+ 活动对象，透明方框修复已获得实板确认。
- 当前测试场景下音乐连续，未修改音乐播放代码或存储音乐的 Flash。
- **尚未实现 2000+、75 FPS、零丢弃。** 高负载帧率和桶溢出是后续问题。
- 37 FPS 的具体瓶颈尚未定位，不能直接断言是 CPU、DDR 或新透明覆盖逻辑导致。
- 本轮仅临时 JTAG 下载。断电后恢复原 Flash 版本，不会保留本版弹幕修改。

本次交接仅记录状态与建议路线，不代表用户已授权改写 Flash 或要求实现新的性能指标。

## 2. 指标含义

| 指标 | 实际含义 | 不应作出的推断 |
| --- | --- | --- |
| SPRITES | 活动敌机、敌弹、玩家弹、道具、玩家及 Boss 的合计；不包含装饰 FX、天气、激光像素 | 不是完全绘制出来的子弹数量 |
| LOAD | 压力场补弹目标；Boss 自身弹型仍会发射，数量可能超过目标 | 不是精确的屏幕可见数量 |
| DROP | 当前档位内，单帧被拒绝桶表项数量的历史峰值 | 不是掉帧数，也不是整颗子弹的丢失数量 |

当前每 8 条扫描线共用一个桶，每桶最多 128 项。桶满时，一颗子弹在一个扫描线组中的显示项被拒绝，计一次 DROP；同一颗子弹可能跨多个组。

`TLM_BUCKET_DROPS` 保存当前帧计数，HUD 显示 `bt_drop_peak`。换档或重新进入时清零。**不能用 2212 - 560 计算真实显示数量。**

## 3. 当前固件改动

主要文件：`sw/app/main.c`、`sw/driver/memory_map.h`。

- `MM_EBULLET_COUNT`：1024 → 2304。
- 敌弹池仍位于 `0x01675400`，每项 8 字节，占用 `[0x01675400, 0x01679C00)`；DDR 地址检查已通过。
- 敌弹池末尾 32 项保留给 orb，玩家弹池仍为 512 项。
- `STRESS_STORM_TARGET = 192`，`STRESS_STORM_MAX = 2112`。
- 按 Y 每次增加 128，档位为 192、320、……、1984、2112，再回到 192；保持按住不会连续换档。
- `STRESS_STORM_BUDGET`：12 → 48，每个逻辑 tick 最多补入 48 发，未一次性堆满整个池。
- HUD 活动数量字段从 11 位扩到 12 位，避免超过 2047 回绕。
- LOAD 改为四位显示，并调整左侧标签和数字区域，布局检查及双缓冲逐像素验证通过。

**固件空间非常紧：** binary 为 62327 字节，链接数据/BSS 结束于 `0xF900FBD8`，距离预留的 1 KiB 栈底仅余 40 字节。后续增加统计或优化代码时，必须保留链接大小检查；不要通过随意缩小栈来绕过溢出。

## 4. 透明方框根因与修复

实际参与当前工程构建的是：

`rtl/display_engine/2_layer_generators/video_bullet_overlay.v`

**不要误改旧的 `rtl/v_dma/video_bullet_overlay.v`。** 工程 XML 引用的是前者。

### 原问题

旧设计先按矩形覆盖选出优先级最高的两个候选，再读取它们的图块像素。若两个候选在当前像素都透明，直接露出背景，不再检查下面的弹幕。因此三层以上重叠仍会出现透明矩形挖洞。

### 当前设计

1. 启动配置图块时，从同一份 role 数据生成覆盖位：`role != 0`。
2. 每 32 个图块字节打包成一个覆盖字，存入 `512×32` 双时钟 RAM。
3. 每条扫描线在左侧 HUD 区预读桶内各项的覆盖行，形成 `128×26 bit` 寄存器缓存。
4. 每个像素只让真正非透明的桶项参与优先级选择，在全部 128 项中选最后一个有效命中。
5. 只读取最终赢家的 role 和 palette，输出延迟仍为输入采样后的 `N+3`。

这消除了“两层回退”的深度限制，并省去第二份 `16K×5` 图块 RAM。用户已确认实板透明方框消失。

### 必须保持的接口条件

- DMA 应在 `x=0` 前发布本行桶，并在有效扫描期间保持稳定。
- 当前覆盖缓存约在 `x=129` 就绪，早于游戏区域起点 `x=181`。
- 图块配置从地址 0 开始连续递增写入；当前固件写 14352 字节，末尾半个覆盖字也受支持。
- 图块在运行期间保持不变；若以后支持动态改图块，需要重新设计更新同步机制。
- 复位或 `bucket_ready` 丢失后，缓存失效，直到下一次完整行准备后才恢复。
- hue、role、alpha、DE、遮罩与裁剪必须保持对齐。
- 这是“最高优先级非透明像素”合成，**不是所有半透明光晕逐层累加**。
- 仍然只有 128 个桶项；修复透明覆盖不等于消除了桶溢出。

综合中 `coverage` 的 3328 bit 映射为寄存器是有意设计，因为要并行读取全部项。覆盖字由 32 位截为 26 位也是有意丢弃最大图块宽度之外的列，相关告警已核查。

## 5. 验证证据

| 项目 | 本轮结果 |
| --- | --- |
| 独立像素参考模型 | 699392 个像素通过 |
| RTL 连续像素测试 | 26624 个连续像素向量 |
| RTL 总检查 | 66280 项，零失败 |
| 极深重叠 | 上方 127 个透明矩形不再遮掉第 0 项的有效像素 |
| 其他 RTL 边界 | 图块/hue、越界行、裁剪、遮罩、DE、配置尾部、ready 丢失恢复、复位恢复 |
| 固件桶表测试 | 真实 RV32 指令，双缓冲、旧尾项清理、满池、溢出和边缘裁剪通过 |
| 均匀分布满池 | 2304 敌弹 + 512 玩家弹，7869 个桶项，DROP 0 |
| 压力场仿真 | 244 帧，峰值 2257 sprites，单帧拒绝项峰值 584；全部档位及 HUD 检查通过 |
| 普通游戏回归 | bulletpool、hitsweep、stresslab、menu，4/4 通过 |
| 全量硬件构建 | Map / PNR / PGM 全部通过 |
| 用户实板反馈 | 2212 sprites / 37 FPS / DROP 560，方框消失、音乐连续 |

资源与时序：

- RAM10：247/256，修改前为 255/256。
- LUT4：28058；FF：26530。
- 布局后 XLR：54894/60800，约 90.29%。
- 最差 setup：+0.125 ns；最差 hold：+0.023 ns。
- HDMI 像素时钟域 setup：+1.464 ns；hold：+0.035 ns。

注意：仿真的指令数不是实板周期数，更不是 FPS。旧版 900+ sprites 约 75 FPS 的反馈来自此前版本，尚未补做“本版 960 档位”的同版本对照。

模拟器补充了“SPI 未连接，读回 0xFF”的行为，使新音乐固件能够走无 BGM 启动分支，并保留音频控制寄存器读回。**模拟器没有验证真实 Flash 音乐播放或 I2S 时序。** 本版音乐连续的证据来自用户实板反馈。

## 6. 文件与产物

| 位置 | 用途 |
| --- | --- |
| `sw/app/main.c` | 补弹、弹池分配、桶表构建、HUD、性能统计 |
| `sw/driver/memory_map.h` | 弹池大小及桶几何参数 |
| `rtl/display_engine/2_layer_generators/video_bullet_overlay.v` | 本轮透明覆盖修复 |
| `rtl/dma/dma_bucket_prefetch.v` | 现有分组预取与行发布逻辑，本轮未修改 |
| `simulator/scanout_model.py` | 全深度非透明优先级参考模型 |
| `simulator/rv32i_soc_vm.py` | 图形回归所需 SPI 未连接及音频寄存器行为 |
| `tests/tb_bullet_overlay.sv` | 覆盖与流水线回归 |
| `tools/check_bullet_fallback.py` | 独立参考与连续像素向量生成 |
| `tools/test_bucket_rebuild.py` | 真实固件桶表、档位和 HUD 验证 |
| `docs/boss_stress_2112.md` | 本轮英文技术记录 |
| `docs/overlay_fix_handoff.md` | 较早双候选历史记录，不能当作当前实现 |

日志均在 `work_sim/`：

```text
boss_2112_build.log
boss_2112_overlay.log
boss_2112_bucket.log
boss_2112_bucket.json
boss_2112_regression.log
boss_2112_uart.log
```

串口 COM10 / 115200 的 65 秒采集没有收到字节，不能用该日志证明音乐识别成功，也不能据此断言板卡未启动。

当前 bitstream：`outflow/ti60_top.bit`。本轮下载版本 SHA-256：

```text
891dd9cfdcbe83e15bdb33c39d15b0ab417fb1f167086d16694f2e3ee42fa22b
```

## 7. 构建与回归命令

在工程根目录的 PowerShell 执行：

```powershell
python tools/check_ddr_layout.py
python tools/check_hud_layout.py
cmd /c sw\build_firmware.bat
powershell -ExecutionPolicy Bypass -File tools/sim_bullet_overlay.ps1 -Rebuild
tools/pypy/pypy3.exe -u tools/test_bucket_rebuild.py --check-hud --report work_sim/boss_2112_bucket.json
$env:SIM_PURE_PYTHON = '1'
tools/pypy/pypy3.exe -u simulator/test_runner.py --only bulletpool,hitsweep,stresslab,menu
cmd /c build_hw.bat
```

硬件构建约需数分钟；检查最终完成状态、报告时间和 setup/hold，避免把 outflow 中旧报告当成新结果。

Efinity 路径：`D:\FPGAqiansai\efinity-2026.1.132-windows-x64\efinity\2026.1`。下载前先使用其 `pgm/bin/ftdi_pgm.bat -l` 重新枚举设备，不要假定 USB 地址永远不变。本轮设备 ID 为 `0x10660A79`。

## 8. 后续优化建议

### 先建立同版本基线

在当前版本测 960、1472、1984、2112 档位，保持相同操作、场景和观察时长，记录 SPRITES、FPS、DROP、音频连续性以及明显缺失的弹幕条带。暂不扩大最高档位。

先确认用户期望的最低 FPS、可接受 DROP 和测试时长，再设最终验收指标；75 FPS 可作为优化方向，但尚不是已经实现的结论。

### 分别定位 CPU 帧耗时与桶容量

优先检查 `sw/app/main.c` 中以下入口：

- `alloc_bullet_range()`：当前从范围起点寻找空槽。高负载时反复补弹可能重复扫描大量活动项，是待测热点，不是已证实根因。
- `stress_storm_update()`：统计活动数并补弹，需要分离计数和分配成本。
- `pool_bounds_rebuild()`、`FOR_EACH_EBULLET`：保持高水位及 orb 尾区的完整遍历语义。
- `bucket_put_run()`、`bucket_build()`：观察写入量、分组占用和拒绝量，保留每个缓冲区自己的旧深度账本。
- `diag_window()`、已有 telemetry：优先复用现有统计，避免在仅余 40 字节的固件空间中加入大量打印。

如优化分配器，要保留池边界、orb 保留区、分配后高水位维护、清池和重新进入游戏的正确性，不能让遍历漏掉高地址活动项。

DROP 需单独治理。均匀满池测试无溢出而 Boss 实测有较大 DROP，提示空间集中程度值得测量。分布优化、缩小扫描线分组、扩大桶容量的取舍不同：

- 改弹型分布会改变压力负载，应明确说明，不能把减小真实负载包装成渲染能力提升。
- 改分组大小会联动固件、DMA、overlay 行偏移、表尺寸和参考模型，并可能增加 CPU 写表量。
- 扩桶会增加比较逻辑、预取量和行准备时间。当前缓存逐项预读，盲目从 128 扩到 192 将超过 `x=181` 的准备窗口，不能只改一个常量。
- 不要用隐藏 DROP、缩小统计范围或回退到双候选遮挡错误来换取表面好看的结果。

### 每次改动后的门禁

1. DDR/HUD/链接空间检查通过。
2. 128 层透明覆盖、连续像素和真实固件桶表测试通过。
3. 普通玩法回归通过。
4. 全量构建及最终时序通过后，才临时 JTAG 下载。
5. 用户确认 FPS、DROP、方框和音乐，再考虑持久化部署。

## 9. 回退与注意事项

- 修改前快照：`backups/boss_2112_20261015/`，包含此前音乐正常版本的 bitstream、报告和部分源码。
- 本版快照：`backups/boss_2112_candidate_20261015/`，包含本轮 bitstream、固件、关键源码和报告。
- 上述目录是选定文件的快照，不是完整 Git 提交或完整工程镜像。
- 原音乐 Flash 未变；断电重启可恢复原 Flash 版本。
- `outflow/ti60_top_bgm.hex` **仍是旧版组合镜像**。本版 `ti60_top.hex` 不是重新打包后的音乐组合镜像。
- 不要在后续未经明确部署安排时擦写 Flash；避免覆盖已有音乐。
- 工作区存在大量此前的 staged/unstaged/untracked 改动。不要清空工作区或回退无关文件；本次没有创建提交。
- 历史文档、注释中仍可能出现旧的 512/1024 弹池、旧档位或双候选描述。核对当前宏、工程 XML 和本轮证据，不凭旧文字修改硬件。
