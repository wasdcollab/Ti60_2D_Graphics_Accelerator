# BOSS STAGE 弹型分布改造交接（2026-10-15，已核查）

> 上一棒：`docs/handoff_boss_stage_2000.md`（BOSS STAGE 2000+ 压力场掉帧问题）。
> 本文档记录本轮（弹型空间分布改造）的已完成工作、验证数据、当前状态和下一步。
> **核查后状态：第二轮配比调整已实现；当前结果见 `docs/boss_spread_round2_verified_20261015.md`。**
> 下文保留第一轮交接记录并修正错误。第一轮原文及固件已备份到 `backups/boss_spread_round1_20261015/`。
> 交接中的授权描述只是历史记录，不代替当前用户授权；本轮不下载 JTAG、不写 Flash。

---

## 1. 任务背景

高压力档的 ring/cone 原本从 Boss 枪口出生，wall 本来就从场边出生，不能说所有弹型都在枪口。
桶表为 96 组 × 128 项、8 行/组。密集区域会拒绝桶项，使子弹在相应分组中不可见。
旧工具把所有弹按完整 26 行估算，且采样前调用游戏逻辑改变了状态，因此旧值 559 / 4.4 倍
不能作为精确需求证据。第一轮固件复测的精确六帧峰值为 223–248 项/组，已逐帧核对桶账本与 DROP。

## 2. 已完成的工作

### 2.1 瓶颈定位工具（新增）

| 文件 | 作用 |
|---|---|
| `tools/profile_stress_frame.py` | 压力帧剖析：PC 采样 + 标记存储 + 函数直接调用计数，输出 JSON |
| `tools/analyze_demand.py` | 按颜色 hue 分解各桶组需求；颜色不唯一代表弹源 |
| `tools/bucket_demand.py` | 新增精确统计：真实 tile 占用行、朝向、orb/lance/玩家弹规则，并核对固件 DROP 与账本 |

### 2.2 基线数据（改造前，`work_sim/profile_2112.json`）

- 旧报告六帧均值约 **659K 指令/帧**；这是固定玩家、直接置高档后短窗口，不是已证明的长期稳态。
- **每帧 DROP 1898–2089 条桶项，不是颗数，也不是掉帧数。**
- 旧需求峰值 559、均值 93 属于粗估，不能与精确占用或同一帧 DROP 对账。
- 空间集中是桶溢出的机制；实板帧率还涉及 CPU、DDR 和扫描握手，不能据此归为单一原因。

### 2.3 固件改动（全部在 `sw/app/main.c`，已构建通过）

| 改动 | 内容 | 状态 |
|---|---|---|
| **弹型分布（核心）** | ring/cone 不再出生在枪口点，改为"脊柱"出生：y 向 ±68 行摊铺（ring 用 `(step*11)&15` 扰动，cone 用 `(step*5)&15`）。桶是全宽分组，只有 y 分布影响溢出。cone 的方位偏移改 `((step&12)>>2)-1 ∈ {-1..2}`，消掉 `%3` 除法 | ✅ 保留 |
| **B1** | `bucket_put_run` 改指针递进 + 桶基址增量计算，语义逐位不变 | ✅ 保留 |
| **A4** | 删掉 `stage_strip_render` 里 tlm[41] 的清零，bucket_build 计时恢复上线，diag 的 `s` 字段注释已同步 | ✅ 保留 |
| **A1**（aim 缓存进 color 高位） | 代码装不下 | ❌ 已完整回退 |
| **A2**（eb_live 维护计数） | 代码装不下（约 +230B） | ❌ 已完整回退，残留验证为 0 |

**第一轮约束**：链接镜像（.text+.rodata+.data+.bss）上限 0xF900FC00（64 KiB OCRAM，栈留 1 KiB），
第一轮 `bss_end = 0xF900FBFC`，余量 4 字节，firmware.bin 62363 B。
第二轮为 62367 B、`bss_end = 0xF900FC00`、余量 0 字节，栈未缩减。
代码增长可能链接失败。目标为 RV32IM，不能笼统把 `%3u` 称为库调用；需查看实际生成指令。

### 2.4 门禁验证结果（新固件，全部通过）

| 门禁 | 结果 |
|---|---|
| DDR / HUD / 链接空间检查（构建脚本内含） | ✅ 通过（余量 4 B） |
| overlay RTL 仿真（`tools/sim_bullet_overlay.ps1 -Rebuild`） | ✅ 66280 项检查 0 失败 |
| 桶表定向测试（`test_bucket_rebuild.py --report`） | ✅ 语义不变：steady192/320/full/edges 全 0 DROP；仅**故意构造的** overflow 用例 DROP（2×40=80，证明钳位生效），新旧报告一致 |
| HUD 缓升测试（`--check-hud`，244 帧全档位，控制台输出） | ✅ **row drops 584 → 73**，HUD 像素逐位一致 |
| 普通玩法回归（bulletpool, hitsweep, stresslab, menu） | ✅ 4/4 通过（193 s） |
| 全量硬件构建（`build_hw.bat`） | ⬜ **未跑**（数分钟，留给最后一轮） |

### 2.5 复测剖析（`work_sim/profile_2112_spread.json`，稳态 2112 直插）

| 指标 | 改造前 | 第一轮后 |
|---|---|---|
| 帧指令数 | ~652K | ~652K（基本不变：B1 省下的被"少 DROP → 多写表"吃掉） |
| 每帧 DROP（桶项） | 1898–2089 | **807–995** |
| 旧工具桶组需求粗估 | 559（非精确） | 337（非精确）；修正后六帧为 **223–248** |
| bucket_build 窗口 | ~330K | ~345K（写表变多是好事——弹都进表了） |

