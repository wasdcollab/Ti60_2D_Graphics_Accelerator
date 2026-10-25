# 1300 弹幕 DROP=65535：地址通道饿死定位（2026-10-25）

板上 UART 一句诊断（115200 8N1，每 32 帧一行）：

```text
F560 C11327837 j59616 g59093 m59608 b128 s3 h5126 z134152192 n77 r1400 d85056 B805306368 T10027312
```

结论先说：**这不是分桶容量不够，也不是 DDR 带宽不够。是 `Axi_Mux` 的地址通道仲裁把 3 号通道（弹幕协处理器）饿死了。**
协处理器在 4,000,000 周期看门狗处置 fault，`bucket_build_finish()` 于是把 DROP 写成 65535。
工作区里已经有一版公平仲裁实现（上一轮 23:31 写入、从未综合过），本次已核验并综合，见文末构建结果。

---

## 1. 串口字段怎么读

字段顺序来自 `sw/app/main.c:4953-4967`：

| 字段 | 含义 | 本行数值 | 判读 |
|---|---|---|---|
| `F` | 帧号 | 560 | — |
| `C` | 窗口内最坏帧周期（core_clk） | 11,327,837 | 113 ms，约 8.8 FPS，对应 HUD 的「FPS 10」 |
| `j` | 渲染段均值（不含 update），×128 为周期 | 59,616 | 7.6 M 周期 |
| `g` | 其中等待引擎的串行时间 | 59,093 | 7.56 M，占 j 的 99%：**CPU 在等 BitBlt** |
| `m` | `game_render()` 总时间 | 59,608 | 同上 |
| `b` | 其中底板绘制 | 128 | 16 K，可忽略 |
| `s` | `bucket_build_start()` 自身 | 3 | 384 周期，软件侧没有分桶开销 |
| `h` | 扫描线握手等待 | 5,126 | 0.66 M |
| `n`/`r`/`d` | BitBlt 命令数/行数/脏区字节 | 77 / 1400 / 85056 | 本帧提交了 77 条命令 |
| `B` | **APB 0x120 分桶状态** | **805,306,368 = 0x3000_0000** | bit28 = **fault**，低 16 位 = 0 |
| `T` | **APB 0x12C 任务周期** | **10,027,312** | 比 4,000,000 看门狗大 2.5 倍 |

状态字位定义在 `rtl/apb/apb_command_dispatcher.v:541`：

```verilog
{ (busy|start), done, 1'b1, fault, 12'd0, drop_count }   // bit31..bit0
```

所以 `B = 0x3000_0000` 是 **fault=1、busy=0、drop_count=0**。
`drop_count=0` 说明硬件一条桶表条目都没丢——**65535 不是丢弹数，是固件的故障标记**：

```c
// sw/app/main.c:6469-6472
if ((status & 0xB0000000u) != 0x20000000u) {
    GPU2D_REG_BUCKET_BASE = 0u;
    bt_dropped = 65535u;        // 失败可视，不把半张表当 DROP=0 发布
}
```

其余窗口 `B = 0x2000_0000`、`T = 44k~54k`，说明协处理器本身没坏：正常一帧只跑 0.45~0.55 ms。

## 2. 10M 周期的停顿是怎么来的

`T = 10,027,312` 说明这一帧的任务不但超了看门狗（4,000,000，`dma_bucket_coprocessor.v:367`），
之后还多花了约 6 M 周期才走到 `ST_DONE`。也就是**任务卡在总线上**，而不是算得慢。

卡住的通道是 3 号。`rtl/ti60_top.v:314-510` 的通道分配：

| 通道 | 主设备 | 用途 |
|---|---|---|
| S0 | `dma_top` | 扫描线读，`Cfg_Arb_Type=1` 硬优先 |
| S1 | Sapphire SoC | CPU 的取指/数据 AXI |
| S2 | `bitblt_top` | 2D 引擎读写 |
| S3 | `dma_bucket_coprocessor` | **弹幕读取 + 桶表写入** |

发布位流里的仲裁器（`rtl/common/Axi_Mux.v` 的 `Axi_Mux_Addr_Ctrl`，厂商 `Sta_Cnl_Switch` 状态机）
每次命中的同时把扫描指针复位到 0 号通道，只有在「当前没有任何通道请求」时才往下转一档：

```verilog
if (Act_Cnl_Hit) Sta_Cnl_Switch <= S_ADDR_ACT;
if (Cfg_Arb_Type & Act_Cnl_Hit) begin Channel_Cnt <= 0; Channel_List <= 1; end  // 回到 ch0
else if (Cnl_Search_En) begin ... 旋转 Channel_List ... end
```

