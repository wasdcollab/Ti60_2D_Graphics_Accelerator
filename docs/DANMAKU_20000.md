# Danmaku stress limit 20000

The pressure-stage cap is 20000 bullets. The coprocessor finishes a 20000-bullet
motion-and-bucket job in **6.825 ms** (682,528 core cycles at 100 MHz), which is
51% of the 1366×768 ~75 Hz frame (13.284 ms, 1,328,357 core cycles). Drops on
that spread field are 0. The same job through the AXI mux is 685,316 cycles.

## Bottleneck

Two different limits were in the way. They are not the framebuffer blit and not
the scanline painter.

**1. Motion writeback was one AXI write transaction per two bullets.** The
coprocessor already reads the pool in 16-beat bursts (32 bullets). It used to
write a moved record back as its own address/data/response handshake. The bus
model that matches the board returns one write response per address, and it
stalls that response (`tick % 41` in the normal model, `tick % 1051` on the
board model). Raising the number of outstanding writes does not help: the next
address is not accepted until the previous response comes back. The frame cost
scales with the number of transactions, so the fix is fewer transactions.

Measured on the same testbench, HEAD coprocessor versus this one
(`-DBUCKET_TEST_10000`, direct slave, 100 MHz cycles):

| case | before | after |
|---|---:|---:|
| 512 player + 10240 enemy, motion | 504,954 (5.050 ms) | 309,835 (3.098 ms) |
| 3 player + 4001 enemy, motion | 190,689 | 115,085 |
| 4000 enemy stacked on one point, no motion | 49,075 cycles, **5952 drops** | 49,116 cycles, **5952 drops** |
| 20000 enemy, stratified, motion, both buffers | not representable (14-bit count, max 16383) | **682,528 / 682,566, drops 0** |
| same 20000 through `Axi_Mux` | — | 685,316 / 685,149, drops 0 |

A single-beat extrapolation of the old 10240 result to 20000 is about 986,000
cycles (9.86 ms). That still fits a frame by itself and leaves almost no room
once bitblt is on the same DDR port. The burst writeback is what makes 20000
a half-frame job. The mux adds about 3,000 cycles, so the interconnect is not
the limiter. Default `BURST_READ_LEN=1` (the 6144-pool suite) still matches the
old single-beat path: 6144 with motion is 253,255 cycles and the suite passes.

**2. A scanline group holds 1024 sprites, and that table is already the whole
BRAM budget.** `video_bullet_scanline` paints one sprite per pixel clock after
64 clear cycles, so a line can show at most 1456−64 = 1392 sprites. The
prefetch RAM is 128 bits × 512 and is 7 of the 256 memory blocks. Doubling the
1024 slots would double that RAM and the DDR group tables (2 × 96 × 4096 bytes
fills `MM_BULLET_WORK`). Neither fits. Bullets born on top of each other still
drop: 4000 stacked at one point still report 5952 drops, same as HEAD.

The old storm did that to itself. Walls had `vy = 0` and several steps shared a
group, so group 92 went past 1024 while the population was still well under
20000. The birth pattern is now a coprime lattice of the 96 groups
(`y = ((step * 5) % 96) * 8 + 4`), wall X is inside the coprocessor box
`x ∈ [182, 1169]`, and walls drift ±1 row per frame. A pure occupancy model of
that spawn (budget 224, including `spawn_ebullet` clamps) reaches population
20064 with a peak group of **727**, under the 900 asserted by
`tools/test_danmaku_capacity.py` and under the 1024 hardware slots. Player
shots are a few dozen entries on top of that.

The configurable cap stops at 20000 because that is the requested stress-test
limit. The pool is 20480 records so the last 32 stay the orb tail
(front run 20448). A linear scale of the measured 20000 job covers that front
run in about 7.0 ms. Past that, the next wall is the 1024-slot group, not the
AXI write path.

## Changes by module

