/**
 * @file display.h
 * @brief Streaming Display Engine Driver Header for Titanium Ti60 Accelerator
 * @version 1.0
 * @date 2026-10-09
 *
 * Triad Architecture Role: "Pure Streaming Display Engine Control" (rtl/display_engine/)
 * Dedicated MMIO interface for video stream composition, real-time layers,
 * and post-processing filters.
 */

#ifndef DISPLAY_H
#define DISPLAY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Base address of the APB3 Command Dispatcher (SoC APB slave 0) */
#ifndef DISPLAY_BASE_ADDR
#define DISPLAY_BASE_ADDR           0xF8100000UL
#endif

/* Display Engine & Post-Processing MMIO Registers (0x70 ~ 0xFC) */
#define DISPLAY_REG_CORE_TICKS      (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0x70))
#define DISPLAY_REG_WEATHER         (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0x78))
#define DISPLAY_REG_COLOR_MATRIX    (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0x7C))
#define DISPLAY_REG_ASSET_ADDR      (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0x80))
#define DISPLAY_REG_ASSET_DATA      (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0x84))
#define DISPLAY_REG_BLOOM_CTRL      (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0x88))
#define DISPLAY_REG_WEATHER_MASK_X  (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0x8C))
#define DISPLAY_REG_WEATHER_MASK_Y  (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0xAC))

#define DISPLAY_REG_LASER_COLX_LO   (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0xB0))
#define DISPLAY_REG_LASER_COLX_HI   (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0xB4))

#define DISPLAY_REG_BEAM_X          (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0xB8))
#define DISPLAY_REG_BEAM_CTRL       (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0xBC))

#define DISPLAY_REG_HAIR_BASE       0xC0u
#define DISPLAY_REG_HAIR(k, f)      \
    (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0xC0u + 16u * (uint32_t)(k) + 4u * (uint32_t)(f)))

#define DISPLAY_REG_BUCKET_BASE     (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0xF0))
#define DISPLAY_REG_BTILE_ADDR      (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0xF4))
#define DISPLAY_REG_BTILE_DATA      (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0xF8))
#define DISPLAY_REG_BPAL_DATA       (*(volatile uint32_t *)(DISPLAY_BASE_ADDR + 0xFC))

/* High-level Display Engine Control Helper Inlines */
static inline void display_set_weather(uint32_t ctrl) {
    DISPLAY_REG_WEATHER = ctrl;
}

static inline void display_set_weather_mask(uint32_t x0, uint32_t x1, uint32_t y0, uint32_t y1, int enable) {
    DISPLAY_REG_WEATHER_MASK_Y = ((y1 & 0x7FFu) << 11) | (y0 & 0x7FFu);
    DISPLAY_REG_WEATHER_MASK_X = ((enable ? 1u : 0u) << 31) | ((x1 & 0x7FFu) << 11) | (x0 & 0x7FFu);
}

static inline void display_clear_weather_mask(void) {
    DISPLAY_REG_WEATHER_MASK_X = 0u;
}

static inline void display_set_laser_columns(uint32_t colx_lo, uint32_t colx_hi) {
    DISPLAY_REG_LASER_COLX_LO = colx_lo;
    DISPLAY_REG_LASER_COLX_HI = colx_hi;
}

static inline void display_set_beam(uint32_t x, uint32_t height, int enable) {
    DISPLAY_REG_BEAM_X = x & 0xFFFu;
    DISPLAY_REG_BEAM_CTRL = ((enable ? 1u : 0u) << 11) | (height & 0x7FFu);
}

static inline void display_set_hairline(uint32_t slot, uint32_t centre_x, uint32_t c_out, uint32_t c_lft, uint32_t c_mid) {
    DISPLAY_REG_HAIR(slot, 0) = centre_x & 0xFFFu;
    DISPLAY_REG_HAIR(slot, 1) = c_out & 0xFFFFFFu;
    DISPLAY_REG_HAIR(slot, 2) = c_lft & 0xFFFFFFu;
    DISPLAY_REG_HAIR(slot, 3) = c_mid & 0xFFFFFFu;
}

static inline void display_set_bloom(uint32_t ctrl) {
    DISPLAY_REG_BLOOM_CTRL = ctrl;
}

static inline void display_set_color_matrix(uint32_t ctrl) {
    DISPLAY_REG_COLOR_MATRIX = ctrl;
}

#ifdef __cplusplus
}
#endif

#endif /* DISPLAY_H */