于是它实际是「从 0 号开始、命中即停」的固定优先级扫描：1 号（CPU）和 2 号（BitBlt）只要都举手，
3 号永远排不到。`tests/tb_axi_grant_trace.sv` 把这件事量化了——四个通道持续请求 4000 周期：

```text
t=2599 grant #1000 -> ch1  (n=113,722,165,0)
TOTAL grants=1538 : 174,1111,253,0        <- 3 号通道 0 次
```

跑法：`iverilog -g2012 -I rtl/common -s tb_axi_grant_trace -o work_sim/trace.vvp
tests/tb_axi_grant_trace.sv tests/fixtures/Axi_Mux_vendor.v`，然后 `vvp work_sim/trace.vvp`；
换成 `rtl/common/Axi_Mux.v` 就得到当前的轮转结果。

这正是「1300 才出事」的原因：弹幕少的时候 CPU 或 BitBlt 总有一方空闲，扫描能转到 3 号；
到 1300 发、又按着攻击键时，CPU 的 dcache 缺失和 BitBlt 的逐行突发同时在请求集合里，
3 号就彻底没有窗口。

## 3. 复现（真实 RTL，不是模型）

`tests/tb_bucket_coprocessor_axi.sv` 新增 `-DBUCKET_TEST_BUS_LOADED`：
S1 全程拉高 ARVALID（模拟 CPU 每次访问都缺失），S2 也持续要突发读（模拟 BitBlt 逐行取数），
扫描线给 12.5% 的正常优先级，负载 1300 发，S3 接真实 `dma_bucket_coprocessor`，
仲裁器分别用发布包版本和当前版本：

```powershell
powershell -ExecutionPolicy Bypass -File tools\sim_bus_starvation.ps1 -Arbiter vendor -Load 1300
powershell -ExecutionPolicy Bypass -File tools\sim_bus_starvation.ps1 -Arbiter fixed  -Load 1300
```

`-Arbiter vendor` 用 `tests/fixtures/Axi_Mux_vendor.v`，就是
`release_drop65535_fix_20261024` 里那份（`Sta_Cnl_Switch` 状态机，130,958 B）：

```text
FAIL bucket job did not finish inside 5,000,000 cycles:
     state=4 bullet=0/1300 busy=1 fault=1 cycles=4999999 drop=0
     wr_pend=0 aw=0/0 w=0/0 b=0/1 aq=0/0 wq=0/0 replies=0
     competing bus reads granted: cpu=31123 bitblt=19640
```

`state=4` 是 `ST_READ_R`，`bullet=0` 表示**第一发子弹的读请求都没被批准**，
`aq/wq=0` 表示一条桶表写都没发出去；`fault=1` 是 4,000,000 周期看门狗，`drop=0`——
与板上串口的 `B`/`T` 同构（板上那次 T 之所以是 10 M，是排空阶段又拖了 6 M 周期）。

`-Arbiter fixed` 是工作区当前的公平仲裁器，同一激励、同一负载：

```text
PASS buffer=0 pb=0 eb=1300 drops=0 cycles=1729947
PASS buffer=1 pb=0 eb=1291 drops=0 cycles=1725740
PASS BUS-LOADED CONTENTION: 1300 load under CPU+BitBlt read pressure
```

1.73 M 是被测试台「每 1051 周期才回一个 B」的保守写响应模型拖出来的；
把该模型换成 41 周期回一个 B，同样 1300 发只要 **78,926** 周期（0.79 ms）。
板上正常窗口的 `T = 44k~54k` 正是这一类数量级，说明板上写响应并不慢，慢的是读通道拿不到总线。

仲裁器单独跑（`tests/tb_axi_grant_trace.sv`，四个通道持续请求 4000 周期）：

```text
vendor: TOTAL grants=1538 : 174,1111,253,0      <- 3 号 0 次
fixed : 均分，见 tests/tb_axi_background_fair.sv 的 grants=87,228,227,227
```

## 4. 修正

`rtl/common/Axi_Mux.v:2425-2481` 的 `Axi_Mux_Addr_Ctrl` 重写为：

* 0 号（扫描线）保持硬优先，`Cfg_Arb_Type=1` 时仍然无条件先给 S0，像素域的实时性不变；
* 1/2/3 号在 `cursor_bg` 上轮转，每批准一次就推进一格，**不再每次都从 0 号重扫**；
* 一次只把一个通道的地址送下去（原逻辑同样如此），被选中的通道在握手前地址保持不变。

