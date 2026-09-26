/**
 * @file gpu2d.h
 * @brief 2D Graphics Accelerator (BitBlt) Driver Header for Sapphire RISC-V SoC
 * @version 3.0
 * @date 2026-09-15
 */

#ifndef GPU2D_H
#define GPU2D_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Base address of the BitBlt APB3 peripheral (SoC APB slave 0) */
#define GPU2D_BASE_ADDR         0xF8100000UL

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
