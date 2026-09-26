#ifndef GAMEPAD_H
#define GAMEPAD_H

#include <stdint.h>
#include "gpu2d.h"

// APB Gamepad and Board Switches Registers
#define GPU2D_REG_GAMEPAD_JOY   (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x50))
#define GPU2D_REG_GAMEPAD_BTN   (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x54))
#define GPU2D_REG_BOARD_KEYS    (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x58))
#define GPU2D_REG_I2C_CFG       (*(volatile uint32_t *)(GPU2D_BASE_ADDR + 0x5C))

typedef struct {
    uint8_t x;          // 0 .. 255, center ~128
    uint8_t y;          // 0 .. 255, center ~128
    uint8_t btn_a;      // 1 = pressed, 0 = released
    uint8_t btn_b;      // 1 = pressed, 0 = released
    uint8_t btn_x;      // 1 = pressed, 0 = released
    uint8_t btn_y;      // 1 = pressed, 0 = released
    uint8_t btn_center; // 1 = joystick centre (OK) pressed
    uint8_t online;     // 1 = communicating with I2C slave
} gamepad_state_t;

void gamepad_init(void);
void gamepad_read(gamepad_state_t *state);
uint32_t board_get_sw0(void);
uint32_t board_get_sw2(void);
void board_set_hud_disable(uint32_t disable);


/* ---------------------------------------------------------------------------
 * Face button bit mapping (measured on the real handset, 2026-09-15)
 *
 * The I2C joystick module names its registers A/B/C/D, but the physical buttons
 * sitting on those registers are not the ones the names suggest:
 *
 *      module reg 0x21 ("C")  ->  physical A        -> raw bit 2
 *      module reg 0x22 ("A")  ->  physical Y        -> raw bit 0
 *      module reg 0x23 ("B")  ->  physical B        -> raw bit 1
 *      module reg 0x24 ("D")  ->  physical X        -> raw bit 3
 *
 * Hardware check that produced this table: pressing the physical X lit the top
 * indicator, Y lit the bottom and A lit the left.  Remap here rather than in
 * the RTL so it can be corrected without touching the bitstream build flow...
 * except that the firmware does live in the bitstream - see 外设调试收尾.md.
 * ------------------------------------------------------------------------- */
#define GPU2D_BTN_BIT_A     2
#define GPU2D_BTN_BIT_B     1
#define GPU2D_BTN_BIT_X     3
#define GPU2D_BTN_BIT_Y     0
#define GPU2D_BTN_CENTER    4      /* joystick centre press (module reg 0x20) */
#define GPU2D_BTN_ONLINE    15

#endif // GAMEPAD_H