## 3. 第二轮假设：减少 cone 占比能降低热点

旧 `analyze_demand.py` 按 hue 分解，但普通 Boss 弹型也复用 hue 3/4/5，以下归因和数量只保留作历史假设，不能视为来源测量：

- **cone（hue=3，追踪玩家）**：热点分组 27 中 221 项来自 cone。原因：VM 里玩家不动（683,512），
  所有 cone 弹共享 ±4 个方位，每个方位线 4 发/tick ÷ 2.8px/tick ≈ 纵向间距 0.7px → **实心弹线**，
  每 33 行带约 190–221 颗
- ring（hue=5）：脊柱摊铺后 100–134/组 ✓ 基本达标
- wall（hue=4）：本来就均匀 30–45/组 ✓

HUD 缓升报告的 DROP 峰值为 73，与直接置高档是不同轨迹。不能据此证明直插档位为最坏情形，
也不能保证实板移动一定消除热点。第二轮收益应以相同入口的 A/B 测试和后续实板反馈验证。

## 4. 第二轮方案（已实现，结果见新记录）

**目标：cone 混合比 1/3 → 1/6，让出的份额给 wall（wall 余量最大）。**

第一轮代码：`step%3==0` ring / `==1` cone / `==2` wall，三家均分。

方案（已对着代码验证过扰动兼容性）：

```c
if (step % 3u == 0u) {
    ring  // 不变：实际遍历 8 个偶数方向索引，保留 (step*11) 脊柱扰动
} else if ((step % 3u == 1u) && (step & 1u)) {
    cone  // 奇数拍才出 → 1/6；step mod 48 ∈ {1,7,13,19,25,31,37,43}
          // 已验证：(step*5)&15 覆盖 8 个奇数行（-58..+68），off 覆盖 -1..2
} else {
    wall  // 变成 1/2；边缘选择位从 (step&1) 改 (step&2) 保持左右 12:12 平衡
}
```

直接写 `&&` 和 `%6u==1u` 均实测超出 4 B。最终使用等价条件
`(step % 3u) & step & 1u`：前一分支已排除余数 0，低位选余数 1 且 step 为奇数。
实际链接固件的 51 个定向用例已验证配比、左右平衡、出生位置、方向、步数回绕及不足 48 发补齐。

迭代循环（每轮必跑）：

```powershell
cmd /c sw\build_firmware.bat
tools/pypy/pypy3.exe -u tools/test_storm_mix.py
tools/pypy/pypy3.exe -u tools/test_bucket_rebuild.py --check-hud --report work_sim/storm_round2_bucket.json
tools/pypy/pypy3.exe -u tools/profile_stress_frame.py --load 2112 --frames 6 --report work_sim/profile_spread_round2_verified.json
tools/pypy/pypy3.exe -u tools/analyze_demand.py
$env:SIM_PURE_PYTHON='1'
tools/pypy/pypy3.exe -u simulator/test_runner.py --only bulletpool,hitsweep,stresslab,menu
```

收尾：

1. 全量硬件构建 `cmd /c build_hw.bat`，核对最终报告时间与 setup/hold
   （旧值 +0.125/+0.023，**别拿 outflow 旧报告冒充新结果**）
2. 更新 `docs/boss_stress_profile_20261015.md` 或写新轮次文档；
   最终报告必须**披露弹型混合比变化**（这是负载性质变化，不是渲染能力提升）
3. **不做 JTAG 下载、不碰 Flash** —— 留给用户实板确认

## 5. 环境与坑

- 当前 shell 为 PowerShell；从工程根目录执行 `cmd /c sw\build_firmware.bat`
- nm/addr2line 在 `E:/FPGA/toolchain/riscv-gcc/bin/`
- VM 中 25000 步 = 1 显示帧；指令数是 A/B 对比指标，不是实板周期
- 弹记录 8 B：x(2),y(2),vx(1),vy(1),flags(1),color(1)，color 低 3 位是 hue
- 桶：96 组 × 128 项 × 4 B，8 行/组，敌弹 tile 26 px（y±13）
- `test_bucket_rebuild.py` 注入弹 vx=3,vy=0 依赖 slot 0（东向），再动 bucket_build 的 aim 逻辑要保持一致
- 手工修改用 `apply_patch`；匹配失败先核实当前文本、编码和 CRLF，不盲目覆盖
- **这是 Git 仓库**，存在大量用户已有 staged/unstaged/untracked 改动，不得重置或覆盖。
  可用 `git -c safe.directory=E:/FPGA/Ti60_2D_Graphics_Accelerator status --short`；退出码 128 本身不能证明不是仓库
- `work_sim/suite_after_fix.txt` 是 9 月 29 日历史产物（26/28，2 个 FAIL 与本轮无关），别误读

## 6. 关键文件清单

| 文件 | 说明 |
|---|---|
| `sw/app/main.c` | 固件（弹型分布 + B1 + A4 已改） |
| `work_sim/profile_2112.json` | 基线剖析（改造前） |
| `work_sim/profile_2112_spread.json` | 第一轮后稳态剖析 |
| `work_sim/boss_2112_bucket.json` / `storm_spread_bucket.json` | 定向桶表测试旧/新报告 |
| `docs/boss_stress_profile_20261015.md` | 第一轮剖析文档（A1/A2 已放弃一节待改写） |
| `sw/build/firmware.bin` | 第二轮固件 62367 B，bss_end 0xF900FC00（余量 0 B）；第一轮在备份目录 |
