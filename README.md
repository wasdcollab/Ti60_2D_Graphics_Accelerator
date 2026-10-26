# Ti60 2D 图形加速器

面向 Efinix Ti60 FPGA 的 2D 图形加速器，以及跑在其上的弹幕游戏。仓库包含 Verilog RTL、Sapphire RISC-V 裸机固件，以及可脱板运行的仿真器与工具链。弹幕、天气、激光等图层在扫描端流式合成；固件负责游戏逻辑、扫描线分桶，以及 BitBlt 脏矩形绘制。

## 硬件目标

- 器件：Efinix Titanium **Ti60F225**（`ti60_top.xml`）
- SoC：Sapphire RISC-V，片外 **256 MB DDR3**（`sw/driver/memory_map.h`）
- 显示：HDMI **1366×768 @ 约 75 Hz**（像素时钟约 85.71 MHz，见 `rtl/ti60_top.v`）
- 时钟：`core_clk` 100 MHz，DDR PHY `sdram_clk` 400 MHz（`sdc/ti60_top.sdc`）

## 仓库布局

| 路径 | 内容 |
| --- | --- |
| [`rtl/`](rtl/) | Verilog：顶层 `ti60_top.v`，以及 APB、BitBlt、DMA、显示引擎、HDMI、音频、DDR3 |
| [`sw/`](sw/) | RISC-V 裸机固件（`app/`、`driver/`、`startup/`、`linker/`）与构建脚本 |
| [`simulator/`](simulator/) | 指令级仿真工作台；回归入口 [`test_runner.py`](simulator/test_runner.py) |
| [`tests/`](tests/) | RTL testbench |
| [`tools/`](tools/) | 资产烘焙、布局检查、性能剖析等脚本 |
| [`docs/`](docs/) | 设计说明、故障记录与恢复证据 |
| [`assets/`](assets/) | 贴图等源资产与处理后的资源 |
| [`sdc/`](sdc/) | 时序约束 `ti60_top.sdc` |
| [`bgm/`](bgm/) | BGM 源文件 |
| [`学习手册/`](学习手册/学习手册.md) | 架构与源码导读 |
| [`build_hw.bat`](build_hw.bat) | Efinity 硬件全流程（先编固件再综合） |
| `ti60_top.xml`、`ti60_top.peri.xml` | Efinity 工程与外设配置 |

## 构建与运行

硬件流程面向 Windows 上的 Efinity。下列命令均来自仓库内已有脚本与说明，参数细节以各脚本开头的用法说明为准。

**硬件** — [`build_hw.bat`](build_hw.bat)

调用 [`sw/build_firmware.bat`](sw/build_firmware.bat) 之后，再跑 Efinity 工程 `ti60_top` 的 compile。产物为 `outflow/ti60_top.bit` 与 `outflow/ti60_top.hex`。脚本需要 `EFINITY_HOME`（找不到时使用文件内写死的安装路径）。烧录不在此脚本中。

**固件** — [`sw/build_firmware.py`](sw/build_firmware.py)

```text
python sw/build_firmware.py
```

Windows 下等价入口是 `sw/build_firmware.bat`。工具链根目录由环境变量 `RISCV_GCC_DIR` 指定，默认候选路径写在脚本开头。产物在 `sw/build/`（ELF / BIN），并更新 BRAM 初始化文件。

**仿真回归** — [`simulator/test_runner.py`](simulator/test_runner.py)

```text
python simulator/test_runner.py --list
python simulator/test_runner.py --only alpha,settings
```

分组、全套与导出图片的参数见脚本 `--help` 与 [`simulator/README.md`](simulator/README.md)。Windows 下一键入口是 [`simulator/run_sim.bat`](simulator/run_sim.bat)（先编固件，再按分组跑）。验收以 Python 内核为准；`simulator/native/` 尚未作为验收依据（见 [`README_RECOVERY.md`](README_RECOVERY.md)）。

## 文档

- [`HANDOVER.md`](HANDOVER.md)：架构交接。目录结构、软硬件协同、帧预算，以及弹幕规模的硬件上限。
- [`README_RECOVERY.md`](README_RECOVERY.md)：2026-10-24 起的板上恢复笔记，以及后续总线与命令锁存修复的入口。历史文档中的路径和数字以该说明为准。
- [`docs/`](docs/)：分项设计与故障记录。
- [`学习手册/学习手册.md`](学习手册/学习手册.md)：源码导读。

本仓库为私人项目。
