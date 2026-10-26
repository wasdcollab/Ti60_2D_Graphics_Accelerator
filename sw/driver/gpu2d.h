/**
 * @file gpu2d.h
 * @brief 2D Graphics Accelerator (BitBlt) Driver Header for Sapphire RISC-V SoC
 * @version 4.0
 * @date 2026-10-09
 *
 * Triad Architecture Role: "Pure 2D GPU Engine Driver" (rtl/bitblt/)
 * Dedicated MMIO interface for 2D hardware rasterization (FILL, COPY, ALPHA, ADD).
 *
 * NOTE: Display engine and streaming layer controls (weather, lasers, beam,
 * bloom filter, color matrix) have been cleanly decoupled into "display.h".
 */

#ifndef GPU2D_H
#define GPU2D_H

#include <stdint.h>
#include "display.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Base address of the BitBlt APB3 peripheral (SoC APB slave 0) */
#define GPU2D_BASE_ADDR         0xF8100000UL
#define GPU2D_REG_BUCKET_ACCEL  (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x120))
/* Enemy-bullet count is 15 bits on APB 0x120. [28:16] holds count[12:0] and
 * [15:14] holds count[14:13]. Bit 31 is start, bit 30 clears the ledger,
 * bit 29 is motion, [13:4] is the player-bullet count, bit 0 selects the buffer. */
#define GPU2D_BUCKET_EB(n) ((((uint32_t)(n) & 0x1FFFu) << 16) | (((uint32_t)(n) & 0x6000u) << 1))
#define GPU2D_REG_BUCKET_CFG    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x124))
#define GPU2D_REG_BUCKET_INFO   (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x128))
#define GPU2D_REG_BUCKET_CYCLES (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x12C))
#define GPU2D_REG_BUCKET_DEBUG  (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x138))
#define GPU2D_REG_HEARTBEAT     (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x130))
extern uint32_t gpu2d_stalled;

/* APB3 register offsets */
#define GPU2D_REG_STATUS        (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x00))
#define GPU2D_REG_DST_ADDR      (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x04))
#define GPU2D_REG_RECT_W        (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x08))
#define GPU2D_REG_RECT_H        (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x0C))
#define GPU2D_REG_COLOR         (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x10))
#define GPU2D_REG_START         (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x14))
#define GPU2D_REG_OP_TYPE       (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x18))
#define GPU2D_REG_SRC_ADDR      (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x1C))
#define GPU2D_REG_LEFT_NEXT     (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x20))
#define GPU2D_REG_VSYNC_STS     (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x24))
#define GPU2D_REG_LEFT_ACTIVE   (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x28))
#define GPU2D_REG_RIGHT_ACTIVE  (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x2C))
#define GPU2D_REG_SRC_STRIDE    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x30))
#define GPU2D_REG_FPS_BCD       (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x34))
#define GPU2D_REG_CPU_FRAMES    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x38))
#define GPU2D_REG_FPGA_FRAMES   (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x3C))
#define GPU2D_REG_RIGHT_NEXT    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x40))
#define GPU2D_REG_FRAME_NEXT    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x134))
#define GPU2D_REG_DIAGNOSTICS   (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x44))
#define GPU2D_REG_DST_STRIDE    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x48))
#define GPU2D_REG_COLORKEY      (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x60))
#define GPU2D_REG_COLORKEY_CTRL (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x64))
#define GPU2D_REG_ALPHA_CTRL    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x68))
#define GPU2D_REG_GLOBAL_ALPHA  (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x6C))
#define GPU2D_REG_CORE_TICKS    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x70))

/**
 * @brief LIVE ENGINE PROBE -- read-only diagnostic, added 2026-09-23.
 *
 * APB 0x74, packed as {20'd0, sg_state[1:0], 4'd0, ar_pend, q_cnt}:
 *
 *     [3:0]   rd_q_cnt   read master request-queue occupancy (0..4)
 *     [4]     ar_pend    a request is staged on the AR channel
 *     [11:8]  sg_state   stride_gen state (0 = idle, 2 = S_LOOP)
 *
 * Normal idle reading is 0x0000.  The failure this exists to catch is a read
 * burst that the stride generator stopped counting but the master still holds:
 * once that happens the master's queue can never drain - it is cleared only by
 * reset - and every later COPY/ALPHA command stalls until the engine watchdog
 * fires.  FILL commands keep working, because they never touch the read path,
 * which is exactly why the board shows "fills are fine, sprites are dead".
 *
 * Read this while the engine reports BUSY and stuck: a non-zero q_cnt with an
 * idle stride_gen is the stranded-burst signature.
 */
