# 美术来源与授权

本项目没有自绘或 AI 生成角色/背景素材。以下为下载素材及可复现的格式适配。

| 用途 | 作者 / 原始页面 | 授权 |
| --- | --- | --- |
| 灵梦四帧、琪露诺敌人、空 Boss / 敌人 | Jaysa：[Touhou Fumo Factory](https://opengameart.org/content/touhou-fumo-factory) | 素材页面标注 CC0 |
| 森林背景四层 | Luis Zuno / ansimuz：[Forest Background](https://opengameart.org/content/forest-background) | CC0，原文见 source/forest/parallax_forest_pack/license.txt |
| 血量、火力图标、弹幕及击杀粒子 | Kenney：[Pixel Shmup](https://kenney.nl/assets/pixel-shmup) | CC0，原文见 source/shmup/License.txt |
| 面板九宫格纹理 | Kenney：[UI Pack – Pixel Adventure](https://kenney.nl/assets/ui-pack-pixel-adventure) | CC0，原文见 source/ui/License.txt |
| 界面与 HUD 字体 | Kenney：[Kenney Fonts](https://kenney.nl/assets/kenney-fonts) | CC0，原文见 source/fonts/License.txt |
| 第 1 关冰原背景 | OpenGameArt：[Winter Pixel Art Background With Mountain](https://opengameart.org/content/winter-pixel-art-background-with-mountain) | OGA-BY 3.0；PNG 归档于 source/stage/winter/ |
| 第 2 关火山背景 | Tio Aimar：[2D Platformer Volcano Pack 1.1](https://opengameart.org/content/2d-platformer-volcano-pack-11) | CC0；PNG 归档于 source/stage/volcano/ |
| 第 3 关梦境背景 | OpenGameArt：[Fairy-Tale 2D Backgrounds](https://opengameart.org/content/fairy-tale-2d-backgrounds) | OGA-BY 3.0；PNG 归档于 source/stage/fairytale/ |

角色下载地址（保留原始 PNG，未从商业游戏拆包）：

- https://opengameart.org/sites/default/files/fumoreimu_0.png
- https://opengameart.org/sites/default/files/fumoreimu-sheet_0.png
- https://opengameart.org/sites/default/files/fumocirno_0.png
- https://opengameart.org/sites/default/files/fumookuu.png

三关新增的琪露诺 Boss、镜像灵梦 Boss / 小兵均由上表已归档的原图做最近邻缩放、镜像与调色板变换；激光光晕复用 Kenney Pixel Shmup 的竖向弹体轮廓。没有引入新的、来源不明的角色图片。

适配包括最近邻缩放、透明像素转换为 0x00FF00FF、32 色调色板、背景压暗、
面板九宫格排版、字体栅格化及 RLE 压缩。左右倾斜是同一授权角色的旋转版本；
四帧主要为头饰/附属动作变化，不是额外绘制的身体动画。

角色页面在本次工具抓取中返回过 404，但网页检索记录仍提供作者/CC0信息，
静态 PNG 可以下载；公开发布前建议再次核实或向原作者确认。

本项目为基于东方 Project 的非官方同人比赛演示，不代表 ZUN / 上海爱丽丝幻乐团。
角色原始 IP 不会因某张同人图片采用 CC0 而变为公共领域，仍需遵守
[东方官方同人规则](https://touhou-project.news/guidelines_en/)。

禁止将代码仓库的开源许可证误认为所有其他素材的许可证。

## 三关背景（2026-09-20 新增）

`tools/build_stage_backgrounds.py` 把下面三张原始素材编码成 `sw/app/stage_bg.c` 里
的三张 640x600 plate（外加一条 32x600 视差条）：最近邻缩放、**逐资产独立 32 色调色板**，
RLE 与 visual_assets 同格式（tag 高 3 位是 len-1、低 5 位是调色板索引，len 全 1 时转义到
12 位计数，单 run 最多 4095 像素）。三张 plate 共 17110 字节，开机一次性解码进 DDR，
换阶段只写一个指针。

- 第 1 关冰原：源图 `source/stage/winter/background.png`。为压缩做过取舍——RLE 按 run
  收费，所以雪点噪点按成本削减，雪帽下沿从逐列跳变改成正弦（同一张图 12.9 kB -> 5.8 kB）。
- 第 2 关火山：源图 `source/stage/volcano/bg_volcano.png`。
- 第 3 关梦境：**最终没有使用 fairy-tale 的像素层**。那套是 1920x1080 绘画，降到目标
  分辨率后边缘颜色过多，RLE 要 18 kB，超出那 63 KiB 的固件预算；改成程序画的阔叶树剪影。
  `source/stage/fairytale/` 仍留在仓库备用，若将来固件腾出空间可以换回。

以上三处素材的授权信息来自各自 OpenGameArt 页面，页面本身不提供独立的 license 文件，
因此每个素材目录下补了一份 `LICENSE.txt`，写明作者、来源 URL、授权与抓取日期：

- `source/stage/winter/LICENSE.txt` — OGA-BY 3.0
- `source/stage/volcano/LICENSE.txt` — CC0（作者 Tio Aimar）
- `source/stage/fairytale/LICENSE.txt` — OGA-BY 3.0（该套图层当前未用于出货图）

公开发布前仍建议再访问一次这三条 URL，核对授权是否变化。
