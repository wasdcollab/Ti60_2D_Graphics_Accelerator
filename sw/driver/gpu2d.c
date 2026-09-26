/**
 * @file gpu2d.c
 * @brief 2D Graphics Accelerator (BitBlt) Driver Implementation
 * @version 2.0
 * @date 2026-09-10
 */

#include "gpu2d.h"

void gpu2d_init(void) {
    GPU2D_REG_OP_TYPE    = (uint32_t)GPU2D_OP_FILL;
    GPU2D_REG_SRC_STRIDE = SCREEN_STRIDE;
    GPU2D_REG_DST_STRIDE = SCREEN_STRIDE;
    GPU2D_REG_COLORKEY      = 0x00FF00FFu; /* pure magenta sprite background */
    GPU2D_REG_COLORKEY_CTRL = 1u;
    GPU2D_REG_COLOR_MATRIX  = 0u;
    GPU2D_REG_BLOOM_CTRL    = 0u;
    /* The scanout bases already power up at FB_*_FRONT; publishing them here
     * would be a redundant (and, on a live scanout, self-defeating) flip. */
}

/* See gpu2d.h.  NULL unless the application installs one; a single pointer
 * test in front of a loop that is already spinning over APB. */
void (*gpu2d_idle_hook)(void);

/* See gpu2d.h.  Accumulated, never cleared here: the application owns the
 * window.  Two extra APB reads per call against a spin that is already polling
 * APB every iteration - and the frame issues a few hundred commands, so it is
 * under 0.2% of the frame it measures. */
uint32_t gpu2d_wait_cyc;

void gpu2d_wait_idle(void) {
    uint32_t t0 = GPU2D_REG_CORE_TICKS;
    if (gpu2d_idle_hook) {
        while (GPU2D_REG_STATUS & GPU2D_STATUS_BUSY_MASK) {
            gpu2d_idle_hook();
        }
    } else {
        while (GPU2D_REG_STATUS & GPU2D_STATUS_BUSY_MASK) {
            // Spin wait until hardware completes
        }
    }
    uint32_t t1 = GPU2D_REG_CORE_TICKS;
    gpu2d_wait_cyc += (t1 >= t0) ? (t1 - t0) : (t1 + (100000000u - t0));
}

void gpu2d_finish(void) {
    /* Issue the command that has been queued in the registers, then wait.
     *
     * bitblt_apb_regs latches START only while (!cmd_busy && !cmd_start), so
     * the engine has to be idle before the launch.  Driver callers therefore
     * fill the registers with the writes of any operation and only pay one
     * spin here - which replaces the gpu2d_wait_idle() that used to sit in
     * front of every single fill/copy command.  A 650-object benchmark frame
     * is ~700 commands, so this removes ~700 APB status polls and the
     * engine-idle bubble in front of each of them. */
    gpu2d_wait_idle();
    GPU2D_REG_START = 1;
}

void gpu2d_fill(uint32_t dst_addr, uint32_t w, uint32_t h, uint32_t color, uint32_t dst_stride) {
    if (w == 0 || h == 0) return;

    GPU2D_REG_OP_TYPE    = (uint32_t)GPU2D_OP_FILL;
    GPU2D_REG_DST_ADDR   = dst_addr;
    GPU2D_REG_RECT_W     = w;
    GPU2D_REG_RECT_H     = h;
    GPU2D_REG_COLOR      = color;
    GPU2D_REG_DST_STRIDE = dst_stride;
    
    gpu2d_finish();
}

void gpu2d_copy(uint32_t dst_addr, uint32_t src_addr, uint32_t w, uint32_t h, 
                uint32_t src_stride, uint32_t dst_stride) {
    if (w == 0 || h == 0) return;

    GPU2D_REG_OP_TYPE    = (uint32_t)GPU2D_OP_COPY;
    GPU2D_REG_DST_ADDR   = dst_addr;
    GPU2D_REG_SRC_ADDR   = src_addr;
    GPU2D_REG_RECT_W     = w;
    GPU2D_REG_RECT_H     = h;
    GPU2D_REG_SRC_STRIDE = src_stride;
    GPU2D_REG_DST_STRIDE = dst_stride;
    
    gpu2d_finish();
}

void gpu2d_add(uint32_t dst_addr, uint32_t src_addr, uint32_t w, uint32_t h,
               uint32_t src_stride, uint32_t dst_stride) {
    if (w == 0 || h == 0) return;

    GPU2D_REG_OP_TYPE    = (uint32_t)GPU2D_OP_ADD;
    GPU2D_REG_DST_ADDR   = dst_addr;
    GPU2D_REG_SRC_ADDR   = src_addr;
    GPU2D_REG_RECT_W     = w;
    GPU2D_REG_RECT_H     = h;
    GPU2D_REG_SRC_STRIDE = src_stride;
    GPU2D_REG_DST_STRIDE = dst_stride;

    gpu2d_finish();
}