#define GPU2D_REG_ENGINE_PROBE    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x74))

/**
 * @brief Weather overlay control (hardware-synthesised particles, 2026-09-24).
 *
 * The scanout draws the snow / ash / mote layer itself from a hardware copy of
 * the firmware's 170-dot xorshift table, so the firmware no longer paints it
 * into the framebuffer.  Write per frame:
 *
 *     [15]    enable
 *     [14:13] stage  0 ice, 1 lava, 2 dream, 3 card -> ice colours
 *     [12:8]  scroll phase 0..31, already direction-adjusted
 *     [7:0]   slide  whole-layer vertical offset (boss shake), 0 or 8
 */
#define GPU2D_REG_WEATHER         (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x78))

/**
 * @brief Weather occlusion box (Phase 2 task 04).
 *
 * The weather layer is composited by the scanout ABOVE the framebuffer, so the
 * pause card - which is nothing but pixels in the framebuffer - sits UNDER the
 * snow, and its lettering ends up behind falling flakes.  Switching the whole
 * layer off while paused clears the text and empties the sky with it, which is
 * not what a frozen battlefield should look like.  These two words instead name
 * the rectangle the scanline logic must leave alone (rtl/v_dma/video_weather.v):
 *
 *     0x8C  MASK_X: [10:0] x0, [21:11] x1, [31] enable   (0 = no box)
 *     0xAC  MASK_Y: [10:0] y0, [21:11] y1
 *
 * The box is inclusive on all four edges, and only the part of it that lies in
 * the playfield band matters - outside that band the layer draws nothing anyway.
 * Write MASK_Y first and MASK_X last: the enable rides on MASK_X, so a box is
 * never live with half a rectangle in it, and clearing the box is that one write.
 *
 * Both are readable at the same addresses.  The scanout consumes them in another
 * clock domain, so "the firmware wrote it" and "the scanline logic has it" are
 * two different claims - the read-back is what settles the second one.
 */
#define GPU2D_REG_WEATHER_MASK_X  (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x8C))
#define GPU2D_REG_WEATHER_MASK_Y  (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xAC))

/**
 * @brief Laser column centres (Phase 2 task 02 follow-up).
 *
 * The scanout draws the boss's four laser columns itself (rtl/v_dma/video_laser.v)
 * - four 16x768 bars are 3,072 DRAM row activations a frame, which is where the
 * spell card used to lose its frame time.  The hardware knows the shape; what it
 * cannot know is WHERE the columns stand, so the firmware writes the four centres:
 *
 *     0xB0  columns 0 and 1   {8'd0, x1[11:0], x0[11:0]}
 *     0xB4  columns 2 and 3   {8'd0, x3[11:0], x2[11:0]}
 *
 * The opener parks them at its fixed four; the cut/beam lasers move three of them
 * wherever the boss aims.  A centre of 0 parks that column off screen (the
 * playfield starts at x = 181), which is how three beams are stood up where the
 * opener had four.  Both words land on the scanline logic at the same frame edge
 * the weather control word does, so a column can never appear at the previous
 * frame's x.
 */
#define GPU2D_REG_LASER_COLX_LO   (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xB0))
#define GPU2D_REG_LASER_COLX_HI   (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xB4))

/**
 * @brief Player beam and cut/beam warning hairlines (A3, rtl/v_dma/video_beam.v).
 *
 * These were the last two shapes in the picture that were one DRAM row
 * activation per scanline of something with no information in it: the craft's
 * beam is a 16-wide sheet that repeats every 16 rows, and a warning hairline is
 * one solid colour from top to bottom.  A one-pixel column opens a DRAM row and
 * writes four bytes; three slots of hairlines is 4,608 of them in a frame,
 * which is a third of what a saturated pressure stage spends.
 *
 * The scanout draws both now, so neither owns a framebuffer pixel: nothing to
 * erase next frame and no damage-ledger entry to pay for.  What the hardware
 * cannot know is where they stand and what colour they are, so:
 *
 *     0xB8  beam_x      [11:0] centre column of the craft's beam
 *     0xBC  beam_ctrl   [10:0] height, [11] enable
 *
 * The height is the CRAFT'S TOP EDGE, not its centre.  The craft is drawn into
 * the framebuffer and this layer is composited above the framebuffer, so
 * anything this beam covers, it hides - and it used to run all the way down to
 * player_y, i.e. through the top half of the sprite it was fired from.  The
 * firmware now publishes player_y - PLAYER_HALF_H, so the beam's exclusive end
 * (video_beam.v tests y < height) lands on the craft's first row and the
 * artwork keeps the pixels it owns.  The field is 11 bits and the screen is
 * 768 rows, so nothing about the encoding changed.
 *
 *     0xC0 + 16k +  0   hair_x   [11:0] centre column of slot k (0 = off)
 *     0xC0 + 16k +  4   hair_out [23:0] colour of columns hx-2 and hx+1
 *     0xC0 + 16k +  8   hair_lft [23:0] colour of column hx-1
 *     0xC0 + 16k + 12   hair_mid [23:0] colour of column hx
 *
 * k = 0..2.  A colour of 0 draws nothing, which is how a slot that is not
 * standing is taken off the screen - so all three slots are written every
 * frame, including the dead ones, for the same reason the laser columns are.
 *
 * The beam is opaque and sits above the laser columns; both are latched by the
 * scanout on the same frame edge as the weather control word.
 */
