# 可用的开源音频素材与导入边界

## 已选来源

- [Touhou-SFX](https://git.touhou.dev/brogrammist/Touhou-SFX)：CC0，包含东方风格的敌弹、击杀、爆炸等效果音。适合下一阶段从外部 Flash 或 DDR 流式播放。
- [Kenney Digital SFX](https://opengameart.org/content/63-digital-sound-effects-lasers-phasers-space-etc)：CC0，含 9 个 laser、phaser、zap 等 WAV 效果音。
- [CC0 VGM 合集](https://iamoneabe.itch.io/public-domain-vgm)：CC0 的可用游戏音乐来源；应选择其中短循环的 chiptune/Tracker 曲目，而不是导入东方官方曲目。

## 当前实现

本版使用 FPGA 内合成器：背景循环、射击、激光、命中、击杀和 Boss 大招均为实时生成，不占 DDR 与 BitBlt 带宽。激光已改为短促高频版本，命中为短噪声爆裂。

## 为什么暂不导入完整 BGM WAV/MP3

当前 Ti60 映射已使用 245 / 256 个 RAM10；未压缩音频即使只按 8 kHz、8 bit、单声道保存，三分钟也要约 1.44 MB，不能可靠地放入剩余片内 RAM。把 PCM 放入 DDR 并由 I2S DMA 读出会与图形 DDR 流量竞争，破坏当前压力场景的帧率。

要播放选定的公开 BGM，下一步应增加外部 Flash 的顺序读取和小型双 FIFO，再从 Tracker/VGM 数据生成或缓存音频。该架构与实时弹幕扫描路径隔离。
