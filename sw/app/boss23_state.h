/* DDR state; no extra firmware BSS or block RAM. */
typedef struct { int16_t x,y,nx,ny; uint8_t ttl,warn,life,width,hue,pad[3]; } spell_beam_t;
typedef struct { int16_t x,y; uint16_t r0,rmax; uint8_t ttl,life,hue,soft; } spell_fx_t;
typedef struct {
    uint16_t age; uint8_t kind,pad;
    int16_t x,y,aim_x,aim_y;
    spell_beam_t beams[6];
    spell_fx_t fx[4];
    int16_t burst_xy[75][2];
    uint8_t burst_count;
} boss23_state_t;
static boss23_state_t * const spell = (boss23_state_t *)MM_BOSS23_CAST;
typedef struct { uint8_t age,freeze,burst,pad; } ember_age_t;
static ember_age_t * const ember_ages = (ember_age_t *)MM_BULLET_AUX;
static void boss23_clear(void);