#define GPU2D_REG_BEAM_X          (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xB8))
#define GPU2D_REG_BEAM_CTRL       (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xBC))
/**
 * @brief B1: the bullet bucket table and the scanout's tile store.
 *
 * The scene's bullets are no longer blitted into the framebuffer.  The firmware
 * appends one entry per (bullet, scanline it covers) to a per-scanline bucket in
 * DDR, and the scanout composites them on the way past.  The framebuffer never
 * sees a bullet, so the backdrop repair has nothing to put back - which is the
 * expensive half of the old cost.
 *
 *     0xF0  bucket_base  [27:0]  MM_BUCKET_TABLE
 *     0xF4  tile_addr    [13:0]  tile store write pointer (16 KB: one byte a
 *                                 pixel, and the enemy tile is 26x26 now)
 *     0xF8  tile_data    [7:0]   byte; the pointer advances by one
 *     0xFC  pal_data     [31:0]  palette entry {alpha, rgb}; advances too
 *
 * The tile store holds one byte per pixel: a shape ROLE, 0 = transparent.  The
 * scanout forms the palette index itself as role + hue*32, which is why one
 * tile now serves all eight colours.
 * The engine's tiles use 159 colours for the enemy set and 40 for the player
 * set, so a 256-entry palette covers both.  At the framebuffer's own packing
 * those tiles are 110.5 KB - more than the whole free block RAM budget; indexed
 * they are 30.3 KB, which fits the 32 KB a power-of-two depth costs.
 */
#define GPU2D_REG_BUCKET_BASE     (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xF0))
#define GPU2D_REG_BTILE_ADDR      (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xF4))
#define GPU2D_REG_BTILE_DATA      (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xF8))
#define GPU2D_REG_BPAL_DATA       (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xFC))

/* Procedural impact rings: APB bank 2, four slots at a 16-byte stride.
 *   word 0: {en[31], add[30], r_out[29:21], cy[20:11], cx[10:0]}
 *   word 1: {15'd0, r_in[24:16], alpha[7:0]}
 *   word 2: {8'd0, rgb[23:0]}
 * The scanout computes the circle from the pixel position, so a ring costs no
 * DDR traffic, no BitBlt command and no damage-repair rectangle - see
 * rtl/display_engine/2_layer_generators/video_fx_ring.v.  `add` uses the
 * saturated-add path and ignores `alpha`; clear it for a blended ring. */
#define GPU2D_REG_FX_RING(slot, word) \
    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x200u + \
                            ((uint32_t)(slot) << 4) + ((uint32_t)(word) << 2)))

/* Slot 0 of the hair group, i.e. the offset GPU2D_REG_HAIR(k, f) is built on
 * (0xC0 + 16k + 4f).  It used to read 0xB0, which is LASER_COLX_LO: a useful
 * base for nothing.  Nothing reads this name today, and it is a plain offset
 * rather than the pointer macro its neighbours are - never dereference it. */
#define GPU2D_REG_HAIR_BASE       0xC0u
#define GPU2D_REG_HAIR(k, f)      \
    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xC0u + 16u * (uint32_t)(k) + 4u * (uint32_t)(f)))

#define GPU2D_REG_COLOR_MATRIX    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x7C))
#define GPU2D_REG_BLOOM_CTRL      (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x88))

/**
 * @brief Stall snapshot (read-only, added 2026-09-25).
 *
 * The engine keeps the worst command it has ever run: a command whose
 * START->DONE time exceeds 1 ms is captured with its op, size, addresses and
 * the live probe state taken the moment it finished.  Reading it needs no
 * board probe and no extra wiring, and it separates one stalled command
 * from every command being slow - the question the UART line cannot answer.
 */
