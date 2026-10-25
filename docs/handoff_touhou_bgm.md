# 东方 BGM 集成交接（Ti60 2D Graphics Accelerator）

**日期：** 2026-10-12  
**目标：** 在 Ti60F225 的射击游戏中，以 DDR3 中的 PCM 背景音乐替换目前 FPGA 内合成的循环 BGM，同时不影响 HDMI 显示、DDR3、游戏逻辑和音效。

## 后续进度：阶段 A 已下载并完成基础实板确认

2026-10-12 19:05 后，已加入 2 KiB 片上 PCM 测试段，替换默认合成 BGM。
全量 Map / PNR / PGM 通过，JTAG 下载成功；用户确认“画面正常，声音已变化，音量有效”。
这只是约 0.171 秒的循环测试段，尚非完整东方 BGM，900+ sprites 压力场也尚未确认。
目前 RAM 为 255/256 块，固件静态分配距预留栈边界仅余 504 字节。
阶段 B 必须按这两个预算设计，音效抢占问题仍待单独修复。
实现、测试、时序和原 bitstream 备份位置见 [audio_stage_a.md](audio_stage_a.md)。

下面“当前可用基线”及回退清单描述的是本次阶段 A 之前的历史状态。

## 当前可用基线

项目目前已回退到“未加入东方 BGM”的版本。这是下一步开发的起点：

- 屏幕：1366×768 @ 75 Hz。
- 游戏压力场实板曾达到约 **980 sprites / 75 FPS**；`DROP` 在高负载时会非零。
- 音频：MAX98357 的 I2S 通路已能发声；菜单音量、普通攻击、击杀/爆炸和激光音效均在该基线中。
- BGM：当前为 `rtl/audio/game_audio_synth.v` 内的 FPGA 合成旋律，控制位为 `AUDIO_BGM_ENABLE`。
- FPGA：Ti60F225 I3；RISC-V 固件位于片上 BRAM，游戏图像和资源在 DDR3。

已通过的回退构建：

```text
firmware.bin: 61879 bytes
Map: PASS
PNR: PASS
PGM: PASS
bitstream: outflow/ti60_top.bit
```

构建命令：

```powershell
cd E:\FPGA\Ti60_2D_Graphics_Accelerator
cmd /c build_hw.bat
```

JTAG 下载命令（板卡重新被电脑枚举后）：

```powershell
& 'D:\FPGAqiansai\efinity-2026.1.132-windows-x64\efinity\2026.1\pgm\bin\ftdi_pgm.bat' `
  -m jtag -u 'ftdi://0x0403:0x6011:2:7/2' outflow\ti60_top.bit