- `rtl/dma/dma_bucket_coprocessor.v` — `eb_count` and the bullet index are 15
  bits (max 32767). On a burst read, a word that motion actually changed
  overwrites that beat of the existing 16×128 capture registers. At the end of
  the chunk one INCR write burst flushes the chunk (`awlen` = last beat
  consumed, `wlast` on that beat). Unchanged beats in a dirty chunk are written
  back as the bytes just read. A chunk is 256 bytes and both pool bases are
  256-byte aligned, so the burst stays inside a 4 KiB page and does not write
  past `bullet_limit`. Bucket, candidate, clear, and used-count writes stay
  single-beat (`awlen = 0`, `wlast = 1`). No new RAM block.
- `rtl/apb/apb_command_dispatcher.v`, `rtl/ti60_top.v` — APB 0x120 count is
  `{pwdata[15:14], pwdata[28:16]}`. `EB_CAPACITY` is 20480. Slot count, burst
  length 16, and `BUCKET_GROUP_ROWS` are unchanged.
- `rtl/dma/video_write_guard.v` — unchanged. It holds W until AW is accepted,
  then allows the beats of that one write until one B. A burst is one write.
  The board-contention bench (slow B, video priority) passes with the new
  `awlen`: 1088-load job, drops 0, 905,963 cycles, under the 2,000,000-cycle
  gate. Bus-loaded 1300 (CPU + bitblt reads competing) passes at 1,089,888
  cycles.
- `sw/driver/memory_map.h` — `MM_EBULLET_COUNT` 20480. Records end at
  `0x0169D400`, free/candidate lists end at `0x016A7400`, still below the font
  at `0x019B0000`. `MM_LANCE_INDEX` stays 1024 entries so it does not grow into
  `MM_RUNTIME_WORK`. `tools/check_ddr_layout.py` reports 55 surfaces + 26
  assets, disjoint.
- `sw/driver/gpu2d.h`, `sw/app/main.c` — `GPU2D_BUCKET_EB(n)` packs the 15-bit
  count. Counts ≤ 16383 still decode with the old formula. Stress max is
  20000, per-frame birth budget is 224 (the old budget of 96 topped out near
  15700 because bullets leave the field before the pool fills). Y on the
  pressure stage steps 19872 → 20000 → wrap to 192. Both `eb_lances[]` pushes
  stop at `MM_LANCE_INDEX_MAX`.
- `pool_clear()` still wipes the historical 10240-slot campaign prefix plus
  the 32-slot orb tail. Wiping all 20480 flags inside `game_init()` costs
  tens of thousands of instructions while the workbench is inside a fixed
  25000-step slice, so the campaign boss pattern drifts off the script and
  the craft dies during the scripted SHOT pickup (stage scenario: 5 pickups,
  atk 2, then the fourth SHOT feed respawns the craft). The stress stage
  clears the extended front run in `stress_stage_init()` after `game_init()`.
  With that split the stage scenario passes: caps atk 4 / weapon level 4,
  boss entered, 5 pattern changes.
- `simulator/bucket_model.py`, `simulator/native/socvm.cpp` — 15-bit count,
  pool 20480, 1024 slots, stride 4096. The Python model is what the workbench
  runs. The C++ model matches it; this VM has no pybind11 build of `_socvm`.
- Tests — `tests/tb_bucket_coprocessor_axi.sv` `-DBUCKET_TEST_20000` (direct
  path must finish under 750,000 cycles; the mux/board builds only have to
  finish with drops 0). `tests/tb_bgm_flash_spi.sv` round-trips 16383, 16384,
  20000, 20480, 32767. `tools/test_danmaku_capacity.py`,
  `tools/test_storm_mix.py`, `tools/test_load10000_card.py`,
  `tools/sim_bucket_accel.ps1 -Load20000`.

`sdc/ti60_top.sdc` and `build_hw.bat` are unchanged. `core_clk` stays 10.00 ns.

## Firmware image

The on-chip image must end at or below `0xF900FD00` (64 KiB RAM, 768-byte
stack). Ubuntu `gcc-riscv64-unknown-elf` 13.2.0 emits about 1.7 KiB more than
the laptop compiler that last linked this tree: HEAD itself overflows by 1696
bytes on 13.2, and this tree without a flag change overflows by 1552 (the
storm edit is 144 bytes smaller than HEAD on the same compiler).