三套验证都过：

| 验证 | 结果 |
|---|---|
| `tests/tb_axi_background_fair.sv`（旧版 `Axi_Mux`） | FAIL `master 3 starved: grants=1,2,1,0` |
| `tests/tb_axi_background_fair.sv`（当前版本） | PASS 两种仲裁模式，`grants=87,228,227,227` |
| `tools/sim_bucket_accel.ps1 -Large`（8192 池、全功能回归） | 18 帧全 PASS，8192 发 230,049 周期 |
| 本文第 3 节的负载复现 | 旧 FAIL（fault=1, bullet=0）/ 新 PASS |

## 5. 本次构建

`build_hw.bat`，日志 `work_sim/build_arbfix.log`，map / interface / pnr / pgm 全 PASS：

| 项目 | 数值 |
|---|---|
| 固件 | 64252 字节，`image_end = 0xF900FCF0`（与发布位流同一份固件，只有 RTL 变了） |
| XLR | 51200 / 60800 |
| DSP | 66 / 160 |
| core_clk setup / hold | +1.182 ns / +0.026 ns |
| hdmi_tx_slow_clk setup / hold | +1.822 ns / +0.035 ns |
| 位流 | `outflow/ti60_top.bit`（3,126,306 B，SHA-256 `D043CA52…D7A34FD`） |

发布包 `release_drop65535_fix_20261024` 里的 `rtl/common/Axi_Mux.v` 仍是厂商状态机
（130,958 B，含 `Sta_Cnl_Switch`），位流也是 23:11 用那份综合的；公平仲裁是 23:31 才写进工作区的，
所以板上跑的一直是没有修正的仲裁器。

## 6. 上板复测要点

烧 `outflow/ti60_top.bit` 后，同样进 BOSS STAGE、LOAD 加到 1300 以上、按住攻击，看串口：

* `B` 应为 `0x2000_0000`（`536870912`），**bit28 恒 0**；一旦出现 `0x3000_0000` 说明又 fault 了；
* `T` 应稳定在 5 万上下；出现百万级说明还在等总线；
* `C` 应回到 1.33 M 附近（75 FPS）；仍是 11 M 说明另有停顿；
* `g` 应远小于 `j`；`g≈j` 说明 CPU 还在等 BitBlt，即写通道又被谁堵住了。

## 7. 另一个隐患（本次未改）

`rtl/dma/video_write_guard.v:39-51` 的 `write_pending` 只有「收到 B 才清零」这一条路径，
256 周期的 `hold_out` 只管 AW 准入，管不了已被接受却没回来的 B。
如果某笔写的 B 没有被路由回来（例如 `Axi_Mux` 的 AW2W/W2B 信息 FIFO 在满的时候丢项），
整个写通道会无限期关闭，表现同样是百万周期级 `T`。

用当前测试台上「每 1051 周期才给一个 B」的极端模型可以稳定打出来：

```text
FAIL ... state=18(ST_CLEAR_WRITE) busy=1 fault=0 cycles=497512
     wr_pend=1 aw=1/0 w=1/0 b=0/1 aq=4758/4758 wq=4758/4758 replies=1
```

把该模型换成 41 周期一个 B 就不会出现，所以它是否在板上成立还没有证据。
建议后续给 `write_pending` 加一个有界排空（例如 4,096 周期后强制清零并置 sticky 诊断位），
或者在 `Axi_Mux` 的 W2B 压入前加 `~W2B_Full` 的背压。改这里之前先做板上复测，
避免把两种根因混在一起。

## 8. 本次新增/改动的测试

| 文件 | 作用 |
|---|---|
| `tests/tb_axi_grant_trace.sv` | 打印仲裁器逐次批准时间线，量化 3 号通道饿死 |
| `tests/tb_write_starvation_chain.sv` | BitBlt「先发 AW、W 等读数据」+ 单笔写保护器 → 其他主设备写被连坐 |
| `tests/tb_bucket_coprocessor_axi.sv` | 新增 `-DBUCKET_TEST_BUS_LOADED`：CPU + BitBlt 同时抢读，1300 发复现板上 fault |

`tb_write_starvation_chain` 在旧仲裁器下也能过（BitBlt 单笔在飞，写通道还有空隙），
它说明的是「写通道连坐」这条机制本身，不是本次的触发器；**触发器是读通道的 3 号饿死**。
