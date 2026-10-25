# Ti60 2D 硬件图形加速器 —— RTL 深度解读手册

> **工程路径**：`E:\FPGA\Ti60_2D_Graphics_Accelerator\rtl`  
> **芯片平台**：Efinix Titanium Ti60F225 (`Ti60F225I3-V4`)  
> **设计语言**：Verilog-2001 / SystemVerilog  
> **核心频点**：系统与 AXI 总线时钟 100 MHz (`core_clk`)、视频像素时钟 85.714 MHz (`hdmi_tx_slow_clk`)、DDR3 物理时钟 400 MHz (`sdram_clk`)  

---

## 目录
- [第一大章：RTL 项目全局目录结构与文件清点](#第一大章rtl-项目全局目录结构与文件清点)
  - [1.1 `rtl/` 目录组织概览](#11-rtl-目录组织概览)
  - [1.2 根部顶层与公用组件 (`rtl/` & `rtl/common/`)](#12-根部顶层与公用组件-rtl--rtlcommon)
  - [1.3 2D 图形硬件加速引擎 (`rtl/bitblt/`)](#13-2d-图形硬件加速引擎-rtlbitblt)
  - [1.4 中央命令分发中枢 (`rtl/apb/`)](#14-中央命令分发中枢-rtlapb)
  - [1.5 显存 DMA 纯数据提取引擎 (`rtl/dma/`)](#15-显存-dma-纯数据提取引擎-rtldma)
  - [1.6 纯流式像素渲染与多图层合成工坊 (`rtl/display_engine/`)](#16-纯流式像素渲染与多图层合成工坊-rtldisplay_engine)
  - [1.7 DDR3 存储器控制器与物理 PHY (`rtl/ddr3_controller/`)](#17-ddr3-存储器控制器与物理-phy-rtlddr3_controller)
  - [1.8 HDMI / DVI 差分编码与发送 (`rtl/hdmi/`)](#18-hdmi--dvi-差分编码与发送-rtlhdmi)
- [第二大章：核心硬件子系统源码级深度剖析](#第二大章核心硬件子系统源码级深度剖析)
  - [2.1 第一小章：BitBLT 2D 硬件图形加速引擎详解](#21-第一小章bitblt-2d-硬件图形加速引擎详解)
    - [2.1.1 BitBLT 引擎整体架构与流水线数据流图](#211-bitblt-引擎整体架构与流水线数据流图)
    - [2.1.2 `bitblt_top.v`：顶层集成、总线互联与流控仲裁](#212-bitblt_topv顶层集成总线互联与流控仲裁)
    - [2.1.3 `bitblt_apb_regs.v`：APB3 寄存器文件、合法性校验与看门狗](#213-bitblt_apb_regsvapb3-寄存器文件合法性校验与看门狗)
    - [2.1.4 `bitblt_stride_gen.v`：三迭代器 2D 跨距与 AXI 突发状态机](#214-bitblt_stride_genv三迭代器-2d-跨距与-axi-突发状态机)
    - [2.1.5 `bitblt_align_shifter.v`：三拍滑动窗口与 128 位桶形对齐移位器](#215-bitblt_align_shifterv三拍滑动窗口与-128-位桶形对齐移位器)
    - [2.1.6 `bitblt_alpha_blend.v`：四级流水线 Alpha 混合与饱和加法器](#216-bitblt_alpha_blendv四级流水线-alpha-混合与饱和加法器)
    - [2.1.7 `bitblt_axi_read_master.v`：多请求队列与并发 AXI 读通道](#217-bitblt_axi_read_masterv多请求队列与并发-axi-读通道)
    - [2.1.8 `bitblt_axi_master.v`：非阻塞 AXI 写通道与动态字节选通](#218-bitblt_axi_masterv非阻塞-axi-写通道与动态字节选通)
    - [2.1.9 `bitblt_read_fifo.v`：弹性同步读 FIFO 模块](#219-bitblt_read_fifov弹性同步读-fifo-模块)
    - [2.1.10 辅助与支撑模块：`bitblt_asset_rom.v`、`bitblt_demo_scheduler.v`、`bg_rle.*` 与 `_v1_backup/`](#2110-辅助与支撑模块bitblt_asset_romvbitblt_demo_schedulervbg_rle-与-_v1_backup)
  - [2.2 第二小章：common 基础公用组件详解](#22-第二小章common-基础公用组件详解)
    - [2.2.1 `common` 目录的系统定位与职责](#221-common-目录的系统定位与职责)
    - [2.2.2 `Axi_Mux.v`：128 位 AXI4 3 进 1 出总线仲裁器深度剖析](#222-axi_muxv128-位-axi4-3-进-1-出总线仲裁器深度剖析)
    - [2.2.3 `Axi_Mux_Param.vh`：多路复用参数宏定义与级联展开](#223-axi_mux_paramvh多路复用参数宏定义与级联展开)
    - [2.2.4 `i2c_gamepad_top.v`：全自主硬件手柄 I2C 轮询与板载按键消抖引擎](#224-i2c_gamepad_topv全自主硬件手柄-i2c-轮询与板载按键消抖引擎)
    - [2.2.5 `simple_dual_port_ram.v`：通用伪双口 BRAM 原语推导与跨时钟隔离](#225-simple_dual_port_ramv通用伪双口-bram-原语推导与跨时钟隔离)
  - [2.3 第三小章：apb 命令分发中枢详解](#23-第三小章apb-命令分发中枢详解)
    - [2.3.1 三权分立架构定位与 APB 寄存器空间宏观布局](#231-三权分立架构定位与-apb-寄存器空间宏观布局)
    - [2.3.2 2D BitBlt 专有指令总线与参数门禁 (`bitblt_cmd_*`)](#232-2d-bitblt-专有指令总线与参数门禁-bitblt_cmd_)
    - [2.3.3 显示特效与行桶调色板推流总线 (`display_cfg_*`)](#233-显示特效与行桶调色板推流总线-display_cfg_)
    - [2.3.4 双缓冲翻页、遥测状态快照与 BCD 硬件帧率计数器](#234-双缓冲翻页遥测状态快照与-bcd-硬件帧率计数器)
    - [2.3.5 全自主 I2C 手柄与板载按键状态解包](#235-全自主-i2c-手柄与板载按键状态解包)
  - [2.4 第四小章：dma 纯数据提取引擎详解](#24-第四小章dma-纯数据提取引擎详解)
    - [2.4.1 纯数据“自来水厂”战略定位与协议解耦范式](#241-纯数据自来水厂战略定位与协议解耦范式)
    - [2.4.2 `dma_top.v`：双通道读调度、跨时钟脉冲同步与行/场节拍控制器](#242-dma_topv双通道读调度跨时钟脉冲同步与行场节拍控制器)
    - [2.4.3 `dma_fb_reader.v`：22 突发/行扫描引擎、6-Beat 尾突发裁剪与双基址分屏](#243-dma_fb_readerv22-突发行扫描引擎6-beat-尾突发裁剪与双基址分屏)
    - [2.4.4 `dma_bucket_prefetch.v`：超前 2 行弹幕预取、80 槽 20 突发 BRAM 扁平化](#244-dma_bucket_prefetchv超前-2-行弹幕预取80-槽-20-突发-bram-扁平化)
    - [2.4.5 `async_fifo.v`：格雷码双时钟域隔离、2048 深度高低水位线与消隐复位](#245-async_fifov格雷码双时钟域隔离2048-深度高低水位线与消隐复位)
    - [2.4.6 `video_write_guard.v`：防欠载优先级守卫与死锁活锁自解引擎](#246-video_write_guardv防欠载优先级守卫与死锁活锁自解引擎)
    - [2.4.7 128b 转 32b 像素齿轮箱（Gearbox）与 `word_stall` 欠载相位冻结](#247-128b-转-32b-像素齿轮箱gearbox与-word_stall-欠载相位冻结)
    - [2.4.8 【关键复盘】上板画面撕裂 BUG 根因剖析与四重硬件防线](#248-关键复盘上板画面撕裂-bug-根因剖析与四重硬件防线)
  - [2.5 第五小章：display_engine 纯流式视频显示引擎与图层合成详解](#25-第五小章display_engine-纯流式视频显示引擎与图层合成详解)
    - [2.5.1 纯流式“艺术工坊”战略定位与“零带宽”实时多图层合成拓扑](#251-纯流式艺术工坊战略定位与零带宽实时多图层合成拓扑)
    - [2.5.2 `display_engine_top.v`：时钟域纯净解耦、CDC 场消隐原子暗影锁存](#252-display_engine_topv时钟域纯净解耦cdc-场消隐原子暗影锁存)
    - [2.5.3 `video_timing_gen.v`：1366x768 @ 75Hz 数字时序发生器与 16 周期 `frame_clear`](#253-video_timing_genv1366x768--75hz-数字时序发生器与-16-周期-frame_clear)
    - [2.5.4 实时过程化图层发生器集群（Layer 1 ~ Layer 5）](#254-实时过程化图层发生器集群layer-1--layer-5)
      - [2.5.4.1 `video_weather.v`：170-Dot LFSR 伪随机粒子与开窗遮挡](#2541-video_weatherv170-dot-lfsr-伪随机粒子与开窗遮挡)
      - [2.5.4.2 `video_bullet_overlay.v`：B1 行桶弹幕覆盖层合成器（角色与调色板分离）](#2542-video_bullet_overlayvb1-行桶弹幕覆盖层合成器角色与调色板分离)
      - [2.5.4.3 `video_laser.v`：BOSS 4路等离子高能光柱发生器与动态等离子脉冲](#2543-video_laservboss-4路等离子高能光柱发生器与动态等离子脉冲)
      - [2.5.4.4 `video_beam.v`：自机聚焦光束与 3 路 BOSS 预警切线实时发生器](#2544-video_beamv自机聚焦光束与-3-路-boss-预警切线实时发生器)
      - [2.5.4.5 `video_dual_hud.v`：双图层硬件 OSD 遥测 HUD（CPU 与 FPGA 双帧率实时比对）](#2545-video_dual_hudv双图层硬件-osd-遥测-hudcpu-与-fpga-双帧率实时比对)
    - [2.5.5 `video_pixel_compositor.v`：三级硬核流水线图层叠加与色彩混合算子](#255-video_pixel_compositorv三级硬核流水线图层叠加与色彩混合算子)
    - [2.5.6 `video_bloom_filter.v`：2D 5行各向同性卷积核、SRL 移位网络与软膝 HDR 泛光滤镜](#256-video_bloom_filterv2d-5行各向同性卷积核srl-移位网络与软膝-hdr-泛光滤镜)
    - [2.5.7 `video_color_matrix.v`：9-DSP 硬核 3x3 仿射色彩矩阵变换器](#257-video_color_matrixv9-dsp-硬核-3x3-仿射色彩矩阵变换器)
  - [2.6 第六小章：ddr3_controller 高速存储子系统详解](#26-第六小章ddr3_controller-高速存储子系统详解)
    - [2.6.1 DDR3 控制器子系统的战略定位与带宽拓扑](#261-ddr3-控制器子系统的战略定位与带宽拓扑)
    - [2.6.2 `ddr3_parameter.vh`：物理几何与 JEDEC AC 时序参数全景](#262-ddr3_parametervh物理几何与-jedec-ac-时序参数全景)
    - [2.6.3 `ddr3_top.v`：存储器控制器顶层与系统时钟树规划](#263-ddr3_topv存储器控制器顶层与系统时钟树规划)
    - [2.6.4 AXI 总线协议转换层 (`axi4_bus_ctl/`)](#264-axi-总线协议转换层-axi4_bus_ctl)
    - [2.6.5 本地命令调度与缓冲层 (`local_bus_ctl/`)](#265-本地命令调度与缓冲层-local_bus_ctl)
    - [2.6.6 JEDEC 协议核心引擎 (`memory_bus_ctl/`)](#266-jedec-协议核心引擎-memory_bus_ctl)
    - [2.6.7 物理层 PHY 与动态校准子系统 (`phy_ctl/`)](#267-物理层-phy-与动态校准子系统-phy_ctl)
    - [2.6.8 跨时钟桥与底层 FIFO 缓冲 (`lb2_axi_clk.v` & `common/`)](#268-跨时钟桥与底层-fifo-缓冲-lb2_axi_clkv--common)
  - [2.7 第七小章：hdmi 差分编码与视频物理串化详解](#27-第七小章hdmi-差分编码与视频物理串化详解)
    - [2.7.1 TMDS 协议原理与 HDMI/DVI 显示规范](#271-tmds-协议原理与-hdmidvi-显示规范)
    - [2.7.2 `encode.v`：标准 DVI 1.0 8b/10b 编码器底层深度剖析](#272-encodev标准-dvi-10-8b10b-编码器底层深度剖析)
    - [2.7.3 `dvi_encoder.v`：三通道色彩打包与时钟信道发生器](#273-dvi_encoderv三通道色彩打包与时钟信道发生器)
    - [2.7.4 板级物理层差分串化与 PCB 极性反转适配](#274-板级物理层差分串化与-pcb-极性反转适配)
  - [2.8 第八小章：Triad 架构全局走线互联与引脚映射速查表](#28-第八小章triad-架构全局走线互联与引脚映射速查表)

---

# 第一大章：RTL 项目全局目录结构与文件清点

## 1.1 `rtl/` 目录组织概览

`rtl/` 目录包含了整个硬件加速器与显示架构的全部自主设计与集成的 Verilog 代码。在最新重构演进中，系统彻底抛弃了早期将 AXI 读状态机、图层合成、时序控制和寄存器耦合在一起的单体结构，全面确立了**“三权分立（Triad Architecture）”模块化组织范式**：

```
rtl/
├── ti60_top.v                 # 全工程唯一顶层模块（统一时钟树与三权分立总集成）
├── common/                    # 系统级公用基础 IP（AXI 仲裁器、双口 RAM、I2C 手柄）
├── bitblt/                    # 2D 图形光栅化硬件加速引擎（纯绘图核心，执行 FILL/COPY/ALPHA/ADD）
├── apb/                       # APB3 中央命令分发中枢（中央统帅，分发 2D 指令与显示配置）
├── dma/                       # 显存 DMA 纯数据提取引擎（数据自来水厂，专职 AXI 读与 FIFO 供水）
├── display_engine/            # 纯流式像素渲染与多图层合成工坊（艺术工坊，图层现算、合成与滤镜）
├── ddr3_controller/           # DDR3 高速存储器控制器、仲裁器与物理 PHY 逻辑
└── hdmi/                      # DVI/HDMI 8b/10b TMDS 编码与 5:1 高速差分串行化
```

---

## 1.2 根部顶层与公用组件 (`rtl/` & `rtl/common/`)

| 文件路径 | 模块名称 | 作用与功能简析 |
| :--- | :--- | :--- |
| [rtl/ti60_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ti60_top.v) | `ti60_top` | **系统硬件总顶层**。统一引脚分配，例化并互联 PLL 时钟树、复位同步逻辑、Sapphire RISC-V SoC、AXI 多主仲裁器、DDR3 控制器、BitBLT 引擎、APB 命令分发器、DMA 读提取引擎、纯流式显示合成引擎与 HDMI 物理差分接口。 |
| [rtl/common/Axi_Mux.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/common/Axi_Mux.v) | `Axi_Mux` | **128位 AXI4 多路复用仲裁器 (3 Slave -> 1 Master)**。支持 CPU(S0)、Video DMA(S1)、BitBLT(S2) 三个主控共享访问底层 DDR3 控制器，支持优先级与轮询仲裁。 |
| [rtl/common/Axi_Mux_Param.vh](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/common/Axi_Mux_Param.vh) | - | AXI 仲裁器宏定义头文件，配置通道数量（`X3`）、突发限制、地址位宽与仲裁策略。 |
| [rtl/common/i2c_gamepad_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/common/i2c_gamepad_top.v) | `i2c_gamepad_top` | **硬件手柄 I2C 自动轮询与按键消抖引擎**。以 100 kHz 硬件时钟自动访问外挂 I2C 扩展芯片，解包 16 种按键状态并送入 APB 寄存器，免去 CPU 软件模拟 I2C 的开销。 |
| [rtl/common/simple_dual_port_ram.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/common/simple_dual_port_ram.v) | `simple_dual_port_ram` | **通用伪双口 BRAM 模块**。单时钟写、单时钟读，作为 FIFO 和行缓冲的通用硬件原语推导基底。 |

---

## 1.3 2D 图形硬件加速引擎 (`rtl/bitblt/`)

| 文件路径 | 模块名称 | 作用与功能简析 |
| :--- | :--- | :--- |
| [rtl/bitblt/bitblt_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_top.v) | `bitblt_top` | **2D 加速器顶层模块**。集成 APB 配置端、AXI 读/写双主通道、对齐移位器、Alpha 混合器与弹性 FIFO，执行 FILL / COPY / ALPHA / ADD 指令。 |
| [rtl/bitblt/bitblt_apb_regs.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_apb_regs.v) | `bitblt_apb_regs` | **APB3 寄存器文件与合法性检验器**。实现 APB 从机协议，校验矩形尺寸与 16 字节对齐，提供死锁探测看门狗及双缓冲控制寄存器。 |
| [rtl/bitblt/bitblt_stride_gen.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_stride_gen.v) | `bitblt_stride_gen` | **三迭代器 2D 地址与 Burst 发生器**。将 2D 矩形拆分为每行若干 128 位 AXI 突发，管理读/写流水线信用计数（Credit）。 |
| [rtl/bitblt/bitblt_align_shifter.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_align_shifter.v) | `bitblt_align_shifter` | **128位非对齐桶形字节旋转移位器**。利用 3 拍滑动窗口动态拼接相邻 128-bit 数据，解决源/目的显存地址低 4 位不一致导致的错位问题。 |
| [rtl/bitblt/bitblt_alpha_blend.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_alpha_blend.v) | `bitblt_alpha_blend` | **四级流水线像素混合与饱和加法器**。硬件实现纯整数 $n/255$ 算法、ColorKey 滤除、Alpha 线性插值及 $Dst + Src$ 饱和加法（用于弹幕白心）。 |
| [rtl/bitblt/bitblt_axi_read_master.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_axi_read_master.v) | `bitblt_axi_read_master` | **AXI4 读主控通道**。内置深度为 4 的请求队列，支持连续派发 AR 突发，并能根据 `rd_is_dst` 标签将源图流与背景流分流到对应 FIFO。 |
| [rtl/bitblt/bitblt_axi_master.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_axi_master.v) | `bitblt_axi_master` | **AXI4 写主控通道**。采用非阻塞式写回（BREADY 常高），接收混合完成的 128-bit 像素，动态生成 16 字节选通掩码（`wstrb`）并刷入 DDR3。 |
| [rtl/bitblt/bitblt_read_fifo.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_read_fifo.v) | `bitblt_read_fifo` | **同步弹性数据 FIFO**。采用 First-Word Fall-Through (FWFT) 模式，用于源图与目的背景读数据的弹性隔离。 |
| [rtl/bitblt/bitblt_asset_rom.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_asset_rom.v) | `bitblt_asset_rom` | **片上图形资产 ROM**。存储最基本的开机引导图元或测试贴图。 |
| [rtl/bitblt/bitblt_demo_scheduler.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_demo_scheduler.v) | `bitblt_demo_scheduler` | **硬件自动演示调度器**。在无 CPU 固件驱动的情况下自动发射填充与搬运测试指令，供脱机硬件自检。 |
| [rtl/bitblt/bg_rle.hex](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bg_rle.hex) | - | 早期固件启动背景 RLE 压缩十六进制数据文件。 |
| [rtl/bitblt/bg_rle_path.vh](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bg_rle_path.vh) | - | 背景十六进制数据的引用路径头文件。 |
| `rtl/bitblt/_v1_backup/` | - | 早期 v1 架构代码备份目录（包含串行读写、硬编码 16 突发长度的旧版文件）。 |

---

## 1.4 中央命令分发中枢 (`rtl/apb/`)

| 文件路径 | 模块名称 | 作用与功能简析 |
| :--- | :--- | :--- |
| [rtl/apb/apb_command_dispatcher.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/apb/apb_command_dispatcher.v) | `apb_command_dispatcher` | **中央司令部（Central Military Command）**。挂接 Sapphire RISC-V SoC 的 APB3 从机接口，统一解包并向下游广播纯 2D 指令总线（`bitblt_cmd_*`）、纯显示配置总线（`display_cfg_*`）、双缓冲换页基址、遥测快照与全自主 I2C 手柄按键状态。 |

---

## 1.5 显存 DMA 纯数据提取引擎 (`rtl/dma/`)

| 文件路径 | 模块名称 | 作用与功能简析 |
| :--- | :--- | :--- |
| [rtl/dma/dma_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/dma_top.v) | `dma_top` | **纯数据自来水厂总装（Pure Water Supply Plant）**。协调 Framebuffer 扫描读与行桶预取读之间的 AXI 内部仲裁，通过 2048 深度异步 FIFO 实现 100MHz 到 85.714MHz 跨时钟隔离，内置 128b->32b 像素齿轮箱与 `word_stall` 欠载相位冻结逻辑。 |
| [rtl/dma/dma_fb_reader.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/dma_fb_reader.v) | `dma_fb_reader` | **显存帧缓冲扫描读状态机**。计算行起始地址，每行精准派发 21 次 16-Beat 突发 + 1 次 6-Beat 尾突发（合计 342 拍 128-bit 字），支持左右半屏双基址分屏显示。 |
| [rtl/dma/dma_bucket_prefetch.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/dma_bucket_prefetch.v) | `dma_bucket_prefetch` | **行桶弹幕超前预取引擎**。在每行扫描期间超前 2 行向 DDR3 读取 80 槽弹幕描述符（20 拍 AXI 突发），存入片上 BRAM 并在行消隐期间瞬间扁平化为 2560 位宽并行总线。 |
| [rtl/dma/async_fifo.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/async_fifo.v) | `async_fifo` | **跨时钟域异步 FIFO 缓冲器**。2048 深度格雷码指针隔离，提供精确的写使用量（`wusedw`）水位监控（阈值 1400/1920），并在场消隐脉冲 `t_frame_clear` 到来时彻底清空内部残留。 |
| [rtl/dma/video_write_guard.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/video_write_guard.v) | `video_write_guard` | **防欠载优先级写守卫**。监听 FIFO 水位低预警（`video_read_priority`），在扫描读缺水时强行阻断 BitBlt 写入 DDR3，确保读扫描带宽绝对优先，杜绝显存读断流。 |

---

## 1.6 纯流式像素渲染与多图层合成工坊 (`rtl/display_engine/`)

| 文件路径 | 模块名称 | 作用与功能简析 |
| :--- | :--- | :--- |
| [rtl/display_engine/display_engine_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/display_engine_top.v) | `display_engine_top` | **纯流式艺术工坊总装（Pure Art Workshop）**。完全运行在纯净的 85.714 MHz 视频像素时钟域，零 AXI 总线依赖，集成时序发生、5 大图层过程化生成、三级硬核合成器及 Bloom/色彩矩阵后处理。 |
| [rtl/display_engine/1_timing/video_timing_gen.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/1_timing/video_timing_gen.v) | `video_timing_gen` | **1366x768 @ 75Hz 时序基准源**。产生标准行场同步、消隐信号、提前 8 行预充脉冲 `frame_start` 以及持续 16 像素时钟的场结束复位脉冲 `frame_clear`。 |
| [rtl/display_engine/2_layer_generators/video_weather.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/2_layer_generators/video_weather.v) | `video_weather` | **【Layer 1】全屏天气粒子发生器**。内置 170-Dot LFSR 伪随机数算法，动态生成雪花、余烬与火星，支持开窗防遮挡矩形。 |
| [rtl/display_engine/2_layer_generators/video_bullet_overlay.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/2_layer_generators/video_bullet_overlay.v) | `video_bullet_overlay` | **【Layer 2】B1 行桶弹幕图层实时合成器**。根据超前扁平化的 80 槽弹幕描述符，片上查表取出单通道角色点阵并映射 256 色调色板，**0 DDR 显存写消耗**。 |
| [rtl/display_engine/2_layer_generators/video_laser.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/2_layer_generators/video_laser.v) | `video_laser` | **【Layer 3】BOSS 4路等离子高能光柱发生器**。硬件现算高斯能量衰减与白芯高光，生成通天彻地的动态等离子激光柱。 |
| [rtl/display_engine/2_layer_generators/video_beam.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/2_layer_generators/video_beam.v) | `video_beam` | **【Layer 4】自机光束与预警切线发生器**。硬件实时合成自机 16 像素宽聚焦光束及 BOSS 施法前的 3 组彩色预警标线，消除画细线对 DDR 的巨大惩罚。 |
| [rtl/display_engine/2_layer_generators/video_dual_hud.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/2_layer_generators/video_dual_hud.v) | `video_dual_hud` | **【Layer 5】双图层硬件 OSD 遥测 HUD**。内置点阵字模，硬件直译 BCD 码实时在屏幕两侧绘制 CPU/FPGA 双帧率、GPU 占用、弹幕计数与血条。 |
| [rtl/display_engine/3_compositor/video_pixel_compositor.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/3_compositor/video_pixel_compositor.v) | `video_pixel_compositor` | **三级流水线多图层色彩混合器**。Stage 1 融合天气与弹幕；Stage 2 叠加高能激光；Stage 3 叠加自机光束与 HUD，并输出供 Bloom 识别的发光掩码 `comp_a`。 |
| [rtl/display_engine/4_post_process/video_bloom_filter.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/4_post_process/video_bloom_filter.v) | `video_bloom_filter` | **2D 各向同性 SRL8 硬件 Bloom 滤镜**。提取发光掩码，利用 SRL8 延迟网络在水平方向扩散流光，配合软膝 HDR 压制呈现电影级柔和辉光。 |
| [rtl/display_engine/4_post_process/video_color_matrix.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/4_post_process/video_color_matrix.v) | `video_color_matrix` | **9-DSP 硬核 3x3 仿射色彩矩阵变换器**。利用 9 个 DSP 硬乘法器实时对 RGB 执行矩阵变换，实现受击白闪、符卡泛红与子弹时间黑白化。 |

---

## 1.7 DDR3 存储器控制器与物理 PHY (`rtl/ddr3_controller/`)

| 文件路径 | 模块名称 | 作用与功能简析 |
| :--- | :--- | :--- |
| [rtl/ddr3_controller/ddr3_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/ddr3_top.v) | `ddr3_top` | **DDR3 控制器硬件顶层**。对外连接 DDR3 SDRAM 颗粒物理引脚，对内提供 128 位 AXI4 从机接口。 |
| [rtl/ddr3_controller/ddr3_parameter.vh](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/ddr3_parameter.vh) | - | DDR3 协议时序参数头文件（定义 tRCD、tRP、tRAS、tREFI 及 16 位位宽/256MB 容量参数）。 |
| [rtl/ddr3_controller/lb2_axi_clk.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/lb2_axi_clk.v) | `lb2_axi_clk` | 本地总线时钟与 AXI4 时钟之间的异步时钟转换桥。 |
| `axi4_bus_ctl/` | `axi4_bus_ctl`, `axi_upsizer` | AXI 协议解析模块，将外部 AXI 事务转换为内部定长读写命令并做位宽缩放。 |
| `local_bus_ctl/` | `local_bus_ctl` | 本地突发调度器，执行读写排队与自动刷新（Auto-Refresh）调度。 |
| `memory_bus_ctl/` | `memory_bus_ctl` | DDR3 状态机引擎，将命令转化为严格的 ACT、PRE、RD、WR 等物理引脚电平。 |
| `phy_ctl/` | 包含 `phy_ctl.v` 等 7 个文件 | **物理层 PHY 与动态调平子系统**。上电执行 DQS 读写门控对齐、Write Leveling 调平、MPR 读校准，输出 `cal_done`。 |
| `common/` | 包含 `simple_dual_port_ram.v` 等 | 内部突发队列使用的标准双口 RAM 与 FIFO 原语包装。 |

---

## 1.8 HDMI / DVI 差分编码与发送 (`rtl/hdmi/`)

| 文件路径 | 模块名称 | 作用与功能简析 |
| :--- | :--- | :--- |
| [rtl/hdmi/dvi_encoder.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/hdmi/dvi_encoder.v) | `dvi_encoder` | **DVI 编码与物理串化发送顶层**。包含 3 组 RGB 8b/10b 编码器和时钟通道，利用 Titanium 5:1 齿轮箱串化为 428.57 MHz 差分信号。 |
| [rtl/hdmi/encode.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/hdmi/encode.v) | `encode` | **标准 TMDS 8b/10b 编码核心**。最小化直流偏置，并在行场消隐期间插入固定的同步控制字符。 |

---

# 第二大章：核心硬件子系统源码级深度剖析

---

## 2.1 第一小章：BitBLT 2D 硬件图形加速引擎详解

> **所属目录**：`rtl/bitblt/`  
> **核心使命**：提供硬件级的 2D 矩形显存填充、精灵高速贴图搬运、Alpha 混合及饱和加法，免除 CPU 逐像素读写 DDR3 带来的严重掉帧。

---

### 2.1.1 BitBLT 引擎整体架构与流水线数据流图

BitBLT 引擎在系统内部构成了一条高度流水化的 128 位（单拍 4 像素 ARGB8888）数据通道：

```
                    ┌───────────────────────────────┐
                    │  CPU APB3 Bus (0xF810_0000)   │
                    └───────────────┬───────────────┘
                                    │ PADDR / PWDATA / PSEL / PENABLE
                                    ▼
                    ┌───────────────────────────────┐
                    │       bitblt_apb_regs         │
                    │  (参数校验 / 看门狗 / 状态寄存器) │
                    └───────────────┬───────────────┘
                                    │ cmd_start / cmd_op_type / 几何参数
                                    ▼
                    ┌───────────────────────────────┐
                    │       bitblt_stride_gen       │◄───────────────────────┐
                    │ (三迭代器 2D 跨距与 Burst 发生器) │                       │
                    └───────┬───────────────┬───────┘                        │
            rd_req (Source) │               │ rd_req (Dst Background)       │
            rd_is_dst = 0   │               │ rd_is_dst = 1                  │
                            ▼               ▼                                │
                 ┌─────────────────────────────────────┐                     │
                 │        bitblt_axi_read_master       │                     │
                 │   (并发 AXI 读通道, 深度为 4 请求队列)  │                     │
                 └──────────┬───────────────┬──────────┘                     │
             fifo_winc_src  │               │ fifo_winc_dst                  │
                            ▼               ▼                                │
                    ┌──────────────┐ ┌──────────────┐                        │
                    │u_read_fifo   │ │u_dst_fifo    │                        │
                    │(源图像弹性缓冲)│ │(目的背景缓冲) │                        │
                    └───────┬──────┘ └──────┬───────┘                        │
                            │ fifo_rdata    │                                │
                            ▼               │                                │
                    ┌──────────────┐        │                                │
                    │align_shifter │        │                                │
                    │(3拍滑动窗口   │        │                                │
                    │ 128位桶形移位)│        │                                │
                    └───────┬──────┘        │                                │
          realigned_stream  │               │ background_stream              │
                            ▼               ▼                                │
                 ┌─────────────────────────────────────┐                     │
                 │          bitblt_alpha_blend         │                     │
                 │  - ColorKey 穿透判断                 │                     │
                 │  - 4 级流水线 Alpha 线性插值          │                     │
                 │  - OP_ADD 8-bit 饱和加法混合器       │                     │
                 └──────────────────┬──────────────────┘                     │
                                    │ blended_stream / out_mask              │
                                    ▼                                        │
                         ┌──────────────────────┐                            │
                         │   bitblt_axi_master  │                            │
                         │ (非阻塞 AXI 写通道,   │                            │
                         │  生成 16 字节选通掩码) │                            │
                         └──────────┬───────────┘                            │
                                    │ burst_done (信用分递还) ─────────────────┘
                                    ▼
                         ┌──────────────────────┐
                         │   AXI4 Write to DDR3 │
                         └──────────────────────┘
```

---

### 2.1.2 `bitblt_top.v`：顶层集成、总线互联与流控仲裁

* **源码定位**：[rtl/bitblt/bitblt_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_top.v)
* **核心参数**：
  - `MAX_BURST_BEATS = 64`：AXI 单次突发最大拍数（64 拍 $\times$ 16 字节 = 1 KiB 边界）。
  - `READ_FIFO_DEPTH = 192`：源读 FIFO 深度。
  - `DST_FIFO_DEPTH = 192`：目的背景读 FIFO 深度。
  - `PREFETCH_BEATS = 2`：对齐移位器的预取深度门限。

#### 1. 核心架构与设计决策
`bitblt_top` 是将所有子模块组装为完整加速器的中枢。它解决了**读写并发死锁**与**多数据流仲裁**问题：
- **双读流单主控设计**：在执行 `OP_ALPHA`（透明混合）与 `OP_ADD`（饱和加法）时，不仅需要读取源贴图（Source），还必须把屏幕底色（Destination Background）读回来进行算术混合。由于 DDR3 控制器只有一个 AR 通道，模块通过内部标签 `rd_is_dst` 让两个读流共用 `bitblt_axi_read_master`，并在返回时将数据精准分流进 `u_read_fifo` 与 `u_dst_fifo`。
- **FIFO 深度与信用额度约束**：
  $$\text{DST\_FIFO\_DEPTH} \ge 2 \times \text{MAX\_BURST\_BEATS} + 4$$
  因为 `stride_gen` 在派发读请求时是按“整突发”预扣除信用分，若 FIFO 过浅，会导致前一个突发尚未写完、后一个突发被拒收，从而发生流水线永久死锁。因此工程将 FIFO 深度定为 192。

#### 2. 关键输入输出与内部总线
* **APB 从机接口**：`apb_paddr[15:0]`, `apb_psel`, `apb_penable`, `apb_pwrite`, `apb_pwdata`, `apb_prdata`, `apb_pready`。
* **AXI4 读主控通道**：`m_axi_araddr[27:0]`, `m_axi_arlen[7:0]`, `m_axi_arvalid`, `m_axi_arready`, `m_axi_rdata[127:0]`, `m_axi_rlast`, `m_axi_rvalid`, `m_axi_rready`。
* **AXI4 写主控通道**：`m_axi_awaddr[27:0]`, `m_axi_awlen[7:0]`, `m_axi_awvalid`, `m_axi_awready`, `m_axi_wdata[127:0]`, `m_axi_wstrb[15:0]`, `m_axi_wlast`, `m_axi_wvalid`, `m_axi_wready`。
* **双缓冲切换握手**：`vdma_next_base[27:0]` 输出给扫描端。

---

### 2.1.3 `bitblt_apb_regs.v`：APB3 寄存器文件、合法性校验与看门狗

* **源码定位**：[rtl/bitblt/bitblt_apb_regs.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_apb_regs.v)

#### 1. 核心职责与设计理念
- **参数校验与防死机机制（Validation Guard）**：
  在早期 v1 版本中，若软件传入未 16 字节对齐的行跨距（Stride）或非法的长宽，引擎会无限空转等待 `burst_done`，导致 CPU 驱动轮询 `STATUS` 永久挂死。v3 版本在硬件中增加了**前置参数严格校验**：
  - 检查 `cmd_src_stride[3:0] == 0` 且 `cmd_dst_stride[3:0] == 0`（必须 16 字节对齐）。
  - 检查 `cmd_rect_w > 0` 且 `cmd_rect_h > 0`。
  - 对于带混合的操作，校验源与目的地址是否对齐至 4 字节像素边界。
  - **若校验失败**：立即置位状态寄存器的 `ERROR` 粘滞位，**直接产生 `cmd_done` 假完成响应**，彻底避免 CPU 挂起。
- **硬件实时探针 (`0x74 ENGINE_PROBE`)**：
  通过 APB `0x74` 寄存器将 `bitblt_top` 内部最隐秘的状态打包暴露给软件驱动：
  - `[3:0] rd_q_cnt`：读主控内部待处理请求队列计数（0..8）。
  - `[4] rd_ar_pend`：AR 地址通道上正挂起握手的请求。
  - `[9:8] sg_state`：`stride_gen` 的主状态机（0=IDLE, 2=S_LOOP）。
  若出现引擎报告 `BUSY` 但 `sg_state == 0` 且 `rd_q_cnt > 0`，软件可立即断定为读突发泄露，通过复位恢复。
- **看门狗超时定时器（Watchdog Timer）**：
  内置 1000 万周期（100 ms）硬件计数器，若单次绘图指令超过 100 ms 未完成，强制终止并拉起超时标志。

#### 2. 关键寄存器空间映射表 (基址 `0xF810_0000`)

| 偏移地址 | 寄存器名称 | 读/写 | 详细位域定义与功能说明 |
| :--- | :--- | :---: | :--- |
| `0x00` | `REG_STATUS` | R | `[0]`: 引擎 Busy 状态（1=运行中）；`[1]`: 换页请求挂起；`[2]`: 参数配置错误；`[3]`: 看门狗超时。 |
| `0x04` | `REG_DST_ADDR` | R/W | `[27:0]`: 目标表面显存绝对起始字节地址（需 16 字节对齐）。 |
| `0x08` | `REG_RECT_W` | R/W | `[10:0]`: 绘制矩形宽度（像素为单位，1..1366）。 |
| `0x0C` | `REG_RECT_H` | R/W | `[10:0]`: 绘制矩形高度（像素为单位，1..768）。 |
| `0x10` | `REG_COLOR` | R/W | `[31:0]`: `OP_FILL` 纯色填充使用的 32 位 ARGB8888 颜色值。 |
| `0x14` | `REG_START` | W | 写 `1` 触发指令校验与状态机启动。 |
| `0x18` | `REG_OP_TYPE` | R/W | `[1:0]`: 操作码。`0`: OP_FILL, `1`: OP_COPY, `2`: OP_ALPHA, `3`: 保留。 |
| `0x1C` | `REG_SRC_ADDR` | R/W | `[27:0]`: 源贴图显存绝对起始字节地址。 |
| `0x20` | `REG_LEFT_NEXT` | R/W | `[27:0]`: 软件请求切换的左屏/主显存前台缓冲基址。 |
| `0x24` | `REG_VSYNC_STS`| R | `[0]`: 硬件垂直消隐标志（1=当前处于场消隐期）。 |
| `0x30` | `REG_SRC_STRIDE`| R/W | `[15:0]`: 源图像全图跨距（行字节步进，必须为 16 的倍数）。 |
| `0x48` | `REG_DST_STRIDE`| R/W | `[15:0]`: 目的图像全图跨距（行字节步进，必须为 16 的倍数）。 |
| `0x60` | `REG_COLORKEY` | R/W | `[31:0]`: 透明色抠图比对值（通常为纯黑 `0x00000000`）。 |
| `0x64` | `REG_CKEY_CTRL`| R/W | `[0]`: ColorKey 抠图使能。 |
| `0x68` | `REG_ALPHA_CTRL`| R/W | `[0]`: Alpha 混合使能；`[1]`: `OP_ADD` 饱和加法混合使能。 |
| `0x6C` | `REG_GLOBAL_ALPHA`| R/W| `[7:0]`: 全局 Alpha 缩放因子（`0xFF` 表示直通原像素 Alpha）。 |
| `0x74` | `REG_ENGINE_PROBE`| R | `[3:0]`: `rd_q_cnt`; `[4]`: `rd_ar_pend`; `[9:8]`: `sg_state`。死锁诊断探针。 |

---

### 2.1.4 `bitblt_stride_gen.v`：三迭代器 2D 跨距与 AXI 突发状态机

* **源码定位**：[rtl/bitblt/bitblt_stride_gen.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_stride_gen.v)

#### 1. 核心架构与 2D 几何规划
`bitblt_stride_gen` 是 BitBLT 的“指挥官”。它负责将软件传入的 2D 矩形（宽 W, 高 H）在空间上解构为一行行由 128 位数据组成的 AXI 突发事务：
- **行几何学计算公式**：
  $$\text{row\_bytes} = \text{dst\_off} + 4 \times \text{rect\_w} \quad (\text{dst\_off} = \text{dst\_addr}[3:0])$$
  $$N_{\text{write}} = \left\lceil \frac{\text{row\_bytes}}{16} \right\rceil$$
  $$N_{\text{read}} = N_{\text{write}} + 1 \quad (\text{预取 1 拍用于对齐滑动窗口})$$
  $$N_{\text{dst\_rd}} = N_{\text{write}} \quad (\text{背景读出拍数严格等于写入拍数})$$
- **三迭代器并发（Tri-Iterator Concurrency）**：
  引擎维护三个并发计数器：
  1. `rd_cur_x`：源贴图读取位置，在 FIFO 有余量（Credit 充足）时超前派发；
  2. `dst_rd_cur_x`：背景读取位置，按需提取当前要写入的底色像素；
  3. `wr_cur_x`：写入位置，紧随对齐移位和混合流水线之后。
  通过这种解耦设计，**第 $N+1$ 个数据块的读出与第 $N$ 个数据块的写入在总线上重叠并行**，大幅提升了 DDR3 总线利用率。

#### 2. 主状态机跳转逻辑
```
  ┌────────┐  cmd_start   ┌────────┐  行首初始化   ┌────────┐  完成一行
  │ S_IDLE ├─────────────►│ S_INIT ├─────────────►│ S_LOOP ├──────────┐
  └────────┘              └────────┘              └───┬────┘          │
      ▲                                               │               │
      │                  所有行全部完成               │               ▼
      └───────────────────────────────────────────────┴───────── S_NEXT_ROW
```
- **`S_IDLE`**：空闲监听 `cmd_start` 脉冲。
- **`S_INIT`**：根据 `rect_w` 与地址低位初始化单行拍数、首拍掩码 `burst_wstrb_first` 与末拍掩码 `burst_wstrb_last`。
- **`S_LOOP`**：根据 `MAX_BURST_BEATS`（64）拆分切片，生成 `rd_req`、`rd_len` 与 `burst_req`。
- **`S_NEXT_ROW`**：行计数递减，源地址累加 `cmd_src_stride`，目的地址累加 `cmd_dst_stride`，跳回 `S_LOOP` 继续下一行。

---

### 2.1.5 `bitblt_align_shifter.v`：三拍滑动窗口与 128 位桶形对齐移位器

* **源码定位**：[rtl/bitblt/bitblt_align_shifter.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_align_shifter.v)

#### 1. 为什么必须存在（痛点背景）
AXI4 总线事务强制要求地址按 16 字节对齐（低 4 位为 0）。然而在实际游戏渲染中，精灵贴图在显存中的起始位置（`src_addr`）与目标屏幕贴图坐标（`dst_addr`）的低 4 位偏移量 $\sigma$ 往往不相等：
$$\sigma = (\text{src\_addr}[3:0] - \text{dst\_addr}[3:0]) \pmod{16}$$
若没有对齐移位器，整张图片在拷贝时就会产生 $1 \sim 15$ 个字节（约 $1 \sim 3$ 个像素）的横向几何错位。

#### 2. 硬件实现原理（三拍滑动窗口）
- **滑动窗口寄存器 `win`**：内部维护一个 $3 \times 128 = 384$ 位宽的移位寄存器：
  $$\text{win} = \{ D(k+1), D(k), D(k-1) \}$$
  其中最新读出的 128 位 beat 存入最高位通道。
- **桶形抽取公式**：
  $$\text{Output Beat } k = \text{win}[(16 + \sigma) \times 8 +: 128]$$
  移位参数在整条指令期间为常数，硬件综合为轻量的 4 级多路选择器（分别对应 1、2、4、8 字节旋转）。
- **预取门限与流控（Pop Policy）**：
  必须等源读 FIFO 预读出两拍（`PREFETCH_BEATS = 2`）并灌入窗口后，`beat_valid` 才会拉高，通知后级混合器和写主控开始吃数据。当写通道确认消耗一拍（`beat_ack` 脉冲）时，窗口滑动并从 FIFO 补充一拍。

---

### 2.1.6 `bitblt_alpha_blend.v`：四级流水线 Alpha 混合与饱和加法器

* **源码定位**：[rtl/bitblt/bitblt_alpha_blend.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_alpha_blend.v)

#### 1. 核心数学模型与精确除法推导
- **Alpha 混合物理公式**：
  $$\alpha_e = \frac{A_{\text{src}} \times \text{GLOBAL\_ALPHA} + 127}{255}$$
  $$\text{Color}_{\text{out}} = \frac{\text{Src} \times \alpha_e + \text{Dst} \times (255 - \alpha_e) + 127}{255}$$
- **硬件除以 255 的快速恒等式**：
  标准数字电路中除以 255 极度昂贵，本项目采用经过数学严格验证的加法移位恒等式（在 $0 \le n \le 65152$ 范围内完全精确）：
  $$\lfloor n / 255 \rfloor \equiv (n + 1 + (n \gg 8)) \gg 8$$
  利用此特性，将分子重写为：
  $$n = 255 \times \text{Dst} + 127 + \alpha_e \times (\text{Src} - \text{Dst})$$
  其中 $255 \times \text{Dst} = (\text{Dst} \ll 8) - \text{Dst}$（仅需移位减法）。**每个色彩通道只需 1 个 $9 \times 8$ 有符号乘法器**，相较传统架构节省了 50% 的乘法资源！

#### 2. `OP_ADD` 饱和加法混合机制
在弹幕射击游戏中，多重光环与大玉子弹重叠时，不能使用变暗的 Alpha 混合，必须使用加法叠亮：
$$\text{Color}_{\text{out}} = \min(255, \text{Src} + \text{Dst})$$
在 `is_add == 1` 时，四级流水线绕过乘法器，直接以 9 位无符号加法器执行加和：若第 8 位溢出位为 1，则输出强行截断钳位为 `8'd255`。纯黑背景底色（RGB=0）天然透明加算（$Dst + 0 = Dst$），多颗子弹重叠处迅速汇聚为高亮白芯。

#### 3. 四级打拍流水线（Pipeline Latency = 4）
- **P0**：锁存源像素 `src_data`、背景像素 `dst_data` 以及字节保留掩码。进行 ColorKey 比较，若命中则立即关闭该像素的 4 字节写使能。
- **P1**：计算有效 Alpha $\alpha_e$（执行 $8 \times 8$ 乘法并除以 255）。
- **P2**：计算颜色差值基底与乘积项 $\alpha_e \times (\text{Src} - \text{Dst})$（9位有符号乘法）。
- **P3**：执行 18 位加法并带入快速除法，将 4 个像素拼接为 128 位 `out_data`。
- **Hold**：一级弹性缓冲寄存器，在写主控反压时锁存数据，防止流水线数据丢失。

---

### 2.1.7 `bitblt_axi_read_master.v`：多请求队列与并发 AXI 读通道

* **源码定位**：[rtl/bitblt/bitblt_axi_read_master.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_axi_read_master.v)

#### 1. 核心架构改进（v3 到 v4 的并发飞跃）
- **单突发阻塞的瓶颈**：早期 v3 版本每次只敢下发一个 AR 读请求，必须死等 DDR3 控制器返回 `RLAST` 信号后才回到空闲状态。由于 DDR3 控制器存在近百个时钟周期的往返延迟，导致全屏贴图搬运只能达到 30 FPS。
- **深度为 4 的多未决突发队列（Outstanding Queue）**：
  v4 引入了参数化请求队列（`MAX_OUTSTANDING = 4`），连续向 AXI 派发背靠背（Back-to-Back）读请求，使 DDR3 控制器预先完成 Bank 激活与流水线排队。
- **保序返回特性（In-Order Completion）**：
  由于底层的 `Axi_Mux` 和 DDR3 控制器严格按 AR 发送顺序返回读数据，队列只需按 FIFO 顺序在头部（Head）记录：① 该突发属于源图还是目的背景（`q_is_dst`）；② 突发长度（`q_len`）。每当捕获到 `m_axi_rlast && m_axi_rvalid && m_axi_rready`，队列头出队，发出 `rd_done` 脉冲递减对应通道的在途计数。

#### 2. 关键流控握手
- `rd_accept`：只有当内部队列未满且未在当前拍出队时拉高，`stride_gen` 依靠此电平信号确定请求被成功接收。
- `fifo_winc_src` / `fifo_winc_dst`：根据当前返回数据的标签，精确产生对应 FIFO 的写使能，实现单总线双流自动拆分。

---

### 2.1.8 `bitblt_axi_master.v`：非阻塞 AXI 写通道与动态字节选通

* **源码定位**：[rtl/bitblt/bitblt_axi_master.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_axi_master.v)

#### 1. 关键设计亮点
- **非阻塞 B 响应处理（Posted Writes）**：
  传统 AXI 设计会在写完数据后停留在等待写响应状态（`S_B`），直到收到 `BVALID` 握手。本项目将 `m_axi_bready` 永久拉高，**在最后一个 W 拍（`m_axi_wlast`）成功握手的瞬间就触发 `burst_done`** 并退出状态机。这使得写突发完成信号与数据离开 FIFO 的时机精确重合，信用分释放更加及时。
- **动态字节掩码合成（`m_axi_wstrb`）**：
  写通道接收首拍掩码 `burst_wstrb_first`、末拍掩码 `burst_wstrb_last` 以及混合器传来的 ColorKey 掩码 `stream_mask`。在写入 DDR3 时，三者进行按位与操作：
  - 非矩形边界内的边缘残缺像素不被写入；
  - 命中 ColorKey 透明色的像素对应的 4 个字节选通全置 0；
  - 只有合法像素才会被 DDR3 颗粒物理写入，完美支持非 16 字节对齐的图形贴图。

---

### 2.1.9 `bitblt_read_fifo.v`：弹性同步读 FIFO 模块

* **源码定位**：[rtl/bitblt/bitblt_read_fifo.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_read_fifo.v)
* **参数与结构**：
  - `DATA_WIDTH = 128`，`DEPTH = 192`，`ADDR_WIDTH = 8`。
  - 采用 **First-Word Fall-Through (FWFT)** 机制：只要 FIFO 非空，读指针处的数据就立即呈现在 `fifo_rdata` 总线上，无需等待 `rinc` 产生额外的一个时钟周期延迟，极大简化了移位器滑动窗口的推进控制逻辑。
  - 在 `bitblt_top` 中例化了两组：一组作为 `u_read_fifo` 存放源贴图数据，另一组作为 `u_dst_fifo` 存放目的背景读回数据。

---

### 2.1.10 辅助与支撑模块：`bitblt_asset_rom.v`、`bitblt_demo_scheduler.v`、`bg_rle.*` 与 `_v1_backup/`

1. **[rtl/bitblt/bitblt_asset_rom.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_asset_rom.v)**：
   片上字模与微小图标 ROM，利用 BRAM 推导，存放开机或调试期免 DDR 加载的轻量资产。
2. **[rtl/bitblt/bitblt_demo_scheduler.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bitblt_demo_scheduler.v)**：
   用于纯硬件自主验证的调度状态机。在没有烧录 RISC-V 固件时，上电后自动产生一系列往返移动、填充变色的测试矩形命令，驱动 BitBLT 引擎进行回放演示，用于产线快速点屏。
3. **[rtl/bitblt/bg_rle.hex](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bg_rle.hex) 与 [rtl/bitblt/bg_rle_path.vh](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/bitblt/bg_rle_path.vh)**：
   早期用于静态背景初始化的 RLE 压缩数据文件及相对包含路径宏。
4. **`rtl/bitblt/_v1_backup/` 文件夹**：
   早期版本归档。保留了未优化突发长度、单突发阻塞读写的历史代码，可供对比研究体系结构演进历程。

---

## 2.2 第二小章：common 基础公用组件详解

> **所属目录**：`rtl/common/`  
> **核心使命**：提供跨模块共享的底层基础设施，包括系统级 128 位 AXI4 高速总线仲裁网络、全自主硬件手柄 I2C 轮询控制器以及硬件 BRAM 原语封装。

---

### 2.2.1 `common` 目录的系统定位与职责

在大型 SoC 与 FPGA 系统架构中，`common/` 目录并不承担具体的图形渲染计算，而是承担**系统骨架连接与底层硬件抽象**的关键职能：
1. **总线枢纽（Bus Fabric）**：连接 CPU、DMA 读引擎与 2D 加速器三个 AXI 主机至单一 DDR3 控制器，解决总线带宽争用、通道死锁与地址路由。
2. **零 CPU 占用外设硬件化**：将传统由 CPU 软件模拟（Bit-banging）或中断轮询的外设协议（如 I2C 游戏手柄）彻底交由硬件状态机全自动处理，节省宝贵的 CPU 运算时钟。
3. **平台通用存储原语推导**：屏蔽 EDA 工具链的底层原语差异，以标准可综合 Verilog 模式推导出高效的 Block RAM。

---

### 2.2.2 `Axi_Mux.v`：128 位 AXI4 3 进 1 出总线仲裁器深度剖析

* **源码定位**：[rtl/common/Axi_Mux.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/common/Axi_Mux.v)
* **参数配置**：
  - 数据总线位宽：`AXI_DATA_WIDTH = 128`（单拍 16 字节）
  - 地址总线位宽：`AXI_ADDR_WIDTH = 28`（寻址 256 MB DDR3）
  - 从机 ID 位宽：`SLAVE_ID_WIDTH = 4`，主机 ID 位宽：`MASTER_ID_WIDTH = 6`
  - 通道使能宏：定义 `X3`，代表 3 从机进 1 主机出（3 Slave -> 1 Master）

#### 1. 模块设计背景与 3-Slave -> 1-Master 拓扑
在本项目中，DDR3 存储器控制器对外只提供单个 128 位的 AXI4 从机接口，但系统内有三个并发发起方需要高频访问显存：
- **Slave 0 (S0)**：Sapphire RISC-V SoC 软核（CPU 指令与数据访存、DDR 资产搬运）；
- **Slave 1 (S1)**：Video DMA 读通道（75 Hz 视频行扫描、每秒硬性读取 4.32 MB $\times$ 75 = 324 MB/s 像素底图）；
- **Slave 2 (S2)**：BitBLT 2D 硬件图形加速器（贴图拷贝、矩形填充、Alpha 混合读写）。

`Axi_Mux` 充当了全系统的“高速十字路口”，确保 S0、S1、S2 互不干扰且无死锁地共享 DDR3。

```
     ┌────────────────────────┐
     │  S0: Sapphire RISC-V   │
     │  (CPU AXI Master)      │
     └───────────┬────────────┘
                 │
     ┌───────────▼────────────┐
     │  S1: Video DMA Read    │
     │  (Scanout AXI Master)  │
     └───────────┬────────────┘
                 │                ┌──────────────────────────────────────┐
                 ├───────────────►│               Axi_Mux                │
                 │                │  (128-bit, 3S -> 1M Multiplexer)     │
     ┌───────────┴────────────┐   │                                      │
     │  S2: BitBLT Accelerator│   │  - Axi_Mux_Addr_Ctrl (AR/AW 仲裁)     ├──────► M0: DDR3 Controller
     │  (2D Engine Read/Write)│   │  - Axi_Mux_Rd_Ctrl   (R 返回路由)    │        (128-bit AXI4 Slave)
     └────────────────────────┘   │  - Axi_Mux_Wr_Ctrl   (W/B 写流控制)  │
                                  │  - Info_Fifo_Axi_Mux (未决解耦 FIFO) │
                                  └──────────────────────────────────────┘
```

#### 2. 五大内部子模块层次架构与协同机制
`Axi_Mux.v` 内部由 5 个高度解耦的子模块构成：

1. **`Axi_Mux_Addr_Ctrl`（地址仲裁与通道切换控制器）**：
   - 仲裁写地址（AW）与读地址（AR）通道。
   - 维护通道切换状态机 `Sta_Cnl_Switch`。当某个 Slave 发起 `VALID` 请求且未被屏蔽时，仲裁器评估当前授权（Grant），并在完成握手后将地址、突发长度（`LEN`）、突发大小（`SIZE`）透传至底层 Master 端口。
2. **`Axi_Mux_Rd_Ctrl`（读数据路由控制器）**：
   - 监听底层的读数据通道（`I_M_R_*`）。
   - 由于 DDR3 控制器返回的读数据是严格按照 AR 下发顺序返回的，该模块从 `Info_Fifo_Axi_Mux` 中弹出当前返回数据对应的源从机编号，将 `RDATA`、`RRESP`、`RLAST` 与 `RVALID` 准确反向路由回对应的 S0、S1 或 S2。
3. **`Axi_Mux_Wr_Ctrl`（写数据与写响应分派控制器）**：
   - 负责写数据通道（W）与写响应通道（B）。
   - 根据当前被授权的写从机，将该从机的 `WDATA`、`WSTRB`（16字节掩码）、`WLAST` 连通到底层写通道；
   - 捕获底层的写响应 `I_M_B_VALID`，解包从机 ID 并送回对应从机，完成闭环。
4. **`Info_Fifo_Axi_Mux`（未决事务解耦信息 FIFO）**：
   - **解耦核心**：AXI 协议允许“地址已发出但数据尚未返回”的未决（Outstanding）状态。此 FIFO 专门在 AR 握手成功的瞬间，将发起该请求的 Slave ID 和事务元数据推入队列；数据返回时依次弹出。使得地址通道不会因为等待数据传输而停滞。
5. **`Axi_Mux_Info`（元数据包装模块）**：
   - 打包与解包 AXI 通道号、从机私有 ID 与突发属性。

#### 3. 核心仲裁算法与轮询/优先级切换 (`Cfg_Arb_Type`)
模块内部通过寄存器与参数支持两种仲裁模式：
- **模式 0：公平共享轮询模式（Round-Robin）**：
  默认工作模式。S0、S1、S2 拥有均等的访问机会。当 S2 完成一次突发后，仲裁权顺延给下一个有请求的从机，防止任何单一主设备（如持续画图的 BitBLT）独占 DDR3 带宽导致视频扫描端断流黑屏。
- **模式 1：固定优先级模式（Priority Mode）**：
  可按 S1（Video DMA，实时性最高，绝不能欠载）> S2（BitBLT）> S0（CPU）进行刚性优先级仲裁。
- **通道动态屏蔽 (`Cfg_Cnl_Mask`)**：
  支持对特定通道进行软屏蔽，便于在硬件调试期间隔离某个出问题的从机模块。

#### 4. 关键信号引脚走线表

| 通道/端口组 | 信号名称 | 宽度/方向 | 对应顶层挂接模块与系统流向 |
| :--- | :--- | :---: | :--- |
| **时钟与复位** | `Sys_Clk` / `Sys_Rst_N` | 1-bit (I) | 接 `core_clk` (100 MHz) 与同步释放的 `sys_rst_n`。 |
| **Master (M0)** | `O_M_AW_*` / `O_M_W_*` | Out | 驱动底层的 `ddr3_top` 写地址与写数据接口。 |
| **Master (M0)** | `I_M_B_*` | In | 接收 `ddr3_top` 的写响应通道。 |
| **Master (M0)** | `O_M_AR_*` | Out | 驱动 `ddr3_top` 的读地址通道。 |
| **Master (M0)** | `I_M_R_*` | In | 接收 `ddr3_top` 返回的 128 位物理读数据流。 |
| **Slave 0 (S0)** | `I_S0_AW/W/AR_*` | In/Out | 挂接 **Sapphire RISC-V SoC** 的 AXI Master。 |
| **Slave 1 (S1)** | `I_S1_AR/R_*` | In/Out | 挂接 **Video DMA Read** 读通道（S1 不使用写通道，写端拉死）。 |
| **Slave 2 (S2)** | `I_S2_AW/W/AR/R/B_*`| In/Out | 挂接 **BitBLT 2D 硬件加速引擎** 的读写主控。 |

---

### 2.2.3 `Axi_Mux_Param.vh`：多路复用参数宏定义与级联展开

* **源码定位**：[rtl/common/Axi_Mux_Param.vh](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/common/Axi_Mux_Param.vh)

#### 1. 级联宏展开原理
该头文件用于以优雅的纯宏定义方式配置 `Axi_Mux` 的物理通道数量：
- 当顶层定义了宏 `` `define X3`` 时，头文件内部会依次向下级联触发：
  ```verilog
  `ifdef X3
    `define X2
  `endif
  ```
- 最终展开计算出总通道宏：
  ```verilog
  `define Axi_Chnanel_Num 3
  ```
- 这种设计允许该 AXI 仲裁 IP 在 2 到 8 个端口之间任意平滑裁剪配置，代码无需做任何结构性修改即可被其他工程直接复用。

---

### 2.2.4 `i2c_gamepad_top.v`：全自主硬件手柄 I2C 轮询与板载按键消抖引擎

* **源码定位**：[rtl/common/i2c_gamepad_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/common/i2c_gamepad_top.v)
* **核心参数**：
  - `CLK_FREQ_HZ = 100_000_000`：系统时钟 100 MHz
  - `I2C_FREQ_HZ = 100_000`：标准 I2C 通信速率 100 kHz

#### 1. 核心设计目标：CPU 零负担的手柄输入硬件化
在街机与游戏机开发中，手柄读取通常采用 CPU 模拟 I2C 时序或定时中断查询。但这在 75 FPS 高速射击游戏中会造成严重的中断抖动与指令流水线气泡。  
本项目设计了**完全自主的硬件轮询状态机**：
- 硬件以严格的 **50 Hz（每 20 ms 一次）** 周期，自主发起 I2C 事务，依序轮询迷你摇杆与按键芯片（I2C 地址 `0x5A`）的 7 个内部寄存器；
- 采集结果自动锁存至内部寄存器，并直接映射到 APB 寄存器；
- CPU 任何时刻只需执行一次 32 位读指令，即可获得绝对零延迟、已去抖的游戏操作输入，**CPU 开销彻底归零**。

#### 2. 板载双按键 10ms 硬件消抖与单脉冲发生器
除了外部手柄，开发板板载两个物理按键（SW0 / SW2，低电平有效）：
- **2 级同步打拍**：`sw0_sync` 与 `sw2_sync`，消除机械按键引脚上的亚稳态。
- **10ms 硬件防抖计数器**：
  $$\text{DEBOUNCE\_CYCLES} = \frac{\text{CLK\_FREQ\_HZ}}{100} = 1,000,000 \text{ 周期 (100MHz 下)}$$
  按键状态必须连续维持 10ms 稳定，内部状态 `sw0_state` 才会发生翻转，彻底过滤物理抖动。
- **下降沿单脉冲输出**：
  同时输出稳态电平（`sw0_pressed`）与单周期脉冲（`sw0_pulse`），方便菜单选择时进行“按一次跳一格”的单次触发判定。

#### 3. 物理开漏 (Open-Drain) I2C 引脚电气驱动与亚稳态过滤
I2C 物理总线要求 SCL 和 SDA 具备“线与”开漏特性：
- 模块通过输出使能控制实现真正的硬件开漏：
  ```verilog
  assign i2c_scl_out = 1'b0;
  assign i2c_sda_out = 1'b0;
  // 当 oe = 1 时，引脚输出 0；当 oe = 0 时，引脚呈高阻态 (High-Z)，由外部 4.7K 上拉电阻拉高
  ```
- 输入引脚配置 3 级同步移位寄存器（`scl_sync`, `sda_sync`），抑制来自 40-Pin 排针引线的高频毛刺。

#### 4. 50Hz 自动轮询状态机（FSM）全流程剖析
状态机在 `scl_tick`（半时钟周期节拍，500 个 core_clk 脉冲）驱动下一步步推进。每次轮询周期（20 ms）依次执行 7 个寄存器的读取：

```
       ┌──────────┐ 20ms 定时到
       │ ST_IDLE  ├────────────┐
       └────▲─────┘            │
            │                  ▼
            │            ┌────────────┐ (写阶段: 确定要读的子寄存器)
            │            │ ST_W_START │ 产生 START 条件
            │            └─────┬──────┘
            │                  ▼
            │            ┌────────────┐
            │            │ ST_W_ADDR  │ 发送从机写地址 0xB4，检测从机 ACK
            │            └─────┬──────┘
            │                  ▼
            │            ┌────────────┐
            │            │  ST_W_REG  │ 发送目标寄存器地址 (0x10..0x24)，检测 ACK
            │            └─────┬──────┘
            │                  ▼
            │            ┌────────────┐
            │            │ ST_W_STOP  │ 产生 STOP 条件，总线空闲微等待 (~25us)
            │            └─────┬──────┘
            │                  ▼
            │            ┌────────────┐ (读阶段: 读取当前寄存器数据)
            │            │ ST_R_START │ 重新产生 START 条件
            │            └─────┬──────┘
            │                  ▼
            │            ┌────────────┐
            │            │ ST_R_ADDR  │ 发送从机读地址 0xB5，检测从机 ACK
            │            └─────┬──────┘
            │                  ▼
            │            ┌────────────┐
            │            │ ST_R_DATA  │ 移位接收 8-bit 数据，主机发送 NACK 结束
            │            └─────┬──────┘
            │                  ▼
            │            ┌────────────┐
            │            │ ST_R_STOP  │ 产生 STOP 条件，锁存当前步数据
            │            └─────┬──────┘
            │                  │
            │                  ├─── [未满 7 步] ──► reg_step++，跳回 ST_W_START
            └──────────────────┴─── [完成 7 步] ──► 刷新 gamepad_online，跳回 ST_IDLE
```

* **7 个寄存器的轮询序列与数据含义**：
  - `Step 0 (0x10)`：摇杆 X 轴模拟量（`0..255`，中心值约 128）。
  - `Step 1 (0x11)`：摇杆 Y 轴模拟量（`0..255`，中心值约 128）。
  - `Step 2 (0x22)`：Button A（`0..6` 表示按下，8 表示松开）。
  - `Step 3 (0x23)`：Button B（`0..6` 表示按下，8 表示松开）。
  - `Step 4 (0x21)`：Button X / C 键。
  - `Step 5 (0x24)`：Button Y / D 键。
  - `Step 6 (0x20)`：Button OK（摇杆中心垂直下压键）。

#### 5. 状态锁存与容错重连机制
- **错误捕获 (`err_flag`)**：在通信过程中，若任何一步从机未产生 ACK 响应，状态机立即进入 `ST_W_STOP` / `ST_R_STOP` 提前终止本轮读取，并将 `gamepad_online` 拉低，防止脏数据注入游戏主循环。
- **在线识别 (`gamepad_online`)**：当完整且无错地读完 7 个寄存器后，立即拉高 `gamepad_online = 1`，并将临时寄存器数值原子刷新至输出端 `joy_x`、`joy_y`、`buttons[4:0]`，为系统提供可靠的热插拔容错支持。

---

### 2.2.5 `simple_dual_port_ram.v`：通用伪双口 BRAM 原语推导与跨时钟隔离

* **源码定位**：[rtl/common/simple_dual_port_ram.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/common/simple_dual_port_ram.v)
* **参数配置**：
  - `DATA_WIDTH`：数据位宽（默认为 8 位）
  - `ADDR_WIDTH`：地址线位宽（默认为 9 位，即 512 深度）
  - `OUTPUT_REG`：输出级是否插入寄存器（`"TRUE"` 或 `"FALSE"`）
  - `RAM_INIT_FILE` / `RAM_INIT_RADIX`：初始化数据文件路径与进制格式（`"HEX"` 或 `"BIN"`）

#### 1. 结构与设计规范
该模块是易灵思 Titanium 架构下最高效的伪双口（Simple Dual-Port，即单口写、单口读）BRAM 推荐推导模板：
- **独立的写/读时钟**：`wclk`（写时钟）与 `rclk`（读时钟）相互独立，可天然作为同步或异步 FIFO 的底层物理存储单元。
- **写逻辑**：标准同步写。在 `wclk` 上升沿且 `we == 1` 时将 `wdata` 写入 `ram[waddr]`。
- **读延迟流水线优化 (`OUTPUT_REG`)**：
  - 当 `OUTPUT_REG == "FALSE"` 时：`rdata` 采用一级寄存器输出（1 时钟周期读延迟）；
  - 当 `OUTPUT_REG == "TRUE"` 时：`rdata` 采用二级寄存器输出（2 时钟周期读延迟），在 BRAM 输出端增加了一级流水拍，显著切断长走线组合逻辑延迟，助力系统轻松跑到 100MHz ~ 200MHz。
- **存储器初始化支持**：支持通过 Verilog 系统函数 `$readmemh` / `$readmemb` 在编译综合阶段直接固化只读字模或初始调色板数据。

---

## 2.3 第三小章：apb 命令分发中枢详解

> **所属目录**：`rtl/apb/`  
> **核心使命**：作为三权分立体系下的**“中央司令部（Central Military Command）”**，挂接 Sapphire RISC-V SoC 的标准 APB3 从机总线，将 CPU 发出的绘制请求与配置指令进行硬件合法性检验，并彻底解耦分发为：**纯 2D BitBlt 绘图指令总线（`bitblt_cmd_*`）**、**纯流式显示与后处理配置总线（`display_cfg_*`）**、**双缓冲显存原子翻页控制** 以及 **全自主硬件手柄/按键状态遥测**。

---

### 2.3.1 三权分立架构定位与 APB 寄存器空间宏观布局

* **源码定位**：[rtl/apb/apb_command_dispatcher.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/apb/apb_command_dispatcher.v)

在早期单体架构中，APB 寄存器散落于 `bitblt_top` 和 `video_dma_read` 之间，导致 CPU 的控制流与显存数据流在总线接口处深度缠绕。在重构后的三权分立架构中，`apb_command_dispatcher` 成为系统唯一的 APB3 从机实体（基地址 `0xF810_0000`），将 256 字节的地址空间精细划分为六大独立功能域：

```
                Sapphire RISC-V SoC (APB3 Master @ 100 MHz)
                                     │
                                     ▼
        ┌────────────────────────────────────────────────────────┐
        │        apb_command_dispatcher (中央司令部分发中枢)       │
        └───────┬────────────┬───────────┬───────────┬───────────┘
                │            │           │           │
    [0x00 ~ 0x20]   [0x24 ~ 0x44]  [0x50 ~ 0x5C]  [0x60 ~ 0x6C]  [0x70 ~ 0xFC]
          │              │               │           │                 │
          ▼              ▼               ▼           ▼                 ▼
     Pure 2D BitBlt   双缓冲翻页   I2C手柄/按键   硬件探针与遥测   纯显示/特效/调色推流
      (bitblt_top)    (dma_top)    (i2c_gamepad)   (BCD帧率/诊断)  (display_engine_top)
```

#### APB3 核心寄存器空间全景映射表

| 偏移地址 (`paddr`) | 寄存器名称 | 读/写 | 位域分布与核心物理含义 |
| :---: | :--- | :---: | :--- |
| `0x00` | `REG_OP_TYPE` | R/W | `[1:0]` 操作码：`00`=FILL, `01`=COPY, `10`=ALPHA, `11`=ADD。 |
| `0x04` | `REG_DST_ADDR` | R/W | `[27:0]` 目标显存字节物理基地址（必须 16 字节对齐）。 |
| `0x08` | `REG_SRC_ADDR` | R/W | `[27:0]` 源图显存字节物理基地址。 |
| `0x0C` | `REG_RECT_SIZE` | R/W | `[26:16]` 矩形高度 $H$；`[10:0]` 矩形宽度 $W$（像素）。 |
| `0x10` | `REG_COLOR` | R/W | `[31:0]` 32-bit ARGB 纯色填充色值。 |
| `0x14` | `REG_STRIDES` | R/W | `[31:16]` 目标行跨距（Stride）；`[15:0]` 源行跨距。 |
| `0x18` | `REG_COLORKEY` | R/W | `[31]` 使能抠图；`[23:0]` ColorKey 剔除色。 |
| `0x1C` | `REG_ALPHA` | R/W | `[31]` 全局 Alpha 使能；`[7:0]` 全局透明度因子（$0\sim 255$）。 |
| `0x20` | `REG_START` | W | 写 `1` 脉冲启动 BitBlt；`[0]` 读出为 `cmd_busy` 状态。 |
| `0x24` | `REG_STATUS_VSYNC` | R/W1C | `[0]` 读出当前场消隐标志，写 1 清零软件中断标志。 |
| `0x40` | `REG_LEFT_NEXT` | R/W | `[27:0]` 左半屏下一帧待扫描前台基地址（原子翻页）。 |
| `0x44` | `REG_RIGHT_NEXT` | R/W | `[27:0]` 右半屏下一帧待扫描前台基地址。 |
| `0x50` | `REG_JOYSTICK` | R | `[15:8]` 摇杆 Y 轴模拟量；`[7:0]` 摇杆 X 轴模拟量。 |
| `0x54` | `REG_BUTTONS` | R | `[4:0]` 手柄 5 键物理电平；`[16]` 手柄在线指示 `online`。 |
| `0x58` | `REG_BOARD_KEYS` | R | `[0]` SW0 电平；`[1]` SW2 电平；`[8/9]` SW0/SW2 边沿单脉冲。 |
| `0x60` | `REG_TELEMETRY_FPS` | R/W | `[15:8]` FPGA 硬件帧率 BCD 码；`[7:0]` CPU 软件帧率 BCD 码。 |
| `0x64` | `REG_SCAN_DIAG` | R | `[31:0]` 视频扫描诊断（包含下溢计数与总线停顿快照）。 |
| `0x68` | `REG_PROBE_Q` | R | `[3:0]` BitBlt 读请求队列深度；`[4]` AR 阻塞；`[6:5]` 跨距状态。 |
| `0x70` | `REG_WEATHER_CTRL` | R/W | `[1:0]` 天气类型（晴/雪/熔岩）；`[3:2]` 风向；`[15:8]` 粒子数。 |
| `0x74` | `REG_WEATHER_MASK_X`| R/W | `[27:16]` 遮挡盒 $X_{max}$；`[11:0]` 遮挡盒 $X_{min}$。 |
| `0x78` | `REG_WEATHER_MASK_Y`| R/W | `[26:16]` 遮挡盒 $Y_{max}$；`[10:0]` 遮挡盒 $Y_{min}$。 |
| `0x80` ~ `0x84` | `REG_LASER_COLX_*` | R/W | 4 根 BOSS 贯通等离子光柱中心 X 坐标（各 12-bit）。 |
| `0x88` | `REG_BEAM_CFG` | R/W | `[31]` 光束使能；`[27:16]` 光束长度；`[11:0]` 自机中心 X。 |
| `0x90` ~ `0x9C` | `REG_HAIR_CFG_*` | R/W | 3 组贯穿全屏的 BOSS 预警切线方程参数。 |
| `0xA0` | `REG_COLOR_MATRIX` | R/W | `[3:0]` 仿射色彩矩阵模式（白闪/红化/灰度/反色等）。 |
| `0xA4` | `REG_BLOOM_CTRL` | R/W | `[7:0]` 软膝阈值；`[15:8]` 泛光增益强度；`[16]` 滤镜旁路。 |
| `0xF0` | `REG_BUCKET_BASE` | R/W | `[27:0]` DDR3 行桶弹幕描述符表物理基地址。 |
| `0xF4` | `REG_BTILE_STORE` | W | `[21:8]` 子弹 Tile RAM 写入地址；`[7:0]` 角色点阵数据。 |
| `0xF8` | `REG_BPAL_STORE` | W | `[7:0]` 调色板 RAM 写入地址；写 `0xFC` 注入 32-bit ARGB。 |

---

### 2.3.2 2D BitBlt 专有指令总线与参数门禁 (`bitblt_cmd_*`)

分发器向下游 `bitblt_top` 输出完全解耦的专用点对点连线：
- **发射握手**：当 CPU 向 `REG_START` 写入任意值时，分发器执行**参数前置门禁检查**：
  ```verilog
  wire cmd_valid = (reg_rect_w != 11'd0) && (reg_rect_h != 11'd0) && !cmd_busy;
  always @(posedge clk or negedge rst_n) begin
      if (!rst_n)
          cmd_start <= 1'b0;
      else
          cmd_start <= apb_psel && apb_penable && apb_pwrite && (apb_paddr[7:0] == 8'h20) && cmd_valid;
  end
  ```
- **门禁保护机制**：若长宽存在 0（零面积矩形）或当前硬件引擎尚未就绪（`cmd_busy == 1`），发射脉冲 `cmd_start` 被强制抑制，防止下级状态机进入死循环；
- **状态反压**：BitBlt 引擎的忙状态 `cmd_busy` 与超时指示 `engine_timeout` 直通分发器读通道，供 CPU 固件以非阻塞或零气泡轮询方式精准捕获。

---

### 2.3.3 显示特效与行桶调色板推流总线 (`display_cfg_*`)

为了支持东方弹幕游戏丰富的视觉表达，分发器向 `rtl/display_engine/` 提供高扇出直通配置总线：
1. **开机资产推流通路**：
   - 固件在开机初始化时，只需通过 APB 循环写入 `REG_BTILE_STORE`（`0xF4`）和 `REG_BPAL_STORE`（`0xFC`）；
   - 分发器产生写使能单脉冲 `btile_we` 与 `bpal_we`，直达 `display_engine_top` 内部的专用伪双口 BRAM，硬件上电瞬间完成 192 颗子弹的单通道字模与 256 色 ARGB 调色板注入；
2. **纯流式几何参数广播**：
   - 天气参数（`weather_ctrl`）、开窗遮罩（`weather_mask_*`）、激光坐标（`laser_colx`）、聚焦光束（`beam_*`）均在时钟上升沿更新为稳定电平，送入显示工坊进行跨时钟域暗影锁存。

---

### 2.3.4 双缓冲翻页、遥测状态快照与 BCD 硬件帧率计数器

- **双缓冲基地址投递**：CPU 固件在后台完成一帧渲染后，向 `0x40` 写入就绪显存基址。分发器将 `vdma_next_base` 锁存并送至 `rtl/dma/`，等待场消隐到来执行原子置换；
- **硬件 BCD 帧率解译**：分发器接收 SoC 写入的 `cpu_fps_bcd` 与 `fpga_fps_bcd`，无需经过任何软件字符串格式化，硬件直接以 BCD 码分发给 OSD HUD 模块，将十进制数字瞬时翻译为 8x12 点阵输出；
- **总线停顿探针与扫描下溢遥测**：分发器通过 `scan_diagnostics` 收集底层 DMA 的 FIFO 下溢次数、AR 突发排队深度与 AXI 总线读写响应时间，CPU 仅需一条 `LDR` 指令即可获得硬件微架构的运行快照。

---

### 2.3.5 全自主 I2C 手柄与板载按键状态解包

分发器内联了对底层硬件手柄模块 `u_i2c_gamepad` 的监控：
- **物理按键解包**：将手柄上报的 5 个动作按键、摇杆 X/Y 轴模拟量解包到独立可读寄存器 `0x50` 和 `0x54`；
- **板载按键边沿捕获**：对板载拨码按键 SW0 与 SW2 进行双级打拍消抖，同时提供电平状态与单拍上升沿脉冲，用于一键呼出/关闭硬件遥测 HUD。

---

## 2.4 第四小章：dma 纯数据提取引擎详解

> **所属目录**：`rtl/dma/`  
> **核心使命**：作为三权分立体系下的**“数据自来水厂（Pure Water Supply Plant）”**，彻底摒弃任何显示图层渲染与色彩计算逻辑。专职通过 128 位 AXI4 读主控通道，以微秒级硬实时确定性从 DDR3 提取**显存底图（Framebuffer）**与**超前行桶弹幕表（Bullet Bucket Table）**；借助 2048 深度异步 FIFO 实现 100 MHz AXI 显存时钟到 85.714 MHz 视频像素时钟的弹性跨域；内嵌 128b $\to$ 32b 像素齿轮箱（Gearbox）与防欠载相位冻结机制，向上游提供纯净无瑕的 32-bit ARGB 底图流。

---

### 2.4.1 纯数据“自来水厂”战略定位与协议解耦范式

* **设计定位与重构动机**：
  在早期单体 `video_dma_read.v` 中，AXI 读状态机、异步 FIFO 读写、行桶弹幕解析、激光/光束/天气/HUD 等 5 个图层的组合逻辑以及后处理全屏色彩矩阵全部挤压在同一个 1500+ 行的代码巨石中。这种设计不仅导致时序收敛极其困难（跨时钟域走线与多级长组合逻辑交织），且难以排查扫描欠载与总线死锁。
  重构后的 `rtl/dma/` 实现了绝对的**职责纯净化**：
  1. **零绘图协议**：不感知任何图层透明度、颜色或形状；
  2. **双通道读仲裁**：自主协调 Framebuffer 扫描读流与 Bullet Bucket 预取读流；
  3. **硬实时流控守卫**：通过 `video_write_guard` 实施最高优先级背压，捍卫视频扫描读带宽；
  4. **标准流接口**：仅输出纯净的 `fb_pixel[31:0]`、`bucket_row[2559:0]` 与时序状态。

```
                [ Axi_Mux Master (128-bit @ 100MHz) ]
                                   │
                                   ▼
        ┌───────────────────────────────────────────────────────┐
        │            dma_top (数据提取与流控中枢)                  │
        │                                                       │
        │   ┌────────────────────┐     ┌────────────────────┐   │
        │   │   dma_fb_reader    │     │dma_bucket_prefetch │   │
        │   │  (22突发/行扫描引擎) │     │ (超前2行弹幕预取)   │   │
        │   └─────────┬──────────┘     └─────────┬──────────┘   │
        │             │                          │              │
        │             └───────────┬──────────────┘              │
        │                         ▼                             │
        │             [ AXI 内部固定优先级仲裁器 ]                 │
        │                         │                             │
        │                         ▼                             │
        │             [ async_fifo (2048 深度) ]                │
        │                         │                             │
        │       100 MHz axi_clk ──┼── 85.714 MHz pixel_clk      │
        │                         ▼                             │
        │             [ 128b -> 32b 像素齿轮箱 ]                │
        │             (含 word_stall 相位冻结)                   │
        └─────────────────────────┬─────────────────────────────┘
                                  │
                                  ▼
             输出纯净底图像素 fb_pixel[31:0] 至 display_engine
```

---

### 2.4.2 `dma_top.v`：双通道读调度、跨时钟脉冲同步与行/场节拍控制器

* **源码定位**：[rtl/dma/dma_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/dma_top.v)

`dma_top` 是提取引擎的顶层胶水与时序调度核，核心处理两大维度的控制逻辑：

#### 1. 跨时钟域脉冲同步器（CDC Synchronizers）
- **`frame_start`（提前 8 行预充脉冲）**：来自显示工坊的 `t_frame_start` 在像素时钟域（85.714 MHz）触发翻转寄存器 `frame_toggle_p <= ~frame_toggle_p`，在 AXI 时钟域通过 3 级移位寄存器采样异或（`sync[2] ^ sync[1]`），还原出单周期的 `frame_start_axi`，驱动 AXI 状态机提前向 DDR3 灌入前 8 行像素；
- **`frame_clear`（场结束消隐复位脉冲）**：显示工坊在垂直消隐结束前发出持续 16 个像素时钟的电平，AXI 域采样边沿 `frame_clear_axi_pulse`，**在此绝对安全间隙内原子锁存 CPU 下发的新帧基地址**（`active_base <= next_frame_base_addr`），从硬件物理上实现零撕裂双缓冲翻页。

#### 2. 双通道内部 AXI 读仲裁
```verilog
wire bk_req = bk_arvalid && (cal_done && !bk_act);
assign m_axi_araddr  = bk_req ? bk_araddr  : fb_araddr;
assign m_axi_arlen   = bk_req ? bk_arlen   : fb_arlen;
assign m_axi_arvalid = bk_req ? bk_arvalid : fb_arvalid;
```
行桶预取（`dma_bucket_prefetch`）单次突发仅需 20 拍，优先级高于底图扫描。由于单行扫描时间（$15.94\ \mu s$）内有超过 $12\ \mu s$ 的总线空闲间隙，行桶预取可以在消隐期以极短突发瞬时插队，完全不影响底图 FIFO 的平滑供水。

---

### 2.4.3 `dma_fb_reader.v`：22 突发/行扫描引擎、6-Beat 尾突发裁剪与双基址分屏

* **源码定位**：[rtl/dma/dma_fb_reader.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/dma_fb_reader.v)

#### 1. 22 突发/行扫描数学模型
1366 像素每像素 4 字节，单行需传输 $1366 \times 4 = 5464$ 字节。
128 位 AXI 总线每拍传输 16 字节，因此单行必须读取：
$$\text{Words/Line} = \lceil 1366 / 4 \rceil = 342 \text{ 个 128-bit 字}$$
为最大化 DDR3 吞吐并兼顾行边界整齐，`dma_fb_reader` 设计了非对称突发拆分方案：
$$\mathbf{342 \text{ Beats} = 21 \times 16\text{-Beat (Full Burst)} + 1 \times 6\text{-Beat (Tail Burst)}}$$
- **前 21 次突发**：`arlen = 8'd15`（即 16 拍），读取 $21 \times 16 = 336$ 拍；
- **最后 1 次尾突发**：`arlen = 8'd5`（即 6 拍），精确补齐剩余 6 拍；
- **优势**：杜绝了传统架构将 342 向上取整为 22 次 16 突发（352 拍）所浪费的 10 拍显存带宽，避免 FIFO 在行末被多余的无用像素填满而导致跨行位移！

#### 2. 双基址左右分屏支持
模块支持左右半屏独立寻址：
- 扫描前 683 像素（左半屏）使用 `active_base`；
- 扫描后 683 像素（右半屏）自动无缝切换到 `active_right_base`；
- 使得系统天然具备在单屏上同时呈现“纯软件渲染 vs 硬件加速”或者“双缓冲对比”的演示级能力。

---

### 2.4.4 `dma_bucket_prefetch.v`：超前 2 行弹幕预取、80 槽 20 突发 BRAM 扁平化

* **源码定位**：[rtl/dma/dma_bucket_prefetch.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/dma_bucket_prefetch.v)

为了让东方弹幕游戏实现“零显存写带宽”的奇迹，必须以零延迟向显示流水线提供当前行待画子弹列表：
1. **超前 2 行预取（2-Line Ahead Prefetch）**：当视频扫描到达第 $Y$ 行时，状态机已经在后台通过 AXI 读出第 $Y+2$ 行的 80 槽弹幕描述符；
2. **20 拍 AXI 极速突发**：每个弹幕描述符占 4 字节（32-bit：包含 X 坐标、子弹类型、调色板索引），80 槽共 320 字节，正好对应一次单突发 20 拍（$20 \times 16 = 320$ 字节，`arlen = 8'd19`）；
3. **片上 BRAM 扁平化展开**：数据在 100MHz 写入双口 RAM，并在水平行消隐结束瞬间（`H_TOTAL - 2`），由专用逻辑瞬时展开为 **2560 位宽（80 槽 $\times$ 32 位）的超宽并行总线 `bucket_row`**，直通显示工坊的 80 路并发比对阵列！

---

### 2.4.5 `async_fifo.v`：格雷码双时钟域隔离、2048 深度高低水位线与消隐复位

* **源码定位**：[rtl/dma/async_fifo.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/async_fifo.v)

作为连接 100 MHz AXI 总线与 85.714 MHz 视频像素时钟的核心弹性纽带，`async_fifo` 具备以下关键微架构特性：
- **2048 深度大容量缓冲**：单字 128 位，总容量高达 32 KB，足以容纳整整 **6 条完整扫描线** 的像素预存，抵御任何总线竞争引起的瞬态抖动；
- **精密水位线监控**：
  - **低水位预警（`WATERMARK_LOW = 1400`）**：当写端剩余字数不足以维持后续扫描时，立即拉高 `video_read_priority`，激活写通道阻断守卫；
  - **回填达标线（`WATERMARK_REFILL = 1920`）**：只有当 FIFO 重新注水至 1920 字以上时，才释放 `video_read_priority`，留出足够的迟滞回差（Hysteresis），防止写通道频繁启停振荡；
- **垂直消隐强制清空（`rclr = t_frame_clear`）**：在每帧场消隐期间强制清空读写指针，抹除上一帧因显示器非标消隐累积的任何相位微差，确保每帧第 1 像素都从 FIFO 头部严格对齐读出。

---

### 2.4.6 `video_write_guard.v`：防欠载优先级守卫与死锁活锁自解引擎

* **源码定位**：[rtl/dma/video_write_guard.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/video_write_guard.v)

这是保障高刷视频绝对不闪烁、不欠载的“安全安全阀”：
- **门控核心规则**：
  ```verilog
  wire admit = !write_pending && (!video_priority || aw_held);
  assign m_axi_awvalid = s_axi_awvalid && admit;
  assign m_axi_wvalid  = s_axi_wvalid && (write_pending ? write_pass : admit);
  ```
- **工作机理**：
  当 `video_priority == 1`（FIFO 处于缺水渴求状态）时，守卫模块直接切断所有非紧急的 AXI 写事务准入（`admit = 0`）；
  正在传输中的突发允许通过 `aw_held` 与 `write_pass` 正常写完最后一拍，避免总线协议悬空；而后续新的写请求则被坚决阻断在 DDR3 控制器之外，将全部 DDR3 物理带宽归还给视频扫描读通道！

---

### 2.4.7 128b 转 32b 像素齿轮箱（Gearbox）与 `word_stall` 欠载相位冻结

* **源码定位**：[rtl/dma/dma_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/dma/dma_top.v#L263-L318)

从 128-bit 显存字提取 32-bit ARGB 像素的过程看似简单，但在极端工况下隐藏着致命陷阱：
1. **预充与换行节拍**：在行消隐末尾（`h_cnt == H_TOTAL - 2`），触发 `line_prefetch` 从 FIFO 预读出当前行的第一个 128 位字存入 `cur_word`；
2. **4 像素循环移位**：在有效显示期（`t_de == 1`），双位计数器 `sub_pix_cnt` 在 `00 -> 01 -> 10 -> 11` 之间轮转，依次截取 `cur_word[31:0]`, `cur_word[63:32]`, `cur_word[95:64]`, `cur_word[127:96]`；
3. **【关键防线】欠载相位冻结（`word_stall`）**：
   ```verilog
   wire word_stall = (sub_pix_cnt == 2'd2) && (h_cnt < H_ACT - 2) && t_de && fifo_rempty;
   ```
   **物理意义**：当硬件准备在 `sub_pix_cnt == 2` 向 FIFO 请求下一个 128 位字时，如果此时由于总线拥堵导致 `fifo_rempty == 1`（扫描欠载），**必须强制冻结 `sub_pix_cnt` 的计数递增**！  
   如果任由 `sub_pix_cnt` 继续跑马计数，当数据姗姗来迟时，硬件将把原本属于第 0 像素的高位数据错位赋给第 2 像素，造成**整行画面永久向左错位 1~3 个像素，形成整幅画面的严重横向毛刺与撕裂**！

---

### 2.4.8 【关键复盘】上板画面撕裂 BUG 根因剖析与四重硬件防线

在系统重构上板初期，屏幕曾出现严重的水平撕裂与周期性像素错位。经过对硬件信号走线与逻辑状态的深度复盘，最终精确定位出四大连锁诱因并构筑了四重硬件防线：

| 诱因排查分类 | 原始缺陷机理 (Bug Mechanism) | 导致板级故障现象 | 最终修复方案与四重防线 (Hardware Fix) |
| :---: | :--- | :--- | :--- |
| **防线 1：写守卫优先级反转** | `video_write_guard.v` 曾被误引入 `hold_out` 允许 BitBlt 持续占用写通道（`admit = ... \|\| hold_out`）。 | 在高密度图形绘制时，BitBlt 写事务死霸总线，视频读通道饥饿断流，FIFO 频频排空。 | **彻底剔除 `hold_out` 旁路**，恢复严格的写门控：`admit = !write_pending && (!video_priority \|\| aw_held)`，确立扫描绝对优先。 |
| **防线 2：像素齿轮箱欠载错位** | 齿轮箱在 FIFO 欠载时未暂停计数，`sub_pix_cnt` 自由溢出。 | 欠载恢复后，32 位像素与 128 位字对齐脱节，整行画面撕裂并呈现 1~3 像素彩色噪波。 | **引入 `word_stall` 相位冻结**：在 `fifo_rempty` 时暂停计数器与移位，欠载恢复后完美承接第 0 像素。 |
| **防线 3：场消隐脉冲跨时钟漏采样** | `video_timing_gen.v` 的 `frame_clear` 脉冲宽度仅为 1 个像素时钟周期（约 11.6 ns）。 | 85.71 MHz 单拍脉冲跨到 100 MHz AXI 域时偶发漏捕获，导致双缓冲无法在整帧起始处原子翻页。 | **展宽为 16 个像素时钟（约 186 ns）**，并在 AXI 域采用 3 级同步器捕获上升沿脉冲 `frame_clear_axi_pulse`。 |
| **防线 4：双缓冲基地址阴影不同步** | `dma_fb_reader.v` 内部独立维系了 `cur_active_base` 阴影寄存器，与顶层 `active_base` 产生双时钟域竞争。 | 左右半屏分屏线两侧基地址更新时序错位，导致左右半屏上下跳变撕裂。 | **物理消除 reader 内部影子寄存器**，显存基址完全由 `dma_top` 在 `frame_clear_axi_pulse` 原子锁存并硬直连驱动。 |

---

## 2.5 第五小章：display_engine 纯流式视频显示引擎与图层合成详解

> **所属目录**：`rtl/display_engine/`  
> **核心使命**：作为三权分立体系下的**“纯流式艺术工坊（Pure Art Workshop）”**，运行在纯净的 85.714 MHz 视频像素时钟域，**零 AXI 总线依赖、零 APB 状态耦合**。它向下游接收来自 `rtl/dma/` 的纯净底图像素流与超前行桶表，根据由 `rtl/apb/` 广播的特效参数，在飞线扫描周期内实时完成 **5 大图层的过程化生成（Layer 1~5）**、**三级硬核流水线图层叠加与 Alpha 混合（`video_pixel_compositor`）**，并通过 **2D SRL8 软膝 HDR 泛光滤镜** 与 **9-DSP 3x3 仿射色彩矩阵** 实施电影级后处理，最终向 DVI/HDMI 编码发送器输出高清无撕裂视频基流。

---

### 2.5.1 纯流式“艺术工坊”战略定位与“零带宽”实时多图层合成拓扑

* **显存写带宽的零消耗革命**：
  在东方弹幕射击游戏中，若将 192 颗子弹、4 根激光柱、3 组全屏预警线、170 颗天气粒子与 OSD HUD 逐像素光栅化到显存中，单帧显存随机写入与脏矩形擦除开销将超过 **2.5 GB/s**，远超单颗 16 位 DDR3 颗粒的有效极限（~1.0 GB/s）。
  `rtl/display_engine/` 的颠覆性在于：**显存中只保留静态与半静态背景底板，所有高频、细长、规则几何或算法生成的动态实体，全部在视频送显流水线的“飞线（On-the-Fly）”过程中硬件现算并实时混叠**。

```
  [rtl/dma/dma_top]                 [rtl/apb/apb_command_dispatcher]
   │ 纯底图流 fb_pixel                     │ 直通显示/特效配置总线
   ▼                                       ▼
┌────────────────────────────────────────────────────────────────────────┐
│                    display_engine_top (纯流式艺术工坊)                  │
│                                                                        │
│  [video_timing_gen] ──► 产生 1366x768 @ 75Hz 时基 (hsync, vsync, de)   │
│                                                                        │
│  【Layer 1】video_weather        (170-Dot LFSR 伪随机粒子发生器)         │
│  【Layer 2】video_bullet_overlay (B1 行桶弹幕图层：80槽查表与调色板映射)│
│  【Layer 3】video_laser          (BOSS 4路等离子高能光柱发生器)          │
│  【Layer 4】video_beam           (自机聚焦等离子光束 + 3路预警切线)      │
│  【Layer 5】video_dual_hud       (双图层硬件 OSD 遥测 HUD，BCD直译)      │
│                            │                                           │
│                            ▼                                           │
│  [video_pixel_compositor] (三级硬核流水线图层叠加与 Alpha/饱和加法)    │
│                            │ 输出 comp_r/g/b 与发光掩码 comp_a         │
│                            ▼                                           │
│  [video_bloom_filter]    (2D 5行各向同性卷积核 + SRL8 软膝 HDR 泛光)   │
│                            │                                           │
│                            ▼                                           │
│  [video_color_matrix]    (9-DSP 硬核 3x3 仿射色彩矩阵变换)             │
└────────────────────────────┬───────────────────────────────────────────┘
                             │
                             ▼ 输出 final_r/g/b, hs, vs, de
                 [rtl/hdmi/dvi_encoder] (8b/10b TMDS 编码发送)
```

---

### 2.5.2 `display_engine_top.v`：时钟域纯净解耦、CDC 场消隐原子暗影锁存

* **源码定位**：[rtl/display_engine/display_engine_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/display_engine_top.v)

`display_engine_top` 是艺术工坊的顶层胶水，具备三大核心职责：
1. **时钟域纯净解耦**：除开机时接收 APB 时钟加载子弹 Tile 与调色板的配置端口（`cfg_clk`）外，主渲染流水线全部锁定在 85.714 MHz 的视频像素时钟 `pixel_clk` 上，杜绝跨时钟亚稳态穿透；
2. **流水线对齐打拍（1-Cycle Latency Matching）**：
   来自 `dma_top` 的底图像素 `fb_pixel` 穿越异步 FIFO 后存在 1 周期延迟。因此，顶层将时序发生器的 `hsync`、`vsync`、`de`、`h_cnt` 与 `v_cnt` 统一延时 1 拍（`t_*_d1`），确保各个图层发生器取到的屏幕物理坐标与输入的背景像素严格重合；
3. **场消隐原子暗影锁存（VSync Shadow Latches）**：
   游戏逻辑在 100MHz 域更新的激光坐标（`laser_colx`）、光束长宽（`beam_*`）与天气参数，首先通过两级同步器打入像素时钟域，并在场消隐起始点（`v_cnt == V_ACT && h_cnt == 0`）统一原子写入暗影寄存器（`*_latched`），严禁在扫描线中途跳变导致实体折断变形。

---

### 2.5.3 `video_timing_gen.v`：1366x768 @ 75Hz 数字时序发生器与 16 周期 `frame_clear`

* **源码定位**：[rtl/display_engine/1_timing/video_timing_gen.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/1_timing/video_timing_gen.v)

模块参数严格针对 1366 $\times$ 768 @ 75Hz 高刷显示进行拓扑压缩：

| 时序参数名称 | 1366x768 @ 75Hz 顶层实配值 | 物理含义与微架构职责 |
| :--- | :---: | :--- |
| `H_ACT` / `V_ACT` | 1366 / 768 | 水平与垂直有效显示视口分辨率 |
| `H_FP` / `H_SYNC` / `H_BP` | 8 / 56 / 26 | 水平消隐前沿、同步脉冲与后沿（合计 $H_{TOTAL} = 1456$） |
| `V_FP` / `V_SYNC` / `V_BP` | 2 / 3 / 9 | 垂直消隐前沿、场同步脉冲与后沿（合计 $V_{TOTAL} = 782$） |
| `frame_start` | `(v_cnt == V_ACT + V_FP) && (h_cnt == 0)` | **提前 8 行预充脉冲**：通知 AXI 状态机提前预注 FIFO |
| `frame_clear` | `(v_cnt == V_ACT) && (h_cnt < 12'd16)` | **场消隐清空脉冲**：**持续整整 16 个像素时钟**，确保跨时钟 100% 捕获 |

* **16 周期 `frame_clear` 的重大工程意义**：
  早期设计该脉冲仅维持 1 个周期（11.6 ns）。当脉冲穿越到 100 MHz AXI 域（10 ns 周期）时，因时钟相位滑动偶发漏采样，造成双缓冲换页漏帧或 FIFO 历史游标残留。展宽至 16 个像素时钟（186.6 ns）后，AXI 域能极其稳健地捕获上升沿，彻底根除跨域漏帧。

---

### 2.5.4 实时过程化图层发生器集群（Layer 1 ~ Layer 5）

#### 2.5.4.1 `video_weather.v`：170-Dot LFSR 伪随机粒子与开窗遮挡
* **源码定位**：[rtl/display_engine/2_layer_generators/video_weather.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/2_layer_generators/video_weather.v)
- **170-Dot 伪随机数发生器**：采用 32-bit 最大长度伽罗瓦 LFSR（特征多项式 $x^{32} + x^{22} + x^2 + x^1 + 1$），在像素行扫描中动态生成雪花、熔岩火星或梦境光点；
- **防遮挡遮罩盒子（Mask Box）**：支持硬件开窗 $X \in [X_{min}, X_{max}], Y \in [Y_{min}, Y_{max}]$。当粒子坐标落入角色对话框或血条安全区时，硬件组合逻辑瞬间抑制 `w_visible = 0`，防止 UI 被暴风雪遮蔽。

#### 2.5.4.2 `video_bullet_overlay.v`：B1 行桶弹幕覆盖层合成器（角色与调色板分离）
* **源码定位**：[rtl/display_engine/2_layer_generators/video_bullet_overlay.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/2_layer_generators/video_bullet_overlay.v)
- **80 槽并发比对阵列**：接收来自 DMA 的 2560 位宽扁平化行桶数据（包含当前行最多 80 颗活跃子弹的 $X$ 坐标、Tile 索引与调色板偏移）；
- **角色与调色板硬件解耦（B1 优化）**：子弹点阵仅存储 1 字节角色形状（Role Mask），色彩由 256 色片上调色板 RAM 动态映射。同一款米弹通过切换调色板基址即可呈现赤、橙、黄、绿、青、蓝、紫 7 种华丽色系，显存零写入、BRAM 占用压缩 75%！

#### 2.5.4.3 `video_laser.v`：BOSS 4路等离子高能光柱发生器与动态等离子脉冲
* **源码定位**：[rtl/display_engine/2_layer_generators/video_laser.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/2_layer_generators/video_laser.v)
- **硬件高斯衰减评估**：计算当前像素与 4 根光柱中心坐标的欧氏距离 $\Delta x = |x - x_{center}|$；
- **纯白核心与外层等离子辉光**：当 $\Delta x \le 2$ 时输出 255 纯白高亮白芯；当 $2 < \Delta x \le 8$ 时按 $1 - (\Delta x/8)^2$ 进行二次多项式平滑衰减，产生极具压迫感的高清贯通光柱。

#### 2.5.4.4 `video_beam.v`：自机聚焦光束与 3 路 BOSS 预警切线实时发生器
* **源码定位**：[rtl/display_engine/2_layer_generators/video_beam.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/2_layer_generators/video_beam.v)
- **自机聚焦等离子光束**：实时在自机正前方渲染 16 像素宽的贯通主炮，带有边缘柔和 Alpha 衰减；
- **3 路全屏预警虚线（Hairlines）**：在 BOSS 释放符卡大招前 0.5 秒，硬件根据一元一次方程 $y = kx + b$ 实时计算并高亮显示 3 根彩色细线，提前警示弹道，杜绝画细线对 DDR 行激活的巨大惩罚。

#### 2.5.4.5 `video_dual_hud.v`：双图层硬件 OSD 遥测 HUD（CPU 与 FPGA 双帧率实时比对）
* **源码定位**：[rtl/display_engine/2_layer_generators/video_dual_hud.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/2_layer_generators/video_dual_hud.v)
- **内置纯硬件字模 ROM**：内置 8x12 ASCII 字符字模点阵，通过对行号/列号右移 1 位实现硬件 2x2 物理像素放大，清晰锐利；
- **BCD 实时硬直译**：直接接收 BCD 码帧率输入，无需任何软件字符串转换，硬实时在屏幕两侧实时对比 CPU 纯软渲染帧率与 FPGA 硬件加速帧率。

---

### 2.5.5 `video_pixel_compositor.v`：三级硬核流水线图层叠加与色彩混合算子

* **源码定位**：[rtl/display_engine/3_compositor/video_pixel_compositor.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/3_compositor/video_pixel_compositor.v)

`video_pixel_compositor` 将过去混杂的代码提取为独立的**高内聚图层合成器**，采用 3 级严密时钟流水线执行图层深度合并：

#### 1. 核心数学算子（纯无除法器实现）
- **无除法器 8 位归一化算法 (`div255`)**：
  $$\text{div255}(n) = \frac{n + 1 + (n \gg 8)}{256} \approx \frac{n}{255}$$
  利用移位与加法精确替代了消耗巨大的除法器，最大绝对误差为 0；
- **有符号线性插值算子 (`blend8`)**：
  $$\text{blend8}(fg, bg, a) = \text{div255}\left( bg \times 255 + (fg - bg) \times a + 127 \right)$$
- **饱和加法器 (`sat_add8`)**：
  $$\text{sat\_add8}(A, B) = \min(255, A + B)$$
  用于弹幕重叠高光与白芯汇聚，避免色彩回绕溢出导致黑斑。

#### 2. 三级硬核流水线架构
- **Stage 1（底层环境与弹幕融合）**：
  首先将【Layer 1 天气粒子】叠在底图像素 `cur_pixel` 上；随后将【Layer 2 B1 行桶弹幕】依 `u_add_sel` 标志执行 `blend8` 或 `sat_add8` 叠加，打拍输出 `s1_r/g/b/a`；
- **Stage 2（高能激光柱叠加）**：
  在 Stage 1 结果上叠入【Layer 3 BOSS 激光柱】，计算等离子光晕插值与白芯饱和加法，打拍输出 `s2_r/g/b/a`；
- **Stage 3（自机光束、预警线与 HUD 顶层覆盖）**：
  在 Stage 2 结果上叠入【Layer 4 自机光束】与【Layer 5 遥测 HUD】。HUD 具备最高显示层级（直接覆盖）；同时输出发光掩码 `comp_a`（子弹高光与激光白芯均标记为 `comp_a >= 32`），供后级 Bloom 滤镜精确识别辉光源。

---

### 2.5.6 `video_bloom_filter.v`：2D 5行各向同性卷积核、SRL 移位网络与软膝 HDR 泛光滤镜

* **源码定位**：[rtl/display_engine/4_post_process/video_bloom_filter.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/4_post_process/video_bloom_filter.v)

- **SRL8 横向流光网络**：利用 Ti60 片上极度廉价的 LUT 移位寄存器（SRL8）构建 $\pm 16 \sim 32$ 像素横向抽头延迟网络，无需消耗昂贵的 BRAM；
- **软膝 HDR 压缩方程（Soft-Knee HDR Compression）**：
  对卷积求和后的发光强度执行分段非线性压缩：
  $$\text{soft\_knee}(val) = \begin{cases} val & val < 140 \\ 140 + \frac{(val - 140) \times 6}{8} & 140 \le val < 220 \\ 200 + \frac{(val - 220) \times 4}{8} & val \ge 220 \end{cases}$$
  有效抑制了高光过曝发白，呈现出通透柔和的电影级辉光。

---

### 2.5.7 `video_color_matrix.v`：9-DSP 硬核 3x3 仿射色彩矩阵变换器

* **源码定位**：[rtl/display_engine/4_post_process/video_color_matrix.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/display_engine/4_post_process/video_color_matrix.v)

调用 9 个硬核 DSP 乘法单元，对流水线输出的 R、G、B 像素实施全屏 3 级流水线仿射变换：
$$\begin{bmatrix} R_{out} \\ G_{out} \\ B_{out} \end{bmatrix} = \frac{1}{256} \left( \begin{bmatrix} m_{00} & m_{01} & m_{02} \\ m_{10} & m_{11} & m_{12} \\ m_{20} & m_{21} & m_{22} \end{bmatrix} \begin{bmatrix} R_{in} \\ G_{in} \\ B_{in} \end{bmatrix} + \begin{bmatrix} off_0 \\ off_1 \\ off_2 \end{bmatrix} \right)$$
- **Mode 0 (Bypass)**：纯穿透；
- **Mode 1 (受击白闪)**：偏置注入全白偏移；
- **Mode 2 (符卡红化)**：维持红通道，绿蓝衰减 80%；
- **Mode 3 (子弹时间灰度化)**：$Y = \frac{77R + 150G + 29B}{256}$ 硬件 NTSC 亮度感知加权；
- **Mode 4 (底片反色)**：系数对角线设为 $-256$，注入 $+65280$ 偏置。

---

## 2.6 第六小章：ddr3_controller 高速存储子系统详解

> **所属目录**：`rtl/ddr3_controller/`  
> **核心使命**：管理板载 256 MB DDR3-800 高速物理内存，对内提供 128 位 AXI4 从机总线，对外完成 400 MHz 物理 PHY 动态校准、时序状态机驱动与自刷新维护。

---

### 2.6.1 DDR3 控制器子系统的战略定位与带宽拓扑

DDR3 SDRAM 是整个 2D 图形加速系统的数据心脏。本工程需要同时支撑 **1366x768 @ 75Hz 实时扫描读出**（324 MB/s 恒定吞吐）、**BitBLT 多层贴图搬运/背景修补**、**行桶弹幕表访问** 以及 **CPU 资产加载**。

#### 1. 物理芯片与电气规格
- **物理芯片规格**：单颗 2 Gb（256 MB）DDR3 SDRAM 颗粒（16 位物理数据总线）。
- **物理工作时钟**：`sdram_clk = 400 MHz`（在双沿触发 DDR 机制下，等效数据速率为 **800 Mbps/pin**）。
- **理论峰值物理带宽**：
  $$\text{Bandwidth}_{\text{peak}} = 400 \text{ MHz} \times 2 \times 16 \text{ bits} / 8 = 1600 \text{ MB/s} = 1.6 \text{ GB/s}$$

#### 2. 时钟与位宽的精妙数学匹配（4:1 频比）
为什么片上总线选择 **100 MHz + 128-bit**？这背后存在极为严谨的体系结构设计考量：
- **片上 AXI 总线侧**：运行在 100 MHz 核心时钟，位宽 128-bit（16 字节），其单拍带宽为：
  $$100 \text{ MHz} \times 16 \text{ Bytes} = 1.6 \text{ GB/s}$$
- **外部 DDR3 颗粒侧**：控制器采用 4:1 时钟分频比（`CK_RATIO = 4`），DDR3 颗粒工作在标准的突发长度 8（Burst-of-8, BL8）模式：
  $$\text{1 个 BL8 传输} = 16 \text{ bits} \times 8 = 128 \text{ bits}$$
- **结论**：**片上 AXI 总线单拍 128 位数据，在物理时间上正好完美对应外部 DDR3 芯片在 400 MHz 下跑完一个 BL8 突发所需的 4 个内存时钟周期（10 ns）**。两者吞吐率完全同构，在流水线全速吞吐时内部无需任何速率适配缓冲等待！

```
     100 MHz AXI4 总线 (128-bit)
     [ 1 拍 128-bit 数据 @ 100 MHz (10 ns) ]
                      │
                      ▼ 内部硬核 4:1 齿轮转换
     [ BL8: 8 次物理传输 @ 400 MHz DDR (10 ns) ]
     400 MHz 16-bit DDR3 物理总线
```

---

### 2.6.2 `ddr3_parameter.vh`：物理几何与 JEDEC AC 时序参数全景

* **源码定位**：[rtl/ddr3_controller/ddr3_parameter.vh](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/ddr3_parameter.vh)

该头文件固化了 DDR3 芯片的物理组织架构与 JEDEC 标准电气 AC 时序。

#### 1. 物理几何参数（Memory Geometry）

| 参数宏定义 | 配置数值 | 含义与物理映射 |
| :--- | :---: | :--- |
| `DQ_WIDTH` | 16 | 物理双向数据线（DQ）引脚总数。 |
| `DQS_WIDTH` | 2 | 差分数据选通脉冲对（每 8 根 DQ 对应 1 对 DQS）。 |
| `DM_WIDTH` | 2 | 写入数据掩码线（高/低字节独立屏蔽）。 |
| `BANK_WIDTH` | 3 | 物理 Bank 数量为 $2^3 = 8$ 个。 |
| `ROW_WIDTH` | 14 | 行地址引脚数，单 Bank 包含 $2^{14} = 16,384$ 行。 |
| `COL_WIDTH` | 10 | 列地址引脚数，单行包含 $2^{10} = 1,024$ 列。 |
| `MEM_ADDR_ORDER` | `"BANK_ROW_COLUMN"` | 物理寻址映射顺序：最高位 Bank，中间 Row，最低位 Column。 |

* **容量核算公式**：
  $$\text{容量} = 2^{\text{BANK\_WIDTH}} \times 2^{\text{ROW\_WIDTH}} \times 2^{\text{COL\_WIDTH}} \times \text{DQ\_WIDTH} = 8 \times 16384 \times 1024 \times 16 \text{ bits} = 2 \text{ Gb} = 256 \text{ MB}$$

#### 2. JEDEC AC 动态时序参数 (单位: ps 或 时钟周期)

| 参数宏定义 | 配置数值 | 物理意义与严格时序约束 |
| :--- | :---: | :--- |
| `tCK` | 2500 ps | 内存物理时钟周期（对应 400 MHz 频率）。 |
| `CL` | 6 | CAS 读延迟（从发出读命令到 DQ 线上出现第一拍有效数据需 6 个 tCK）。 |
| `CWL` | 5 | CAS 写延迟（从发出写命令到驱动 DQS 写数据需 5 个 tCK）。 |
| `tRCD` | 15000 ps | 行激活至列读写延迟（ACT 到 RD/WR 需要等待 6 个 tCK）。 |
| `tRP` | 15000 ps | 行预充电时间（关闭当前行所需等待的 6 个 tCK）。 |
| `tRAS` | 35000 ps | 行有效激活时间（同一个行从打开到允许关闭的最小持续时间，14 个 tCK）。 |
| `tREFI` | 7800000 ps | 刷新周期（平均每 7.8 $\mu s$ 必须向内存发送一次 Auto-Refresh 刷新命令）。 |
| `tRFC` | 350000 ps | 刷新恢复周期（发送刷新命令后芯片内部充电所需等待的时间，140 个 tCK）。 |
| `tFAW` | 35000 ps | 四激活窗口（在 35 ns 时间窗口内最多允许激活 4 个不同的 Bank）。 |
| `RTT_NOM` / `RTT_WR` | `"40"` / `"60"` | 片上终端电阻（ODT）配置阻抗（40 $\Omega$ 与 60 $\Omega$），抑制高频传输反射。 |

---

### 2.6.3 `ddr3_top.v`：存储器控制器顶层与系统时钟树规划

* **源码定位**：[rtl/ddr3_controller/ddr3_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/ddr3_top.v)

#### 1. 核心架构职责
`ddr3_top` 集成了物理 PHY、协议引擎、本地仲裁与 AXI 从机接口。它在顶层向上提供标准的 128 位 AXI4 Slave 接口（挂接至 `Axi_Mux` 的 Master 端口），向下输出 DDR3 物理管脚信号（`ddr_ck_*`, `ddr_addr`, `ddr_ba`, `ddr_dq_*` 等）。

#### 2. 严密的 6 大时钟树规划
高速 DDR3 接口对时钟相位的要求极其严苛，模块引入了多路协同锁相环时钟输入：
- `axi_clk` / `core_clk` (100 MHz)：驱动 AXI 总线握手、本地 FIFO 与命令缓冲逻辑；
- `sdram_clk` (400 MHz)：DDR3 物理差分时钟（`ddr_ck_hi/lo`）的基准源；
- `rx_cal_clk` (400 MHz)：**读捕获时钟**，专门在物理层接收端作为输入采样基准；
- `tx_cal_clk` (400 MHz)：**写发射时钟**，负责对外同步发送地址、命令与写数据；
- `tx_cal_clk_90edge` (400 MHz, 90°相移)：**DQS 居中发射时钟**。根据 DDR3 规范，写入数据时 DQS 脉冲必须相对于 DQ 边沿居中对齐（Center-aligned），此 90° 相移时钟由 PLL_TR0 硬核原生生成并直驱 DQS 发生逻辑。

#### 3. PLL 动态相移反馈闭环
模块提供 3 根动态相移控制线直连顶层 PLL：
- `pll_shift[2:0]`：步进微调命令；
- `pll_shift_sel[4:0]`：选择微调哪一个时钟相位；
- `pll_shift_ena`：相移使能脉冲。
在物理层进行上电校准时，控制器利用这套接口动态微调 PLL 输出相位，直至找到数据采样的最佳眼图中心。
- `cal_done`：当且仅当所有校准步骤（调平、门控、写校准）完全通过后，拉高 `cal_done = 1`。顶层逻辑在捕获到此信号前保持挂起，防止未校准状态下读写发生总线崩塌。

---

### 2.6.4 AXI 总线协议转换层 (`axi4_bus_ctl/`)

* **包含源码**：
  - [rtl/ddr3_controller/axi4_bus_ctl/axi4_bus_ctl.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/axi4_bus_ctl/axi4_bus_ctl.v)
  - [rtl/ddr3_controller/axi4_bus_ctl/axi_upsizer.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/axi4_bus_ctl/axi_upsizer.v)

#### 1. `axi4_bus_ctl.v` 协议桥接机制
将复杂的五通道 AXI4 从机事务解构为简洁的底层内存控制器用户接口（Native MC User Interface）：
- **命令端口（Command Port）**：
  - `mc_user_en`：用户请求使能；
  - `mc_user_cmd[2:0]`：原子操作码（`3'b000` = 写入命令，`3'b001` = 读取命令）；
  - `mc_user_addr[27:0]`：映射后的物理存储地址；
  - `mc_user_ready`：本地总线就绪反压信号。
- **数据写入端口（Write Data Port）**：
  - `mc_user_wren` / `mc_user_wdata[127:0]` / `mc_user_mask[15:0]` / `mc_user_end`（突发结束标志）。
- **数据读出端口（Read Data Port）**：
  - `mc_user_rd_valid` / `mc_user_rd_data[127:0]` / `mc_user_rd_end`。

#### 2. `axi_upsizer.v` 数据重组器
当 AXI 主机的突发大小或总线位宽与底层控制器不一致时，该模块充当减速/加速齿轮箱。通过内部暂存寄存器，在小数据宽度输入时将其拼装为 128 位对齐节拍，或在读出时将 128 位拆分为对应窄总线。

---

### 2.6.5 本地命令调度与缓冲层 (`local_bus_ctl/`)

* **源码定位**：[rtl/ddr3_controller/local_bus_ctl/local_bus_ctl.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/local_bus_ctl/local_bus_ctl.v)

#### 1. 核心调度职责
`local_bus_ctl` 是位于 AXI 协议接口与底层协议引擎之间的“减震器”：
- **读写缓冲区管理**：集成深度可配置的写数据缓冲与读数据暂存 FIFO，处理突发期间两端时钟或握手微小抖动；
- **地址顺序重排与拆分**：将传入的线性连续地址分解为对应的 `Bank`、`Row` 和 `Column` 物理切片；
- **就绪信号流水反馈**：向上游输出 `mc_user_wrdy`（写准备就绪）与 `mc_user_ready`，当下游协议引擎执行行预充电或自刷新时，及时产生优雅反压。

---

### 2.6.6 JEDEC 协议核心引擎 (`memory_bus_ctl/`)

* **源码定位**：[rtl/ddr3_controller/memory_bus_ctl/memory_bus_ctl.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/memory_bus_ctl/memory_bus_ctl.v)

#### 1. DDR3 核心状态机行为
该模块是整个存储子系统中逻辑最庞大的状态机。它将“读/写数据”这一高级意图，翻译为严格符合 JEDEC 规范的底层物理引脚控制流程：
1. **行冲突与行激活（Precharge & Activate）**：
   - 检查目标 Bank 当前打开的行号。
   - 若目标行与当前打开行不同（Row Miss / Bank Conflict）：先发出 `PRE`（预充电）命令关闭旧行，延时 $t_{RP}$；接着发出 `ACT`（激活）命令打开目标行，延时 $t_{RCD}$；
   - 若目标行与当前打开行相同（Row Hit）：跳过预充电与激活，直接发射列读写命令（**极大降低访存延迟，这是 BitBLT 按行读写性能极高的根本原因**）。
2. **读/写命令派遣（Read / Write Dispatching）**：
   - 下发 `RD` 或 `WR` 命令并送出 Column 地址；
   - 写操作时，在经过 $CWL$ 周期后驱动数据与选通；读操作时，在 $CL$ 周期后接收返回数据。
3. **自刷新定时注入（Auto-Refresh Injection）**：
   - 内部维护一个纳秒级计数器监控 $t_{REFI} = 7.8 \mu s$；
   - 当计数溢出时，仲裁器抢占普通读写请求，将所有激活的 Bank 执行预充电关闭，随后发出 `REF` 刷新命令，严格等待 $t_{RFC} = 350 \text{ ns}$ 完成 DRAM 电容充电，之后恢复普通读写。

---

### 2.6.7 物理层 PHY 与动态校准子系统 (`phy_ctl/`)

* **包含源码**：
  - [phy_ctl/phy_ctl.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/phy_ctl/phy_ctl.v)：物理层控制顶层
  - [phy_ctl/ddr_calibration_ini.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/phy_ctl/ddr_calibration_ini.v)：上电复位与模式寄存器配置引擎
  - [phy_ctl/ddr_phy_wrlvl.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/phy_ctl/ddr_phy_wrlvl.v)：写入调平（Write Leveling）
  - [phy_ctl/ddr_phy_rdlvl_dqs.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/phy_ctl/ddr_phy_rdlvl_dqs.v)：读 DQS 门控与定心对齐
  - [phy_ctl/ddr_mpr_rdlvl.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/phy_ctl/ddr_mpr_rdlvl.v)：基于多用途寄存器的读校准
  - [phy_ctl/ddr_phy_wrcal.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/phy_ctl/ddr_phy_wrcal.v)：写 DQ 校准
  - [phy_ctl/ddr_phy_if.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/phy_ctl/ddr_phy_if.v)：物理 I/O 引脚原语映射接口

#### 1. 为什么在 400 MHz 下必须进行动态校准？
在 400 MHz 时钟下，1 个比特的数据窗口仅有 **1.25 ns**。PCB 走线微小的物理长度差异、芯片封装引线电感、以及温度/电压漂移，会导致信号边缘发生数百皮秒（ps）的偏斜（Skew）。静态配置无法保证时序收敛，必须在上电时由硬件逐项动态训练。

#### 2. 上电初始化与模式寄存器配置 (`ddr_calibration_ini.v`)
严格遵照 JEDEC DDR3 标准上电时序：
1. **上电复位期**：保持 `ddr_reset_n = 0` 至少 200 $\mu s$；
2. **CKE 稳定期**：拉高 `ddr_cke = 1` 并维持 500 $\mu s$ 时钟震荡；
3. **预充电与寄存器初始化**：
   - 下发全 Bank 预充电（`PREA`）；
   - 依次配置模式寄存器：**MR2**（设定 $CWL=5$）、**MR3**（常规操作）、**MR1**（使能内部 DLL，设置 $AL=0$, $RTT\_NOM=40\Omega$）、**MR0**（触发 DLL 复位，设置 $CL=6$, 突发类型为 BL8）；
   - 执行长校准（`ZQCL`），等待 512 个时钟周期完成引脚阻抗标定。

#### 3. 写入调平机制 (`ddr_phy_wrlvl.v` - Write Leveling)
DDR3 规范要求时钟线 CK 采用 Fly-by 菊花链走线拓扑，这导致 CK 信号到达存储颗粒的时间必然晚于 DQS。
- 调平逻辑使能芯片内部的调平反馈模式；
- 控制器通过步进调节内部可编程延迟线（Delay Chain），微调各个字节通道的 DQS 输出相位；
- 当捕获到内存芯片通过 DQ 反馈回来的翻转跳变沿时，锁定该延迟偏置，确保 DQS 与 CK 在芯片引脚处精准同相对齐。

#### 4. 读 DQS 门控与 MPR 读校准 (`ddr_phy_rdlvl_dqs.v` & `ddr_mpr_rdlvl.v`)
- **读门控（Read Gate Training）**：
  在读操作期间，DQS 是双向三态信号。控制器必须精准推测出外部 DQS 脉冲到达 FPGA 引脚的确切窗口，适时打开内部门控；太早会采样到总线高阻浮空噪声，太晚会丢失第一拍数据。
- **MPR 预定码测试**：
  指挥 DDR3 芯片输出其内部多用途寄存器固化的预置模式串（`01010101`）；
  控制器逐拍平移内部 `rx_cal_clk` 时钟相位，扫描并测量眼图（Eye Diagram）的左边界与右边界，最终将实际工作采样点稳稳锁定在眼图正中央（Golden Center），实现最高的抗噪声裕量。

---

### 2.6.8 跨时钟桥与底层 FIFO 缓冲 (`lb2_axi_clk.v` & `common/`)

1. **[rtl/ddr3_controller/lb2_axi_clk.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ddr3_controller/lb2_axi_clk.v)**：
   负责本地总线（Local Bus）与 AXI 总线时钟域的异步/同步适配桥接。在本工程中，通过参数 `ASYN_AXI_CLK = 0` 设置为纯同步模式（两者均运行在 100 MHz），此时桥接逻辑自动优化为零周期直通，消除不必要的跨时钟域打拍延迟。
2. **`rtl/ddr3_controller/common/` 模块群**：
   例化专用的伪双口 RAM 与 Efinix FIFO 包装器（`efx_fifo_wrapper.v`），用于在命令下发与数据返回各流水级之间提供深层排队弹性，防止物理层偶发刷新时总线接口发生死锁。

---

## 2.7 第七小章：hdmi 差分编码与视频物理串化详解

> **所属目录**：`rtl/hdmi/`  
> **核心使命**：将图形流水线生成的 24 位 RGB 像素与同步信号，转换为符合 DVI 1.0 / HDMI 规范的直流均衡 10-bit TMDS 码字，并通过 Titanium 物理差分串化器输出至外部显示器。

---

### 2.7.1 TMDS 协议原理与 HDMI/DVI 显示规范

本系统最终输出为 **1366 $\times$ 768 @ 75.0 Hz** 高清图像。数字图像从 FPGA 输出到 HDMI 显示器必须经过标准物理层转换。

#### 1. 核心速率与传输拓扑
- **像素工作时钟**：`pixelclk = hdmi_tx_slow_clk = 85.714 MHz`。
- **5 倍速物理串化时钟**：`hdmi_tx_fast_clk = 428.57 MHz`。
- **物理差分通道**：包含 4 对高速差分走线：
  - `TMDS Clock +/-`：差分像素同步时钟；
  - `TMDS Data 0 +/-`：蓝色（Blue）通道及行场同步信息；
  - `TMDS Data 1 +/-`：绿色（Green）通道；
  - `TMDS Data 2 +/-`：红色（Red）通道。
- **等效传输速率与物理带宽**：
  采用 DDR（双沿采样）模式，单通道速率为 $428.57 \text{ MHz} \times 2 = 857.14 \text{ Mbps}$。三路数据通道合计提供高达 **2.57 Gbps** 的物理净传输带宽，轻松满足 75 Hz 高刷显示要求。

#### 2. TMDS 编码的两大核心使命
1. **翻转最小化（Transition Minimization）**：  
   高频信号线上频繁的 $0 \leftrightarrow 1$ 跳变是电磁辐射（EMI）的主要来源。TMDS 算法通过异或或同或逻辑，将原始 8 位的电平跳变次数压制到 4 次以内，极大降低信号辐射与线路损耗。
2. **直流均衡（DC-Balancing）**：  
   如果传输线上连续发送过多的 '1' 或 '0'，会导致差分线两端的直流电平漂移，使接收端无法准确判决阈值。TMDS 算法通过维护“视差计数器（Disparity Counter）”，在统计出现单极性偏移时动态反转输出码字，维持长时间传输中 '1' 与 '0' 数量的严格平衡（50% 占空比）。

---

### 2.7.2 `encode.v`：标准 DVI 1.0 8b/10b 编码器底层深度剖析

* **源码定位**：[rtl/hdmi/encode.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/hdmi/encode.v)

每个颜色通道均独立例化一个 `encode` 模块，其内部硬件实现包含三个严格的流水节拍：

```
       8-bit 输入像素 din[7:0]
                 │
                 ▼
      ┌─────────────────────┐
      │  Stage 1: 8b -> 9b  │ 统计 '1' 个数，依据 decision1 执行 XOR/XNOR
      │ (翻转最小化编码)      │ 产生 9 位中间码 q_m[8:0]
      └──────────┬──────────┘
                 │
                 ▼
      ┌─────────────────────┐
      │  Stage 2: 9b -> 10b │ 运行视差计数器 cnt 评估直流偏置 (decision2/3)
      │ (直流均衡与极性反转) │ 产生 10 位最终平衡码字 dout[9:0]
      └──────────▲──────────┘
                 │
      ┌──────────┴──────────┐ (de == 0 消隐期)
      │  消隐期控制 Token 发生 │ 根据输入 {c1, c0} 插入 4 组专用同步码字，
      │  (Control Tokens)   │ 并将视差计数器 cnt 强制复位清零
      └─────────────────────┘
```

#### 1. Stage 1：8-bit 到 9-bit 翻转最小化算法
- **步骤 1：统计 '1' 的个数 (`n1d`)**：
  流水线第一拍对 `din[7:0]` 的 8 个比特执行加法求和，得出当前字节中高电平的数量（范围 0..8）。
- **步骤 2：模式判定准则 (`decision1`)**：
  ```verilog
  assign decision1 = (n1d > 4'h4) | ((n1d == 4'h4) & (din_q[0] == 1'b0));
  ```
- **步骤 3：逻辑编码转换**：
  - 若 `decision1` 为真：第 0 位保持原样，后续各位依次与前一位进行**同或（XNOR）**运算，并将第 8 位标识位置 `1'b0`；
  - 若 `decision1` 为假：第 0 位保持原样，后续各位依次与前一位进行**异或（XOR）**运算，并将第 8 位标识位置 `1'b1`；
  - 输出 9 位中间数据 `q_m[8:0]`。此时低 8 位内部相邻比特间的跳变次数被严格压制在 4 次及以下。

#### 2. Stage 2：9-bit 到 10-bit 直流均衡控制
模块内部维护一个 5 位的有符号视差计数器 `cnt[4:0]`（最高位 `cnt[4]` 为符号位），统计整个通信历史上发送的 1 与 0 之差：
- **统计中间码偏斜**：计算 `q_m[7:0]` 中 1 的数量（`n1q_m`）与 0 的数量（`n0q_m`）；
- **判定 1 (`decision2`)**：若当前历史视差为 0（`cnt == 0`）或本码字内 1 与 0 数量相等，则直接根据 `q_m[8]` 进行输出，第 9 位填入 `~q_m[8]`；
- **判定 2 (`decision3`)**：若历史视差的正负方向与本码字中多数比特的方向相同（例如历史 1 偏多，本码字 1 也偏多），表明直流偏移正在进一步恶化：
  - 硬件将第 9 位置 `1'b1`；
  - 将低 8 位全部按位取反输出；
  - 强制拉回中性电平，并更新视差计数器 `cnt`；
- 否则：第 9 位置 `1'b0`，原样输出 `q_m[7:0]`。

#### 3. 消隐期控制字符插入 (Control Tokens during Blanking)
当数据有效使能 `de == 0`（即当前像素处于行消隐或场消隐期间）时，模块不输出图像，而是将视差计数器 `cnt` 强制复位清零，并根据输入的 2 根控制线 `{c1, c0}` 插入固定的抗干扰控制字符：

| 控制输入 `{c1, c0}` | 输出 10-bit 控制码字 (`dout`) | 对应控制 Token 宏定义 |
| :---: | :---: | :---: |
| `2'b00` | `10'b1101010100` | `CTRLTOKEN0` |
| `2'b01` | `10'b0010101011` | `CTRLTOKEN1` |
| `2'b10` | `10'b0101010100` | `CTRLTOKEN2` |
| `2'b11` | `10'b1010101011` | `CTRLTOKEN3` |

* **物理层重要意义**：这 4 个特殊的控制码字拥有极其稠密且对称的跳变沿，显示器端的解码芯片（如 HDMI 接收 PHY）在消隐期依靠捕捉这些 Token，完成**时钟与数据相位锁定（CDR Clock/Data Recovery）**以及**10 位字边界对齐（Byte-Boundary Framing）**。

---

### 2.7.3 `dvi_encoder.v`：三通道色彩打包与时钟信道发生器

* **源码定位**：[rtl/hdmi/dvi_encoder.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/hdmi/dvi_encoder.v)

`dvi_encoder` 整合了 3 个 `encode` 实例，并将色彩和同步脉冲分配给标准的物理差分信道：

#### 1. 蓝通道：`encb`（Channel 0 / `tmds_data0`）
- 输入像素：`blue_din[7:0]`；
- **核心控制引脚复用**：
  ```verilog
  .c0(hsync),
  .c1(vsync)
  ```
- **DVI 规范核心**：行同步脉冲 `hsync` 与场同步脉冲 `vsync` **全部通过蓝色数据信道的消隐期控制 Token 编码传递**！显示器通过解包蓝色通道在消隐期的 `CTRLTOKEN0~3`，就能准确还原出水平行与垂直场扫描信号，外部无需任何独立的同步连线。

#### 2. 绿通道与红通道：`encg` & `encr`（Channel 1 & 2）
- 绿通道（Data 1）：输入 `green_din[7:0]`，控制端拉死 `.c0(1'b0), .c1(1'b0)`；
- 红通道（Data 2）：输入 `red_din[7:0]`，控制端拉死 `.c0(1'b0), .c1(1'b0)`。

#### 3. 差分时钟发生通道（Clock Channel / `tmds_clk`）
模块以纯硬件常数生成时钟信道字：
```verilog
assign tmds_clk = 10'b1111100000;
```
5 个高电平后接 5 个低电平。当外部串化器以 10 倍速时钟将其移位发出时，输出端呈现的正好是一个**频率严格等于 85.714 MHz 像素时钟、占空比严格为 50% 的完美差分方波时钟**。

---

### 2.7.4 板级物理层差分串化与 PCB 极性反转适配

#### 1. Titanium 硬件高速 TX 串化器（10:1 减速齿轮箱）
`dvi_encoder` 输出的是 4 组 10-bit 并行总线（`tmds_data0/1/2` 与 `tmds_clk`）。在易灵思 Titanium 架构中：
- 顶层引脚在 Interface Designer（`ti60_top.peri.xml`）中被配置为专用的高速 LVDS 发送器（Serializer 模式）；
- 硬件以 `hdmi_tx_slow_clk`（85.714 MHz）写入并行字，以 `hdmi_tx_fast_clk`（428.57 MHz）执行双沿触发（DDR）串行移位，实现 10:1 齿轮串化，驱动差分物理引脚。

#### 2. PCB 走线极性反转补偿（`~tmds_*`）
在 [rtl/ti60_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ti60_top.v) 第 1041-1044 行存在一个非常精妙的硬件适配设计：
```verilog
// Invert TMDS outputs to match board differential LVDS PCB trace polarities
assign tmds_clk_o   = ~tmds_clk;
assign tmds_data0_o = ~tmds_data0;
assign tmds_data1_o = ~tmds_data1;
assign tmds_data2_o = ~tmds_data2;
```
- **物理成因**：在开发板 PCB 布局布线时，为了保证高速差分对走线平直等长、免打过孔并获得最优阻抗控制，硬件工程师常常会在走线层直接将差分对的正端（P）和负端（N）引脚进行了物理交叉对调；
- **FPGA 软解法**：数字逻辑内部只需在发送前整体执行**按位取反（`~`）**，零门电路代价、零延迟抵消了 PCB 走线极性反接。显示器接收到的差分电平依然为纯正的正相波形，体现了 FPGA 软硬件协同设计的极高灵活性。

---

## 2.8 第八小章：Triad 架构全局走线互联与引脚映射速查表

> **核心使命**：汇总全系统在重构为 **Triad（三足鼎立）解耦架构** 后的模块间总线路由、时钟域拓扑、仲裁优先级与物理引脚约束。为底层驱动开发、时序收敛调优以及系统级硬件 Debug 提供最高效的全景互联指引。

---

### 2.8.1 Triad 架构顶层互联总线与通道映射表

在顶层模块 [rtl/ti60_top.v](file:///E:/FPGA/Ti60_2D_Graphics_Accelerator/rtl/ti60_top.v) 中，重构后的 Triad 架构通过五大互联通道实现高内聚、低耦合的协同运作：

```
                    +------------------------------------+
                    |   Sapphire RISC-V SoC (100MHz)     |
                    +-----------------+------------------+
                                      | APB3 Master
                                      v
                    +------------------------------------+
                    |   apb_command_dispatcher (rtl/apb) |
                    +--------+------------------+--------+
                             |                  |
      Pure 2D Command Bus    |                  | Effect / Layer Config Bus
      (No Display Bloat!)    v                  v (No AXI/FIFO Bloat!)
       +-----------------------+              +-----------------------------+
       |   bitblt_top          |              | display_engine_top          |
       |   (rtl/bitblt/)       |              | (rtl/display_engine/)       |
       +-----------+-----------+              +--------------+--------------+
                   | AXI4 Read/Write                         ^
                   | Master (S2)                             | Streaming fb_pixel
                   v                                         | & Timing Bus
       +-----------------------+              +--------------+--------------+
       |   axi_mux (3-to-1)    |<=============| dma_top                     |
       +-----------+-----------+ AXI4 Read    | (rtl/dma/)                  |
                   |             Master (S0)  +-----------------------------+
                   v
       +-----------------------+
       |   video_write_guard   | (Defends Scanout FIFO from BitBlt Starvation)
       +-----------+-----------+
                   |
                   v
       +-----------------------+
       |   ddr3_top            |
       +-----------------------+
```

下表详尽列出了各大核心模块在顶层中的端口绑定、所属时钟域、数据位宽与功能定义：

#### 1. APB 命令分发中枢 (`u_apb_command_dispatcher`)

| 端口名称 | 方向 | 位宽 | 关联顶层信号 / 源模块 | 时钟域 | 信号功能说明 |
| :--- | :---: | :---: | :--- | :---: | :--- |
| `clk / rst_n` | 输入 | 1/1 | `core_clk / ddr_rstn` | 100MHz | 核心时钟与 DDR 稳定复位信号 |
| `apb_paddr` | 输入 | 16 | `apb0_paddr` (SoC) | 100MHz | APB3 从机字节寻址地址 |
| `apb_psel` | 输入 | 1 | `apb0_psel` (SoC) | 100MHz | APB3 从机片选信号 |
| `apb_penable` | 输入 | 1 | `apb0_penable` (SoC) | 100MHz | APB3 使能信号 |
| `apb_pwrite` | 输入 | 1 | `apb0_pwrite` (SoC) | 100MHz | APB3 读写选择（1: 写, 0: 读） |
| `apb_pwdata` | 输入 | 32 | `apb0_pwdata` (SoC) | 100MHz | APB3 写入数据 |
| `apb_prdata` | 输出 | 32 | `apb0_prdata` (SoC) | 100MHz | APB3 读取回传数据 |
| `apb_pready` | 输出 | 1 | `apb0_pready` (SoC) | 100MHz | 从机就绪应答（固定 1'b1 零等待） |
| `cmd_*` | 输出 | 复合 | `u_bitblt` 命令接口 | 100MHz | 纯净 2D 绘图命令总线（Op, Addr, Stride, Alpha） |
| `vdma_next_base` | 输出 | 28 | `u_dma.next_frame_base_addr` | 100MHz | 左半屏待切换显存基地址（双缓冲） |
| `vdma_right_next_base` | 输出 | 28 | `u_dma.next_right_base_addr`| 100MHz | 右半屏待切换显存基地址（双缓冲） |
| `vdma_active_base` | 输入 | 28 | `u_dma.active_frame_base_addr`| 100MHz | 当前场生效左半屏基地址 |
| `vsync_flag` | 输入 | 1 | `vdma_vsync_flag` (`u_dma`) | 100MHz | 场消隐单脉冲，驱动 `frame_irq` 翻页触发 |
| `weather/laser/beam_*` | 输出 | 复合 | `u_display_engine` 控制端 | 100MHz | 纯流式特效实时参数总线 |
| `btile/bpal_*` | 输出 | 复合 | `u_display_engine` 写入端 | 100MHz | 启动期弹幕精灵瓦片与调色板写端口 |

#### 2. 纯数据提取引擎 (`u_dma`)

| 端口名称 | 方向 | 位宽 | 关联顶层信号 / 目标模块 | 时钟域 | 信号功能说明 |
| :--- | :---: | :---: | :--- | :---: | :--- |
| `axi_clk / axi_rst_n` | 输入 | 1/1 | `core_clk / ddr_rstn` | 100MHz | AXI 总线时钟与复位 |
| `pixel_clk / pixel_rst_n`| 输入 | 1/1 | `hdmi_tx_slow_clk / locked` | 85.71MHz | 视频像素时钟与锁相环锁定标志 |
| `m_axi_ar*` | 输出 | 复合 | `axi_mux` S0 通道 | 100MHz | 视频扫描读 AXI4 地址通道（ID=0, LEN=63/31） |
| `m_axi_r*` | 输入 | 复合 | `axi_mux` S0 通道 | 100MHz | 视频扫描读 AXI4 数据通道（128-bit 突发数据） |
| `h_cnt / v_cnt` | 输入 | 12/11 | `u_display_engine.h/v_cnt` | 85.71MHz | 像素级实时扫描光标坐标 |
| `t_de` | 输入 | 1 | `u_display_engine.t_de` | 85.71MHz | 有效显示期数据使能 |
| `t_frame_clear` | 输入 | 1 | `u_display_engine.t_frame_clear` | 85.71MHz | 跨时钟场消隐复位（16 周期展宽电平） |
| `video_read_priority` | 输出 | 1 | `u_video_write_guard.video_priority` | 100MHz | 扫描 FIFO 缺水指示（Watermark < 512） |
| `fb_pixel` | 输出 | 32 | `u_display_engine.fb_pixel` | 85.71MHz | 经过 Gearbox 转换后的底层 32-bit ARGB8888 像素 |
| `bucket_row` | 输出 | 2560 | `u_display_engine.bucket_row` | 85.71MHz | 预取的 80 槽位弹幕空间桶数据 |

#### 3. 纯流式视频显示引擎 (`u_display_engine`)

| 端口名称 | 方向 | 位宽 | 关联顶层信号 / 目标模块 | 时钟域 | 信号功能说明 |
| :--- | :---: | :---: | :--- | :---: | :--- |
| `pixel_clk / pixel_rst_n`| 输入 | 1/1 | `hdmi_tx_slow_clk / locked` | 85.71MHz | 视频像素时钟与复位 |
| `fb_pixel` | 输入 | 32 | `u_dma.fb_pixel` | 85.71MHz | 底层背景像素输入 |
| `t_frame_clear` | 输出 | 1 | `u_dma.t_frame_clear` | 85.71MHz | 16 周期展宽场消隐脉冲，通知 DMA 复位水位 |
| `h_cnt / v_cnt` | 输出 | 12/11 | `u_dma.h/v_cnt` | 85.71MHz | 数字视频时序坐标输出 |
| `video_r / g / b` | 输出 | 8/8/8 | `u_dvi_encoder.red/green/blue_din` | 85.71MHz | 经过 5 层图层合成与后处理滤镜后的最终 RGB 数据 |
| `video_hs / video_vs` | 输出 | 1/1 | `u_dvi_encoder.hsync / vsync` | 85.71MHz | 最终行/场同步数字脉冲 |
| `video_de` | 输出 | 1 | `u_dvi_encoder.de` | 85.71MHz | 最终消隐数据使能 |

---

### 2.8.2 Ti60F225 物理引脚分配速查表

全工程针对 Efinix **Ti60F225** 封装（0.8mm Pitch 225-Ball FBGA）进行了详尽的 Bank 电压与引脚映射规划。各主要功能引脚物理定义如下：

#### 1. 系统时钟、复位、串口与外设接口

| 端口名称 | FPGA 管脚编号 | Bank 编号 | I/O 电平标准 | 方向 | 功能描述 |
| :--- | :---: | :---: | :---: | :---: | :--- |
| `clk_25m` | **K15** | Bank 1B | 1.8V LVCMOS | 输入 | 板载 25.0 MHz 晶振主时钟输入源 |
| `system_uart_0_io_txd` | **F14** | Bank 1A | 1.8V LVCMOS | 输出 | RISC-V SoC 调试串口发送（115200 bps） |
| `system_uart_0_io_rxd` | **F13** | Bank 1A | 1.8V LVCMOS | 输入 | RISC-V SoC 调试串口接收 |
| `key_sw0_in` | **L15** | Bank 1B | 1.8V LVCMOS | 输入 | 板载轻触按键 SW0（低电平有效，带硬件消抖） |
| `key_sw2_in` | **M15** | Bank 1B | 1.8V LVCMOS | 输入 | 板载轻触按键 SW2（低电平有效，带硬件消抖） |
| `i2c_scl_IN/OUT` | **J14** | Bank 1B | 1.8V LVCMOS | 双向 | 游戏手柄 I2C 时钟线 SCL（外接 40-Pin 扩展座） |
| `i2c_sda_IN/OUT` | **H14** | Bank 1B | 1.8V LVCMOS | 双向 | 游戏手柄 I2C 数据线 SDA（外接 40-Pin 扩展座） |
| `soc_gpio_OUT[0..3]` | **D13, D14, E13, E14** | Bank 1A | 1.8V LVCMOS | 输出 | 状态指示 LED（指示系统运行、DDR 校准完成与帧翻页） |

#### 2. DDR3 SDRAM 内存物理总线（16-Bit / 1.5V SSTL-15）

| 端口名称 | FPGA 管脚编号 | Bank 编号 | I/O 电平标准 | 信号极性与说明 |
| :--- | :---: | :---: | :---: | :--- |
| `ddr_ck_hi / lo` | **B12 / A12** | Bank 4A | SSTL-15 差分 | DDR3 差分时钟（400 MHz，物理差分对） |
| `ddr_reset_n` | **A10** | Bank 4A | 1.5V LVCMOS | DDR3 硬件复位引脚（低有效） |
| `ddr_cke` | **C11** | Bank 4A | SSTL-15 | DDR3 时钟使能信号 |
| `ddr_cs_n` | **C10** | Bank 4A | SSTL-15 | DDR3 片选信号（低有效） |
| `ddr_ras_n` | **B10** | Bank 4A | SSTL-15 | DDR3 行地址选通（低有效） |
| `ddr_cas_n` | **B9** | Bank 4A | SSTL-15 | DDR3 列地址选通（低有效） |
| `ddr_we_n` | **A9** | Bank 4A | SSTL-15 | DDR3 写使能信号（低有效） |
| `ddr_ba[0..2]` | **C9, D9, A8** | Bank 4A | SSTL-15 | DDR3 8 个 Bank 寻址引脚 |
| `ddr_addr[0..13]`| **B8, C8, D8, A7, B7, C7, D7, A6, B6, C6, D6, A5, B5, C5** | Bank 4A | SSTL-15 | DDR3 14 位多路复用行/列地址线 |
| `ddr_odt` | **D10** | Bank 4A | SSTL-15 | DDR3 片上终端匹配控制 |
| `ddr_dqs_in/out_hi[0..1]`| **A3 / B2, A1 / B1** | Bank 4B | SSTL-15 差分 | 高低字节差分数据选通（DQS0/DQS1 P/N 对） |
| `ddr_dm_hi/lo[0..1]` | **C3, C2** | Bank 4B | SSTL-15 | 高低字节数据掩码线 |
| `ddr_dq_in/out_hi[0..15]`| **D4, C4, B4, A4, D3, B3, D2, C1, D1, E1, E2, E3, F1, F2, F3, G1** | Bank 4B | SSTL-15 | 16 位双向数据总线 DQ[15:0] |

#### 3. HDMI / DVI 高速差分显示物理接口（3.3V LVDS 串行发送）

| 端口名称 | FPGA 管脚编号 | Bank 编号 | 接口电气标准 | 说明 |
| :--- | :---: | :---: | :---: | :--- |
| `tmds_clk_p / n` | **L3 / M3** | Bank BL | 3.3V LVDS 差分 | 85.71 MHz 像素时钟差分对（PCB 极性正常） |
| `tmds_data0_p / n` | **M4 / N4** | Bank BL | 3.3V LVDS 差分 | 蓝色分量 + H/V 差分通道（PCB 极性反转，已在 RTL 反相抵消） |
| `tmds_data1_p / n` | **N5 / P5** | Bank BL | 3.3V LVDS 差分 | 绿色分量差分通道（PCB 极性反转，已在 RTL 反相抵消） |
| `tmds_data2_p / n` | **L6 / M6** | Bank BL | 3.3V LVDS 差分 | 红色分量差分通道（PCB 极性反转，已在 RTL 反相抵消） |

---

### 2.8.3 全局时钟拓扑与复位同步链结构

全系统依赖 Efinix 钛金系列 FPGA 内部的 3 组硬核锁相环（PLL）构建出严格对齐、低抖动的多时钟域骨干网络：

```
                25.0 MHz Crystal (Pin K15)
                             |
         +-------------------+-------------------+
         |                   |                   |
         v                   v                   v
     +-------+           +-------+           +-------+
     |PLL_TL0|           |PLL_TR0|           |PLL_BR0|
     +---+---+           +---+---+           +---+---+
         |                   |                   |
         v                   +----> 400 MHz      +----> 85.71 MHz (Pixel Clk)
     100.0 MHz (Core/AXI)    |      (sdram_clk)  |      (hdmi_tx_slow_clk)
     (core_clk)              +----> 400 MHz      |
                             |      (rx_cal_clk) +----> 428.57 MHz (5x SERDES)
                             +----> 400 MHz 90°         (hdmi_tx_fast_clk)
                                    (tx_cal_clk)
```

#### 1. 复位时序产生树与防亚稳态释放
1. **PLL 锁定监测**：顶层组合逻辑采集 `sys_rst = pll_locked & user_pll_locked`。在主晶振起振或 PLL 失锁抖动时，复位立即强制拉低；
2. **200,000 周期硬件延迟计数器**：
   在 `core_clk` 时钟域下启动 20-bit 计数器 `rst_cnt`：
   $$\Delta t_{delay} = \frac{200000}{100 \times 10^6 \text{ Hz}} = 2.0 \text{ ms}$$
   提供 2 毫秒的充足物理静置时间，确保 DDR3 颗粒内部初始化（tXPR/tMOD）及电源轨绝对平稳；
3. **分域异步复位同步释放（Asynchronous Assert, Synchronous Deassert）**：
   计数完成输出 `ddr_rstn` 主复位信号，各子系统分别使用本地两级 D 触发器进行同步释放，彻底规避亚稳态扩散。

### 2.8.4 架构演进成果总结

通过本次对原单一巨型单片结构 `v_dma/` 的战略重构，整个图形加速器项目实现了质的跃迁：
1. **解耦彻底（Decoupled Triad）**：
   - `rtl/apb/`：纯粹专注总线寻址与时钟域隔离，告别任何视频时序与计算杂质；
   - `rtl/dma/`：纯粹专注显存突发吞吐与跨时钟域 FIFO 缓冲，告别一切着色与图层计算；
   - `rtl/display_engine/`：纯粹专注流水线时序发生与 5 层图层实时着色，无任何 AXI 总线及存储器仲裁负担；
2. **撕裂根绝（Zero-Tearing Certified）**：
   - 彻底修复 `video_write_guard` 中的优先级反转；
   - 修正 Gearbox 在欠载下的 `word_stall` 相位冻结，根除行像素错位；
   - 将 CDC 场消隐单脉冲展宽为 16 像素周期的安全电平，杜绝跨时钟漏帧；
   - 统一由顶层单点分发 `active_base`，终结读地址竞争。

---

*(本手册当前已完整收录第一大章【RTL 全局结构】及第二大章全部八大小章：2.1【BitBLT 详解】、2.2【common 详解】、2.3【apb 命令分发中枢】、2.4【dma 纯数据提取引擎】、2.5【display_engine 纯流式视频显示引擎】、2.6【ddr3_controller 高速存储子系统】、2.7【hdmi 差分编码与串化】与 2.8【Triad 全局走线互联与引脚映射速查】。全套核心 RTL 解读体系已全面合龙。)*