```

当前电脑在最后一次尝试时无法枚举 JTAG，`ftdi_pgm.bat -l` 与 `--scan_usb` 均返回 `No USB target detected`。这不是编译错误。

## 相关文件

| 位置 | 用途 |
|---|---|
| `rtl/audio/game_audio_synth.v` | 当前可用的原合成 BGM、SFX 混音和 I2S 采样输出 |
| `rtl/audio/i2s_tx.v` | MAX98357 的 I2S 发送器 |
| `rtl/ti60_top.v` | 音频模块、DDR3、视频和系统总线的顶层连接 |
| `rtl/common/Axi_Mux.v` | 当前为 `X3`，即三个 AXI 从机通道 |
| `rtl/apb/apb_command_dispatcher.v` | 游戏音频 APB 控制寄存器复位值 |
| `sw/driver/audio.h` | 音频控制位与事件定义 |
| `sw/app/main.c` | 游戏事件触发、菜单音量设置 |
| `rtl/audio/sfx_rom.hex` | 已使用的音效 PCM/波形 ROM |
| `sw/driver/memory_map.h` | DDR3 资源地址定义，新增 BGM 缓冲前必须检查 |
| `tools/check_ddr_layout.py` | DDR 地址区间冲突检查 |

## 已尝试的 DDR3 BGM 方案

曾实现并上板测试过以下架构，**现已从编译路径移除**：

1. 将 MP3 转成 12 kHz、8 bit、单声道 unsigned PCM，大小约 **4,348,447 bytes**。
2. 固定放在 DDR3 地址 `0x05000000`。
3. 新增 `rtl/audio/ddr_bgm_player.v`：AXI 读取 DDR3、内部 FIFO 缓冲、按采样节拍输出 PCM。
4. 在 `game_audio_synth.v` 将该 PCM 和原 SFX 混音；BGM 数据完全上传后才启用该流。
5. RISC-V 端加入 UART 装载器：收到 `BGM!` 和长度后，把 PCM 写入 DDR3；主机用 COM10 在约 921600 baud 上传。
6. 为播放器增加第 4 个 AXI 从机，`Axi_Mux.v` 从 `X3` 改到 `X4`。

使用的用户提供源文件是“上海アリス幻樂団 - シンデレラケージ ～ Kagome-Kagome.mp3”。

## 失败现象与可能原因

该方案的上传日志显示传输完成，但用户观察到：

1. 背景音乐仍然是原 BGM；
2. 显示器已检测到输出，却只有灰色画面，没有游戏图像。

因此不能把“UART 上传成功”当作 BGM 播放成功。问题很可能在新增 AXI 主机 / DDR 仲裁 / 时钟复位 / 音频混音的综合后行为，且与显示灰屏存在关联。

已执行过一次只撤掉部分连接的回退，灰屏仍存在。后续完整回退同时移除了 UART 轮询代码、音频控制扩展、顶层 AXI 连接和播放器源码，才得到目前可重新通过完整编译的基线。因此，下一次不要只增删一个模块后直接上板，应分阶段验证。

## 推荐的调试路线


### 不要先接入实时 DDR AXI 读取

实时读 BGM 会与 framebuffer、BitBlt、CPU 和扫描端争用 DDR 带宽，也增加一个 AXI 主机和跨域 FIFO。建议先做两个较低风险阶段：

- **阶段 A：** 用很短的片上 BRAM PCM 测试替代合成 BGM，确认采样时钟、PCM 符号转换、音量和 SFX 混音正确，且画面稳定。
- **阶段 B：** 仅在开机时由 RISC-V 从 DDR3 分块搬运 PCM 到音频 BRAM / ping-pong FIFO，音频端不直接成为 AXI 主机。先用数秒循环音乐验证。

只有阶段 B 可靠后，再考虑流式 DDR3 播放。

### 若必须做流式 DDR3 播放

- 使用单独的、带明确 `valid/ready` 的异步 FIFO，分别约束 DDR 时钟域与 I2S 采样时钟域。
- 给 BGM AXI 读取设较低优先级和有限 burst，避免阻塞显示扫描及 BitBlt。
- 用 16/32/64 KiB FIFO 吸收 DDR 仲裁抖动；先计算最坏服务间隔是否小于 FIFO 储量。
- 让音乐播放器默认静音，只有 FIFO 到达安全水位、完成首个 DDR burst 后才拉高 `valid`。
- 保持音频输出为固定采样率；不要把 I2S bit clock 当作音乐采样使能。
- 用 ILA/SignalTap 或输出调试寄存器观察：AXI read issued/response、FIFO level、underflow count、BGM enabled、DDR 初始化完成信号。
- 每次修改都运行 `tools/check_ddr_layout.py`，并把 BGM 地址加入统一的地址图，确保不覆盖资源和 framebuffer。

###  软件/UART 方案的注意点

之前 UART 装载器直接轮询 SoC UART 状态寄存器并在主循环中阻塞读完整个 PCM。即使传输协议表面成功，也不适合最终方案：

- 它会长时间阻塞游戏；
- 它依赖 UART 寄存器地址和状态位假设；
- 在 DDR 地址未经统一登记时容易覆盖其他对象；
- 传输没有 CRC、断点恢复或运行时状态显示。

建议如果仍使用 UART，只把它作为开发期加载工具，并增加：分块协议、CRC、显式 `loaded_bytes` 计数、失败超时和屏幕状态提示。量产演示可用 SD 卡或把音频压缩进 SPI Flash；不要把受版权约束的原始 MP3 放入公开仓库。

## 资源与性能预算

- 12 kHz × 8 bit × 单声道：约 12 KB/s；4.35 MB PCM 约 362 秒。
- 22.05 kHz × 8 bit × 单声道：约 22 KB/s；音质更好，但仍远低于 DDR3 峰值带宽。
- 音频的平均带宽很小，风险主要是 AXI/DDR 突发延迟、FIFO 下溢，以及新增逻辑意外改变顶层连接或时序。
- 游戏处于 1366×768@75 Hz，显示扫描、DDR3 framebuffer 和高 sprite 负载是系统的关键实时路径。任何 BGM 访问都必须允许视频路径优先完成。

### 优化普攻 boss释放大招音效
- 普攻过快时声音微小 boss放大招有时无声 击杀反馈也时好时不好

## 回退改动清单

以下文件曾为 BGM 试验新增，现已删除或从工程 XML 移除：

```text
rtl/audio/ddr_bgm_player.v
rtl/audio/bgm_pcm.vh
tools/build_bgm_pcm.py
tools/upload_bgm.py
```

同时已恢复：

```text
rtl/common/Axi_Mux.v                 X4 -> X3
rtl/ti60_top.v                       移除 BGM AXI 主机/流接口
rtl/audio/game_audio_synth.v         移除 BGM 流接口，恢复原 BGM + SFX 混音
ti60_top.xml                         移除 ddr_bgm_player.v
sw/driver/audio.h                    移除 AUDIO_BGM_DDR 与状态变量
sw/app/main.c                        移除 UART BGM loader 与主循环轮询
```

工作目录中可能仍保留未被工程引用的 PCM/MP3 临时文件；它们不参与构建。不要将该 MP3 或派生 PCM 提交到公开仓库。

## 验收标准

东方 BGM 集成完成前，应同时满足：

1. HDMI 画面正常，菜单、游戏和压力场均可进入；
2. BGM 确认为目标曲目而非旧合成旋律；
3. 普攻、散弹、击杀/爆炸、激光和 Boss 大招音效可区分且优化；
4. 菜单音量能同时影响 BGM 与音效；
5. 至少在压力场 900+ sprites 时，画面无灰屏、无明显 BGM 断续，FPS 不低于既定底线；
6. 全量 `build_hw.bat` 的 Map、PNR、PGM 均通过，并以新生成 bitstream 实板验证。

