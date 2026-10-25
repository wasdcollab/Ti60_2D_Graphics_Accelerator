# 绘图命令预填导致写通道停顿：锁存修复（2026-10-25）

用户烧录 busdiag 版后，1000 sprite 仍出现 DROP=65535。本次依据首次故障 Q 现场，
定位并复现了 BitBlt 在运行期间被下一条命令改写处理模式的缺陷。
已修正 RTL、通过像素精确回归；是否消除实际板卡上的全部卡顿仍需烧录复测。

## 板上证据

原始七行 UART 保存在 `docs/recovery_evidence/board_uart_cmd_latch_20261025.txt`。
共同的 `Q=755016708=0x2D00A404` 解码为：

| 字段 | 值 |
|---|---|
| 首次原因 | 4000000 周期看门狗 |
| 分桶状态 | REC_WR：更新子弹记录的写入路径 |
| 分桶已接受但未收到响应的写入数 | 0 |
| 分桶 AWVALID / AWREADY | 1 / 0 |
| 分桶 WVALID / WREADY | 1 / 0 |
| 分桶 BVALID / BREADY | 0 / 1 |
| 共享写保护器 pending | 1 |
| BitBlt 未完成读请求 | 0 |
| DDR RVALID | 0 |
| 视频优先级 | 0 |

这是分桶正在等待共享写通道的证据。读路由选择为 0，但 RVALID 为 0，不能据此判断视频占住读总线。
Q 记录首次错误，后续 B/T 是当前或最近一笔任务，因此 Q 非零和 B 正常同时出现是预期行为。
F534/F566 的 B=0x30000000 表示 fault=1、真实 drop_count=0；T 分别为 10031651/10021783，
与 BitBlt 的 10000000 周期 watchdog 长度吻合。
F438/F502 的 B 低位 81/65 是没有 fault 的真实条目丢弃，与 65535 失败标记不同。

## 触发路径

`sw/driver/gpu2d.c` 的 copy/fill/add/alpha_blit 都先填写下一条命令的 APB 寄存器，
随后在 `gpu2d_finish()` 中等待上一条命令结束，再写 START。
这个提交顺序允许寄存器准备与上一条命令的绘制重叠。

`bitblt_stride_gen` 已在 START 锁存操作、地址和几何参数；
但 `bitblt_top` 原来直接用实时 `cmd_op_type` 选择 COPY/ALPHA/ADD 数据通路，
也直接使用实时透明色及 global alpha。

例如正在 COPY 时，软件预填下一条 ALPHA：地址迭代器仍只读取源数据，
输出却切换到必须同时有源和目标数据的混合管线。目标读取从未安排，WVALID 最终降为 0，
已经接受 AW 的写事务无法发完数据。写保护器等待它的 B 响应，分桶写也因此无法进入。
引擎在 10000000 周期后 abort/padding 才能释放这笔写，分桶此前已经超时。

游戏中的 `burst_render()` 直接调用 `r_alpha()`，没有在预填 OP_TYPE 前等待；
这为普通绘制与爆炸特效切换提供了实际软件触发路径。高负载下前一命令执行更久，
更容易与下一次预填重叠；触发负载不是固定的 sprite 容量边界。

## 修正

只修改 `rtl/bitblt/bitblt_top.v` 的运行配置：

- 在 cmd_start 锁存 active_op、active_colorkey_en、active_colorkey_val、active_global_alpha。
- 数据通路选择、Alpha/ADD 混合及写入色键掩码使用这组运行配置，直到下一次 START。
- 地址/几何参数仍由已有 stride generator 在 START 锁存。

固件提交顺序与字节内容保持不变；看门狗门限、共享写事务处理、分桶容量和视觉算法没有调整。
Q/B/T 诊断保留，重新烧录后可继续确认是否还有其他错误。

## 复现与回归

`tests/run_bitblt_portable.ps1 -Overlap -BeforeLatch` 使用归档旧 RTL，
让真实 APB dispatcher 在 COPY 已接受写地址时接收下一命令参数，并接入实际 video_write_guard。
旧实现实际失败，现场为：

```text
COPY timeout diagnostic: row=0 rows_done=0 reserved=34 writes_done=0 pending=34 rd_left=0 wr_left=0
WRITE WAIT: active=1 WVALID=0 read_queue=0 staged_op=2 running_op=1
SHARED GUARD: pending=1 AWVALID/READY=0/0 WVALID/READY=0/0
```

此测试在硬件 watchdog 前用有限等待判失败，验证的是写事务停顿。
它与 Q 中共享写事务未完成、读队列已空的状态吻合，不冒充完整板级复现。

修正后 `-Overlap` 的 10 组检查全部通过：COPY/FILL/ALPHA/ADD 在命令执行期间，
改变下一条操作、色键、透明度、地址、宽高、步长；当前命令的逐字节结果仍正确。
测试同时覆盖 AW/W 背压下的有效信号、数据稳定性及写入范围。

常规回归通过 153 组 COPY/FILL/色键相关向量和 86 组 Alpha 向量；
大画面回归通过 124/125/600 行复制、512×352 非对齐 COPY 与 Alpha+色键。
未用这些结果宣称 8000 sprite 已在实板流畅运行。

## 发布与板上复测

发布目录为 `D:\Ti60_Recovery_20261024\release_cmd_latch_20261025`。
使用其中 `ti60_cmd_latch_fix.bit` 或 `ti60_cmd_latch_fix.hex`。
先复测原来的 1000/1300 档，再逐级加负载；检查是否仍有约 100 ms 停顿和 65535。
若再出现错误，保留包含 Q/B/T 的一整行串口。串口仍为 115200、8N1。

源码压缩包及 SHA-256 清单同时保存到 C、D 两处，原先的 busdiag 发布包保留。

## 最终构建

`hardware_cmd_latch_20261025.log`：map/interface/pnr/pgm 全部通过，仅生成文件、未执行烧录。
最终布线时序通过；应使用 `.timing.rpt`，不要把布线前 `.place.timing.rpt` 的暂时违例当成最终结果。

| 项目 | 结果 |
|---|---|
| XLR | 51300 / 60800 |
| BRAM | 256 / 256 |
| DSP | 66 / 160 |
| core setup / hold | +0.906 ns / +0.008 ns |
| pixel setup / hold | +1.016 ns / +0.026 ns |
| 固件 | 64252 字节，与 busdiag 发布包逐字节一致 |
| bit 大小 | 3170859 字节 |
| bit SHA-256 | `a892e20109d7dffb836ee062a824bd50a930268389fc9f1d2218464b8bf6b4e0` |
| hex SHA-256 | `d8cbd516518cb92fc82c4652b62845ef390264c783877fc1d927044f4aa1bb91` |

既有综合警告数量仍为 237，没有新增运行配置的未驱动或 latch 警告。
core hold 余量较小，后续 RTL 改动仍须重新检查最终布线报告。
本轮测试日志、时序/资源报告和修改前的源码一并保存到 `docs/recovery_evidence`。

打包命令：`python tools/package_recovery.py --cmd-latch`。
源码包 `Ti60_cmd_latch_source_20261025.zip`；C 盘副本位于
`C:\Users\TimeCheney123\Ti60_recovery_20261024\release_cmd_latch_20261025`。