void gpu2d_set_color_matrix(uint8_t mode, uint8_t intensity) {
    GPU2D_REG_COLOR_MATRIX = ((uint32_t)intensity << 8) | ((uint32_t)mode & 0x0Fu);
}

void gpu2d_set_bloom(uint8_t enable, uint8_t threshold, uint8_t intensity) {
    GPU2D_REG_BLOOM_CTRL = ((uint32_t)intensity << 16) | ((uint32_t)threshold << 8) | (enable ? 1u : 0u);
}

void gpu2d_wait_vsync(void) {
    // Read sticky VSync flag from APB (reading automatically clears it)
    while (!(GPU2D_REG_VSYNC_STS & 0x01)) {
        // Spin wait for 60Hz frame blanking tick
    }
}

void gpu2d_swap_buffers(uint32_t left_buf, uint32_t right_buf) {
    // Write published next frame bases to APB
    GPU2D_REG_LEFT_NEXT  = left_buf;
    GPU2D_REG_RIGHT_NEXT = right_buf;
}

void gpu2d_get_fps(uint8_t *out_cpu_fps, uint8_t *out_fpga_fps) {
    uint32_t bcd = GPU2D_REG_FPS_BCD;
    if (out_cpu_fps) {
        uint8_t raw = (uint8_t)(bcd & 0xFF);
        *out_cpu_fps = ((raw >> 4) * 10) + (raw & 0x0F);
    }
    if (out_fpga_fps) {
        uint8_t raw = (uint8_t)((bcd >> 8) & 0xFF);
        *out_fpga_fps = ((raw >> 4) * 10) + (raw & 0x0F);
    }
}

uint32_t gpu2d_asset_copy(uint32_t dst_addr, uint32_t nbytes)
{
    volatile uint8_t *dst = (volatile uint8_t *)dst_addr;
    uint32_t i;

    /* Byte at a time, deliberately: the ROM read is synchronous and pipelined
     * one clock behind the address, and the two APB transactions between two
     * consecutive bytes are far longer than that clock, so no explicit delay is
     * needed and no alignment assumption has to hold.  The plate stream lengths
     * (4,588 / 3,842 / 3,883) are not multiples of four anyway, so a word-packing
     * version would need tail handling for no measurable gain: this runs once,
     * at boot, for about 1.5 ms.
     *
     * The DDR writes go through the D-cache and are still visible to this CPU
     * (same core, same cache), so the decoder that reads them immediately
     * afterwards sees them without an intervening flush. */
    for (i = 0u; i < nbytes; i++) {
        GPU2D_REG_ASSET_ADDR = i;
        dst[i] = (uint8_t)(GPU2D_REG_ASSET_DATA & 0xFFu);
    }
    return i;
}

void gpu2d_flush_dcache(void) {
    /* Sapphire cache maintenance: write back / invalidate the D-cache and
     * drain the CPU write buffer, then touch a known-mapped DDR location so
     * the drain is guaranteed to have completed.  Same two-step sequence the
     * proven hand-written firmware used. */
    __asm__ volatile (".word 0x0000500F" ::: "memory");
    (void)*(volatile uint32_t *)GPU2D_ENTITY_BASE;
    __asm__ volatile ("" ::: "memory");
}

void gpu2d_blit_sprite(uint32_t dst_addr, uint32_t src_addr, uint32_t w,
                       uint32_t h, uint32_t src_stride, uint32_t dst_stride) {
    gpu2d_copy(dst_addr, src_addr, w, h, src_stride, dst_stride);
}

uint32_t gpu2d_last_error(void) {
    return GPU2D_REG_STATUS & (GPU2D_STATUS_CFGERR | GPU2D_STATUS_TIMEOUT);
}

void gpu2d_set_colorkey(uint32_t enable, uint32_t transparent_color) {
    gpu2d_wait_idle();
    GPU2D_REG_COLORKEY = transparent_color;
    GPU2D_REG_COLORKEY_CTRL = enable ? 1u : 0u;
}

void gpu2d_set_alpha(uint32_t enable, uint32_t global_alpha) {
    gpu2d_wait_idle();
    GPU2D_REG_GLOBAL_ALPHA = global_alpha & 0xFFu;
    GPU2D_REG_ALPHA_CTRL   = enable ? 1u : 0u;
}

void gpu2d_alpha_blit(uint32_t dst_addr, uint32_t src_addr, uint32_t w,
                      uint32_t h, uint32_t src_stride, uint32_t dst_stride) {
    if (w == 0 || h == 0) return;

    GPU2D_REG_OP_TYPE    = (uint32_t)GPU2D_OP_ALPHA;
    GPU2D_REG_DST_ADDR   = dst_addr;
    GPU2D_REG_SRC_ADDR   = src_addr;
    GPU2D_REG_RECT_W     = w;
    GPU2D_REG_RECT_H     = h;
    GPU2D_REG_SRC_STRIDE = src_stride;
    GPU2D_REG_DST_STRIDE = dst_stride;

    gpu2d_finish();
}
