# BOSS STAGE 第二轮：交接核查与配比调整

日期：2026-10-15。工程：`E:/FPGA/Ti60_2D_Graphics_Accelerator`。

## 1. 当前状态

- 已核对上一棒交接、实现第二轮配比调整，完成固件构建、软件回归、overlay RTL 仿真和全量硬件构建。
- 本轮助手没有 JTAG 下载，没有擦写 Flash。用户后续反馈该配比候选实板为 **SPRITES 2116、FPS 37、DROP 0，画面和音乐正常**。
- 更早的 2000+ 版本反馈为 `SPRITES 2212 / FPS 37 / DROP 560`，透明方框消失、音乐连续。两次反馈应分别保留，不混用。
- 本轮改变的是压力场弹型分布，不是扫描端容量，也没有实现“2000+ 稳定 75 FPS”。

## 2. 交接核查结果

| 项目 | 核查结论 |
| --- | --- |
| 第一轮代码 | y 向脊柱出生、桶内指针递进、恢复 tlm[41] 都在当前代码中；A1 aim 缓存、A2 eb_live 计数没有保留 |
| DROP | 被拒绝的桶项数量，不是子弹颗数，也不是掉帧数；同一颗弹可跨多个桶组。HUD 显示峰值，剖析报告记录逐帧值 |
| 旧需求 559 / 337 / 4.4 倍 | 旧脚本按完整 26 行计所有弹，忽略非透明行界、orb、lance 等差异；且在额外调用游戏逻辑之后取样，不能用于同帧精确对账 |
| hue 来源归因 | 普通 Boss 弹型也使用 hue 3/4/5，不能用颜色直接认定 ring/cone/wall 来源 |
| ring 方向 | `(step*2)&15` 实际只有 8 个偶数方向索引，不是 16 个 |
| 出生位置 | ring/cone 是 y 向脊柱，范围 -67..+68；没有“召唤圆”。wall 一直从两侧出生 |
| 稳态/最坏情形 | 原六帧只是固定玩家直接置高档后的短窗口，没有证明长期稳态或全局最坏情形 |
| Git | 工程是 Git 仓库，存在大量既有 staged/unstaged/untracked 改动；退出码 128 不能证明不是仓库 |
| 软件性能 | VM 指令不等于实板周期或 FPS。不能仅凭 VM 推定 CPI、DDR 占比或达到 75 FPS 的条件 |

原交接已就地更正，旧原文和第一轮文件保存在 `backups/boss_spread_round1_20261015/`。
`docs/boss_stress_profile_20261015.md` 保留为历史剖析，顶部列出失效结论和实施状态。

## 3. 本轮改动

### 固件

仅修改 `sw/app/main.c` 的 `stress_storm_update()` 配比判断、墙弹侧别及相关过时注释：

| 参数 | 第一轮 | 第二轮 |
| --- | --- | --- |
| ring / cone / wall | 1/3、1/3、1/3 | 1/3、1/6、1/2 |
| 每 48 发 | 16、16、16 | 16、8、24 |
| wall 左右选择 | `step & 1u` | `step & 2u`，每完整周期左右各 12 |
| 压力目标 | 192..2112，步进 128 | 不变 |
| 每逻辑 tick 补弹预算 | 48 | 不变 |
| 弹池、速度、脊柱公式、图块、音乐和扫描 RTL | 第一轮设置 | 不变 |

最终 cone 条件为 `(step % 3u) & step & 1u`。
前一个 ring 分支已排除余数 0，余数只能为 1 或 2；取低位再与 step 奇偶相交，等价于 `step%6==1`。
直接 `&&` 写法及 `%6==1` 写法均导致链接超出 4 B；最终表达式只增长 4 B。

这会改变弹型组成、存活时间、随机数调用轨迹和场景负载，不应包装为同负载引擎优化。

### 测量与验证工具

