# BGM Stage A: local PCM probe

Date: 2026-10-12

## Scope

The default BGM source is now a 2048-byte, unsigned 8-bit PCM ROM. The
original procedural melody remains available with `PCM_BGM=0` on
`game_audio_synth`. No AXI master, DDR allocation, UART loader, firmware
polling, pin assignment, or clock constraint is added by this stage.

The starting implementation report used 253 of 256 memory blocks. This
probe therefore uses only 2 KiB, not the several-second clip suggested in
the handoff. At 12000 samples/s the loop lasts 0.170667 seconds. It is a
PCM-path test and is too short to establish recognizable full-song playback.

## Local Asset

Generate the probe from the existing private, 12 kHz mono unsigned PCM:

```powershell
python tools/build_bgm_stage_a.py --input assets/audio/bgm/cinderella_cage_12k_u8.pcm --start-seconds 30
```

For a source-independent public build, generate a 439.453125 Hz test tone:

```powershell
python tools/build_bgm_stage_a.py --test-tone
```

Run one of these before building. It creates
`assets/audio/generated/bgm_stage_a.hex`, a JSON provenance record, and a
WAV preview containing 24 repetitions of the actual loop. Generating the
test tone replaces the local probe; rerun the private-input command to
restore the music excerpt. Source and generated audio directories are
ignored by Git. No MP3 or music-derived PCM should be published.

The current private probe begins at source sample 360000, is normalized
to a peak of 96, and has 32-sample fades at the two loop boundaries.
Its unsigned PCM SHA-256 is
`12ec1367bc9e2380e5df9ba73595bcf371f2ca857a464e23fe89cc33f5901f83`.

## Clock And Fixed Point

All playback logic uses the existing 100 MHz `core_clk` and active-low
asynchronous reset. The ROM has a synchronous registered read without a
data-register reset, allowing Efinity block-ROM inference. The source
address is prefetched between audio frames; the existing I2S sample
enable is spaced 2048 core cycles apart.

| Signal | Representation / range | Operation |
| --- | --- | --- |
| ROM byte | unsigned offset binary, 0..255 | silence is 128 |
| PCM sample | signed 16-bit, -8192..8128 | subtract 128, multiply by 64 |
| Rate phase | 14-bit, 0..12499 | add 3072 per I2S sample, subtract 12500 on advance |
| Source rate | 12000 Hz | 48828.125 * 3072 / 12500 |
| BGM + SFX | signed 18-bit | explicit sign extension before addition |
| Maximum mix range | -24576..24384 | includes boosted signed 8-bit SFX |
| Output | signed 16-bit stereo | arithmetic shift by volume, no overflow in specified range |

Volume 0 and values 5..7 mute. Values 1..4 apply gains 1/8, 1/4, 1/2, 1.
Disabling audio or BGM resets the PCM cursor and phase; enabling restarts
the clip. BGM disable does not disable SFX. The APB register map is unchanged.

## Verification

```powershell
./tools/sim_bgm_stage_a.ps1
python tools/check_ddr_layout.py
cmd /c build_hw.bat
```

The new tests generate a public 2048-byte boundary-value fixture, then
check signed endpoints, exactly 3072 source advances in 12500 output
frames, full ROM wrap, disable/restart, reset, stereo mixing, all volume
values, and SFX contribution. The runner also executes the existing I2S
framing test. DDR layout must remain disjoint.

## Board Gate And Next Work

### Recorded Result

The full `build_hw.bat` run completed on 2026-10-12 at 19:05 (Asia/Shanghai):

- Firmware: 61879 bytes; linked code/data/BSS end at 0xF900FA08, with
  only 504 bytes remaining below the reserved stack boundary.
- Map, interface, PNR, PGM: PASS.
- Memory: 255 / 256 blocks; the new PCM instance accounts for 2 blocks.
- XLR: 52796 / 60800; DSP: 64 / 160.
- Minimum reported setup slack: +0.060 ns (sdram_clk).
- Minimum reported hold slack: +0.024 ns (sdram_clk).
- core_clk setup slack: +0.980 ns; HDMI slow-clock setup slack: +0.982 ns.
- Bitstream: `outflow/ti60_top.bit`, 3202641 bytes.
- Bitstream SHA-256:
  `2082db7b363c60780f83359c7d82aa9c60267ae0e65a0e54c55c747df4bc994f`.
- JTAG download completed successfully to device ID 0x10660A79.
- User confirmed: HDMI picture normal, background sound changed, menu
  volume effective. This is a user-observed board result, not inferred
  from the programmer exit status.
- 900+ sprite performance and uninterrupted playback under stress are
  still unverified. Full-track identity/playback is outside this probe.

Evidence: `work_sim/bgm_stage_a_build.log`, `outflow/ti60_top.timing.rpt`,
`outflow/ti60_top.hier_util.rpt`, and the two new self-checking testbenches.
These generated build files can be overwritten by subsequent builds.

Stage B must budget both memory and firmware: reuse the probe's 2 KiB
as writable ping-pong storage, and measure software size before adding
a loader. A large new FIFO or an unchecked blocking UART routine will
not fit the measured constraints.

Before moving to CPU-fed PCM buffering, verify on the new bitstream:

1. HDMI menu and game render normally.
2. The short repeating PCM probe replaces the old 16-step melody. Compare
   with the generated WAV; this stage is not a full musical loop.
3. Menu volume changes both PCM and SFX, including mute.
4. The 900+ sprite stress scene has no gray screen or new frame-rate loss.

The original single-voice SFX scheduler remains unchanged in this stage.
Inspection found two follow-up issues: all events restart the same voice,
and a simultaneous sample tick plus incoming event can clear the new event
when consuming an older pending event. High-rate shots can therefore
truncate other sounds. These need separate event-arbitration/voice tests
and a subsequent change after the PCM-only board comparison.

The baseline bitstream and timing/resource reports are saved locally in
`backups/bgm_stage_a_20261012_190037/` for recovery.