#define GPU2D_REG_SNP_WORST_CYC     (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x90))
#define GPU2D_REG_SNP_COUNT         (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x94))
#define GPU2D_REG_SNP_OP            (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x98))
#define GPU2D_REG_SNP_WH            (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x9C))
#define GPU2D_REG_SNP_SRC           (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xA0))
#define GPU2D_REG_SNP_DST           (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xA4))
#define GPU2D_REG_SNP_PROBE         (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0xA8))

/**
 * @brief Asset ROM window (APB 0x80 / 0x84).
 *
 * The three stage backdrops are 12,313 bytes of run-length data that ship
 * inside the BITSTREAM rather than in the CPU's 64 KiB on-chip RAM.  DDR is
 * volatile, so the bitstream is the only non-volatile place the CPU can read;
 * the ROM is fetched two APB accesses per byte - write the index, read the
 * byte.  See gpu2d_asset_copy() and rtl/bitblt/bitblt_asset_rom.v.
 */
#define GPU2D_REG_ASSET_ADDR (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x80))
#define GPU2D_REG_ASSET_DATA (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x84))

/**
 * @brief Copy @p nbytes of the asset ROM to DDR starting at @p dst_addr.
 *
 * One APB write plus one APB read per byte; a boot-time operation, and the
 * price of not carrying the plate data in the firmware image any more.
 *
 * @return the number of bytes copied.
 */
uint32_t gpu2d_asset_copy(uint32_t dst_addr, uint32_t nbytes);

/* Status register bits */
#define GPU2D_STATUS_BUSY_MASK  0x01u
#define GPU2D_STATUS_DONE_MASK  0x02u
#define GPU2D_STATUS_CFGERR     0x04u   /* registered illegal-command flag */
#define GPU2D_STATUS_TIMEOUT    0x08u   /* engine watchdog fired          */

/* Operation types */
typedef enum {
    GPU2D_OP_FILL  = 0,  /**< Solid color rectangle fill                    */
    GPU2D_OP_COPY  = 1,  /**< Memory-to-memory 2D block copy                */
    GPU2D_OP_ALPHA = 2,  /**< ARGB8888 blend against the live background    */
    GPU2D_OP_ADD   = 3   /**< Saturated add: min(255, Dst + Src) (Scheme A) */
} gpu2d_op_t;

/* Video color matrix preset modes (Phase 1 Task 03) */
typedef enum {
    COLOR_MATRIX_BYPASS    = 0,
    COLOR_MATRIX_FLASH     = 1,
    COLOR_MATRIX_RED_PULSE = 2,
    COLOR_MATRIX_GRAYSCALE = 3,
    COLOR_MATRIX_INVERT    = 4,
    COLOR_MATRIX_GREEN     = 5,
    COLOR_MATRIX_ICE_BLUE  = 6
} color_matrix_mode_t;

/* Framebuffer configuration (1366x768 ARGB8888, double buffered) */
#define SCREEN_WIDTH            1366
#define SCREEN_HEIGHT           768
#define SCREEN_STRIDE           8192  /* 2^13.  1366*4 = 5464 is not a multiple of 16,
                                          * so the framebuffer needs padding anyway; picking a
                                          * power of two keeps y*SCREEN_STRIDE a single shift, which
                                          * is worth ~600 bytes of firmware over a 5472 pitch. */

#define FB_LEFT_FRONT           0x00800000UL
#define FB_LEFT_BACK            0x00E00000UL
#define FB_RIGHT_FRONT          0x00800000UL
#define FB_RIGHT_BACK           0x00E00000UL

/* DDR scratch areas -- the complete layout lives in memory_map.h so that the
 * firmware, the simulator and the test bench cannot drift apart. */
#include "memory_map.h"

#define GPU2D_ENTITY_BASE       MM_ENTITY_BASE
#define GPU2D_SPRITE_BASE       MM_BOSS_SPRITE
#define GPU2D_SPRITE_W          MM_BOSS_SPRITE_W
#define GPU2D_SPRITE_H          MM_BOSS_SPRITE_H
#define GPU2D_SPRITE_STRIDE     MM_BOSS_SPRITE_STRIDE
#define GPU2D_ALPHA_SPRITE_BASE MM_AURA_SPRITE
#define GPU2D_ALPHA_SPRITE_W    MM_AURA_SPRITE_W
#define GPU2D_ALPHA_SPRITE_H    MM_AURA_SPRITE_H