- `tools/bucket_demand.py`：从固件启动生成的 tile 像素独立取得占用行界，应用敌弹朝向、held/零速度、orb、lance、玩家弹和导弹规则；逐帧断言预测 DROP 及截断后的账本等于实际固件结果。
- `tools/profile_stress_frame.py`：在自然发布帧取需求快照，位于任何直接函数调用之前；记录 BIN/ELF SHA-256；修正非 2 的幂采样间隔；批量 addr2line 查询。保留 `tel_end` 旧字段名，但注明它只是帧号写入标记，桶标记窗口也不含完整函数序言。
- `tools/analyze_demand.py`：复用精确统计，支持 source/load/report，标注 hue 不是来源，移除错误的来源占比推论。
- `tools/test_storm_mix.py`：在真实链接固件的 game_update 中捕获 storm 最后一步存储，检查实际生成的弹记录。51 个用例覆盖 48 个起始相位、uint16 回绕、小额补齐、零余量；验证配比、墙弹平衡、出生坐标及速度方向。测试通过推迟 Boss 发射计时来隔离 storm，来源判断仅在这个隔离测试中成立。

## 4. 同口径 A/B 结果

第一轮输入来自备份中的 62363 B 固件；第二轮使用当前 62367 B 固件。
入口均为压力关，等待 3 帧后直接设置 LOAD 2112，到达目标后再等待 4 帧，固定玩家。
两版都在 21 个 ramp 发布帧达到 2118 sprites。以下六帧的需求统计与固件 DROP、桶账本逐帧完全一致。

| 指标，六个自然发布帧 | 第一轮 | 第二轮 |
| --- | ---: | ---: |
| SPRITES 范围 | 2117–2136 | 2116–2120 |
| 平均 VM 指令/发布帧 | 653177.8 | 659606.0 |
| 逐帧 DROP 范围 | 807–995 | 198–329 |
| 平均 DROP | 891.7 | 261.3 |
| 精确需求峰值范围，项/组 | 223–248 | 162–180 |

平均 DROP 约下降 70.7%，平均 VM 指令约增加 1.0%。**这是密度改善，不是帧率提升证据。**
新 `analyze_demand.py` 在采样窗口之前的那一帧测得 peak 180、DROP 382；采样时刻不同，不与上表范围混为一谈。

### 扩展到 48 个自然发布帧

相同入口，采样间隔为 16 条指令；需求和 DROP 仍在每一帧精确核对，不依赖 PC 采样精度。

| 指标，48 帧窗口 | 第一轮 | 第二轮 |
| --- | ---: | ---: |
| SPRITES 范围 | 2110–2136 | 2110–2120 |
| 平均 VM 指令/发布帧 | 666977.5 | 671225.4 |
| DROP 范围 | 239–995 | 1–329 |
| 平均 DROP | 499.1 | 85.1 |
| 需求最高峰，项/组 | 248 | 180 |

这一窗口平均 DROP 下降约 82.9%，平均指令增加约 0.64%。没有出现平均指令下降。
末帧第二轮仍有 10 条 DROP；48 帧也不是长期稳定性或全局最坏情形证明。
证据：`work_sim/profile_spread_round1_48.json`、`work_sim/profile_spread_round2_48.json` 及同名 `.log`。

### 244 帧缓升档位

两版均重新执行同一测试，逐像素核对双缓冲 HUD，检查按住 Y 只进一档及 2112 回绕 192：

| 指标 | 第一轮重跑 | 第二轮 |
| --- | ---: | ---: |
| 峰值 SPRITES | 2253 | 2263 |
| 测试期间 DROP 峰值 | 73 | 2 |
| 桶表 / 账本 / 清尾 / 边界 / 故意溢出 | PASS | PASS |
| HUD 像素及完整档位循环 | PASS | PASS |

不要把不同入口下的 73/2、逐帧直插数据和实板 560 放进同一个百分比比较。
这些测试不能保证任意玩家轨迹、Boss 相位、运行时长下 DROP 为 0。

## 5. 构建与回归

| 检查 | 结果及证据 |
| --- | --- |
| 固件编译、DDR/HUD 布局、BRAM lanes 校验 | PASS，`work_sim/storm_round2_firmware.log`；全量构建也重跑固件步骤 |
| 配比测试 | 51/51 PASS，`work_sim/storm_round2_mix.log` / `.json` |
| 桶表/HUD | PASS，`work_sim/storm_round2_bucket.log` / `.json`；第一轮证据 `storm_round1_verified_bucket.log` / `.json` |
| overlay RTL | 66280 checks，0 failed；软件参考 699392 pixels、连续 RTL 向量 26624，`work_sim/storm_round2_overlay.log` |
| bulletpool/hitsweep/stresslab/menu | 4/4 PASS，300.4 s，`work_sim/storm_round2_regression.log`；并发构建会影响宿主运行时间，不能当作固件性能变化 |
| Efinity map/interface/pnr/pgm | PASS，`work_sim/storm_round2_hw_build.log`；pgm 是生成文件，不是上板烧录 |
| 最新时序报告 | `outflow/ti60_top.timing.rpt`，报告时间 2026-10-15 15:15:42，文件时间 15:15:44 |
| 最差 setup / hold | +0.125 / +0.023 ns；HDMI slow +1.464 / +0.035 ns；core +1.500 / +0.026 ns |
| 资源 | XLR 54894/60800；Memory Blocks 247/256；与前版相同。本轮没有修改 RTL 或约束 |

