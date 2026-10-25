# Ti60 项目恢复版（2026-10-24）

工作目录：`D:\Ti60_Recovery_20261024\Ti60_2D_Graphics_Accelerator`。

本目录从远古备份复制，并结合本机保留的 Codex 会话中的补丁、源码输出和编译信息重建。
原始备份目录未修改。此版本是可追溯的恢复实现，不是丢失版本的逐字节副本。

板上 1088 负载出现 DROP=65535 的修正见 [docs/DROP65535_FIX.md](docs/DROP65535_FIX.md)。

2026-10-25：公平仲裁版本仍有板上故障；本次排空修复、首次错误快照及新版验证见 [docs/BUS_FAULT_20261025.md](docs/BUS_FAULT_20261025.md)。

最新修正：用户 Q 现场指向写事务停顿，已复现并修复运行命令被下一条 APB 配置改变模式的缺陷，见 [docs/CMD_LATCH_FIX_20261025.md](docs/CMD_LATCH_FIX_20261025.md)。

恢复说明、验证结果和未完成项见 [docs/RECOVERY_20261024.md](docs/RECOVERY_20261024.md)。
历史文档中的路径、性能数字、Flash 自动加载说明可能属于其他版本，以恢复说明为准。

构建：`build_hw.bat`，产物为 `outflow/ti60_top.bit` 和 `outflow/ti60_top.hex`。
该命令只构建，不烧录。固件单独构建：`python sw/build_firmware.py`。

游戏仿真：`python simulator/test_runner.py --only alpha,settings`。
恢复版默认使用 Python 内核；备份中的 native 扩展尚未验证，不应据其结果验收。

暂停菜单增加 `GLOW FX`；B 开关菜单，A 向下、Y 向上、X 确认。
压力场景目标上限 8000，实际板上帧率和视觉效果仍需实测。
BGM 当前使用 `tools/upload_bgm.py` 串口上传，尚未恢复上电自动从 Flash 加载。
