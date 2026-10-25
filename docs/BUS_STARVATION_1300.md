# 1300 负载：旧仲裁器饥饿复现记录（2026-10-25）

本文保留 DeepSeek 检查所得的旧仲裁器问题。用户已经确认烧录公平仲裁版本后仍出错，
因此这份记录只证明一个可复现缺陷；板上剩余故障的原因尚未确定。
当前修正、首次故障快照及新版烧录说明见 [BUS_FAULT_20261025.md](BUS_FAULT_20261025.md)。
修改前的原报告保存在 `D:\Ti60_Recovery_20261024\before_busdiag_20261025`。

## 板上已知证据

用户 UART 样本：

```text
F560 C11327837 j59616 g59093 m59608 b128 s3 h5126 z134152192 n77 r1400 d85056 B805306368 T10027312
```

B = 0x30000000，表示 fault=1、busy=0、实际 drop_count=0。
界面 65535 是固件的失败标记，不是实际丢弃了 65535 发子弹。
T = 10027312，超过协处理器 4000000 周期看门狗；它表明任务超时并花了更长时间结束。
这些字段不能单独区分读仲裁、读响应背压、写响应等待等原因。
用户确认未按攻击键也会发生卡顿。

## 旧仲裁缺陷及修改

`tests/fixtures/Axi_Mux_vendor.v` 对应旧发布包的厂商状态机。
地址批准后从 S0 重新扫描，持续的 CPU/BitBlt 请求可能让 S3 分桶协处理器得不到批准。
四通道持续请求的旧测试记录为：

```text
TOTAL grants=1538 : 174,1111,253,0
```

当前 `rtl/common/Axi_Mux.v` 的地址仲裁保持 S0 视频优先，在 S1/S2/S3 间轮转；
已选请求在握手前保持稳定。
独立测试 `tests/tb_axi_background_fair.sv` 验证两种仲裁模式及背压：
旧实现报 `master 3 starved: grants=1,2,1,0`，当前实现通过。

## 持续总线负载复现

`tests/tb_bucket_coprocessor_axi.sv` 的 BUS_LOADED 模式持续请求 CPU/BitBlt 读，
S0 定期请求，S3 连接真实协处理器。写响应每 1051 周期提供一次。
这是压力激励，不是实板 DDR 延迟测量。

```powershell
powershell -ExecutionPolicy Bypass -File tools\sim_bus_starvation.ps1 -Arbiter vendor -Load 1300 -ExpectStall
powershell -ExecutionPolicy Bypass -File tools\sim_bus_starvation.ps1 -Arbiter fixed -Load 1300
```

旧仲裁运行到 5000001 周期仍在 READ_R、bullet=0、fault=1，
同时 CPU/BitBlt 已分别获得 31123/19640 笔读批准。
这证明该激励能使 S3 饥饿，不证明实板故障一定由同一路径触发。

当前仲裁的完整四任务测试结果：

| 任务 | 周期 | 结果 |
|---|---:|---|
| buffer 0，1300 发 | 1729947 | 通过 |
| buffer 1，1291 发 | 1725740 | 通过 |
| buffer 0，空池清尾 | 1046794 | 通过 |
| buffer 1，空池清尾 | 1046794 | 通过 |

内容与参考结果一致，fault/drop 均为零。

## 原报告中清尾死锁判断的更正

原报告引用的 `state=18, cycles=497512, fault=0` 不是死锁证据。
当时测试把“整个测试累计超过 500 万 tick”误当成“当前任务超过 500 万周期”，
在正常清尾过程中提前中止。修正检查后，两次清尾都完成。

没有据此给 `write_pending` 增加超时强制清零；已经接受的 AXI 事务必须完成或按明确的总线复位协议恢复。
写响应是否在实板缺失仍需现场证据。

## 历史构建

DeepSeek 编译的公平仲裁镜像时间为 2026-10-25 00:06:15：
bit 文件 3126306 字节，SHA-256 前后缀 `D043CA52…D7A34FD`；
core setup/hold +1.182/+0.026 ns，pixel setup/hold +1.822/+0.035 ns。
该版本仅改变仲裁，固件仍未包含 Q 快照。用户已烧录此版并报告故障仍在。
当前 outflow 将被后续构建更新，应以单独发布目录及其 SHA-256 判断版本。
