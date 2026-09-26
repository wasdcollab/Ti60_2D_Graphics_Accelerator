#include "gamepad.h"

/* ---------------------------------------------------------------------------
 * Stick conditioning
 *
 * The handset reports its two axes with a few counts of noise around the
 * mechanical centre, and the firmware samples them exactly once per frame, so
 * a single stray sample used to nudge the craft and flip the walk pose while
 * the player was not touching the stick at all.
 *
 * Three cheap filters, all of them in one place so every reader - movement,
 * pose selection, the boot menu and the stress demo - sees the same value:
 *
 *   * a dead band, wider than the noise, around the centre;
 *   * hysteresis: once a direction is engaged it only releases close to the
 *     centre again, so noise sitting on the threshold cannot chatter;
 *   * a direction change has to be seen on two consecutive frames, which
 *     rejects a sample that jumps out of the band for one frame only.
 *
 * The result is quantised to low / centre / high.  Every caller only ever
 * asked which side of the band the axis was on, so the quantisation loses no
 * information - and it is what keeps the noise out of the pose code.
 * ------------------------------------------------------------------------- */
#define PAD_CENTRE      128
#define PAD_ENGAGE       28    /* counts from centre that start a push */
#define PAD_RELEASE      14    /* ... and the tighter band that ends it */
#define PAD_LOW_VAL      40
#define PAD_HIGH_VAL    216

typedef struct { uint8_t state, pending; } pad_axis_t;
static pad_axis_t pad_axis[2];

static uint8_t pad_axis_scan(pad_axis_t *f, uint8_t raw)
{
    int d = (int)raw - PAD_CENTRE;
    uint8_t now;

    if (f->state == 2u)                 /* engaged high: release near centre */
        now = (d >  PAD_RELEASE) ? 2u : (d < -PAD_ENGAGE ? 1u : 0u);
    else if (f->state == 1u)            /* engaged low */
        now = (d < -PAD_RELEASE) ? 1u : (d >  PAD_ENGAGE ? 2u : 0u);
    else                                /* centred: needs a deliberate push */
        now = (d >  PAD_ENGAGE) ? 2u : (d < -PAD_ENGAGE ? 1u : 0u);

    if (now == f->state)        f->pending = 0u;     /* settled, no vote */
    else if (now == f->pending) f->state = now;      /* second frame: believe */
    else                        f->pending = now;    /* first frame: ask again */
    return f->state;
}

static uint8_t pad_axis_value(uint8_t state)
{
    return (uint8_t)(state == 2u ? PAD_HIGH_VAL :
                     state == 1u ? PAD_LOW_VAL : PAD_CENTRE);
}

void gamepad_init(void) {
    // Slave 7-bit addr = 0x5A (Mini-Joystick), auto_poll enabled
    GPU2D_REG_I2C_CFG = 0x0001005AUL;
}

void gamepad_read(gamepad_state_t *state) {
    if (!state) return;
    uint32_t joy_val = GPU2D_REG_GAMEPAD_JOY;
    uint32_t btn_val = GPU2D_REG_GAMEPAD_BTN;

    state->x      = pad_axis_value(pad_axis_scan(&pad_axis[0], (uint8_t)joy_val));
    state->y      = pad_axis_value(pad_axis_scan(&pad_axis[1], (uint8_t)(joy_val >> 8)));

    /* logical button <- raw bit, see the mapping table in gamepad.h */
    state->btn_a  = (uint8_t)((btn_val >> GPU2D_BTN_BIT_A) & 0x01);
    state->btn_b  = (uint8_t)((btn_val >> GPU2D_BTN_BIT_B) & 0x01);
    state->btn_x  = (uint8_t)((btn_val >> GPU2D_BTN_BIT_X) & 0x01);
    state->btn_y  = (uint8_t)((btn_val >> GPU2D_BTN_BIT_Y) & 0x01);
    state->btn_center = (uint8_t)((btn_val >> GPU2D_BTN_CENTER) & 0x01);
    state->online = (uint8_t)((btn_val >> GPU2D_BTN_ONLINE) & 0x01);
}

uint32_t board_get_sw0(void) {
    return (GPU2D_REG_BOARD_KEYS & 0x01);
}

uint32_t board_get_sw2(void) {
    return ((GPU2D_REG_BOARD_KEYS >> 1) & 0x01);
}

void board_set_hud_disable(uint32_t disable) {
    if (disable)
        GPU2D_REG_I2C_CFG |= (1UL << 20);
    else
        GPU2D_REG_I2C_CFG &= ~(1UL << 20);
}
