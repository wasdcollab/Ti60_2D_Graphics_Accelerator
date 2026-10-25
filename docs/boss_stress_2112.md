# Boss stress 2112 and transparent overlap repair

Date: 2026-10-15. Candidate downloaded by volatile JTAG. User confirmed
2212 sprites, 37 FPS, DROP 560, rectangular overlap holes gone and continuous
music. Functional board acceptance passed for these observations; high-load
performance and bucket omissions remain unresolved. Music Flash was NOT changed.

## DROP and population

- SPRITES counts active enemies, player/enemy projectiles, items, player and
  boss. It excludes decorative FX, weather and laser pixels.
- Each eight-scanline group has 128 bucket entries. A rejected entry is one
  projectile/group pair, not one whole projectile and not a dropped frame.
- TLM_BUCKET_DROPS is the current frame's rejection count. The HUD holds the
  worst single-frame count since entering/changing the load.
- Subtracting DROP from SPRITES does not give a rendered projectile count.

## Firmware

- Enemy pool: 2304 records, 8 bytes each, at 0x01675400..0x01679BFF.
  The last 32 records remain reserved for orbs. Player pool stays at 512.
- Y cycles 192, 320, ... 1984, 2112, then 192. It advances once per press.
- Supplemental spawn budget is 48 per logic tick. Boss patterns still fire,
  so population may exceed the supplemental target.
- HUD population uses 12 bits (previously 11, which wrapped above 2047).
  LOAD uses four digits; its label/box were resized to stay in the left gutter.
- Expanded DDR ranges pass tools/check_ddr_layout.py.
- Firmware binary is 62327 bytes; linked data/BSS end at 0xF900FBD8,
  leaving only 40 bytes below the reserved 1 KiB stack. Future firmware
  changes must keep the linker-size gate enabled.

## RTL

Active source: rtl/display_engine/2_layer_generators/video_bullet_overlay.v.
The older rtl/v_dma copy is not the active project source.

Previously the highest two rectangular hits were tested for transparency.
Two transparent candidates hid every lower bullet, exposing the background
as a rectangular hole. The new encoder selects the last NONTRANSPARENT hit
among all 128 entries.

Coverage is derived from the same boot-time tile writes, not a hand-authored
shape approximation. One bit per tile byte is packed into a 512x32 dual-clock
RAM. Each scanline caches one 26-bit mask per bucket entry during x=0..128.
The cache is usable at x=129, before the playfield starts at x=181.

The DMA must publish the bucket before x=0 and keep it stable through the
active line. Existing DMA lifts it in the preceding horizontal blank. Loss of
bucket_ready or reset invalidates the cache until a complete line preparation.
Tile configuration must remain an ascending contiguous boot stream starting
at address zero, followed by immutable tiles during gameplay. Partial final
32-byte blocks are supported; firmware writes 14352 bytes.

Pixel pipeline latency remains N+3. Hue/role/alpha/DE stay aligned. Masking,
playfield clipping and the palette's additive sentinel remain unchanged.
This is priority selection of the top nontransparent texel, NOT accumulation
of every overlapping translucent glow. Bucket capacity is still 128.

The 3328-bit coverage cache deliberately maps to registers (all entries are
read in parallel). The 32-to-26-bit mask narrowing deliberately discards the
six columns outside the maximum tile width. These synthesis warnings are
expected; neither is a latch or an accidental BRAM fallback.

## Evidence

- tools/sim_bullet_overlay.ps1 -Rebuild:
  699392 reference pixels; 26624 streamed RTL pixels; 66280 checks, zero errors.
  Covers all tile shapes/hues, 127 transparent rectangles above a live bottom
  entry, row guards, clipping, occlusion, DE, partial final configuration
  block, readiness loss/recovery and reset/recovery.
- tools/test_bucket_rebuild.py --check-hud:
  actual linked RV32 instructions; both table buffers and stale-tail erasure;
  full 2304 enemy + 512 player pools; forced overflow and edge clipping.
  Uniform full-pool fixture: 7869 entries, zero rejected entries.
  244 pressure-stage frames: exact HUD pixels on both buffers, peak population
  2257, maximum per-frame group rejections 584, all 16 load settings and wrap.
  This is functional simulation, not board FPS or proof of zero omissions.
- Full build_hw.bat: Map, PNR and PGM passed.
  RAM10 247/256 (previous 255); LUT4 28058; FF 26530;
  packed XLRs 54894/60800 (90.29%).
  Worst setup +0.125 ns; worst hold +0.023 ns.
  HDMI pixel-domain setup +1.464 ns; hold +0.035 ns.
- Additional pure-Python RV32 regression: bulletpool, hitsweep, stresslab,
  menu all passed (4/4, 175.9 s). Menu scenario minimum SP was 0xF900FE30.
- JTAG programmer: device ID 0x10660A79, completed successfully.
- COM10 at 115200 baud produced no bytes during the 65-second capture;
  no Flash recognition or playback conclusion is drawn from that capture.

Logs: work_sim/boss_2112_build.log, boss_2112_overlay.log,
boss_2112_bucket.log, boss_2112_bucket.json, boss_2112_regression.log and
boss_2112_uart.log.
Timing: outflow/ti60_top.timing.rpt (2026-10-15 build).
Candidate image/reports/source snapshot:
backups/boss_2112_candidate_20261015/.
Bitstream SHA-256:
891dd9cfdcbe83e15bdb33c39d15b0ab417fb1f167086d16694f2e3ee42fa22b.

The graphics VM now models a disconnected SPI device (responses 0xFF) so
the real firmware can take its no-BGM boot path, and preserves audio-control
register readback. It does NOT simulate Flash music playback or I2S timing.

## Board acceptance and rollback

User-reported result after requesting LOAD 2112: SPRITES 2212, FPS 37,
DROP 560; transparent rectangles disappeared and music remained continuous.
This confirms 2000+ active objects and the overlap repair in the tested scene,
not 2000+ fully rendered projectiles at 75 FPS. DROP is a peak of rejected
group entries, not 560 missing whole bullets. Volume, menu return, long-run
minimum FPS and a same-build 960-load comparison were not reported.

Next performance work should measure allocation/update/bucket-building cost
before changing it, and separately address concentrated bucket overflow.
The 37 FPS observation alone does not identify which stage is limiting FPS.

Enter BOSS STAGE, release the entry chord, press Y to LOAD 2112 and wait for
the population to settle. Record SPRITES/FPS/DROP, check dense overlap for
rectangular holes, then confirm continuous music, volume and menu return.
Also compare a lower load (960) to distinguish CPU/bucket limits from a
graphics regression. Do not label 2000+ objects as zero-drop rendering.

Known-good previous image and firmware source snapshot:
backups/boss_2112_20261015/. A power cycle restores the unchanged Flash
version. Persistent deployment requires a new combined bitstream/music
Flash image; outflow/ti60_top_bgm.hex is still the OLD working image.
