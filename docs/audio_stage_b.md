# Stage B: CPU-fed DDR PCM

Date: 2026-10-12 (Asia/Shanghai)

## Data Path

Host UART -> bounded firmware packet parser -> CPU-owned DDR PCM store ->
CPU APB writes -> 2048-byte synchronous FIFO -> 12 kHz PCM hold -> existing
48.828125 kHz mixer and I2S transmitter.

There is no new AXI master or CDC. Firmware services audio once per main
loop pass. Each service copies at most 512 bytes from DDR to the FIFO and
reads at most 128 UART bytes. It never waits for another incoming byte or
for TX space. A full FIFO is never overwritten; playback starts/restarts
only at 1024 queued bytes. Starvation outputs silence and increments a
saturating underflow counter once per starvation episode.

The buffer stores 170.67 ms of PCM; startup watermark is 85.33 ms. The
software must average at least 23.44 service calls/s to keep up with 12 kB/s.
At 75 FPS the expected demand is 160 bytes/frame. These are budgets, not
measured game performance guarantees.

PCM is unsigned 8-bit mono, 12000 Hz. Conversion and mixing retain Stage A's
gain: `(byte - 128) * 64`, signed 16-bit PCM, sign-extended 18-bit mix. Both
the BGM-enable bit and menu master volume still affect the output. Muting
does not stop FIFO consumption. Before upload, BGM is silent and SFX work.

## Registers And Memory

All offsets are relative to APB base `0xF8100000`. The original graphics
page now explicitly decodes page zero, preventing the audio page from
aliasing graphics registers.

| Offset | Access | Meaning |
| --- | --- | --- |
| 0x100 | RW | bit 0 run; writing bit 1 clears FIFO, flags, and counters |
| 0x104 | W | enqueue low 8 bits, one byte per completed APB transfer |
| 0x108 | R | bits 11:0 level; bit 16 playing; bit 17 overflow; bit 18 underflow seen |
| 0x10C | R | starvation episode count |
| 0x110 | R | source samples consumed |

`MM_BGM_PCM = 0x05000000`, capacity `0x00800000`, exclusive end
`0x05800000`. The region is registered in `memory_map.h` and checked by
`tools/check_ddr_layout.py`. Only the CPU writes and reads it, so no new
CPU/device cache-ownership transition is introduced.

The FIFO reuses the two memory blocks that held Stage A's probe. To fit
the loader in firmware BRAM, the 760-byte font is packed at asset-ROM
offset `0x3C00`, within the existing 16 KiB allocation. Font bytes remain
defined by `visual_assets.c`; `build_asset_rom.py` packs them alongside the
unchanged background RLE. The boot atlas builder reads the font over the
existing APB asset window. Rendering continues to use the same DDR atlas.
UART decimal formatting uses the existing RV32IM hardware divider and
shared output helpers. No stack reservation or gameplay feature is removed.

## Upload Protocol

Serial configuration: existing UART0, 115200 baud, 8N1. Local BSP
`embedded_sw/soc/software/standalone/driver/uart.h` defines RX occupancy
in status bits 31:24 and TX free space in bits 23:16.

Packets are 76 bytes, fitting the 128-byte RX FIFO:

| Bytes | Meaning |
| --- | --- |
| 0..3 | ASCII BGM2 |
| 4..7 | little-endian offset or command |
| 8..71 | 64-byte payload |
| 72..75 | standard CRC-32 of bytes 0..71 |

- BEGIN (`0xFFFFFFFF`): payload starts with total length and whole-track
  CRC-32. Length must be a nonzero multiple of 64, at most 8 MiB. Clears
  old playback and accepts a new transfer.
- Data: offset must match loaded bytes; exactly the most recent block may
  be retransmitted without double-writing or changing the running CRC.
- FINISH (`0xFFFFFFFE`): requires full length and whole-track CRC match.
  Repeated FINISH is idempotent and does not restart playback.
- QUERY (`0xFFFFFFFD`): reports progress/playback. Optional nonzero length
  plus CRC payload validates track identity for resume.

Partial frames expire after 0.5 seconds using the existing APB second-tick
counter with wrap handling. The host waits for one response per packet;
this bounds RX occupancy even while gameplay is running. CRC failure,
sequence/bounds failure, and incomplete/bad final CRC have error codes
1, 2, and 3, respectively. A new BEGIN explicitly discards an old upload.

Replies are 32 bytes: ASCII BGA2, echoed command/offset, loaded bytes,
total length with ready in bit 31, FIFO status with error in bits 31:28,
underflows, played samples, then CRC-32 of the first 28 bytes. The host
filters these framed responses out of the existing ASCII diagnostic log.
Acknowledgement writes require room for all 32 bytes and defer otherwise.

The menu footer shows BGM WAITING, BGM LOADING, or BGM READY. READY means
the uploaded bytes passed CRC, not that audio output has been heard.

## Commands

```powershell
./tools/sim_bgm_stage_b.ps1
cmd /c build_hw.bat

# Initial stage-B test: source seconds 30..38, then loop.
python tools/upload_bgm.py --port COM10 --input assets/audio/bgm/cinderella_cage_12k_u8.pcm --start-seconds 30 --seconds 8 --observe 10 --log work_sim/bgm_stage_b_board.json

# Query without changing playback.
python tools/upload_bgm.py --port COM10 --status --observe 10

# Resume the same file/clip after a host interruption (board must remain on).
python tools/upload_bgm.py --port COM10 --input assets/audio/bgm/cinderella_cage_12k_u8.pcm --start-seconds 30 --seconds 8 --resume
```

Omitting `--seconds` uploads the remainder of the input. Uploads are a
development tool; DDR content is volatile and must be reloaded after FPGA
configuration/power loss. At one 64-byte packet per 75 Hz frame, a complete
4.35 MB song takes about 15 minutes. Firmware keeps drawing during upload.
The raw music and generated audio remain local, Git-ignored assets.

## Verification And Limits

RTL tests cover FIFO order/sign, pointer wrap, simultaneous input/output,
full rejection, underflow/recovery, watermarks, clear, APB page isolation,
one-write strobes, and all font bytes through the real APB/ROM logic.
Native C tests run the actual firmware parser with mocked MMIO and Python
zlib as CRC reference: corruption, bounds, ordering, duplicates, premature
finish, whole-track CRC, feed order/wrap, TX backpressure, partial timeout,
timer wrap, and resume identity. Stage A PCM/mix and I2S tests also run.

The original single-voice SFX scheduler is still unchanged; its shot/Boss
preemption and coincident-event loss remain separate follow-up work.
Playback counters alone cannot verify song identity or speaker output.

The known-good Stage A bitstream is saved in
`backups/bgm_stage_b_20261012_191109/`. The user confirmed Stage A at
900+ sprites, approximately 75 FPS, with normal picture and sound.