void gpu2d_init(void);
void gpu2d_wait_idle(void);

/**
 * @brief Optional hook the application installs while its own idle wait has
 *        something else to poll.
 *
 * gpu2d_wait_idle() spins until the BitBlt engine reports idle, and one
 * full-screen COPY can spin there for most of a display frame.  The boot menu
 * has to keep watching the handset through that spin - a press that opens and
 * closes inside one menu pass was otherwise never seen, which is what "press
 * Y, nothing moves, press it again" was.  While the hook is installed the spin
 * calls it on every iteration; everywhere else it is NULL and the loop is
 * exactly the plain spin it always was.
 */
extern void (*gpu2d_idle_hook)(void);

/**
 * @brief Cycles spent spinning inside gpu2d_wait_idle() since the last clear.
 *
 * The engine takes one command at a time - bitblt_apb_regs only latches START
 * while the engine is idle, so gpu2d_finish() waits before every launch - which
 * means the whole of the engine's serial time is spent in that spin, as the CPU
 * experienced it.  The firmware clears it at the top of a game frame and
 * publishes it at the end; nothing else touches it.  Comparing it against
 * game_frame()'s own total is what says whether the engine or the CPU owns the
 * frame.
 */
extern uint32_t gpu2d_wait_cyc;
void gpu2d_fill(uint32_t dst_addr, uint32_t w, uint32_t h, uint32_t color,
                uint32_t dst_stride);
void gpu2d_copy(uint32_t dst_addr, uint32_t src_addr, uint32_t w, uint32_t h,
                uint32_t src_stride, uint32_t dst_stride);
void gpu2d_add(uint32_t dst_addr, uint32_t src_addr, uint32_t w, uint32_t h,
               uint32_t src_stride, uint32_t dst_stride);
void gpu2d_set_color_matrix(uint8_t mode, uint8_t intensity);
void gpu2d_set_bloom(uint8_t enable, uint8_t threshold, uint8_t intensity);
void gpu2d_set_bloom_style(uint8_t style);
void gpu2d_wait_vsync(void);
void gpu2d_swap_buffers(uint32_t left_buf, uint32_t right_buf);
void gpu2d_get_fps(uint8_t *out_cpu_fps, uint8_t *out_fpga_fps);

/**
 * @brief Invalidate the soft core data cache and drain its write buffer.
 *
 * The framebuffer is written by the CPU (software rendering) and by the BitBlt
 * engine / video DMA (hardware), so every CPU-side DDR write must be pushed out
 * before hardware reads it.
 */
void gpu2d_flush_dcache(void);

/**
 * @brief Blit a pre-rendered sprite tile into a framebuffer (OP_COPY).
 */
void gpu2d_blit_sprite(uint32_t dst_addr, uint32_t src_addr, uint32_t w,
                       uint32_t h, uint32_t src_stride, uint32_t dst_stride);

/** Enable/disable transparent-color skipping for subsequent COPY commands. */
void gpu2d_set_colorkey(uint32_t enable, uint32_t transparent_color);

/**
 * @brief Blend an ARGB8888 sprite over the LIVE framebuffer (OP_ALPHA).
 *
 * The engine reads the current background back from DDR, blends it with the
 * source pixel and writes the result, per pixel:
 *
 *     out = (src * a + dst * (255 - a) + 127) / 255      (R, G and B)
 *
 * where a is the source alpha byte optionally scaled by the global alpha.  The
 * background alpha byte is passed through unchanged.  A source pixel equal to
 * the colour key is skipped entirely (nothing is written for that pixel), so
 * colour keying keeps priority over blending.  Both addresses must be 32-bit
 * pixel aligned and both strides multiples of 16 bytes, otherwise the command
 * is rejected with CFGERR and START does nothing.
 */
void gpu2d_alpha_blit(uint32_t dst_addr, uint32_t src_addr, uint32_t w,
                      uint32_t h, uint32_t src_stride, uint32_t dst_stride);

/**
 * @brief Configure hardware alpha blending.
 *
 * @param enable        1 enables OP_ALPHA commands (0 makes them a CFGERR).
 * @param global_alpha  8-bit opacity multiplier applied to every source alpha;
 *                      255 is the identity, 0 makes the sprite fully
 *                      transparent.
 */
void gpu2d_set_alpha(uint32_t enable, uint32_t global_alpha);

/**
 * @brief Non-zero when the hardware rejected the last command or the engine
 *        watchdog fired.  Cleared by the next START.
 */
uint32_t gpu2d_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* GPU2D_H */