`sw/build_firmware.py` now passes `-msave-restore` (libgcc prologue/epilogue
calls). Nothing in the image is an interrupt handler. On 13.2 the linked image
ends at `0xF900FA60` (**64096 bytes, 672 bytes of margin** under `0xF900FD00`).
The same flag shrinks an xPack build as well. `build_firmware.py` still does
not pin a GCC version.

## What this VM ran

Icarus Verilog 12, RISC-V GCC 13.2.0 (`-march=rv32im -mabi=ilp32 -Oz -flto
-msave-restore`).

Passed:

- Bucket direct suite (6144 pool, includes fault/snapshot): `ALL BUCKET AXI TESTS PASSED`
- Bucket 10000 suite, including the stacked-4000 drop count of 5952
- Bucket 20000 direct and through `Axi_Mux` (numbers above)
- Board contention and bus-loaded 1300 (see above). Bus-loaded 8000 still trips the coprocessor's own 4,000,000-cycle fault timer (this tree faults at 4,020,076 cycles; HEAD faults at 4,035,841). That limit is unchanged.
- Bullet scanline: 49,504 pixels, 1024 overlapping entries, 27 kinds, masks
- Frame publish, framebuffer abort, gearbox, BGM SPI/PCM/I2S, audio APB, scanline prefetch
- FX ring (28112 pixels), I2C gamepad, compositor alignment (384 pixels)
- `tools/test_danmaku_capacity.py` (peak group 727, population 20064), `tools/test_storm_mix.py` (51 cases)
- The spell-card plate check in `tools/test_load10000_card.py` scores 0.698 on this tree and on HEAD (the card scores 0.697). The restore gate is 0.69, the same bar as the card, which still rejects a wrong plate (score 0).
- `tools/check_ddr_layout.py`, `tools/check_hud_layout.py`
- `tests/audio_flash_host.c`
- Workbench stage progression, after the campaign `pool_clear` split: caps
  atk 4 / weapon level 4, boss entered, 5 pattern changes.

Two workbench scenarios fail the same way on HEAD firmware built with
`-msave-restore`, so they are not regressions from the 20000-bullet pool.
`hitsweep` finds 0 shockwave pixels on the 24-pixel ring (the RTL FX-ring
bench still matches 28112 pixels; the pure-Python VM does not paint that
ring into the framebuffer the scenario samples). `bossopener` reports that
the framebuffer sample across the spell-card hold matches the pre-hold
frame. On HEAD the card plate itself scores 95% `CARD_BG` during that hold.
The shake lives in the scanout weather word (`stage_strip_render`), not in
the framebuffer rows the scenario compares, and the entrance has already
swapped the plate in before the hold is sampled.

## Only the laptop Efinity run can confirm

- `build_hw.bat` (Efinity **2026.1.132**, the flow `build_hw.bat` already
  looks for). This VM has no Efinity installation.
- Place and timing. The last bitstream of this tree, before this change
  (`docs/recovery_evidence/ti60_top.place.txt`, 25 Oct 2026): XLR 51303/60800
  (84.38%), memory blocks **256/256**, DSP 66/160. Setup slack was +1.336 ns
  on `core_clk` and +2.140 ns on `hdmi_tx_slow_clk`. This change adds no RAM.
  The burst path is a 2:1 mux onto the capture registers that were already
  there, plus `awlen`/`wlast` and two states. That is hundreds of XLRs, not a
  new memory. About 9,500 XLRs were free. Expect the design to still fit;
  only place-and-route proves it.
- The DDR3 controller accepting write bursts. Reads already go out with
  `arlen = 15`. The write guard and the AXI mux forward `awlen`, and both
  contention benches pass, but they are not the Efinix PHY.
- BitBlt's own suite (`tools/sim_bitblt.ps1`) needs
  `D:\Efinix\efinity\2026.1\sim_models`. Verilator benches (scanout, vdma
  bucket, video beam) need the portable Verilator tree under
  `tools/rtl_runtime/`, which is not in this VM.
- `tests/audio_stream_host.c` does not compile against the current
  flash-based `audio_stream.c` (it still names the old UART upload symbols).
  That mismatch predates this change. `audio_flash_host.c` does pass.
