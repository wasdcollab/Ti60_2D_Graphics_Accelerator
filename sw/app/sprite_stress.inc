/* Included after the shared font renderer; intentionally independent of game
 * update/pools. CLINT MTIME runs at 100 MHz (generated BSP soc.h and soc.v).
 * It measures elapsed wall cycles including DDR/APB stalls, not instructions. */
#define STRESS_HZ 100000000u
#define STRESS_KEY 0xFFFF00FFu
#define STRESS_MAX 2048u

static struct {
    /* First 14 words are also the public DDR telemetry layout. */
    union {
        struct {
            uint32_t count, size, automatic, phase, result, best, fps10;
            uint32_t last_us, worst_us, errors, cfg_errors, timeouts, elapsed_ms, samples;
        };
        uint32_t values[14];
    };
    uint32_t start, presented, motion, previous_buttons, previous_stick;
    uint32_t panel_dirty, old_bcd, step;
} stress;

static uint32_t stress_cycles(void)
{
    return *(volatile uint32_t *)0xF8B0BFF8u; /* low MTIME; unsigned wrap safe */
}

static void stress_restart(void)
{
    stress.start = stress_cycles();
    stress.presented = GPU2D_REG_FPGA_FRAMES;
    stress.phase = 0;                  /* 2 seconds warmup, then 10 seconds */
    stress.result = 0;
    stress.fps10 = stress.elapsed_ms = stress.samples = stress.worst_us = 0;
    stress.panel_dirty = 1;
}

static void stress_init(void)
{
    volatile uint32_t *dst = (volatile uint32_t *)MM_STRESS_SPRITE;
    const volatile uint32_t *src = (const volatile uint32_t *)MM_AURA_SPRITE;
    /* Reuse the existing alpha aura. OPAQUE key pixels distinguish genuine
     * ColorKey priority from simply passing through an alpha=0 pixel. */
    for (unsigned i = 0; i < 4096; i++)
        dst[i] = src[i] == MAGENTA_KEY ? STRESS_KEY : src[i];
    for (unsigned i = 4096; i < 4100; i++) dst[i] = STRESS_KEY;
    gpu2d_flush_dcache();
    hw_accel = 1;
    stress.count = stress.size = 64;
    stress.automatic = stress.best = stress.motion = 0;
    stress.errors = stress.cfg_errors = stress.timeouts = 0;
    stress.previous_buttons = 15;       /* suppress held entry buttons */
    stress.previous_stick = 0;
    stress.old_bcd = 0xFFFFFFFFu;
    stress.step = 32;
    gpu2d_set_alpha(1, 160);
    stress_restart();
}

static void stress_input(const gamepad_state_t *pad)
{
    uint32_t buttons = (pad->btn_x ? 1u : 0u) | (pad->btn_y ? 2u : 0u) |
                       (pad->btn_a ? 4u : 0u) | (pad->btn_center ? 8u : 0u);
    uint32_t edges = buttons & ~stress.previous_buttons;
    uint32_t stick = pad->x > 168 ? 1u : (pad->x < 88 ? 2u : 0u);
    int changed = 0;
    if (edges & 8u) {
        stress.step = stress.step == 32 ? 1 : 32;
        stress.panel_dirty = 1;
    }
    if (edges & 2u) {
        stress.size = stress.size == 64 ? 16 : stress.size + 16;
        stress.automatic = stress.best = 0;
        changed = 1;
    }
    if (edges & 4u) {
        stress.count = 64;
        stress.automatic = stress.best = 0;
        stress.errors = stress.cfg_errors = stress.timeouts = 0;
        changed = 1;
    }
    if (stick && !stress.previous_stick) {
        if (stick == 1 && stress.count < STRESS_MAX)
            stress.count = stress.count + stress.step > STRESS_MAX ? STRESS_MAX : stress.count + stress.step;
        if (stick == 2) stress.count = stress.count > stress.step ? stress.count - stress.step : 1;
        stress.automatic = stress.best = 0;
        changed = 1;
    }
    if (edges & 1u) {
        stress.automatic ^= 1;
        stress.best = 0;
        changed = 1;
    }
    stress.previous_buttons = buttons;
    stress.previous_stick = stick;
    if (changed) stress_restart();
}

static int stress_finish(void)
{
    uint32_t start = stress_cycles(), status;
    do {
        status = GPU2D_REG_STATUS;
        if ((uint32_t)(stress_cycles() - start) > STRESS_HZ) {
            stress.errors++; stress.timeouts++;
            stress.result = 2; stress.automatic = 0;
            stress.panel_dirty = 1;
            return 0;                  /* do not issue START while still busy */
        }
    } while (status & GPU2D_STATUS_BUSY_MASK);
    if (status & (GPU2D_STATUS_CFGERR | GPU2D_STATUS_TIMEOUT)) {
        stress.errors++;
        if (status & GPU2D_STATUS_CFGERR) stress.cfg_errors++;
        if (status & GPU2D_STATUS_TIMEOUT) stress.timeouts++;
        stress.result = 2; stress.automatic = 0;
        stress.panel_dirty = 1;
    }
    return 1;
}