时序通过指当前约束覆盖的路径通过，并不等于所有 CDC/未约束接口已经重新审计。
place 报告仍列有 Missing Interface Pins；本轮没有修改接口映射，也不声称构建无警告。

## 6. 当前产物与回退

- `sw/build/firmware.bin`：62367 B。
- `bss_end/image_end = 0xF900FC00`，镜像使用 64512/64512 B，**余量 0 B**。
- 栈区仍为 `0xF900FC00..0xF9010000`，1 KiB，未为容纳代码而缩减。
- 固件 SHA-256：`fbdacf345d0f420714947e563d68e778e4ccd4b9e3e720a0ec49b58675749b43`。
- 新 `outflow/ti60_top.bit`：3173736 B，文件时间 2026-10-15 15:15:48。
- 新 bit SHA-256：`ec18ff032be0e14ad34bddbeb423575e73e40176c1118aa38b1d350633b68bbb`。
- 第一轮固件 SHA-256：`527dee201fc5d4f2cbccdbf1412bf7ca8a9fb001ef5f9a6d16b1da3d44b3effd`，位于 `backups/boss_spread_round1_20261015/`。
- 本轮候选、固件、工具、日志、报告和交接快照：`backups/boss_spread_round2_20261015_151548/`。
- 已上板确认的 2000+ 候选仍在 `backups/boss_2112_candidate_20261015/`，bit SHA-256 为 `891dd9cfdcbe83e15bdb33c39d15b0ab417fb1f167086d16694f2e3ee42fa22b`。

outflow 已被新构建更新，不能把当前 outflow 误称为已上板验证版。没有进行掉电重启验证或 Flash 持久化验证。

## 7. 接手后的下一步

1. 先核对 SHA-256 和镜像空间；任何代码增长都需重新证明可链接，不能静默挤占栈。
2. 获得用户指示后，仅临时 JTAG 下载新候选；不要顺手烧写 bitstream 或音乐 Flash。
3. 同一路径按 Y 到 LOAD 2112，分别测静止、移动、持续射击，记录运行时长、SPRITES、FPS、DROP；确认透明方框仍消失、音乐连续、音量有效。
4. 若目标是提高实际 FPS，再读取恢复后的 `tlm[41]` / diag `s` 桶构建计时及其他板侧耗时。不要仅凭 VM 指令宣称已定位全部瓶颈。
5. 后续结构优化先解决固件零余量问题，再考虑计数缓存/朝向缓存；保留透明覆盖、双桶表、orb 预留池及音乐 Flash 布局。

工程当前有大量先前改动。用 `git -c safe.directory=E:/FPGA/Ti60_2D_Graphics_Accelerator status --short` 查看；不要 reset/checkout 清理，也不要提交无关文件。

## 8. 复现命令

在工程根目录的 PowerShell 中执行；请换报告名以保留历史证据。

```powershell
cmd /c sw\build_firmware.bat
tools/pypy/pypy3.exe -u tools/test_storm_mix.py
tools/pypy/pypy3.exe -u tools/test_bucket_rebuild.py --check-hud --report work_sim/storm_round2_bucket.json
tools/pypy/pypy3.exe -u tools/profile_stress_frame.py --load 2112 --frames 6 --report work_sim/profile_spread_round2_verified.json
tools/pypy/pypy3.exe -u tools/analyze_demand.py --report work_sim/storm_round2_demand.json
powershell -ExecutionPolicy Bypass -File tools/sim_bullet_overlay.ps1 -Rebuild
$env:SIM_PURE_PYTHON='1'
tools/pypy/pypy3.exe -u simulator/test_runner.py --only bulletpool,hitsweep,stresslab,menu
cmd /c build_hw.bat
```