static int stress_panel(void)
{
    uint32_t fb = MM_STRESS_PANEL;
    gpu2d_set_colorkey(1, MAGENTA_KEY);
    gpu2d_fill(fb,1024,128,0x000B1020u,4096);   /* the panel keeps its own pitch */
    if (!stress_finish()) return 0;
    draw_text(fb,16,8,"ALPHA + COLORKEY / SPRITE STRESS",2,0);
    draw_text(fb,544,8,"X AUTO Y SIZE A RESET B EXIT",2,0);
    draw_text(fb,16,40,"N",2,0); draw_number(fb,48,36,stress.count,4,0);
    draw_text(fb,150,40,"SIZE",2,0); draw_number(fb,240,36,stress.size,2,0);
    draw_text(fb,320,40,"FPS",2,0);
    uint32_t bcd = (GPU2D_REG_FPS_BCD >> 8) & 255u;
    draw_number(fb,400,36,(bcd >> 4)*10+(bcd & 15),2,0);
    draw_text(fb,560,40,"LAST US",2,0); draw_number(fb,740,36,stress.last_us,7,0);
    draw_text(fb,16,72,stress.automatic ? "AUTO" : "MANUAL",2,0);
    draw_text(fb,150,72,stress.result == 2 ? "FAIL" :
        (stress.result == 1 ? "PASS" : (stress.phase ? "MEASURE" : "WARMUP")),2,0);
    draw_text(fb,320,72,"BEST",2,0); draw_number(fb,400,68,stress.best,4,0);
    draw_text(fb,560,72,"WORST US",2,0); draw_number(fb,740,68,stress.worst_us,7,0);
    draw_text(fb,16,104,"OK STEP / STICK",2,0); draw_number(fb,240,100,stress.step,2,0);
    draw_text(fb,320,104,"10S FPS X10",2,0); draw_number(fb,490,100,stress.fps10,3,0);
    draw_text(fb,720,104,"ERRORS",2,0); draw_number(fb,870,100,stress.errors,4,0);
    if (!stress_finish()) return 0;
    stress.panel_dirty = 0;
    return 1;
}

static int stress_frame(uint32_t fb)
{
    uint32_t start = stress_cycles();
    uint32_t bcd = (GPU2D_REG_FPS_BCD >> 8) & 255u;
    if (stress.panel_dirty || bcd != stress.old_bcd) {
        if (!stress_panel()) return 0;
        stress.old_bcd = bcd;
    }
    /* One full-screen opaque background and one cached opaque HUD per frame.
     * Source alpha/key then stay fixed for every workload sprite. */
    gpu2d_set_colorkey(0, STRESS_KEY);
    gpu2d_copy(fb,MM_VISUAL_BACKGROUND,SCREEN_WIDTH,SCREEN_HEIGHT,SCREEN_STRIDE,SCREEN_STRIDE);
    if (!stress_finish()) return 0;
    gpu2d_copy(fb,MM_STRESS_PANEL,1024,128,4096,SCREEN_STRIDE);
    if (!stress_finish()) return 0;
    gpu2d_set_colorkey(1, STRESS_KEY);
    uint32_t size = stress.size, inset = (64-size)/2;
    for (uint32_t i = 0; i < stress.count && stress.errors == 0; i++) {
        uint32_t x = (i*37 + stress.motion) & 1023u;
        uint32_t y = (i*23 + stress.motion) & 511u;
        if (x > 1024-size) x -= 1025-size;
        if (y > 464-size) y -= 465-size;
        gpu2d_alpha_blit(fb+(y+136)*SCREEN_STRIDE+x*4,
            MM_STRESS_SPRITE+inset*256+inset*4,size,size,256,SCREEN_STRIDE);
        if (!stress_finish()) return 0;
    }
    gpu2d_flush_dcache();
    stress.last_us = (uint32_t)(stress_cycles()-start)/100u;
    stress.motion++;
    if (stress.phase == 1 && stress.result == 0 && stress.last_us > stress.worst_us)
        stress.worst_us = stress.last_us;

    uint32_t elapsed = (uint32_t)(stress_cycles()-stress.start);
    if (stress.result == 0 && stress.phase == 0 && elapsed >= 2*STRESS_HZ) {
        stress.start = stress_cycles();
        stress.presented = GPU2D_REG_FPGA_FRAMES;
        stress.phase = 1; stress.worst_us = 0; stress.panel_dirty = 1;
    } else if (stress.result == 0 && stress.phase == 1 && elapsed >= 10*STRESS_HZ) {
        stress.elapsed_ms = elapsed/100000u;
        stress.samples = GPU2D_REG_FPGA_FRAMES-stress.presented;
        stress.fps10 = stress.samples*10000u/stress.elapsed_ms;
        /* Allow nominal 59.94 Hz and one boundary frame, but also demand that
         * every measured render (including HUD updates) fits 16.667 ms. */
        stress.result = stress.fps10 >= 598 && stress.worst_us <= 16667 &&
                        stress.errors == 0 ? 1 : 2;
        stress.panel_dirty = 1;
        if (stress.result == 1) stress.best = stress.count;
        if (stress.automatic && stress.result == 1 && stress.count < STRESS_MAX) {
            stress.count = stress.count+32 > STRESS_MAX ? STRESS_MAX : stress.count+32;
            stress_restart();
        } else stress.automatic = 0;
    }
    volatile uint32_t *tlm = (volatile uint32_t *)MM_STRESS_TELEMETRY;
    for (unsigned i = 0; i < 14; i++) tlm[i] = stress.values[i];
    gpu2d_flush_dcache();
    return 1;
}
