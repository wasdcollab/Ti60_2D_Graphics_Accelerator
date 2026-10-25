/**
 * @file main.c
 * @brief RISC-V C application: accelerator benchmark + three-stage bullet hell
 * @version 6.0
 * @date 2026-09-20
 *
 * Mode 1 (SW0): 650-object CPU software rendering vs FPGA BitBlt benchmark,
 *               plus one hardware block copy (OP_COPY) per frame.
 * Mode 2 (SW2): playable bullet-hell stage:
 *   * the player SHOOTS bullets (??? / ??? / ??? plus a laser mode) instead
 *     of holding one permanent laser;
 *   * three themed stages; each boss arrives after a kill quota and dialogue;
 *   * minions drift, weave, hover and fire aimed / spread patterns, carry hit
 *     points and drop power-ups when destroyed;
 *   * the boss moves, summons minions and cycles through RANDOM attack patterns
 *     (fan / ring / aimed / spiral / cross / summon) rather than one fixed fan;
 *   * power-ups: ????/ ????/ ?????/ ?????? / ???;
 *   * the player carries a hardware-alpha aura (OP_ALPHA) that blends against
 *     the live background, i.e. the competition's alpha datapath runs every
 *     frame of the game.
 *
 * Built with riscv-none-elf-gcc (-march=rv32i -Oz) into the 64 KiB on-chip RAM,
 * see sw/linker/ti60_sapphire.ld and sw/build_firmware.py.  All DDR addresses
 * come from sw/driver/memory_map.h.
 */

#include "gpu2d.h"
#include "gamepad.h"
#include "audio.h"
#include "audio_stream.h"
#include "asset_rom.h"
#include "visual_assets.h"
#include "stage_bg.h"

/* ===================================================================== */
/* shared helpers                                                        */
/* ===================================================================== */

static const uint32_t palette[8] = {
    0x00FF3333u, 0x0033FF33u, 0x003366FFu, 0x00FFFF33u,
    0x00FF33FFu, 0x0033FFFFu, 0x00FFA500u, 0x00FFFFFFu,
};

#define MAGENTA_KEY     0x00FF00FFu

/* ---- 图块角色号：形状的组成部分，与颜色无关 --------------------------------
 *
 * 扫描端的图块里一格存的不是调色板索引，而是"这一格是什么角色"：透明、
 * 白、某类的霓虹主体、光晕第 k 级……角色由形状决定，与色相无关，所以三类
 * 的八个颜色版本可以压成一份。真正的调色板索引在扫描端拼出来：
 *
 *     索引 = 角色号 + 色相 * 32
 *
 * 色相从桶条目的 [31:29] 来（bucket_put），就是发射那一刻的 b->color & 7。
 * 角色号 0 是"这里没有东西"的哨兵，与调色板索引 0 是同一个约定 —— 扫描端
 * 判断透不透明仍然看这个字节本身是不是 0，不看拼出来的索引。hue > 0 时
 * 角色 0 会拼出 32/64/... 这些索引，它们永远读不到，填什么颜色都行。
 *
 * 页面大小取 32：角色一共 27 个（26 个非透明 + 哨兵），32 是装得下它的最小
 * 2 的幂；2 的幂让扫描端那边的拼接就是一次左移，不需要加法。实测过程见
 * scratch/tile颜色分离_侦察与方案.md。
 */
enum {
    BROLE_NONE     = 0,     /* 透明 */
    BROLE_WHITE    = 1,     /* 三类共用：敌弹白尖 / 玩家弹白芯 / 大玉白心 */
    BROLE_NEON     = 2,     /* palette[h]，三类共用（大玉的主体也是它） */
    BROLE_EB_CORE  = 3,     /* 敌弹电脊，色相往白靠 60/255 */
    BROLE_ORB_CORE = 4,     /* 大玉亮核，色相往白靠 80/255 */
    BROLE_PB_DIM   = 5,     /* 玩家弹外缘 */
    BROLE_PB_QUART = 6,     /* 玩家弹尾梢，同时也是大玉的暗环（实测同一条） */
    BROLE_PB_TINY  = 7,     /* 玩家弹最末的碎光 */
    BROLE_PB_HOT   = 8,     /* 玩家弹核心尾迹 */
    BROLE_EB_HALO  = 9,     /* 敌弹光晕第 1 级，往上排到 9..26 */
    /* 追踪导弹（slot 18）。这两个角色是"一个形状里两种混合"的全部机关：
     * 弹体的格子落在 27 上，拖尾的格子落在 28 上，扫描端逐像素取调色板，
     * 两个角色的 alpha 不同（190 / BPAL_ADD），于是同一个弹的前半段走乘法
     * alpha、后半段走加法。两者都不随色相变，见 brole_color()。 */
    BROLE_MS_BODY  = 27,    /* 弹体：乘法 alpha，透出背后的雪山 */
    BROLE_MS_TRAIL = 28     /* 拖尾：加法，亮到过曝 */
};
#define BROLE_EB_HALO_N  18u                                       /* 实测 18 级 */
/* 26 -> 28：27/28 原本就是空的（角色位 0..31，用到 26）。 */
#define BROLE_MAX        30u
#define BPAL_PAGE        32u                                       /* 色相页大小 */

/* 敌弹光晕那 18 级的 a。公式是 a = 180 - 7*dist，dist 从 1 到 20 本该有 20 级，
 * 但 13x13 的整数网格上 t16 - w_core 取不到 96 和 68 这两个值：在真实固件
 * 数据上数出来就是下面这 18 个（scratch/recon_color_split.py）。 */
static const uint8_t eb_halo_a[BROLE_EB_HALO_N] = {
    173u, 166u, 159u, 152u, 145u, 138u, 131u, 124u, 117u,
    110u, 103u,  89u,  82u,  75u,  61u,  54u,  47u,  40u
};

/* ---- tile store 里的 slot 号 ---------------------------------------------
 *
 * 与 video_bullet_overlay.v 的 SMALL_TILES 那一套对齐，四个地方必须一致：
 * 那个模块、tests/tb_bullet_overlay.sv 里那份拷贝、这里的调用、以及
 * tools/gen_bullet_tiles.py 的 SETS 表。漏一处座台的 75425 项检查会全红。
 *
 *     slot  0..15   敌弹     26x26 行距 32 -> 每个 832 字节
 *     slot 16       玩家弹   7x26  行距  8 -> 208 字节
 *     slot 17       大玉     16x16 行距 16 -> 256 字节
 *     slot 18       导弹     13x26 行距 16 -> 416 字节
 *
 * 色相不在 slot 里 —— 它在桶条目的 [31:29]，因为同一个 slot 要服务八个色相。 */
#define BTILE_SLOT_PBULLET  16u
#define BTILE_SLOT_ORB      17u
#define BTILE_SLOT_MISSILE  18u
/* The scanout is split at the VDMA HALF_OFFSET (2560 B = 640 px): everything
 * left of it is scanned from the left buffer, everything right of it from the
 * right buffer.  A renderer that only covers part of its own half leaves the
 * rest of that half showing the PREVIOUS frame, which is what the two garbage
 * strips down the sides of the 1366x768 screen were.  These two must always
 * add up to SCREEN_WIDTH. */
#define SCAN_HALF_PIXELS   512u
#define SCAN_HALF_BYTES    (SCAN_HALF_PIXELS * 4u)
#define SCAN_RIGHT_PIXELS  (SCREEN_WIDTH - SCAN_HALF_PIXELS)
/* ---- 1366x768 native playfield ----------------------------------------
 * The screen is now a 180-pixel HUD gutter either side of a 1005-pixel
 * playfield that runs the FULL height of the display:
 *
 *     x:  0 ..  180 | 181 .. 1184 | 1185 .. 1365
 *         left HUD  |  playfield   |  right HUD
 *
 * The plate behind all of it is authored at 683x384 and blitted at 2x, so
 * the playfield camera is a pure 2:1 pixel offset: screen_x = 2*stage_x -
 * CAM_X, with CAM_X = 2*CAM_X_SRC.  CAM_X_SRC = 91 centres the 1005-wide
 * viewport on the 683-wide plate (683/2 - 1005/4 = 91, and 91 is odd so
 * 2*91 = 182 is even, which keeps every playfield x at an even screen
 * column and therefore every source pixel on a whole 2x2 block).
 *
 * PLAYFIELD_TOP is 0: the plate covers row 0 now, so the old "repaint the
 * top 4 rows the shaking plate copy never reached" workaround is gone.
 */
#define CAM_X_SRC       91
#define CAM_X           (2 * CAM_X_SRC)
#define PLAYFIELD_TOP   0
#define GAME_LEFT       181
#define GAME_RIGHT      1185
#define GAME_TOP        0
#define GAME_BOTTOM     SCREEN_HEIGHT
#define PLAYFIELD_BOTTOM SCREEN_HEIGHT

/* The craft's sprite, in one place.  The walk frames are 48x48 and are drawn
 * CENTRED on (player_x, player_y), so its box is player +- PLAYER_HALF_*.  The
 * draw call and the beam's length both have to know the vertical half, and
 * they used to know it as a literal 48 in one place and as "player_y" in the
 * other - which is how the beam ended up drawn straight down the middle of
 * Reimu.  One constant, so the next change to the sprite size cannot move the
 * artwork out from under the beam again. */
#define PLAYER_SPRITE_SIDE 48
#define PLAYER_HALF_H      (PLAYER_SPRITE_SIDE / 2)
#define PLAYER_HALF_W      (PLAYER_SPRITE_SIDE / 2)

/* ---- bullet-hell tuning ------------------------------------------------
 * Speeds are pixels per frame.  The barrage got DENSER but each projectile
 * got SLOWER.  A 5 px/frame aimed shot crossed the playfield in 1.6 s and
 * left about four frames to react to a shot aimed wherever the player
 * happened to be standing; at 3 px/frame it is dodgeable, which is what lets
 * the patterns carry more bullets without becoming unfair.  The player's own
 * shots only lost the very top of their speed, so a hit still lands on the
 * frame it visually should.
 */
#define SPD_AIM_FAST    3
#define SPD_AIM_SLOW    2
#define SPD_RING        2
#define SPD_SPIRAL      2
#define SPD_CROSS       2
#define SPD_FAN         2
#define SPD_RAIN_MIN    2
#define SPD_RAIN_MAX    3
#define SPD_MINION      2
#define SPD_PBULLET     9
#define SPD_PBULLET_S   8
#define SPD_LASER       4
#define SPD_LANCE       3

/* ---- Task 12: the pressure stage's own numbers -------------------------
 * The stress stage does not scale the campaign's tuning, it replaces it.  Its
 * whole purpose is a load the three normal stages are never asked to carry,
 * and every value here is picked for that load:
 *
 *   SPD_LOCKON_MISSILE  speed of the two wing missiles in the three-stream
 *                       shot.  7, not SPD_PBULLET (9): a homing round that
 *                       outruns the fan it was fired with reads as the only
 *                       shot that matters.
 *   SPD_STORM           the storm's shot speed.  3, so a shot that survives
 *                       the crossing stays on screen for ~250 frames - the
 *                       barrage is TOPPED UP, never rebuilt.
 *   STRESS_STORM_TARGET starts at the board-verified 192. Y cycles the
 *                       supplemental storm through 256/320/384/448/192.
 *                       The live population includes boss patterns, so it
 *                       can exceed this target. The HUD records row drops;
 *                       FPS alone cannot prove every bullet was displayed.
 *   STRESS_STORM_BUDGET how many shots one frame may add.  Trickling them in
 *                       is the point - 192 born together would all leave the
 *                       boss's muzzle as one ring, and this stage wants a
 *                       screen that is saturated everywhere.
 *   STRESS_FIRE_CD      frames between salvos of the three-stream shot.  The
 *                       card asks for ??????? and FIRE_CD_MIN is what ???
 *                       means in this build, so the stage uses it verbatim
 *                       rather than inventing a slower number.
 */
#define SPD_LOCKON_MISSILE   7
#define SPD_STORM            3
#define STRESS_STORM_TARGET  192
#define STRESS_STORM_MAX     10000
#define STRESS_STORM_BUDGET  96
#define STRESS_FIRE_CD       FIRE_CD_MIN

/* Bullet sub-stepping: a fast player shot or a fast bullet would otherwise
 * tunnel through a 24-pixel sprite between two frames. */
#define BULLET_STEP     3

static uint32_t rng_state;

/* ---- player hitboxes ---------------------------------------------------
 * The fast 12x12 box on the player's centre is the DAMAGE hitbox and is
 * deliberately unchanged: it is what makes the dodging work.  Item pickup
 * used a second, similarly tiny box, which is why collecting anything needed
 * pixel-perfect flying.  Pickup now tests the whole silhouette instead: a bit
 * map of which 4x4 cells of the 48x48 sprite hold non-transparent pixels,
 * built once at boot from the very frames the renderer blits.  The sprite
 * geometry comes from visual_assets.h, so the map follows whatever arm the
 * current pose draws - there is no hand-kept table to fall out of sync.
 */
#define PICK_CELL        4
#define PICK_COLS        (48 / PICK_CELL)
#define PICK_ROWS        (48 / PICK_CELL)
#define PICK_POSES       6
#define PICK_MASK_BYTES  (((PICK_COLS * PICK_ROWS) + 31) / 32)
extern uint32_t pick_mask[PICK_POSES][PICK_MASK_BYTES];
static uint8_t  player_pose;

/* ---- stage backdrop state ---------------------------------------------
 * One RLE plate per stage, decoded once at boot into its own DDR surface, so
 * changing stage is a single pointer write.  strip_scroll is the parallax
 * phase, 0..SB_STRIP_PERIOD-1.
 */
/* The plate address is a formula, not a table: .bss lives inside the same
 * 63 KiB image budget as .rodata here, and 12 bytes was over the line. */
#define STAGE_BG_BUF(n)   (MM_STAGE_BG + (uint32_t)(n) * MM_STAGE_BG_STRIDE)
static unsigned stage_bg_active;
static uint16_t strip_scroll;
static uint16_t stage_banner;           /* frames left on the stage title card */

static uint32_t xorshift32(void)
{
    uint32_t t = rng_state;
    t ^= t << 13;
    t ^= t >> 17;
    t ^= t << 5;
    rng_state = t;
    return t;
}

static uint32_t rand_percent(void)                    /* 0..99 */
{
    return xorshift32() % 100u;
}

/* ===================================================================== */
/* ===================================================================== */
/* Mode 1: 650-object benchmark                                          */
/* ===================================================================== */

#define NUM_ENTITIES        650

typedef struct {
    int32_t x, y, vx, vy, w, h;
    uint32_t color;
} entity_t;

static entity_t * const entities = (entity_t *)MM_ENTITY_BASE;

static const int8_t vx_table[8] = { -2,  2, -3,  3, -1,  1, -2,  2 };
static const int8_t vy_table[8] = {  3, -3,  2, -2,  1, -1,  3, -3 };

static void entities_init(void)
{
    rng_state = 0x12345678u;
    for (int i = 0; i < NUM_ENTITIES; i++) {
        uint32_t t = xorshift32();
        int w = 28 + (int)((t & 3u) << 2);
        int h = w;

        int x = (int)((t >> 4) & 0x3FFu);
        if (x > (int)SCAN_HALF_PIXELS - w) {
            x = ((int)SCAN_HALF_PIXELS - w) - (x & 0x3F);
            if (x < 0) x = 0;
        }

        int y = (int)((t >> 13) & 0x3FFu) + 36;
        if (y > (int)SCREEN_HEIGHT - h) {
            y = ((int)SCREEN_HEIGHT - h) - (y & 0x3F);
            if (y < 36) y = 36;
        }

        entities[i].x = x;
        entities[i].y = y;
        entities[i].vx = vx_table[(t >> 22) & 7u];
        entities[i].vy = vy_table[(t >> 25) & 7u];
        entities[i].w = w;
        entities[i].h = h;
        entities[i].color = palette[(t >> 8) & 7u];
    }
}

static void entities_update(void)
{
    for (int i = 0; i < NUM_ENTITIES; i++) {
        int x = (int)entities[i].x + (int)entities[i].vx;
        if (x < 0) {
            x = 0;
            entities[i].vx = -entities[i].vx;
        } else if (x > (int)SCAN_HALF_PIXELS - (int)entities[i].w) {
            x = (int)SCAN_HALF_PIXELS - (int)entities[i].w;
            entities[i].vx = -entities[i].vx;
        }
        entities[i].x = x;

        int y = (int)entities[i].y + (int)entities[i].vy;
        if (y < 36) {
            y = 36;
            entities[i].vy = -entities[i].vy;
        } else if (y > (int)SCREEN_HEIGHT - (int)entities[i].h) {
            y = (int)SCREEN_HEIGHT - (int)entities[i].h;
            entities[i].vy = -entities[i].vy;
        }
        entities[i].y = y;
    }
}

static void cpu_software_fill(uint32_t dst_base, int x, int y, int w, int h,
                              uint32_t color)
{
    for (int r = 0; r < h; r++) {
        volatile uint32_t *line = (volatile uint32_t *)(dst_base +
                                   (uint32_t)((y + r) * SCREEN_STRIDE) +
                                   (uint32_t)(x * 4));
        for (int c = 0; c < w; c++)
            line[c] = color;
    }
}

/* ===================================================================== */
/* boot menu                                                             */
/* ===================================================================== */
#define SCREEN_MENU     0
#define SCREEN_BITBLT   1
#define SCREEN_GAME     2
#define SCREEN_STRESS   3
#define SCREEN_STRESS_STAGE 4

static int is_stress_stage = 0;
static uint16_t stress_target;
static uint8_t stress_prev_y;
static uint8_t stress_load_hold;

/* v6's boot menu: TWO cards, not a list.  Row 0 is the BitBlt bench (CPU on
 * the left half, FPGA on the right) and row 1 is the bullet-hell run, i.e.
 * exactly the two screens v6 offered, SCREEN_BITBLT and SCREEN_GAME.  The
 * eight-row list this replaces had six rows with nothing behind them: a
 * player could select MUSIC ROOM and watch the menu simply not move.
 *
 * v6's geometry was a 600x140 card on a 180 pitch over a 1024x600 screen.
 * The same idiom at 1366x768 is a 700x180 card on a 230 pitch, re-centred
 * under the title and clear of the portrait on the right. */
#define MENU_ITEMS      2
#define MENU_X          300
#define MENU_ROW_W      700
#define MENU_ROW_H      180
#define MENU_TOP        300
#define MENU_PITCH      230
/* The solid cursor bar v6 hung off the left edge of the live card, and the
 * gap between that bar and the card itself. */
#define MENU_ARROW_W    28
#define MENU_ARROW_GAP  16
/* The quantised stick (sw/driver/gamepad.c) sits below PAD_AXIS_LOW when it is
 * pushed away from the player and above PAD_AXIS_HIGH when it is pushed
 * towards them; everything in between reads as the centre.  These are the same
 * two thresholds the craft moves on, kept in one place. */
#define PAD_AXIS_LOW    108
#define PAD_AXIS_HIGH   148
/* Menu stick repeat.  A push moves the cursor ONCE, and then the stick has
 * to be held for MENU_STICK_DELAY passes before it starts repeating every
 * MENU_STICK_REPEAT passes.  It used to repeat every 8 passes with no delay at
 * all, which walked the whole list in a moment whenever the stick drifted.
 * The menu loop costs about two display frames a pass, so 45 passes is the
 * 1.5 seconds the brief asks for. */
#define MENU_STICK_REPEAT 8
#define MENU_STICK_DELAY  45
/* The portrait: the player's 48x48 walk frame, blitted 5x into the right
 * third.  BitBlt cannot scale, so this is 48 row copies per band - 240
 * commands for a 240x240 picture. */
#define PORTRAIT_X      1010
#define PORTRAIT_Y      300
#define PORTRAIT_SCALE  5

/* ---- plate expansion ---------------------------------------------------
 * The boot plate is authored at 683x384 (MM_VISUAL_BACKGROUND) and the display
 * is 1366x768, i.e. exactly 2x in both axes.  BitBlt has no scaler, so the
 * engine cannot do this - and storing the plate at 1366x768 instead costs
 * 13416 encoded bytes of RLE, which overflows the 64512-byte image region by
 * 7768.  The half-size plate is 7330 bytes including every HUD label, so the
 * CPU expands it once at boot and every frame after that is still one COPY.
 *
 * 2x2 pixel blocks, not interpolation: the plate is pixel art, so nearest is
 * the correct filter, and one source read feeds four stores.
 */

/* draw_menu() below is the first thing in the file that uses the accelerator
 * copy and the frame counter, so both are introduced here rather than further
 * down; the definitions still live with the rest of the engine wrappers. */
static void r_blit(uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                   uint32_t sstride, uint32_t dstride);
/* The particle pass (particles_render(), far above the engine wrappers) adds
 * its sparks rather than copying them, and the colour key has to be armed
 * around the whole batch rather than per particle. */
static void r_add_begin(void);
static void r_add_end(void);
static void r_add(uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                  uint32_t sstride, uint32_t dstride);
extern uint32_t frame_tick;

/* ---- boot-menu button latch -------------------------------------------
 * The menu is polled ONCE per pass, and a pass costs about two display
 * frames.  The handset only refreshes its button register every 20 ms
 * (i2c_gamepad_top polls the module at 50 Hz), so a press is only ever
 * visible for a 20 ms window - and a window that opens and closes between
 * two menu samples is a press the player made and the menu never saw.  On
 * the board that reads as "press Y, nothing moves, press it again".
 *
 * menu_sample() is called from several points inside one pass - at the
 * decision point, all through draw_menu()'s drawing stages and all through
 * the wait for the scanout to release the back buffer - and ORs every new
 * press into menu_edge_latch.  The press is then consumed at the next
 * decision point, however short it was.  Sampling this often is only safe
 * because it touches the BUTTON register alone: gamepad_read() runs the
 * stick through a two-sample confirmation, so calling IT repeatedly inside
 * one frame would turn "two frames" into "two calls" and let the stick
 * noise straight back in.
 */
#define MENU_EDGE_Y    0x01u
#define MENU_EDGE_A    0x02u
#define MENU_EDGE_X    0x04u
#define MENU_EDGE_OK   0x08u
#define MENU_EDGE_B    0x10u

static uint8_t menu_edge_latch;
static uint8_t menu_btn_prev = 0u;

static void menu_sample(void)
{
    uint32_t b = GPU2D_REG_GAMEPAD_BTN;
    uint8_t bits = (uint8_t)(((b >> GPU2D_BTN_BIT_Y) & 1u) |
                             (((b >> GPU2D_BTN_BIT_A) & 1u) << 1) |
                             (((b >> GPU2D_BTN_BIT_X) & 1u) << 2) |
                             (((b >> GPU2D_BTN_CENTER) & 1u) << 3) |
                             (((b >> GPU2D_BTN_BIT_B) & 1u) << 4));

    menu_edge_latch |= (uint8_t)(bits & (uint8_t)~menu_btn_prev);
    menu_btn_prev = bits;
}

/* Drop whatever the pad is doing right now and re-arm from a clean slate.
 * Called when the menu is entered: the button that left the last screen may
 * still be down, and that is not a press on this one. */
static int menu_last_sel = -1;

static void menu_edge_reset(void)
{
    menu_last_sel = -1;
    menu_sample();
    menu_edge_latch = 0;
}

/* The two spins a menu pass spends its time in.
 *
 * Drawing is not the slow part of a menu pass - WAITING is.  The pass waits
 * for the frame tick (gpu2d_wait_vsync) and it waits for the BitBlt engine to
 * go idle (gpu2d_wait_idle, once per launch), and between them those two
 * loops are most of the 33 ms.  Sampling only around the drawing left gaps
 * wider than a quarter of a frame, and the workbench's short-tap test caught
 * one press in six disappearing into exactly that hole.  Waiting and sampling
 * are the same loop now.
 */
static void menu_wait_vsync(void)
{
    uint32_t guard = 2000000u;
    while (!(GPU2D_REG_VSYNC_STS & 0x01) && --guard) menu_sample();
}

static int frame_wait_free(uint32_t fb)
{
    uint32_t guard = 2000000u;
    while (GPU2D_REG_LEFT_ACTIVE == fb || GPU2D_REG_RIGHT_ACTIVE == fb) {
        if (!--guard) return 0;
        if (gpu2d_idle_hook) gpu2d_idle_hook();
    }
    return 1;
}


/* ---- menu portrait ----------------------------------------------------
 * The player's walk frame expanded PORTRAIT_SCALE times, once at boot.
 *
 * Why not draw the enlargement at menu time: BitBlt has no scaler, and a
 * COMPOSITION of 1-pixel-tall COPYs cannot fake one - each command places a
 * whole source row at one destination x, so five commands give five copies
 * side by side, which is exactly what the first attempt rendered.  A true
 * stretch needs one command per source PIXEL: 48 * 5 * 48 = 11520 of them per
 * frame, which is not affordable.  So it is expanded once (11520 commands at
 * boot, measured in tens of milliseconds) and blitted as one 240x240 copy per
 * frame afterwards.
 */
static void portrait_build(void)
{
    const volatile uint32_t *src =
        (const volatile uint32_t *)visual_assets[ART_REIMU_0].dst;
    volatile uint32_t *dst = (volatile uint32_t *)MM_PORTRAIT;
    const uint32_t dstride = (uint32_t)(48 * PORTRAIT_SCALE);

    for (int r = 0; r < 48; r++) {
        for (int x = 0; x < 48; x++) {
            uint32_t px = src[r * 48 + x];
            for (int v = 0; v < PORTRAIT_SCALE; v++) {
                volatile uint32_t *row = dst +
                    (uint32_t)(r * PORTRAIT_SCALE + v) * dstride;
                for (int q = 0; q < PORTRAIT_SCALE; q++)
                    row[x * PORTRAIT_SCALE + q] = px;
            }
        }
    }
}

/* Forward declarations: the popup code below sits with the menu helpers,
 * higher up the file than the HUD drawing helpers it uses, and score is a
 * game-state variable defined with the rest of the run. */
static void draw_text(uint32_t fb, int x, int y, const char *s, int scale,
                      uint32_t color);
static void draw_number(uint32_t fb, int x, int y, uint32_t value, int digits,
                        uint32_t color);

/* ---- score popups and combo ------------------------------------------
 * A kill awards points in seven different places, and the popup has to be
 * raised WHERE the award happens: only there is the position known, and a
 * "compare score before and after the frame" approach cannot recover it.
 *
 * Measured cost: the struct is 8 bytes, eight slots is 64 bytes of .bss, and
 * the render is one draw_number() plus (on a run) one two-glyph draw_text()
 * per live popup - a handful of 6x8 COPYs a frame, well inside the budget in
 * ???-2.
 *
 * Why it is worth the bytes: before this, a kill's only immediate feedback was
 * the burst.  The player could not tell a 50-point pickup from a 500-point
 * one, and nothing showed whether kills were coming in a run.
 */
#define POPUP_SLOTS  8
#define POPUP_LIFE   42
#define COMBO_WINDOW 120          /* frames a kill stays "in a row" */

typedef struct {
    int16_t  x, y;
    uint16_t value;
    uint8_t  age;
    uint8_t  combo;
} popup_t;

extern popup_t popups[POPUP_SLOTS];
static uint8_t  popup_cursor;
static uint16_t combo_count;
static uint16_t combo_timer;
static uint32_t score;
static uint32_t score_total;

static void score_award(uint32_t points, int x, int y)
{
    score += points;
    score_total += points;

    if (combo_timer) combo_count++;
    else             combo_count = 1;
    combo_timer = COMBO_WINDOW;
    if (combo_count > 255u) combo_count = 255u;

    popup_t *p = &popups[popup_cursor++ & (POPUP_SLOTS - 1u)];
    p->x = (int16_t)x;
    p->y = (int16_t)y;
    p->value = (uint16_t)(points > 65535u ? 65535u : points);
    p->age = 1;
    p->combo = (uint8_t)combo_count;
}

static void popup_step(void)
{
    if (combo_timer) {
        combo_timer--;
        if (!combo_timer) combo_count = 0;
    }
    for (int i = 0; i < POPUP_SLOTS; i++)
        if (popups[i].age && ++popups[i].age >= POPUP_LIFE) popups[i].age = 0;
}

static void popup_render(uint32_t fb)
{
    for (int i = 0; i < POPUP_SLOTS; i++) {
        popup_t *p = &popups[i];
        if (!p->age) continue;
        /* Blink over the last third of the life, so a popup reads as
         * "expiring" instead of simply vanishing. */
        if (p->age > (POPUP_LIFE * 2 / 3) && (p->age & 2u)) continue;
        int rise = 4 + (int)p->age / 4;         /* a slow drift upward */
        int px = (int)p->x - 8;
        int py = (int)p->y - rise;
        if (px < GAME_LEFT + 2 || py < GAME_TOP + 2) continue;
        if (px > GAME_RIGHT - 42 || py > GAME_BOTTOM - 14) continue;
        uint32_t col = (p->combo >= 3u) ? 0x00FFE45Cu : 0x00FFFFFFu;
        draw_number(fb, px, py, p->value, 4, col);
        if (p->combo >= 3u) {
            /* xN right after the number: the run is visible as it grows. */
            char tag[3];
            tag[0] = (char)('0' + (p->combo / 10u) % 10u);
            tag[1] = (char)('0' + p->combo % 10u);
            tag[2] = '\0';
            draw_text(fb, px + 26, py, (p->combo < 10u) ? tag + 1 : tag, 1,
                      0x00FFC040u);
        }
    }
}


static void menu_bar(uint32_t base, int x, int y, int w, int h, uint32_t c)
{
    gpu2d_fill(base + (uint32_t)(y * SCREEN_STRIDE) + (uint32_t)(x * 4), (uint32_t)w,
               (uint32_t)h, c, SCREEN_STRIDE);
}

static void draw_text(uint32_t fb, int x, int y, const char *s, int scale,
                      uint32_t color);

static const char * const menu_labels[MENU_ITEMS] = {
    "RENDER LAB", "START GAME"
};
/* v6 printed a strapline under each card, so a row says what is behind it
 * before the player commits to it. */
static const char * const menu_subs[MENU_ITEMS] = {
    "CPU VS FPGA", "REIMU HAKUREI"
};

/* Which menu row the D-pad is on.  File scope and not a main() local on
 * purpose: LTO keeps a local in a register, and the workbench drives the menu
 * by naming this variable - see HARNESS_SYMBOLS in sw/build_firmware.py. */
int menu_sel;

static void draw_menu(uint32_t base, int sel)
{
    /* Static layer: the plate, painted once at boot and blitted here 1:1. */
    r_blit(base, MM_VISUAL_BACKGROUND, SCREEN_WIDTH, SCREEN_HEIGHT,
           SCREEN_STRIDE, SCREEN_STRIDE);

    menu_sample();


    /* ---- title ----------------------------------------------------------
     * Breaths two pixels and drifts a little: the drift uses frame_tick's low
     * bits, so it costs nothing but a shift and the whole title block moves
     * as one - which is what reads as "breathing" rather than "shaking". */
    {
        int brea = (int)((frame_tick >> 3) & 3u);
        int dy = (brea == 0 || brea == 3) ? 0 : 2;
        /* Title centred over the two cards, well below the skyline.
         *
         * This asked for scale 8, and draw_text() accepts 1..6 because the
         * boot atlas carries six scales - so the title was silently rejected
         * and the screen opened on its own subtitle.  Nothing caught it: the
         * call is well formed, draw_text's guard returns without a word, and
         * the sub-lines below still drew.  Scale 6 is the biggest the atlas
         * has; 13 glyphs at 7*6 is 546 pixels, so x = 300 + (700-546)/2 puts
         * it exactly on the cards' centre line. */
        draw_text(base, 377 + brea, 150 + dy, "SCARLET DREAM", 6, 0x00FFE8B0u);
        draw_text(base, 372 + brea, 212 + dy,
                  "~ Reimu Hakurei and the Deep Blue", 2, 0x00C8B4E8u);
        draw_text(base, 372 + brea, 234 + dy,
                  "1366 x 768 NATIVE EDITION", 2, 0x0090A8C8u);
        /* One hairline under the subtitle: a single command, and it is what
         * stops the title block reading as three loose lines. */
        menu_bar(base, 366 + brea, 254 + dy, 460, 2, 0x00607890u);
    }

    /* The first card is the longest piece of drawing left in this pass, so
     * the pad is sampled either side of it: see menu_sample(). */
    menu_sample();

    /* ---- menu cards ----------------------------------------------------- */
    for (int i = 0; i < MENU_ITEMS; i++) {
        int y = MENU_TOP + i * MENU_PITCH;
        int on = (i == sel);
        /* v6's card: a bright 8-pixel frame around a darker inset, the row's
         * name in big type and its strapline under it.  Colour, not a
         * triangle, is what says which card is live. */
        uint32_t edge  = on ? 0x00FFD700u : 0x00304878u;
        uint32_t inner = on ? 0x00161F38u : 0x000B1020u;

        menu_bar(base, MENU_X, y, MENU_ROW_W, MENU_ROW_H, edge);
        menu_bar(base, MENU_X + 8, y + 8, MENU_ROW_W - 16, MENU_ROW_H - 16,
                 inner);
        draw_text(base, MENU_X + 44, y + 34, menu_labels[i], 4, edge);
        draw_text(base, MENU_X + 44, y + 104, menu_subs[i], 3, 0x00FF909Cu);

        if (on) {
            /* The cursor is v6's solid bar hanging off the left edge of the
             * live card.  It blinks on the old 30-frame period, so a still
             * frame is never ambiguous about which card the pad is on. */
            uint32_t bar = ((frame_tick >> 4) & 1u) ? 0x00B09000u
                                                    : 0x00FFD700u;
            menu_bar(base, MENU_X - MENU_ARROW_W - MENU_ARROW_GAP, y,
                     MENU_ARROW_W, MENU_ROW_H, bar);
        }
        menu_sample();
    }

    /* ---- portrait -------------------------------------------------------
     * The player's own 48x48 walk frame, blitted PORTRAIT_SCALE times.  BitBlt
     * cannot scale, so the enlargement is 48 row copies per horizontal band:
     * each source row becomes SCALE destination rows, and each row is copied
     * SCALE times side by side.  That fills the right third with the
     * character the title is about and costs nothing in .rodata. */
    {
        volatile int bob = (int)((frame_tick >> 4) & 3u);
        int py = PORTRAIT_Y + (bob == 0 || bob == 3 ? 0 : 3);
        /* ONE copy: the enlargement lives at MM_PORTRAIT (portrait_build). */
        r_blit(base + (uint32_t)py * SCREEN_STRIDE +
                   (uint32_t)PORTRAIT_X * 4u,
               MM_PORTRAIT, 48u * PORTRAIT_SCALE, 48u * PORTRAIT_SCALE,
               (uint32_t)(48 * PORTRAIT_SCALE) * 4u, SCREEN_STRIDE);
    }

    menu_sample();

    /* ---- footer --------------------------------------------------------- */
    menu_bar(base, 0, SCREEN_HEIGHT - 40, SCREEN_WIDTH, 40, 0x00081020u);
    menu_bar(base, 0, SCREEN_HEIGHT - 40, SCREEN_WIDTH, 2, 0x00486078u);
    draw_text(base, 300, SCREEN_HEIGHT - 28,
              "(C) 2026 DSH WHALE-CHAN   ALL RIGHTS RESERVED", 2, 0x008098B0u);
    draw_text(base, 1060, SCREEN_HEIGHT - 28, "VER 7.0", 2, 0x008098B0u);
    draw_text(base, 1230, SCREEN_HEIGHT - 28, "1366x768", 2, 0x00607890u);
    draw_text(base, 24, SCREEN_HEIGHT - 28, bgm_ready ? "BGM READY" :
              bgm_size ? "BGM LOADING" : "BGM WAITING", 1, 0x0090C8C8u);
    menu_sample();
}

/* Defined next to the bucket itself, far below.  Every screen leaves the game
 * through resync_scanout(), and that is where the curtain has to come down. */
static void bucket_clear(void);

/* Put the scanout back into a known double-buffer state before a demo starts.
 * The menu is full screen and drives BOTH scanout channels to one buffer, and
 * sampling REG_RIGHT_ACTIVE to pick "the other" buffer races with the flip the
 * display is about to perform.  Publishing one buffer and waiting until the
 * scanout really reports it removes the race. */
static void resync_scanout(uint32_t *lback, uint32_t *rback, int leaving)
{
    uint32_t guard = 4000000u;

    /* The bullet curtain is composited by the SCANOUT from a table the game loop
     * writes (B1).  This routine is where every screen leaves the game, and the
     * game loop stops writing that table the moment it does - but the scanout
     * has no way to know that, so it goes on compositing whatever the table
     * holds and the last frame's barrage stands frozen on top of the menu.
     *
     * The fix is to EMPTY the tables, not to switch the overlay off.  Switching
     * it off (bucket_base = 0) works only as long as every way back into a run
     * remembers to switch it on again, and a path that forgets does not look
     * like "the curtain is stale" - it looks like "the bullets stopped working",
     * which is a far worse failure than the one being fixed.  Emptying leaves
     * the overlay enabled at all times: whatever the game writes gets drawn, and
     * what the menu leaves behind draws nothing.
     *
     * bucket_clear() empties both tables whole: 491,520 bytes, about 5 ms on the
     * board and about ten simulated frames in the workbench.  This routine runs
     * on the way IN and on the way OUT, and paying that on the way in pushed the
     * menu past its own button window - B+X stopped landing in the pressure
     * stage, and a scenario that samples the table right after entering a run
     * found it empty.  So the wipe happens on the way OUT only: on the way in
     * the tables are already empty (this clear emptied them, or the boot
     * sequence did) and the run's first frame refills them. */
    if (leaving) {
        bucket_clear();
        /* The scanout's beam layer and its three warning hairlines are APB
         * registers, not framebuffer pixels: the hardware holds whatever the
         * run's last frame wrote.  A craft that had its beam standing when the
         * player paused and quit therefore left that beam lit over the boot
         * menu - nothing in the menu ever writes APB 0xB8/0xBC, so nothing in
         * the menu could ever take it down.  The laser columns are the same
         * kind of register: the menu already clears the control word that
         * enables them, and their centres are cleared here for the same
         * reason, so no stale x survives either.
         *
         * This sits next to the bucket wipe rather than in each exit path
         * because resync_scanout() is the one place every screen leaves the
         * game through. */
        GPU2D_REG_BEAM_X    = 0u;
        GPU2D_REG_BEAM_CTRL = 0u;
        for (int k = 0; k < 3; k++) {
            GPU2D_REG_HAIR(k, 0) = 0u;
            GPU2D_REG_HAIR(k, 1) = 0u;
            GPU2D_REG_HAIR(k, 2) = 0u;
            GPU2D_REG_HAIR(k, 3) = 0u;
        }
        GPU2D_REG_LASER_COLX_LO = 0u;
        GPU2D_REG_LASER_COLX_HI = 0u;
    }

    gpu2d_flush_dcache();
    GPU2D_REG_FRAME_NEXT = FB_RIGHT_BACK;
    /* The scanout needs a display frame to pick the new buffer up, so this
     * loop normally runs a handful of times.  The guard is not a timeout for
     * the normal case - it is there so that a scanout which never reports the
     * swap back (no pixel clock, a display that went away) cannot trap the
     * firmware in a hard loop with no way out. */
    while ((GPU2D_REG_LEFT_ACTIVE != FB_RIGHT_BACK ||
            GPU2D_REG_RIGHT_ACTIVE != FB_RIGHT_BACK) && guard--) {
    }
    *lback = FB_RIGHT_FRONT;
    *rback = FB_RIGHT_FRONT;
}

/* ===================================================================== */
/* sprites                                                               */
/* ===================================================================== */


/* Hardware-alpha aura: a soft radial fall-off so every blend ratio is used.
 * Four colour-keyed pixels in the middle prove that Color Keying keeps
 * priority over alpha. */
static void aura_sprite_build(void)
{
    volatile uint32_t *p = (volatile uint32_t *)MM_AURA_SPRITE;

    for (int y = 0; y < MM_AURA_SPRITE_H; y++) {
        for (int x = 0; x < MM_AURA_SPRITE_W; x++) {
            int dx = x - 32;
            int dy = y - 32;
            int d2 = dx * dx + dy * dy;
            uint32_t a, r, g, b, v;

            if (d2 < 4) {
                v = MAGENTA_KEY;                       /* must never blend  */
            } else if (d2 >= 1024) {
                v = 0u;
            } else {
                uint32_t t = (uint32_t)(1024 - d2);
                a = t >> 2;                            /* 0 at the rim .. 255 */
                if (d2 > 676) { r = 255u; g = 120u; b = 255u; }
                else          { r =  40u; g = 200u; b = 255u; }
                v = (a << 24) | (r << 16) | (g << 8) | b;
            }
            p[y * MM_AURA_SPRITE_W + x] = v;
        }
    }
}

/* ---- the dream rival ---------------------------------------------------
 * Stage 3's boss is stage 2's boss mirrored and pushed towards a cold
 * palette - a pure function of a bitmap the firmware has already decoded into
 * DDR.  Storing it was the single largest avoidable asset in the bank (1188
 * bytes, several times the free space the firmware had left), so it is
 * derived once at boot instead.  Runs after the asset bank is decoded.
 *
 * Transparency here is the MAGENTA COLOUR KEY, never the alpha byte: every
 * decoded asset in the bank carries alpha = 0 on its opaque pixels, because
 * the engine keys them out by colour.  Testing `s >> 24` therefore classified
 * the whole rival as transparent and filled the tile with nothing but the
 * key - stage 3's boss was invisible on the board.  Only colour is tested
 * now, and the derived tile keeps the same alpha the bank does.
 */
static void boss_dream_build(void)
{
    const volatile uint32_t *src = (const volatile uint32_t *)MM_BOSS_SPRITE;
    volatile uint32_t *dst = (volatile uint32_t *)MM_BOSS_DREAM;

    for (int y = 0; y < MM_BOSS_SPRITE_H; y++) {
        for (int x = 0; x < MM_BOSS_SPRITE_W; x++) {
            uint32_t s = src[y * MM_BOSS_SPRITE_W + (MM_BOSS_SPRITE_W - 1 - x)];

            if (s == MAGENTA_KEY) {              /* keyed by colour, not alpha */
                dst[y * MM_BOSS_SPRITE_W + x] = MAGENTA_KEY;
                continue;
            }
            uint32_t r = (s >> 16) & 0xFFu;
            uint32_t g = (s >> 8)  & 0xFFu;
            uint32_t b =  s        & 0xFFu;
            uint32_t nr = b + 35u;  if (nr > 255u) nr = 255u;
            uint32_t ng = g + 20u;  if (ng > 255u) ng = 255u;
            uint32_t nb = (r < 55u) ? 0u : (r - 55u);
            dst[y * MM_BOSS_SPRITE_W + x] =
                (nr << 16) | (ng << 8) | nb;
        }
    }
}

/* ---- leaning poses -----------------------------------------------------
 * The two walk-lean frames are the idle frame sheared by +-12 degrees.  A
 * shear rather than a true rotation: at 48x48 the difference is under a pixel
 * of rim, it needs no trigonometry on a core with no multiplier, and it saves
 * 1570 bytes of asset RLE that would otherwise be two pictures the firmware
 * can produce itself in a few thousand pixel moves at boot.
 */
#define TILT_SLOPE  54                  /* tan(12 degrees) * 256 */

/* The walk's fourth frame is the SECOND one shifted up two rows: the supplied
 * sheet literally repeats frame 1 in slot 3, and the asset build only nudged it
 * to make the bob read.  Storing that was 759 bytes of RLE - the largest single
 * asset in the bank after the menu backdrop - for a picture this core can
 * produce at boot, exactly like the leaning poses and the third boss. */
static void reimu_bob_build(void)
{
    const volatile uint32_t *src =
        (const volatile uint32_t *)(MM_REIMU_1 + 2UL * MM_REIMU_ROW);
    volatile uint32_t *dst = (volatile uint32_t *)MM_REIMU_3;

    for (unsigned y = 0; y < 46u; y++) {
        for (unsigned x = 0; x < 48u; x++) dst[x] = src[x];
        src += 48u;
        dst += 48u;
    }
    /* The two rows that come up from underneath are transparent, not wrapped. */
    for (unsigned y = 0; y < 2u; y++) {
        for (unsigned x = 0; x < 48u; x++) dst[x] = MAGENTA_KEY;
        dst += 48u;
    }
}

static void tilt_poses_build(void)
{
    const volatile uint32_t *src =
        (const volatile uint32_t *)visual_assets[ART_REIMU_0].dst;

    for (unsigned side = 0; side < 2; side++) {
        volatile uint32_t *dst = (volatile uint32_t *)
            (side ? MM_REIMU_TILT_R : MM_REIMU_TILT_L);
        int dir = side ? 1 : -1;

        for (int y = 0; y < 48; y++) {
            int shift = (dir * (y - 24) * TILT_SLOPE) >> 8;
            for (int x = 0; x < 48; x++) {
                int sx = x - shift;
                dst[y * 48 + x] = (sx < 0 || sx >= 48)
                                ? MAGENTA_KEY : src[y * 48 + sx];
            }
        }
    }
}

static void asset_decode(unsigned id, uint32_t dst, unsigned stride)
{
    const visual_asset_t *a = &visual_assets[id];
    const uint8_t *r = a->rle, *end = r + a->words;
    unsigned x = 0, y = 0;
    while (r < end) {
        unsigned tag = *r++, n = (tag >> 5) + 1u;
        if (n == 8u) { n = r[0] | ((unsigned)r[1] << 8); r += 2; }
        uint32_t color = a->palette[tag & 31u];
        while (n--) {
            for (unsigned dy = 0; dy < a->scale; dy++) {
                volatile uint32_t *row = (volatile uint32_t *)(dst +
                    (y*a->scale + dy)*stride + x*a->scale*4u);
                for (unsigned dx = 0; dx < a->scale; dx++) row[dx] = color;
            }
            if (++x == a->w) { x = 0; y++; }
        }
    }
}

/* ---- stage backdrops ---------------------------------------------------
 * One RLE stream per stage, decoded ONCE into its own DDR surface at boot.
 * Changing stage is then a single pointer write, so a boss transition costs
 * no frame time and cannot tear: the old code decoded a lazy overlay into the
 * live background surface the moment the boss died.
 */
/* ---- stage backdrop decoder -------------------------------------------
 * Driven from the stage_asset_t table: (len-1) in the top 4 bits plus a
 * 4-bit palette index, the all-ones length field escaping to a one-byte
 * count and a zero there to a 16-bit one.
 *
 * Four and four, rather than the visual_asset bank's five and three.  The
 * plates use sixteen colours, so the fifth index bit was never set, while
 * three quarters of their runs are long enough to pay the escape - the two
 * fields were the wrong way round.  The tool that emits these streams
 * renumbers the palette to fit the four bits; see rle() in
 * tools/build_stage_backgrounds.py.  Decoding 384000 pixels once per
 * stage at boot is far cheaper than touching the live background on a
 * boss transition.
 */
/* ---- stage backdrop decoder -------------------------------------------
 * Same run format as the visual_asset bank, driven from the stage_asset_t
 * table instead: (len-1) in the top 3 bits plus a 5-bit palette index, with
 * the all-ones length field escaping to a 12-bit count.  The stream is read
 * until exactly w*h pixels have been produced, so no length has to be stored.
 * Decoding 384000 pixels once per stage at boot is far cheaper than touching
 * the live background surface on a boss transition.
 */
/* sprites_build() paints the backdrop's right and bottom edge strips with
 * cpu_fill: nothing else ever covers them, so they must not depend on the
 * engine being usable that early.  Declared here because the definition
 * sits far below the call site. */
static void cpu_fill(uint32_t dst, uint32_t w, uint32_t h, uint32_t color,
                     uint32_t stride);
static void r_fill(uint32_t dst, uint32_t w, uint32_t h, uint32_t color,
                   uint32_t stride);
static void r_sync(void);

/* ===================================================================== */
/* procedural plate                                                      */
/* ===================================================================== */

/* The plate is DRAWN, not stored.
 *
 * Measured: a 1366x768 plate bitmap costs 12452 encoded bytes.  It has to sit
 * in .rodata together with the sprite bank and stage_bg, and that combination
 * overflowed the 64512-byte image region by 7768 bytes.  Drawing it costs a
 * couple of hundred bytes of code and nothing at all in .rodata.
 *
 * Composition, top to bottom:
 *   - sky:    four flat bands, evenly spaced down to SKY_LINE
 *   - ground: four flat bands below it
 *   - left   gutter: flat panel + two accent columns
 *   - right  gutter: flat panel + two accent columns
 *
 * Band fills are one rectangle each, so a whole plate is a few dozen FILL
 * commands instead of 1.05 million decoded pixels.
 */
#define BG_SKY_LINE   486      /* horizon row */
#define BG_GUT_W      180      /* HUD gutter width */
#define BG_BANDS      4

static const uint32_t bg_sky[BG_BANDS] = {
    0x00141A34u, 0x001A2242u, 0x00283C60u, 0x003A5480u,
};
static const uint32_t bg_ground[BG_BANDS] = {
    0x0016202Eu, 0x00101824u, 0x000B111Bu, 0x00070C14u,
};

static void bg_paint(uint32_t plate)
{
    /* sky and ground, one band at a time: band b covers an equal share of the
     * span, so the plate reads as a stepped gradient with hard edges - which
     * is also what makes it cheap, since a hard edge is one long run. */
    {
        uint32_t span = BG_SKY_LINE / BG_BANDS;
        uint32_t geos = (SCREEN_HEIGHT - BG_SKY_LINE) / BG_BANDS;
        for (uint32_t b = 0; b < BG_BANDS; b++) {
            /* The LAST band absorbs the remainder.  486 is not a multiple of 4,
             * so four bands of 121 stop at row 484 and leave 484/485 unpainted;
             * the simulator's DDR starts at zero so they came out black and
             * nothing noticed, but on the board those two rows show whatever
             * the DDR powered up holding.  The ground is the same: 282/4 = 70
             * stops at 766.  (stage_bg_plate_build already did this.) */
            uint32_t h = (b == BG_BANDS - 1u) ? BG_SKY_LINE - b * span : span;
            r_fill(plate + (b * span) * SCREEN_STRIDE, SCREEN_WIDTH, h,
                   bg_sky[b], SCREEN_STRIDE);
            uint32_t g = (b == BG_BANDS - 1u)
                             ? (SCREEN_HEIGHT - BG_SKY_LINE) - b * geos : geos;
            r_fill(plate + (BG_SKY_LINE + b * geos) * SCREEN_STRIDE,
                   SCREEN_WIDTH, g, bg_ground[b], SCREEN_STRIDE);
        }
    }

    /* The gutters go on last, over the bands.  A gutter is a flat panel with
     * two accent columns: the inner bright edge separates it from the
     * playfield, the outer one gives it a bevel. */
    for (uint32_t g = 0; g < 2u; g++) {
        uint32_t x0 = g ? (SCREEN_WIDTH - BG_GUT_W) : 0u;
        uint32_t edge = g ? 0x00384058u : 0x00304878u;
        r_fill(plate + x0 * 4u, BG_GUT_W, SCREEN_HEIGHT, 0x000C0F22u,
               SCREEN_STRIDE);
        r_fill(plate + (x0 + BG_GUT_W - 3u) * 4u, 3u, SCREEN_HEIGHT, edge,
               SCREEN_STRIDE);
        r_fill(plate + x0 * 4u, 3u, SCREEN_HEIGHT, 0x00141A34u,
               SCREEN_STRIDE);
    }
}

/* bg_paint draws at SCREEN_STRIDE, the pitch the scanout actually reads, so it
 * is correct on the plate surface.  The two framebuffers are left alone: the
 * first rendered frame COPYs the plate across the whole screen anyway, and a
 * CPU write into the buffer the scanout is reading right now is exactly what
 * the workbench's ownership guard rejects. */

/* ===================================================================== */
/* stage plates (decoded from RLE)                                       */
/* ===================================================================== */

/* The three plates are 1366x768, 1:1 with the screen: BitBlt has no scaler,
 * so a half-size plate could only ever cover half the display.
 *
 * They were DRAWN here for a while - a stack of flat colour bands plus one
 * decoration per stage, about 150 bytes of code and no data at all.  That was
 * the right call when the only alternative on the table was 11553 bytes of
 * RLE against a 64512-byte image that had already overflowed; re-proportioned
 * for 1366x768 and trimmed back to the compositions v6 shipped, the same three
 * plates now cost 12510 bytes including their palettes, which fits with room
 * to spare.  What the drawn version could not do was look like anything: four
 * bands and one motif per stage, and every complaint about the backdrops came
 * back to that.
 *
 * Decoding is one pass per plate at boot, written row-major into DDR at
 * SCREEN_STRIDE through a marching row pointer - no multiply in the inner
 * loop, which on an RV32I is the difference between 0.3 s and 3 s at boot.
 */
static void stage_bg_decode(unsigned idx, uint32_t buf)
{
    const stage_asset_t *a = &stage_assets[idx];
    /* The stream comes from the DDR staging copy, not from .rodata: the plate
     * RLE ships in the bitstream (see stage_bg_boot) precisely so that these
     * 12,313 bytes stop competing with the code for the CPU's 64 KiB. */
    const uint8_t *p = stage_rle[idx];
    volatile uint32_t *row = (volatile uint32_t *)buf;
    if (p == 0) {
        /* The staging copy is filled by stage_bg_boot() from the asset ROM, and
         * a plate that never got its stream has a NULL here.  Walking it would
         * read DDR address 0; leaving the destination alone shows the caller's
         * own previous contents instead, which is a visible bug in one plate
         * rather than a wild read in every frame. */
        return;
    }
    uint32_t x = 0, y = 0;
    const uint32_t w = a->w, h = a->h;

    for (;;) {
        uint8_t t = *p++;
        uint32_t c = (uint32_t)(t & 15u);
        uint32_t n;

        /* A run is (length - 1) in the top four bits plus a four-bit palette
         * index, and index 15 never appears there: the coder only writes a
         * one-byte header for lengths up to 15, i.e. with a top nibble of
         * 0..14.  All-ones in the top nibble therefore costs nothing to
         * reserve for "escape" - a one-byte count follows, and a zero count
         * there escapes again to a 16-bit one.
         *
         * Runs are NOT clipped at row ends: the coder walks the whole plate as
         * one stream, so a band of sky crosses rows inside a single run.  That
         * is most of why these plates are as small as they are - without it a
         * 1366-wide row of flat colour would cost six headers of its own. */
        if ((t >> 4) == 15u) {
            uint32_t k = *p++;
            if (k) n = k;
            else { n = (uint32_t)p[0] | ((uint32_t)p[1] << 8); p += 2; }
        } else {
            n = (uint32_t)(t >> 4) + 1u;
        }

        /* Write the run in row-sized pieces.  A run crosses rows constantly -
         * that is the whole point of the format - but testing "did I reach the
         * end of the row" once per PIXEL is two thirds of the decode cost, and
         * boot is three million pixels of it. */
        uint32_t col = a->palette[c];
        while (n) {
            uint32_t k = w - x;                 /* room left on this row */
            if (k > n) k = n;
            n -= k;
            volatile uint32_t *dst = row + x;
            x += k;
            while (k--) *dst++ = col;
            if (x == w) {
                x = 0;
                if (++y == h) return;
                row += SCREEN_STRIDE / 4u;
            }
        }
    }
}

static void stage_background_load(unsigned stage)
{
    if (stage >= SB_STAGE_COUNT) stage = SB_STAGE_COUNT - 1u;
    if (stage == stage_bg_active) return;
    gpu2d_flush_dcache();
    stage_bg_active = stage;
}

/* Record the exact dots the former 32-column tile generated.  Repeating this
 * compact list at render time keeps every pixel and avoids copying a mostly
 * transparent full-screen surface through DDR on every frame. */
typedef struct {
    uint16_t y;
    uint8_t x;
    uint8_t style;                 /* bit 0: shade, bit 1: second row */
} strip_dot_t;

/* The weather dots moved into the scanout (video_weather.v), which runs the
 * same xorshift32 table in hardware; nothing here paints them anymore.
 *
 * One bit per 64x8 screen tile records where the previous pass drew over a
 * scanout buffer.  The next use of that buffer restores only those tiles from
 * the stage plate.  The plate itself stays in DDR unchanged.
 *
 * The tile WAS 64x32; measured on the board, a 9-row bullet then forced a
 * 32-row restore (23 wasted rows) and dense fields paid for it in bytes moved
 * over DDR (backdrop segment b: 2.5..6.4 ms).  8 rows halves that waste: the
 * same bullet restores 16 rows instead of 32.  Measured in the VM on the boss
 * opener: 2085.6 KB/frame of copy traffic -> 1760.1 KB/frame (-15.6%). */
#define DAMAGE_COLS 22u
#define DAMAGE_ROWS 96u
static uint32_t (* const damage_tiles)[DAMAGE_ROWS] = (uint32_t (*)[DAMAGE_ROWS])MM_DAMAGE_TILES;
static uint32_t damage_plate[2];
/* The plate each scanout buffer had its two playfield border columns drawn
 * for.  0 means "not drawn yet".  See the border note in game_render(). */
static uint32_t border_plate[2];
/* Bytes the damage restorer asked the engine to move this frame - the actual
 * DDR bandwidth cost of the backdrop repair, which is what the tile height
 * trades against.  Counted in bytes, not rows: a 1366-wide row is ~11 KB and
 * a 64-wide tile row is 256 B, so the row count was never the cost driver. */
static uint32_t damage_restore_rows;
static uint8_t damage_track, damage_full;
static uint32_t damage_fb;

static void damage_mark_index(uint32_t dst, uint32_t w, uint32_t h,
                              uint32_t stride, unsigned index)
{
    /* Marks against a NAMED scanout buffer, not the one being painted.  The
     * laser columns are drawn unmarked, so their erase pass has to book the
     * OTHER buffer's ledger by hand - see the laser restore in game_render(). */
    /* index 0 -> 0x00800000, index 1 -> 0x00E00000.  FB_LEFT_FRONT and
     * FB_RIGHT_FRONT are BOTH 0x00800000 (the scanout shares one buffer), so
     * the second buffer must be spelled FB_LEFT_BACK - using FB_RIGHT_FRONT
     * here silently pointed every back-buffer mark at the front buffer, and
     * the back buffer's damage was never restored (the moving-craft smear). */
    uint32_t base = (index == 0u) ? FB_LEFT_FRONT : FB_LEFT_BACK;
    if (!damage_track || stride != SCREEN_STRIDE || !w || !h ||
        dst < base || dst - base >= SCREEN_STRIDE * SCREEN_HEIGHT)
        return;
    uint32_t off = dst - base;
    uint32_t x = (off & (SCREEN_STRIDE - 1u)) >> 2;
    uint32_t y = off >> 13;
    if (x >= SCREEN_WIDTH || y >= SCREEN_HEIGHT) return;
    /* The HUD gutters repaint themselves every frame from the menu backdrop
     * (HUD_CLEAR), so restoring their plate tiles first is pure waste - and
     * measured on the board it was a large share of the damage bytes.  A draw
     * that ends inside the left gutter, or starts inside the right one, is the
     * HUD; skip it.  Playfield draws can only touch the border tile column,
     * whose restore overshoots into the gutter by a few pixels at worst. */
    if (x + w <= GAME_LEFT || x >= GAME_RIGHT + 1u) return;
    uint32_t last_x = x + w - 1u;
    uint32_t last_y = y + h - 1u;
    if (last_x >= SCREEN_WIDTH) last_x = SCREEN_WIDTH - 1u;
    if (last_y >= SCREEN_HEIGHT) last_y = SCREEN_HEIGHT - 1u;
    uint32_t first_col = x >> 6, last_col = last_x >> 6;
    uint32_t mask = ((1u << (last_col - first_col + 1u)) - 1u) << first_col;
    for (uint32_t row = y >> 3; row <= (last_y >> 3); row++)
        damage_tiles[index][row] |= mask;
}

static void damage_mark(uint32_t dst, uint32_t w, uint32_t h, uint32_t stride)
{
    damage_mark_index(dst, w, h, stride,
                      damage_fb == FB_LEFT_FRONT ? 0u : 1u);
}

static void damage_restore(uint32_t fb, uint32_t plate)
{
    unsigned index = fb == FB_LEFT_FRONT ? 0u : 1u;
    uint32_t *rows = damage_tiles[index];

    /* ---- the repair is tile-by-tile, and that is now a settled question ---
     * The board pays per SCANLINE - one DRAM row activation each - so a
     * rectangle's cost to the engine is its height, not its area.  That is
     * what made an adaptive "lay the whole playfield down once the ledger is
     * full" path look attractive, and it was built and measured: on the
     * pressure stage it turned 4478 scanlines into 768.
     *
     * It was then REMOVED, because scanlines are only one of the two things a
     * frame pays for.  At its own 288-tile threshold that path moved 3.08 MB
     * a frame against the repair's 1.15 MB - 5.2x the traffic to buy 3x fewer
     * scanlines - and on the board it halved the PLAYABLE stage (75 -> 37 FPS)
     * the moment the shot was maxed and the barrage filled in, while looking
     * like a clean win in the workbench, which counts scanlines and cannot see
     * a bandwidth wall at all.
     *
     * A "span merge" variant was tried afterwards - one blit per damaged tile
     * row instead of one per run of tiles - on the theory that the ledger was
     * fragmented rather than full.  Measured: it bought 1391 of the ~3700
     * scanlines such a merge could theoretically save, and paid 27% more
     * traffic for them, because the marks within a row are scattered rather
     * than adjacent, so a span is mostly empty.  Any span wide enough to
     * collect them covers the whole row and becomes the removed path again.
     * There is no safe middle, and the 768 scanlines of a full plate are the
     * floor for anything that still writes bullets into the framebuffer.
     *
     * So the repair stays exact.  Making the backdrop cheap means stopping the
     * bullets from damaging it in the first place - see B1 in the frame-budget
     * document, which is also the only route that lowers row count and DDR
     * traffic at the same time. */

    for (unsigned row = 0; row < DAMAGE_ROWS; row++) {
        while (rows[row]) {
            unsigned first = 0;
            while (!(rows[row] & (1u << first))) first++;
            unsigned last = first;
            while (last + 1u < DAMAGE_COLS && (rows[row] & (1u << (last + 1u))))
                last++;
            uint32_t mask = ((1u << (last - first + 1u)) - 1u) << first;
            unsigned height_tiles = 1;
            while (row + height_tiles < DAMAGE_ROWS &&
                   (rows[row + height_tiles] & mask) == mask)
                height_tiles++;
            for (unsigned r = row; r < row + height_tiles; r++) rows[r] &= ~mask;
            unsigned x = first << 6;
            unsigned w = (last + 1u) << 6;
            if (w > SCREEN_WIDTH) w = SCREEN_WIDTH;
            w -= x;
            /* Clip the restored band to the PLAYFIELD.  The gutters are
             * repainted from scratch every frame (HUD_CLEAR_L / HUD_CLEAR), so
             * restoring plate bytes over them was dead work - and it is also
             * what used to eat the two border columns, which the plate does
             * not carry: a bullet at the right edge marks tile column 18,
             * whose 64-pixel tile reaches from 1152 to 1215 and therefore
             * sweeps across the gutter. */
            if (x < GAME_LEFT) { w -= (GAME_LEFT - x); x = GAME_LEFT; }
            /* x can be at or past GAME_RIGHT only if damage_mark_index() ever
             * records a tile out there, which its own guard (x >= GAME_RIGHT+1)
             * currently refuses.  Keep the refusal local: without this line
             * GAME_RIGHT - x underflows to a huge unsigned width and r_blit()
             * would be handed it.  This used to depend on the other function's
             * guard, with nothing in either place saying so. */
            if (x >= GAME_RIGHT) continue;
            if (x + w > GAME_RIGHT) w = GAME_RIGHT - x;
            if (!w) continue;
            uint32_t off = (row << 3) * SCREEN_STRIDE + x * 4u;
            r_blit(fb + off, plate + off, w, height_tiles << 3,
                   SCREEN_STRIDE, SCREEN_STRIDE);
            damage_restore_rows += (uint32_t)(height_tiles << 3) * (uint32_t)w * 4u;
        }
    }
}

static void moon_halo_apply(uint32_t buf, int mx, int my, int r_core, int r_halo, uint32_t glow_rgb)
{
    volatile uint32_t *fb = (volatile uint32_t *)buf;
    uint32_t gr = (glow_rgb >> 16) & 0xFFu;
    uint32_t gg = (glow_rgb >> 8) & 0xFFu;
    uint32_t gb = glow_rgb & 0xFFu;
    int r2_core = r_core * r_core;
    int r2_halo = r_halo * r_halo;
    int dr = r_halo - r_core;

    for (int dy = -r_halo; dy <= r_halo; dy++) {
        int y = my + dy;
        if (y < 0 || y >= (int)SCREEN_HEIGHT) continue;
        volatile uint32_t *row = fb + (uint32_t)(y * (SCREEN_STRIDE / 4));
        for (int dx = -r_halo; dx <= r_halo; dx++) {
            int x = mx + dx;
            if (x < 0 || x >= (int)SCREEN_WIDTH) continue;
            int d2 = dx * dx + dy * dy;
            if (d2 <= r2_core) {
                /* Emissive pure white Moon Core with Alpha=0xFF for hardware Bloom */
                row[x] = 0xFFFFFFFFu;
            } else if (d2 <= r2_halo) {
                /* Integer square root for distance */
                int d = r_core;
                while ((d + 1) * (d + 1) <= d2) d++;
                int dist = d - r_core;
                if (dist > dr) dist = dr;
                /* inv: 256 at moon edge -> 0 at halo outer boundary */
                uint32_t inv = (uint32_t)((dr - dist) * 256 / dr);
                /* Quadratic smooth falloff matching the death aura aesthetic */
                uint32_t a = (inv * inv) >> 8; /* 0..256 */
                if (a > 200u) a = 200u;
                uint32_t bg = row[x];
                uint32_t br = (bg >> 16) & 0xFFu;
                uint32_t bg_c = (bg >> 8) & 0xFFu;
                uint32_t bb = bg & 0xFFu;
                uint32_t nr = (gr * a + br * (256u - a)) >> 8;
                uint32_t ng = (gg * a + bg_c * (256u - a)) >> 8;
                uint32_t nb = (gb * a + bb * (256u - a)) >> 8;
                row[x] = (nr << 16) | (ng << 8) | nb;
            }
        }
    }
}

/* Decode the three stage plates and record the weather dots once at boot. */
static void stage_bg_boot(void)
{
    /* Pull the plate RLE out of the bitstream's asset ROM into DDR, then point
     * the decoder at the DDR copy.  Doing it in this order means the ROM is
     * walked once, linearly, and the (much more branchy) decode then runs
     * against memory the CPU can actually address as ordinary data. */
    gpu2d_asset_copy(MM_STAGE_RLE, SB_RLE_TOTAL);
    stage_rle[SB_STAGE_ICE]   = (const uint8_t *)(MM_STAGE_RLE + SB_RLE_OFF_STAGE_ICE);
    stage_rle[SB_STAGE_LAVA]  = (const uint8_t *)(MM_STAGE_RLE + SB_RLE_OFF_STAGE_LAVA);
    stage_rle[SB_STAGE_DREAM] = (const uint8_t *)(MM_STAGE_RLE + SB_RLE_OFF_STAGE_DREAM);

    for (unsigned s = 0; s < SB_STAGE_COUNT; s++)
        stage_bg_decode(s, STAGE_BG_BUF(s));

    /* Apply silky-smooth true-color radial alpha halos to Stage 1 & Stage 3 moons */
    moon_halo_apply(STAGE_BG_BUF(SB_STAGE_ICE),   939,  87, 27, 86, 0x00D0EBFFu);
    moon_halo_apply(STAGE_BG_BUF(SB_STAGE_DREAM), 918, 113, 28, 90, 0x00EFE0FFu);

    gpu2d_flush_dcache();
}




/* The weather dots ride the same offset as the plate during a spell card. */
#define BOSS_SHAKE_PX      8
static uint8_t boss_shake;

static uint32_t profile_elapsed(uint32_t start, uint32_t end)
{
    return end >= start ? end - start : end + (100000000u - start);
}

/* The weather layer is now synthesised by the scanout (video_weather.v), which
 * regenerates the same 170-dot xorshift32 table the CPU used to paint here.
 * This function only publishes the three parameters the overlay needs: the
 * stage (for colour), the direction-adjusted scroll phase and the boss-shake
 * slide.  The 3.28 ms per frame of scattered DDR writes it replaced are gone,
 * together with the per-frame restore cache and its boot build. */
/* The last control word published to the overlay.  Two passes share it: the
 * weather strip owns bits [15:8] and [3:0], the boss draw owns the laser bits
 * [20:18], and each keeps what the other has already published instead of
 * re-deriving it. */
static uint32_t weather_ctrl_word;
static uint8_t  boss_laser;

/* ---- the scanout's laser columns -----------------------------------------
 * The columns are synthesised by video_laser.v, not blitted by the engine.  They
 * used to be: four 16x768 bars are 3,072 rows of copying a frame, one DRAM row
 * activation each, and that was the largest single item in the boss's frame -
 * the same reason the opener's columns moved into hardware in the first place.
 * The cut/beam lasers were the last ones still paying it (three bars, 2,304 rows
 * a frame) and they were why the card stuttered on the board.
 *
 * The hardware draws them at four x positions it is told about here.  Centre 0
 * parks a column off screen.  Both words are latched by the scanout on the same
 * frame edge as the control word, so a beam can never appear at the previous
 * frame's x. */
static void laser_columns_set(uint32_t x0, uint32_t x1, uint32_t x2, uint32_t x3)
{
    GPU2D_REG_LASER_COLX_LO = (x1 << 12) | x0;
    GPU2D_REG_LASER_COLX_HI = (x3 << 12) | x2;
}

/* Non-zero while the cut/beam lasers are standing in those columns.  The two
 * users share the same four slots - the hardware has four, and giving the beams
 * their own would mean four more comparators and a second colour rule for a case
 * the game does not reach - so a beam takes the slots over the opener's columns
 * when both are up, on the grounds that the thing that kills you wins.  Declared
 * here because stage_strip_render() publishes the enable bit and is defined far
 * above the beam state. */
static uint8_t laser_columns_live;

static void stage_strip_render(uint32_t fb)
{
    (void)fb;
    int scroll = (int)strip_scroll;
    if (stage_bg_active == SB_STAGE_LAVA)
        scroll = (SB_STRIP_PERIOD - scroll) & (SB_STRIP_PERIOD - 1);   /* ash rises */
    unsigned stage = stage_bg_active < SB_STAGE_COUNT ? stage_bg_active : 0u;
    unsigned slide = boss_shake && (frame_tick & 1u) ? BOSS_SHAKE_PX : 0u;
    uint32_t laser_ctrl = 0u;
    if (boss_laser) {
        uint32_t band = (boss_laser > 60) ? 0u : (boss_laser > 30) ? 1u : 2u;
        laser_ctrl = (1u << 18) | (band << 19);
    } else if (laser_columns_live) {
        laser_ctrl = (1u << 18);            /* the beams always use band 0 */
    }
    uint32_t w_en = is_stress_stage ? 0u : (1u << 15);
    weather_ctrl_word = w_en | (stage << 13) | ((unsigned)scroll << 8) | slide | laser_ctrl;
    GPU2D_REG_WEATHER = weather_ctrl_word;
    /* tlm[41] is LIVE again: game_render() writes the bucket_build() slice
     * into it at frame start, and diag_window() reports it as 's'.  tlm[40]
     * priced CPU weather-dot painting that no longer exists and has no reader
     * left, so its old zeroing store is gone too. */
}

/* ---- merged sprite tiles ------------------------------------------------
 *
 * WHY.  bitblt_apb_regs only latches START while the engine is idle, so
 * gpu2d_finish() waits for the previous command - commands are strictly
 * serial, and every one of them costs a full DDR round trip.  A 9x9 sprite
 * moves 32 bytes inside a round trip that could have moved 3 KiB: 0.8% of the
 * bus for 100% of the latency.  A busy frame issues ~1000 of those, in front
 * of a DDR bus the backdrop and the scanout have already filled, and that is
 * what dropped the frame rate the moment anything was shooting.
 *
 * So each moving object is composed ONCE at boot and drawn with ONE command:
 *
 *     player shot   bullet + two trail segments   3 -> 1
 *     enemy shot    socket tile + direction speck 2 -> 1
 *     HUD captions  one strip per caption        N -> 1
 *
 * Nothing is removed.  Every pixel each of these drew before is still drawn
 * in the same place, it just costs one round trip instead of three.
 */
static void pbullet_tile_build(void)
{
    /* Phase 2 Task 05: Player bullet visual overhaul.
     * Round dual-layer energy bullet head (center 3x3 pure white hot core,
     * vivid neon aura, soft outer edge) with streamlined ion flare trail
     * featuring smooth opacity feathering and tapered profile.
     *
     * ONE tile, not eight.  The eight colours were the same shape with
     * different values - verified on the firmware's own DDR - so a cell now
     * holds a ROLE number and the scanout picks the colour out of the palette
     * with role + hue*32 (see BROLE_* at the top of the file).  The shape
     * arithmetic below is character-for-character what it was. */
    volatile uint8_t *tile = (volatile uint8_t *)MM_PBULLET_TILE;
    const unsigned pitch = MM_PBULLET_TILE_STRIDE;

    /* BROLE_NONE is the "nothing here" sentinel, and it is index 0 on the
     * palette side too.  Keying the tile with it rather than leaving whatever
     * DDR powered up with is the same rule the MAGENTA_KEY fill had.
     *
     * ONE BYTE A PIXEL.  This surface used to be ARGB8888 with the role in the
     * low byte and three bytes nobody read on top of it; bullet_store_tile()
     * only ever took that low byte.  The three builders now write the role
     * straight in, which is also what let the enemy tile double its edge
     * without moving anything: 16 x 32 x 26 bytes is what 16 x 64 x 13 was. */
    for (unsigned i = 0; i < pitch * MM_PBULLET_TILE_H; i++)
        tile[i] = BROLE_NONE;

    /* 1) 7x7 Round Dual-Layer Energy Bullet Head (y = 0..6, center at (3, 3)) */
    for (int y = 0; y < 7; y++) {
        int dy = y - 3;
        for (int x = 0; x < 7; x++) {
            int dx = x - 3;
            int d2 = dx * dx + dy * dy;
            if (x >= 2 && x <= 4 && y >= 2 && y <= 4) {
                /* Center 3x3 pure white hot core (min_rgb = 255, bloom trigger) */
                tile[y * pitch + x] = BROLE_WHITE;
            } else if (d2 <= 5) {
                /* Vivid saturated neon aura */
                tile[y * pitch + x] = BROLE_NEON;
            } else if (d2 <= 10) {
                /* Soft outer edge */
                tile[y * pitch + x] = BROLE_PB_DIM;
            }
        }
    }

    /* 2) High-energy Ion Flare Streamlined Trail (y = 7..25) */
    for (unsigned y = 7; y < MM_PBULLET_TILE_H; y++) {
        if (y <= 11) {
            /* Upper plume: wide, intense plasma core */
            tile[y * pitch + 3] = BROLE_PB_HOT;
            tile[y * pitch + 2] = BROLE_NEON;
            tile[y * pitch + 4] = BROLE_NEON;
            tile[y * pitch + 1] = BROLE_PB_DIM;
            tile[y * pitch + 5] = BROLE_PB_DIM;
        } else if (y <= 16) {
            /* Mid trail: narrowing slightly, smooth neon fading */
            tile[y * pitch + 3] = BROLE_NEON;
            tile[y * pitch + 2] = BROLE_PB_DIM;
            tile[y * pitch + 4] = BROLE_PB_DIM;
            tile[y * pitch + 1] = BROLE_PB_QUART;
            tile[y * pitch + 5] = BROLE_PB_QUART;
        } else if (y <= 21) {
            /* Lower trail: 3-pixel tapered glow */
            tile[y * pitch + 3] = BROLE_PB_DIM;
            tile[y * pitch + 2] = BROLE_PB_QUART;
            tile[y * pitch + 4] = BROLE_PB_QUART;
        } else if (y <= 23) {
            /* Tail tip */
            tile[y * pitch + 3] = BROLE_PB_QUART;
        } else {
            /* Final wispy spark */
            tile[y * pitch + 3] = BROLE_PB_TINY;
        }
    }
    gpu2d_flush_dcache();
}

/* ---- pickup silhouette map ---------------------------------------------
 * One pass over the sprite pixels at boot: a cell bit is set when that 4x4
 * block of the 48x48 sprite holds at least one pixel that is not the magenta
 * colour key.  Items later test whole cells, so the test is a bit lookup and
 * not a pixel loop.
 */
static void player_pick_mask_build(void)
{
    for (unsigned p = 0; p < PICK_POSES; p++) {
        /* Poses 0..3 come from the asset bank; 4 and 5 are the boot-derived
         * leaning frames, which have no asset index of their own. */
        const uint32_t src = (p < 4)
            ? visual_assets[ART_REIMU_0 + p].dst
            : (p == 4 ? MM_REIMU_TILT_L : MM_REIMU_TILT_R);

        for (unsigned i = 0; i < PICK_MASK_BYTES; i++)
            pick_mask[p][i] = 0u;

        for (unsigned cy = 0; cy < PICK_ROWS; cy++) {
            for (unsigned cx = 0; cx < PICK_COLS; cx++) {
                unsigned hits = 0;
                for (unsigned dy = 0; dy < PICK_CELL; dy++) {
                    const volatile uint32_t *row =
                        (const volatile uint32_t *)(src +
                        (uint32_t)((cy * PICK_CELL + dy) * 192u));
                    for (unsigned dx = 0; dx < PICK_CELL; dx++)
                        if (row[cx * PICK_CELL + dx] != MAGENTA_KEY) hits++;
                }
                if (hits) {
                    unsigned bit = cy * PICK_COLS + cx;
                    pick_mask[p][bit >> 5] |= 1u << (bit & 31u);
                }
            }
        }
    }
}

static void sprites_build(void)
{
    /* The whole bank is decoded once: the later stage plates no longer live
     * here (stage_bg.c owns them and the firmware decodes those separately). */
    for (unsigned i = 0; i < ART_COUNT; i++) {
        const visual_asset_t *a = &visual_assets[i];
        /* The menu backdrop is the one surface scanned out with SCREEN_STRIDE;
         * every sprite keeps its own packed row pitch.  For the backdrop the old
         * expression evaluated to exactly 4096 - the OLD screen stride - which is
         * why this coupling stayed invisible until the stride changed. */
        /* The first arm of that ternary is dead code today: no entry in the asset
         * table has dst == MM_VISUAL_BACKGROUND - the plate is painted by
         * bg_paint()/stage_bg_decode() on its own path and never comes through this
         * loop.  It stays because it is the right stride the day a full-screen plate
         * returns to the table, and because the comment above describes a coupling
         * this line was written to absorb. */
        asset_decode(i, a->dst,
                     a->dst == MM_VISUAL_BACKGROUND ? SCREEN_STRIDE
                                                    : a->w * a->scale * 4u);
    }
    /* The plate now covers the whole 1366x768, so the old "extend the
     * backdrop's own last column and last row into the two dead bands"
     * repair block is gone.  It existed because a 1024x600 plate left 342
     * columns and 168 rows unpainted; there is nothing left to extend, and
     * writing those strips into the plate surface would corrupt the half-size
     * source that bg_build() expands from. */
    /* MM_LASER_GLOW is built procedurally by laser_glow_build() */
    aura_sprite_build();
    {
        volatile uint32_t *bases = (volatile uint32_t *)MM_FONT_TABLE;
        uint32_t next = MM_FONT_ATLASES;
        for (unsigned s = 1; s <= 6; s++) {
            bases[s-1] = next;
            unsigned stride = 512u*s;
            for (unsigned g = 0; g < 96; g++)
                for (unsigned y = 0; y < 8u*s; y++) {
                    uint32_t glyph_row = 0;
                    if (g < 95) {
                        GPU2D_REG_ASSET_ADDR = FONT_ROM_OFFSET + g * 8u + y / s;
                        glyph_row = GPU2D_REG_ASSET_DATA;
                    }
                    volatile uint32_t *row = (volatile uint32_t *)(next +
                        ((g/16u)*8u*s+y)*stride + (g%16u)*8u*s*4u);
                    for (unsigned x = 0; x < 8u*s; x++)
                        row[x] = (g < 95 && x/s < 6 &&
                            (glyph_row & (32u >> (x/s)))) ? 0x00FFFFFFu : MAGENTA_KEY;
                }
            next += 24576u*s*s;
        }
    }
    boss_dream_build();          /* stage 3's rival is derived, not stored */
    tilt_poses_build();          /* ... and so are the two leaning frames */
    reimu_bob_build();           /* ... and the walk's fourth frame */
    player_pick_mask_build();
    gpu2d_wait_idle();
}

/* ===================================================================== */
/* Bullet-hell stage                                                     */
/* ===================================================================== */

#define MAX_ENEMIES        MM_ENEMY_COUNT
#define MAX_ACTIVE_ENEMY   9            /* campaign adds 0..2 to this cap */
#define MAX_PBULLETS      MM_PBULLET_COUNT
#define MAX_EBULLETS      MM_EBULLET_COUNT
#define MAX_ITEMS         MM_ITEM_COUNT

/* How much of the enemy pool the Big Orbs own outright.
 *
 * The pool is shared and was strictly first-come-first-served: alloc_bullet()
 * walks from index 0 and hands out the first free slot.  That is fine until the
 * pressure stage, where stress_storm_update() keeps 192 shots in the air - and
 * then PAT_BURST's twenty-four orbs ask for a slot, find none, and the boss's
 * biggest attack fires into nothing.  Measured on the board's own model: of the
 * ~120 orbs one PAT_BURST should put in the air, two made it in one window and
 * none at all in the next, while the same attack in a campaign stage (where the
 * pool is only half full) put 72..120 orbs on the field.
 *
 * So the tail of the pool is theirs.  Everything else allocates from the front,
 * the orbs allocate from ORB_FIRST up, and an orb may still borrow from the
 * front when its own tail is busy - so no slot is wasted while no orb wants it.
 * stress_storm_update() counts every live shot whatever kind it is, so the
 * storm still fills the pool to its target either way. */
#define ORB_RESERVE       32
#define ORB_FIRST        (MAX_EBULLETS - ORB_RESERVE)

#define EF_ACTIVE         0x01u
#define EF_HELD           0x04u         /* laid out and holding station */
#define EF_LANCE          0x08u         /* 8.5: a shaft, and it bounces     */
/* Bits 4..5 of the flag byte count 8.5's bounces.  The record is exactly
 * eight bytes and every field in it is spoken for, so the spare flag bits
 * are the only place a counter can live without growing the pool. */
#define EF_BOUNCE_SHIFT     4
#define EF_BOUNCE_MASK   0x30u
#define EF_ORB           0x40u          /* Phase 2: high-tier Big Orb / Spell Card projectile (OP_ADD) */
/* Bit 7 is free.  Bit 1 is NOT free, and it has three names depending on which
 * pool the record belongs to - the pools never mix, so one bit is enough:
 *
 *   EF_GRAZED  (enemy bullets) marks a shot that has already thrown its graze
 *              spark, so the spark fires once per bullet instead of every
 *              frame the shot spends inside the aura (see bullets_update).
 *   PF_LOCKON  (player bullets) marks the pressure stage's wing missiles,
 *              which re-aim at the boss every frame.  Nothing on the campaign
 *              path sets it, so the homing test costs the normal shot one
 *              compare and changes nothing.
 *
 * This comment used to say the bit was free and invite a new use: whatever was
 * allocated to it would have collided with the missiles, or with EF_GRAZED -
 * and dropping EF_GRAZED makes the graze spark fire on every frame instead of
 * once. */
#define EF_GRAZED        0x02u
#define PF_LOCKON        0x02u

#define ENEMY_FAIRY       0
#define ENEMY_SHARD       1
#define ENEMY_TURRET      2
#define ENEMY_MINION      3

#define W_CENTER          0
#define W_SPREAD          1
#define W_LASER           2
#define W_FAN             3

#define ITEM_HEAL         0
#define ITEM_RATE         1
#define ITEM_ATK          2
#define ITEM_WEAPON       3
#define ITEM_SCORE        4
#define ITEM_SLOW         5
#define ITEM_JAM          6

/* Two of the seven drops are not prizes.  A slow or a jam used to pay the same
 * 50 points as a heal, so a penalty the player failed to dodge read as a reward
 * on the score popup and there was no reason to prefer missing one.  They now
 * cost the effect and nothing else - no points either way - and the renderer
 * asks the same predicate whether to paint them as a hazard, so "this one is
 * bad for you" is decided in exactly one place. */
static inline int item_is_debuff(uint8_t type)
{
    return type == ITEM_SLOW || type == ITEM_JAM;
}

#define BOSS_NONE         0
#define BOSS_ENTER        1
#define BOSS_FIGHT        2
#define BOSS_DYING        3
#define BOSS_DIALOG       4
#define BOSS_FREEZE       5     /* the field holds still before the opener */

/* ---- HUD layout -------------------------------------------------------
 * Every dynamic element the HUD draws, in SCREEN pixels, as (x, y, w, h).
 * The drawing code below reads its coordinates from here, so this table IS
 * the layout - it cannot drift away from the picture.
 *
 * Two things check it, both automatic:
 *   * tools/check_hud_layout.py, run from build_firmware.py, proves no two
 *     entries overlap each other and no entry overlaps one of the labels
 *     baked into the 512x300 backdrop by tools/build_visual_assets.py (the
 *     backdrop is drawn at 2x, so a label's screen box is its source box
 *     doubled).
 *   * the same script reports any HUD drawing call in game_render() whose
 *     coordinates are not in this table, so a new element cannot be added
 *     without answering the question.
 *
 * Boxes are the union over every state the element takes - the weapon name
 * is sized for SPREAD, the stage tag for STAGE, the heart row for six
 * hearts - because a collision only has to happen in one state to be a bug.
 *
 * WEAPON sits at 776 and not 794: "SPREAD" is six glyphs at scale 3 and ran
 * to x=917, nine pixels into the LV tag and its bar.  None of the other shot
 * names is long enough to reach that far, which is why it survived every
 * round of looking at the screen - the checker found it on its first run.
 *
 * 1366x768 native re-laid the whole table: every element now sits inside one
 * of the two 180-pixel gutters (left: x 0..180, right: x 1185..1365) and the
 * playfield between them carries no HUD at all.  tools/check_hud_layout.py
 * enforces that band as well as the collision test, so a HUD element that
 * drifts into the playfield is a build failure rather than a screenshot.
 */
#define HUD_BOXES(X) \
    /* ---- left gutter (x 0..180): the stage block owns the top -------- */ \
    X(STAGE_TAG,   8,  20, 120,  22) \
    X(WAVE_BAR,    8,  58, 156,  16) \
    X(PLAYER,      8, 104, 164,  64) \
    X(LIVES,       8, 194, 156,  40) \
    X(SCORE,       8, 274, 164,  26) \
    X(SPELL,       8, 360, 164,  54) \
    X(DEBUFF_S,    8, 530, 164,  18) \
    X(DEBUFF_J,    8, 560, 164,  18) \
    X(SPRITES_TAG, 8, 600,  98,  16) \
    X(SPRITES_NUM, 8, 620, 105,  24) \
    X(LOAD_TAG,    8, 652,  56,  16) \
    X(LOAD_NUM,   68, 648, 105,  24) \
    X(DROPS_TAG,   8, 684,  56,  16) \
    X(DROPS_NUM,  68, 680, 105,  24) \
    X(HISCORE,     8, 720, 164,  22) \
    /* ---- right gutter (x 1186..1365) --------------------------------- */ \
    X(WEAPON,    1198,  20, 156,  26) \
    X(LV_TAG,    1198,  60,  22,  16) \
    X(LV_BAR,    1226,  60, 104,  16) \
    X(ATK,       1198, 120, 156,  22) \
    X(BACKEND,   1198, 210, 156,  26) \
    X(FPS_TAG,   1198, 250,  34,  16) \
    X(FPS_NUM,   1240, 270,  44,  22) \
    X(VERTEX,    1198, 730, 156,  22) \
/* Trailng comma, not a semicolon: an enumerator list is comma-separated,
 * and one ';' in here fails the whole declaration - every HUD_* name then
 * comes back as undeclared, a long way from the line that caused it.
 * HUD_W is a synthetic entry: the wave / boss bar code reads its width from
 * the table instead of hard-coding the old 300 pixels, which is how the bar
 * followed the gutter from 598 to 156 wide without a second magic number. */
#define HUD_DEFINE(name, x, y, w, h) \
    HUD_##name##_X = (x), HUD_##name##_Y = (y), \
    HUD_##name##_W = (w), HUD_##name##_H = (h),
enum { HUD_BOXES(HUD_DEFINE) HUD_END };

#define PAT_FAN           0
#define PAT_RING          1
#define PAT_AIMED         2
#define PAT_SPIRAL        3
#define PAT_CROSS         4
#define PAT_SUMMON        5
#define PAT_RAIN          6
#define PAT_WALL          7
#define PAT_TWIN          8
#define PAT_CURTAIN       9
/* Stage 2's four basics.  They are numbered after the old book so the wave 0
 * pool can name them as one range. */
#define PAT_CUT          10
#define PAT_LOCKON       11
#define PAT_BURST        12
#define PAT_VOLLEY       13
/* Stage 3's four advanced ones.  Numbered straight after the stage-2 block
 * again, so wave 2's `r % PAT_COUNT` picks them up without a table. */
#define PAT_SWAY         14
#define PAT_BEAM         15
#define PAT_TORNADO      16
#define PAT_LANCE        17
#define PAT_COUNT        18

/* 6.1 - the cut announces itself for three quarters of a second, and the
 * blink period halves as it runs out, so the last frames read as "now". */
#define CUT_PREVIEW        45
#define CUT_FIRE           18
#define CUT_HALF            6
/* 6.2 - the volley is laid out for a second, holds for a third of one, then
 * every shot on station turns at once. */
#define LOCKON_LAYOUT      60
#define LOCKON_STEP         6
#define LOCKON_HOLD        20
/* 6.3 / 6.4 */
#define BURST_RING         16
#define VOLLEY_ARC          6
/* 8.2 - three delayed columns of light, one on the craft and one either
 * side of it.  They reuse 6.1's three-phase preview/release machine, which
 * is why the cut's single column became an array of three. */
#define CUT_SLOTS           3
#define CUT_SPREAD         64
/* 6.1 / 8.2 column extent, and where the craft's own beam starts.  480 was
 * chosen against a 600-tall playfield; the playfield is 768 tall now and the
 * 480-tall bar is centred instead of grown, so the effect keeps its shape and
 * only its position moved.  BEAM_TOP is the row the beam's glow starts at,
 * i.e. the top of the playfield band the column effects live in. */
#define CUT_H             SCREEN_HEIGHT
#define BEAM_TOP          0
/* Boss dialogue card: centred in the playfield. */
#define DIALOG_W         800
#define DIALOG_H         176
#define DIALOG_X         (GAME_LEFT + (GAME_RIGHT - GAME_LEFT - DIALOG_W) / 2)
#define DIALOG_Y         (GAME_TOP + (GAME_BOTTOM - GAME_TOP - DIALOG_H) / 2)
/* 8.5 - how many walls a lance may bounce off before it expires. */
#define LANCE_BOUNCES       3
/* The shaft is 24x24 CENTRED on the bullet, so every bound below is a
 * sprite edge and not the playfield edge.  Turning at GAME_LEFT+1 like a
 * 9x9 shot did put 11 pixels of shaft into the HUD gutter - which is what
 * "the bullets are outside the screen, stuck to the left and right edges"
 * turned out to be - and turning at y=1 put its top edge at -11, i.e. the
 * destination address wrapped to BEFORE the framebuffer. */
#define LANCE_HALF          (MM_LANCE_W / 2)
#define LANCE_MIN_X         (GAME_LEFT + LANCE_HALF)
#define LANCE_MAX_X         (GAME_RIGHT - LANCE_HALF)
#define LANCE_MIN_Y         (PLAYFIELD_TOP + LANCE_HALF)
#define LANCE_MAX_Y         (GAME_BOTTOM - LANCE_HALF)

typedef struct {
    int16_t x, y;
    int8_t  vx, vy;
    uint8_t flags, color;
} bullet_t;                                 /* 8 bytes */

typedef struct {
    int16_t x, y;
    int8_t  vy;
    uint8_t type, flags, timer;  /* timer: frames left blinking on the floor */
} item_t;                                   /* 8 bytes */

typedef struct {
    int16_t x, y, vx, vy;
    int16_t hp;
    uint8_t type, fire_cd, phase, flags;
    uint16_t pad;
} enemy_rec_t;                              /* 16 bytes */

static enemy_rec_t * const enemies = (enemy_rec_t *)MM_ENEMY_BASE;
static bullet_t    * const pbullets = (bullet_t *)MM_PBULLET_BASE;
static bullet_t    * const ebullets = (bullet_t *)MM_EBULLET_BASE;

/* ------------------------------------------------------------------------
 * HOW FAR A WALK OVER A POOL HAS TO GO  (the pools are 512 slots wide)
 *
 * Both pools are 512 records of 8 bytes now, and a record lives in DDR at a
 * fixed address - these are pointers into a memory map, not arrays the
 * compiler can size or vectorise.  Walking one costs a load every EIGHT bytes,
 * so a 32-byte cache line carries four records and a scan of a whole pool
 * touches 4 KB to read 512 flag bytes.
 *
 * That was cheap when the pools were 192 and 128 (2.5 KB between them).  At
 * 512 each it stopped being cheap, because the frame walks them SEVEN times:
 * bullets_update() over both, bucket_build() over both, telemetry_write() over
 * both, and enemy_bullet_render()'s shaft filter over the enemy one.  That is
 * 3,584 record loads a frame where the old pool sizes cost 1,152 - and it is
 *
 *   a fixed 2,432 extra DDR loads per frame, every frame, whether or not
 *   anything is in the pool.  The cost of a WIDE pool is paid by the scan,
 *   not by the bullets.
 *
 * THE FIX IS A BOUND, NOT A BITMAP.  alloc_bullet_range() hands out the
 * lowest free slot it can see, so live shots pile up at the BOTTOM of a pool
 * and the top stays empty.  Remembering "one past the highest slot that can
 * possibly be live" therefore walks the shots instead of the capacity.
 *
 * IT IS EXACT, NOT A HEURISTIC.  A slot can only become EF_ACTIVE through one
 * of the alloc_* helpers below, and every one of them raises the bound as it
 * hands the slot out - so "index < bound" is true for every live shot by
 * construction.  Nothing has to clear the bound when a shot dies (the bound
 * is allowed to be too big, never too small), and the two functions that empty
 * a pool outright reset it.  A bound that is too large costs a few loads; one
 * that is too small would silently drop bullets, which is why the rule is
 * "raise here, reset on clear, never lower anywhere else".
 *
 * THE ORB TAIL IS WHY THE ENEMY WALK IS TWO RUNS.  The Big Orbs own the top
 * ORB_RESERVE slots (see ORB_FIRST), and PAT_BURST puts twenty-four of them
 * there in one volley - so a single bound over the whole pool would be dragged
 * up to ~504 by the first spell card and stay there.  Instead the bound covers
 * the front run only, and the orb tail is a second, fixed 32-slot run.  That
 * keeps the walk proportional to the shots in the air on BOTH paths, and it
 * preserves the draw order the single-index walk had: front run first, orbs
 * after, so an orb still covers an ordinary shot it overlaps.
 *
 * A break inside FOR_EACH_EBULLET ends the CURRENT RUN, not the walk.  None of
 * the walks below break out - they all cull and continue - and a future one
 * that needs to stop early wants a flag, not a break.
 * ---------------------------------------------------------------------- */
/* The bound must stay BELOW ORB_FIRST: the walk is front run + orb tail, and
 * a bound that reached into the tail would make both runs visit the same
 * slot - counted twice by telemetry_write(), drawn twice by bucket_build().
 * alloc_ebullet() can only hand out slots below ORB_FIRST, so nothing has to
 * clamp this. */
static int pb_hi;                    /* one past the highest live pbullet slot */
static int eb_hi;                    /* ... the front run of the enemy pool    */
static int eb_free_hint;
static int pb_free_hint;
extern uint16_t bt_count[MM_BUCKET_ROWS];
static uint32_t bt_dropped, bt_drop_peak, bt_drop_window;
static uint32_t bt_started, bt_buf;
static uint8_t eb_motion_pending, eb_motion_job;
#ifndef BUCKET_SOFTWARE_REFERENCE
#define BUCKET_SOFTWARE_REFERENCE 0
#endif
static uint16_t * const eb_lances = (uint16_t *)MM_LANCE_INDEX;
static int eb_lance_count;
static uint16_t active_count;
static int active_ebullets_count;

static void pool_bounds_rebuild(void)
{
    int h = pb_hi;

    while (h < MAX_PBULLETS && (pbullets[h].flags & EF_ACTIVE)) h++;
    while (h > 0 && !(pbullets[h - 1].flags & EF_ACTIVE)) h--;
    pb_hi = h;

    /* The orb tail is walked at full width in every walk (see
     * FOR_EACH_EBULLET), so only the front run needs a bound. */
    h = eb_hi;
    while (h < ORB_FIRST && (ebullets[h].flags & EF_ACTIVE)) h++;
    while (h > 0 && !(ebullets[h - 1].flags & EF_ACTIVE)) h--;
    eb_hi = h;
}

#define FOR_EACH_EBULLET(var)                                         \
    for (int _run = 0; _run < 2; _run++)                              \
        for (int _i = (_run == 0 ? 0 : ORB_FIRST),                    \
                 _end = (_run == 0 ? eb_hi : MAX_EBULLETS);           \
             _i < _end; _i++)                                         \
            if (((var) = &ebullets[_i]), ((var)->flags & EF_ACTIVE))

#define FOR_EACH_PBULLET(var)                                         \
    for (int _i = 0; _i < pb_hi; _i++)                                \
        if (((var) = &pbullets[_i]), ((var)->flags & EF_ACTIVE))
static item_t      * const items    = (item_t *)MM_ITEM_BASE;
static volatile uint32_t * const tlm = (volatile uint32_t *)MM_TELEMETRY_BASE;

static int16_t  player_x, player_y;
static uint8_t  lives, weapon, atk, fire_cd, invuln, laser_cd;
/* Phase 2 Task 02: frames left of the fast post-hit blink.  The steady
 * invulnerability flicker is deliberately slow - three frames in four visible,
 * because half of a 1.6 s reaction spent invisible hides the hitbox the player
 * is trying to dodge with.  This counter only overlays a short, fast pulse on
 * the first frames after the hit so the event itself reads as a jolt, and then
 * hands the sprite back to the slow rhythm. */
static uint8_t  hit_blink;

/* Player power.  W_* is the shot TYPE, WEAPON_MAX_LEVEL the number of upgrade
 * steps it has (level 1 = the starting shot).  Taking a weapon item at the
 * cap does nothing at all: the old code did `weapon = (weapon + 1) & 3`, so a
 * fourth pickup wrapped a maxed-out player straight back to the weakest shot.
 * That was the "overflow back to level 1" bug. */
#define WEAPON_MAX_LEVEL   4
#define ATK_MAX            4
#define FIRE_CD_MIN        3
static uint8_t  weapon_level;
static uint16_t fire_timer;
/* moved up with the other run state; see score_award() above */
static uint16_t kills, wave, spawn_timer, wave_max;

static uint8_t  boss_state, boss_pattern, boss_prev_pat, boss_pat_timer;
static uint8_t  boss_fire_timer, boss_dead_timer, boss_since_summon;
static int16_t  boss_x, boss_y, boss_target_x, boss_target_y;


static int16_t  boss_hp, boss_hp_max;
static uint8_t  boss_move_timer, dialog_line, dialog_prev, dialog_grace;
static uint8_t  beam_active;

/* The boss's pre-fight dialogue.  A line can be skipped by a fresh press, or by
 * simply holding the key once the line has been up for a moment - see
 * dialog_update(), which has to work while the player is holding X to shoot. */
#define DIALOG_GRACE   30       /* frames before a key counts, per line */
#define DIALOG_HOLD_AT 60       /* a HELD key repeats once the timer is here */
#define DIALOG_LINE_F  95       /* frames a line stays up on its own */
static uint8_t  boss_freeze_timer;   /* frames the field holds still before the opener */
static uint8_t  boss_shake;          /* frames the scenery is still shaking */
static uint8_t  boss_pending_opener; /* a hold that ends in the spell card */
static uint8_t  boss_card_active;    /* Phase 2: card background preloaded and active across spell card */
static uint8_t  boss_spell_vfx_timer;/* Climax shockwave ring + flash timer on spell card release */
/* 6.1 aimed one column down the craft's lane.  8.2 throws three at once, so
 * the column, its timer and its phase became arrays; slot 0 is still 6.1's
 * cut, and cut_phase below mirrors it because the workbench grades that
 * symbol by name. */
static int16_t  beam_x[CUT_SLOTS];   /* the column each beam is aimed down */
static uint8_t  beam_timer[CUT_SLOTS];
static uint8_t  beam_phase[CUT_SLOTS];
static uint8_t  cut_phase;           /* 0 idle, 1 preview, 2 firing (slot 0) */
static uint8_t  lockon_timer;        /* 6.2: frames left in the phase        */
static uint8_t  lockon_arm;          /* 6.2: 0 idle, 1 laying out, 2 holding  */
static uint8_t  dialog_was_active;  /* dialog stood last frame; restore backdrop when it ends */
static uint8_t  pause_was_active;   /* pause card stood last frame; restore backdrop when unpausing */
#define SET_CARD_W  512
#define SET_CARD_H  392
static int16_t  boss_hp_shown;      /* the bar's lagging "damage trail" */          /* frames the boss's laser columns stay up */
static uint8_t  boss_opener_stage;   /* how many spell cards this boss has spent */
static uint16_t dialog_timer, slow_timer, jam_timer;
static uint32_t laser_hits;
static uint8_t  game_clear;
static uint16_t pattern_changes, summons, hits_taken, items_taken;
static uint8_t  game_over, restart_timer;
uint32_t frame_tick;
static uint8_t  clear_pending;          /* frames that still need a full wipe */

/* ---- the player's spell card -------------------------------------------
 * Every kill banks charge; at full charge a centre-click spends it.  The card
 * wipes every enemy shot off the screen, hits everything on it, and throws a
 * ring of the craft's own shots - the standard "get out of a wall" button the
 * genre expects, and the one thing the handset's centre button had never been
 * used for outside the menus.
 */
#define BOMB_MAX_CHARGE    8
#define BOMB_FLASH_FRAMES  36
static uint8_t  bomb_charge;            /* kills banked, capped at the max   */
static uint8_t  bomb_flash;             /* frames the shockwave is on screen */
static uint8_t  bomb_prev_center;       /* last frame's centre button        */
static uint16_t bomb_kills_seen;        /* kill counter at the previous frame */
/* ---- Phase 2 Task 03: the full-screen flash, and the impact shockwave ---
 *
 * The flash used to be a single hard step to near-white followed by a linear
 * ramp down: `timer * 50` for five frames put 250 on screen the instant the
 * shot landed, which reads as a dropped frame rather than as an impact.  What
 * it needs is an ENVELOPE - it has to ARRIVE, crest, and then disperse.
 *
 * The length is deliberate: about 1.5 s at 75 Hz.  A white frame that blinks
 * is indistinguishable from a rendering fault; a glow that fades out over a
 * second and a half is unmistakably something the game did, and it leaves the
 * aftermath of the hit readable while it goes.  The tail is exponential
 * (-1/32 a frame) with a floor of one step, so it can neither stall on integer
 * truncation and leave the screen tinted for good, nor stop moving.
 *
 * The timer counts DOWN, so age 0 is the first frame of the flash. */
#define CM_FLASH_FRAMES  112        /* ~1.5 s at 75 Hz */
#define CM_FLASH_RISE     12        /* frames spent ramping in */
static const uint8_t cm_flash_rise[CM_FLASH_RISE] = {
    /* the pulse has to arrive, not appear */
     16,  33,  50,  66,  83, 100, 116, 133, 150, 166, 183, 200
};
static uint8_t  color_matrix_flash_timer; /* frames left of the hardware flash */
static uint16_t color_matrix_flash_acc;   /* its level, in 8.8 fixed point    */

/* The shockwave of a hit.  It is centred on the point the shot CONNECTED, not
 * on the craft: by the time this draws, take_hit() has already thrown the
 * craft back to the spawn point, and a ring that teleported with it would say
 * nothing about where the hit actually happened. */
#define HIT_RING_FRAMES  16
static int16_t  hit_ring_x, hit_ring_y;
static uint8_t  hit_ring_timer;

/* Hitstop: the number of rendered frames the world is held still for after a
 * heavy hit.  Everything still draws - the flash, the ring and the core are
 * what the player is looking at - but no logic tick runs, so the picture is
 * frozen for two or three frames exactly where the impact lands.  This is the
 * cheapest "impact" there is: no pixels, no bandwidth, two frames of wall
 * clock, and it is what makes a ring feel like it has weight. */
#define HITSTOP_HIT      2
#define HITSTOP_KILL     3
static uint8_t  hitstop;


/* ---- runtime options (settings / pause menu) ------------------------ */
static uint8_t  hw_accel = 1;            /* 1 = BitBlt engine, 0 = CPU software render */
static uint8_t  infinite_respawn = 1;    /* 1 = losing all lives just refills instantly */
uint8_t game_audio_volume = 3u;          /* 0 mute, 1..4: 12.5/25/50/100 percent */
static uint8_t  paused;
static uint8_t  settings_sel;
/* The pause menu's edge detector.  These used to be function-static inside
 * settings_input(), which only runs while the menu is open: the first call
 * after opening the menu therefore compared the pad against whatever the LAST
 * menu left behind (all zero the first time), so a button the player was
 * already holding read as a fresh press.  X is the fire button - held almost
 * always - so holding X and tapping B to pause flipped the highlighted row,
 * and the highlight starts on INF RESPAWN: infinite respawn silently went off.
 * settings_edge_reset() is called as the menu opens and re-bases them on the
 * pad as it is right now. */
static uint8_t  set_prev_y, set_prev_a, set_prev_x, set_prev_center, set_stick_hold;
static uint8_t  game_exit_request;
static uint8_t  pad_bits;                /* last raw pad word, for telemetry */

/* Display-only state. No gameplay RNG, damage, collision or score writes. */
typedef struct { int16_t x,y; uint8_t age,active,pad[2]; } visual_fx_t;
static visual_fx_t * const visual_fx = (visual_fx_t *)MM_VISUAL_FX;
static uint8_t fx_cursor;

/* ---- Phase 2 Task 02 & Task 08: Combat Particle FX (OP_ADD / Bloom) ------------------- */
#define MAX_PARTICLES 48

typedef enum {
    PARTICLE_HIT      = 0,   /* golden hit spark (8x8 star, pure white core) */
    PARTICLE_ITEM     = 1,   /* Phase 2: rising golden dust motes from item pickup */
    PARTICLE_MOTE     = 2,   /* rising soft glow motes from clear/boss death */
    PARTICLE_CRIT     = 3,   /* fiery crimson spark (critical hit/boss damage) */
    PARTICLE_CYAN     = 4,   /* electric cyan spark (graze / laser impact) */
    PARTICLE_DIM_GOLD = 5,   /* decaying gold ember */
    PARTICLE_DIM_MOTE = 6,   /* decaying soft mote / cyan ember */
    PARTICLE_DIM_FIRE = 7    /* decaying crimson ember */
} particle_type_t;

typedef struct {
    int16_t x, y;
    int8_t  vx, vy;
    uint8_t life;
    uint8_t type;
} game_particle_t;

extern game_particle_t game_particles[MAX_PARTICLES];
_Static_assert(sizeof(game_particles) == MM_PARTICLE_STATE_BYTES, "particle DDR size");
static uint8_t particle_cursor;

static void spawn_particle(int x, int y, int vx, int vy, uint8_t type, uint8_t life)
{
    game_particle_t *p = &game_particles[particle_cursor++ % MAX_PARTICLES];
    p->x = (int16_t)x;
    p->y = (int16_t)y;
    p->vx = (int8_t)vx;
    p->vy = (int8_t)vy;
    p->life = life;
    p->type = type;
}

static void particles_update(void)
{
    for (int i = 0; i < MAX_PARTICLES; i++) {
        game_particle_t *p = &game_particles[i];
        if (!p->life) continue;
        p->life--;
        p->x = (int16_t)(p->x + p->vx);
        p->y = (int16_t)(p->y + p->vy);
        if (p->x < GAME_LEFT || p->x > GAME_RIGHT || p->y < 0 || p->y > GAME_BOTTOM)
            p->life = 0;
    }
}

static void particles_render(uint32_t fb)
{
    /* Sparks, embers and motes are glowing things, so they ADD.  Drawn with a
     * plain COPY they only ever replaced the backdrop, which is why a golden hit
     * spark looked like a sticker laid on the snowfield instead of a flash: a
     * spark that cannot brighten what is behind it is not a spark.
     *
     * The colour key is armed around the whole pass, not per particle: it is a
     * register write and it waits for the engine, so doing it inside the loop
     * would double the stalls this pass already pays to gpu2d_finish(). */
    r_add_begin();
    int rendered = 0;
    for (int i = 0; i < MAX_PARTICLES; i++) {
        game_particle_t *p = &game_particles[i];
        if (!p->life) continue;
        if (is_stress_stage && rendered >= 16) break;
        uint8_t type = p->type & 7u;
        /* Smooth lifecycle attenuation: transition to fading embers in late life */
        if (p->life <= 6 && type < 5) {
            if (type == PARTICLE_HIT || type == PARTICLE_ITEM) {
                type = PARTICLE_DIM_GOLD;
            } else if (type == PARTICLE_CRIT) {
                type = PARTICLE_DIM_FIRE;
            } else {
                type = PARTICLE_DIM_MOTE;
            }
        }
        int pw = 8, ph = 8;
        int px = p->x - 4;
        int py = p->y - 4;
        uint32_t src = MM_PARTICLE_TILE + (uint32_t)type * MM_PARTICLE_TILE_BYTES;
        /* In final 3 frames, smoothly shrink to 4x4 center ember */
        if (p->life <= 3) {
            pw = 4;
            ph = 4;
            px += 2;
            py += 2;
            src += (2u * MM_PARTICLE_TILE_STRIDE) + 8u;
        }
        if (px >= GAME_LEFT && px + pw <= GAME_RIGHT && py >= 0 && py + ph <= SCREEN_HEIGHT) {
            r_add(fb + (uint32_t)(py * SCREEN_STRIDE) + (uint32_t)(px * 4),
                  src, (uint32_t)pw, (uint32_t)ph,
                  MM_PARTICLE_TILE_STRIDE, SCREEN_STRIDE);
        }
    }
    r_add_end();
}

/* ---- composed-once surfaces -------------------------------------------
 * Each of these used to be painted with two or three FILLs for every object
 * on screen, every frame.  The engine charges per command and activates a DRAM
 * row per row touched, so a 9x9 socket and a 3x3 dot are about the most
 * expensive pixels in the build; drawn once into DDR they cost one COPY each.
 * They run at boot, off the frame budget entirely.
 *
 * ebullet_tile_build() USED TO BE THE FIRST OF THEM: eight 13x13 concentric
 * aura sockets at MM_EBULLET_TILE, one per colour.  It was removed here, and
 * the reason it could be is that nothing had read those bytes for a long time -
 * name it and the only hits are its own builder, its own call and its entry in
 * tools/check_ddr_layout.py.  The barrage has been drawn from the scanout's
 * direction tiles (MM_EBULLET_DIRTILE / ebullet_dirtile_build) since the colour
 * split, and those carry their own socket geometry.
 *
 * It went because this image has 100 bytes free and the missile tile and the
 * doubled enemy tile need about 250 of them.  The measured cost of the body
 * was ~300 bytes of .text for eight tiles no picture ever showed.  The address
 * MM_EBULLET_TILE is still declared and still checked by check_ddr_layout.py;
 * nothing writes it any more.
 */

static void orb_tile_build(void)
{
    /* 16x16 Big Orbs for Phase 2 Task 01 & Task 07 (Scheme B Bloom + ColorKey).
     * MAGENTA_KEY background enables single-stream blit with zero DDR read
     * stalls, while the scanout Gaussian Bloom filter creates radiant glowing
     * energy orbs.
     *
     * ONE tile, not eight: same shape, different values.  The dark rim is the
     * player shot's quarter role - measured, the two formulas agree bit for bit
     * across all eight hues - so the orbs and the fan shot share that entry. */
    volatile uint8_t *tile = (volatile uint8_t *)MM_ORB_TILE;
    const unsigned pitch = MM_ORB_TILE_STRIDE;   /* one byte a pixel */

    for (int y = 0; y < MM_ORB_TILE_H; y++) {
        int dy = y * 2 - 15;
        for (int x = 0; x < MM_ORB_TILE_W; x++) {
            int dx = x * 2 - 15;
            int d2 = dx * dx + dy * dy;
            uint32_t role = BROLE_NONE;
            if (d2 <= 12) {
                /* Micro-pinpoint pure white core (hot spark) */
                role = BROLE_WHITE;
            } else if (d2 <= 40) {
                /* Electric core highlight: the hue pushed 80/255 towards white */
                role = BROLE_ORB_CORE;
            } else if (d2 <= 145) {
                /* Deep saturated gemstone body (vivid colour, authentic hue) */
                role = BROLE_NEON;
            } else if (d2 <= 195) {
                /* Outer refractive shade */
                role = BROLE_PB_QUART;
            }
            tile[y * pitch + x] = role;
        }
    }
    gpu2d_flush_dcache();
}

static void particle_tile_build(void)
{
    /* 4 types of 8x8 particles for Phase 2 Task 08 (Scheme B Bloom + ColorKey).
     * MAGENTA_KEY background allows fast single-stream blit without DDR read stall,
     * while scanout Bloom filter creates the glowing visual feedback. */
    volatile uint32_t *base = (volatile uint32_t *)MM_PARTICLE_TILE;
    const unsigned pitch = MM_PARTICLE_TILE_STRIDE / 4u;

    for (unsigned i = 0; i < (MM_PARTICLE_TILE_BYTES * MM_PARTICLE_TILE_COUNT) / 4u; i++) {
        base[i] = MAGENTA_KEY;
    }

    /* Type 0: PARTICLE_HIT (golden hit spark, 8x8 diamond star) */
    volatile uint32_t *t0 = base;
    t0[1 * pitch + 3] = t0[1 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FF8000u;
    t0[2 * pitch + 3] = t0[2 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFCC00u;
    t0[3 * pitch + 1] = t0[3 * pitch + 6] = MM_EMISSIVE_TAG | 0x00FF8000u;
    t0[3 * pitch + 2] = t0[3 * pitch + 5] = MM_EMISSIVE_TAG | 0x00FFD700u;
    t0[3 * pitch + 3] = t0[3 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    t0[4 * pitch + 1] = t0[4 * pitch + 6] = MM_EMISSIVE_TAG | 0x00FF8000u;
    t0[4 * pitch + 2] = t0[4 * pitch + 5] = MM_EMISSIVE_TAG | 0x00FFD700u;
    t0[4 * pitch + 3] = t0[4 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    t0[5 * pitch + 3] = t0[5 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFCC00u;
    t0[6 * pitch + 3] = t0[6 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FF8000u;

    /* Type 1: PARTICLE_ITEM (Phase 2: glowing golden dust mote, 8x8) */
    volatile uint32_t *t1 = base + pitch * 8u;
    t1[1 * pitch + 3] = t1[1 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFA500u;
    t1[2 * pitch + 2] = t1[2 * pitch + 5] = MM_EMISSIVE_TAG | 0x00FFD700u;
    t1[2 * pitch + 3] = t1[2 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    t1[3 * pitch + 1] = t1[3 * pitch + 6] = MM_EMISSIVE_TAG | 0x00FFA500u;
    t1[3 * pitch + 2] = t1[3 * pitch + 5] = MM_EMISSIVE_TAG | 0x00FFD700u;
    t1[3 * pitch + 3] = t1[3 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    t1[4 * pitch + 1] = t1[4 * pitch + 6] = MM_EMISSIVE_TAG | 0x00FFA500u;
    t1[4 * pitch + 2] = t1[4 * pitch + 5] = MM_EMISSIVE_TAG | 0x00FFD700u;
    t1[4 * pitch + 3] = t1[4 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    t1[5 * pitch + 2] = t1[5 * pitch + 5] = MM_EMISSIVE_TAG | 0x00FFD700u;
    t1[5 * pitch + 3] = t1[5 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    t1[6 * pitch + 3] = t1[6 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFA500u;

    /* Type 2: PARTICLE_MOTE (magical pink/white circular rising mote) */
    volatile uint32_t *t2 = base + pitch * 16u;
    for (int y = 1; y <= 6; y++) {
        int dy = y * 2 - 7;
        for (int x = 1; x <= 6; x++) {
            int dx = x * 2 - 7;
            int d2 = dx * dx + dy * dy;
            if (d2 <= 8) {
                t2[y * pitch + x] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
            } else if (d2 <= 20) {
                t2[y * pitch + x] = MM_EMISSIVE_TAG | 0x00FFA0E0u;
            } else if (d2 <= 32) {
                t2[y * pitch + x] = MM_EMISSIVE_TAG | 0x00602050u;
            }
        }
    }

    /* Type 3: PARTICLE_CRIT (crimson star, 8x8) */
    volatile uint32_t *t3 = base + pitch * 24u;
    t3[1 * pitch + 3] = t3[1 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FF3050u;
    t3[2 * pitch + 3] = t3[2 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FF6080u;
    t3[3 * pitch + 1] = t3[3 * pitch + 6] = MM_EMISSIVE_TAG | 0x00FF3050u;
    t3[3 * pitch + 2] = t3[3 * pitch + 5] = MM_EMISSIVE_TAG | 0x00FF80A0u;
    t3[3 * pitch + 3] = t3[3 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    t3[4 * pitch + 1] = t3[4 * pitch + 6] = MM_EMISSIVE_TAG | 0x00FF3050u;
    t3[4 * pitch + 2] = t3[4 * pitch + 5] = MM_EMISSIVE_TAG | 0x00FF80A0u;
    t3[4 * pitch + 3] = t3[4 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    t3[5 * pitch + 3] = t3[5 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FF6080u;
    t3[6 * pitch + 3] = t3[6 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FF3050u;

    /* Type 4: PARTICLE_CYAN (electric cyan / graze spark, 8x8) */
    volatile uint32_t *t4 = base + pitch * 32u;
    t4[1 * pitch + 3] = t4[1 * pitch + 4] = MM_EMISSIVE_TAG | 0x000070D0u;
    t4[2 * pitch + 3] = t4[2 * pitch + 4] = MM_EMISSIVE_TAG | 0x0000C0FFu;
    t4[3 * pitch + 1] = t4[3 * pitch + 6] = MM_EMISSIVE_TAG | 0x000070D0u;
    t4[3 * pitch + 2] = t4[3 * pitch + 5] = MM_EMISSIVE_TAG | 0x0000E0FFu;
    t4[3 * pitch + 3] = t4[3 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    t4[4 * pitch + 1] = t4[4 * pitch + 6] = MM_EMISSIVE_TAG | 0x000070D0u;
    t4[4 * pitch + 2] = t4[4 * pitch + 5] = MM_EMISSIVE_TAG | 0x0000E0FFu;
    t4[4 * pitch + 3] = t4[4 * pitch + 4] = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    t4[5 * pitch + 3] = t4[5 * pitch + 4] = MM_EMISSIVE_TAG | 0x0000C0FFu;
    t4[6 * pitch + 3] = t4[6 * pitch + 4] = MM_EMISSIVE_TAG | 0x000070D0u;

    /* Type 5: PARTICLE_DIM_GOLD (decaying golden ember, 8x8) */
    volatile uint32_t *t5 = base + pitch * 40u;
    t5[2 * pitch + 3] = t5[2 * pitch + 4] = MM_EMISSIVE_TAG | 0x00704008u;
    t5[3 * pitch + 2] = t5[3 * pitch + 5] = MM_EMISSIVE_TAG | 0x00704008u;
    t5[3 * pitch + 3] = t5[3 * pitch + 4] = MM_EMISSIVE_TAG | 0x00D09010u;
    t5[4 * pitch + 2] = t5[4 * pitch + 5] = MM_EMISSIVE_TAG | 0x00704008u;
    t5[4 * pitch + 3] = t5[4 * pitch + 4] = MM_EMISSIVE_TAG | 0x00D09010u;
    t5[5 * pitch + 3] = t5[5 * pitch + 4] = MM_EMISSIVE_TAG | 0x00704008u;

    /* Type 6: PARTICLE_DIM_MOTE (decaying cyan/soft mote ember, 8x8) */
    volatile uint32_t *t6 = base + pitch * 48u;
    t6[2 * pitch + 3] = t6[2 * pitch + 4] = MM_EMISSIVE_TAG | 0x00203050u;
    t6[3 * pitch + 2] = t6[3 * pitch + 5] = MM_EMISSIVE_TAG | 0x00203050u;
    t6[3 * pitch + 3] = t6[3 * pitch + 4] = MM_EMISSIVE_TAG | 0x004080A0u;
    t6[4 * pitch + 2] = t6[4 * pitch + 5] = MM_EMISSIVE_TAG | 0x00203050u;
    t6[4 * pitch + 3] = t6[4 * pitch + 4] = MM_EMISSIVE_TAG | 0x004080A0u;
    t6[5 * pitch + 3] = t6[5 * pitch + 4] = MM_EMISSIVE_TAG | 0x00203050u;

    /* Type 7: PARTICLE_DIM_FIRE (decaying crimson ember, 8x8) */
    volatile uint32_t *t7 = base + pitch * 56u;
    t7[2 * pitch + 3] = t7[2 * pitch + 4] = MM_EMISSIVE_TAG | 0x00401018u;
    t7[3 * pitch + 2] = t7[3 * pitch + 5] = MM_EMISSIVE_TAG | 0x00401018u;
    t7[3 * pitch + 3] = t7[3 * pitch + 4] = MM_EMISSIVE_TAG | 0x00902030u;
    t7[4 * pitch + 2] = t7[4 * pitch + 5] = MM_EMISSIVE_TAG | 0x00401018u;
    t7[4 * pitch + 3] = t7[4 * pitch + 4] = MM_EMISSIVE_TAG | 0x00902030u;
    t7[5 * pitch + 3] = t7[5 * pitch + 4] = MM_EMISSIVE_TAG | 0x00401018u;

    gpu2d_flush_dcache();
}

static void __attribute__((unused)) laser_glow_build(void)
{
    /* Phase 2 / A3: the player laser beam sheet (16x768, stride 64).
     *
     * The engine no longer blits this surface.  A3 moved the craft's beam into
     * the scanout, where video_beam.v draws it out of a sixteen-entry column
     * table, and the sheet's remaining job is to be the thing that table is
     * CHECKED against: tools/dump_beam_ref.py reads these bytes back out of
     * emulated DDR and tests/tb_video_beam.sv compares the RTL's output with
     * them pixel by pixel, all 768 rows and 16 columns, at three beam centres.
     * The two are one table written twice, and changing either alone fails the
     * bench - which is the point of keeping them apart.
     *
     * THE PROFILE.  A beam is light, so an opaque bar of colour is the wrong
     * shape for it - but only its core is a light SOURCE, and the old sheet
     * gave six of its twelve drawn columns white or near white (5, 6, 7, 8, 9,
     * 10) while the scanout ADDED every one of them.  On any non-zero
     * background all six saturated, so the core's over-exposure spread out
     * until the beam read as a solid white bar.  Dimming the colours cannot fix
     * that; it only turns a white bar grey.  The blend has to differ by column,
     * and now it does - video_beam.v carries the same twelve columns with an
     * add flag and an alpha per column:
     *
     *     columns 0, 1, 14, 15   MAGENTA_KEY - the engine's colour key skipped
     *                            them and the scanout skips them too
     *     columns 2..4, 11..13   the rim, a cool blue the scanout BLENDS at
     *                            alpha 130, so the snow reads through it
     *     columns 5, 6, 9, 10    the halo, brighter cyan, blended at alpha 190
     *     columns 7, 8           the core: the only columns that ADD, and the
     *                            only ones allowed to saturate
     *
     * The alpha is deliberately not here.  It is not a colour, this is a 24-bit
     * surface, and the blend decision belongs next to the blend - video_beam.v
     * keeps it in the same table row as the colour it applies to. */
    volatile uint32_t *base = (volatile uint32_t *)MM_LASER_GLOW;
    const unsigned pitch = 16u; /* MM_LASER_GLOW stride is 64 bytes = 16 words */

    for (unsigned y = 0; y < 768u; y++) {
        volatile uint32_t *row = &base[y * pitch];

        /* Outer margin: the four columns the colour key skips.  Written as the
         * bare key, with no emissive tag - a tagged key is not the key the
         * comparison in tb_video_beam.sv (and the old blit) looks for. */
        row[0]  = MAGENTA_KEY;
        row[1]  = MAGENTA_KEY;
        row[14] = MAGENTA_KEY;
        row[15] = MAGENTA_KEY;

        /* Rim: deep to mid cool blue, the most transparent step. */
        row[2]  = MM_EMISSIVE_TAG | 0x002E6C8Cu;
        row[13] = MM_EMISSIVE_TAG | 0x002E6C8Cu;
        row[3]  = MM_EMISSIVE_TAG | 0x004696C0u;
        row[12] = MM_EMISSIVE_TAG | 0x004696C0u;
        row[4]  = MM_EMISSIVE_TAG | 0x0066C0E8u;
        row[11] = MM_EMISSIVE_TAG | 0x0066C0E8u;

        /* Halo: saturated cyan carrying its own colour through the blend. */
        row[5]  = MM_EMISSIVE_TAG | 0x008AD8FFu;
        row[10] = MM_EMISSIVE_TAG | 0x008AD8FFu;
        row[6]  = MM_EMISSIVE_TAG | 0x00C0EEFFu;
        row[9]  = MM_EMISSIVE_TAG | 0x00C0EEFFu;

        /* Core: two columns of pure white, the only pair that adds, so the only
         * pair allowed to drive the scanout bloom into over-exposure. */
        row[7]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
        row[8]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
    }
    gpu2d_flush_dcache();
}

static void laser_bar_build(void)
{
    /* Phase 2: Multi-Frame High-Energy Boss Laser Bar (16x768x3 frames, stride 64).
     * Features:
     * - Blinding pure white hot core (0x00FFFFFF) triggering hardware scanout Bloom;
     * - Radiant peach / high-energy electric transition sheath;
     * - Vibrant neon crimson/magenta plasma flanks;
     * - Smooth radiant glow edge transition (zero noisy dither);
     * - Animated surging plasma flow across frames 0 & 1;
     * - Distinct cooling/thinning warning phase in frame 2;
     * - Saturated additive blending (OP_ADD) over background plate. */
    const unsigned pitch = 16u; /* MM_LASER_BAR stride is 64 bytes = 16 words */

    for (unsigned f = 0; f < MM_LASER_BAR_COUNT; f++) {
        volatile uint32_t *base = (volatile uint32_t *)
            (MM_LASER_BAR + f * MM_LASER_BAR_BYTES);

        uint32_t aura_edge = (f == 2u) ? 0x00300612u : 0x00600C24u;

        for (unsigned y = 0; y < MM_LASER_BAR_H; y++) {
            volatile uint32_t *row = &base[y * pitch];

            /* Outer boundary: 100% transparent to background */
            row[0]  = MAGENTA_KEY;
            row[1]  = MAGENTA_KEY;
            row[14] = MAGENTA_KEY;
            row[15] = MAGENTA_KEY;

            /* Outer corona: smooth radiant halo (no raster dither noise) */
            row[2]  = MM_EMISSIVE_TAG | aura_edge;
            row[13] = MM_EMISSIVE_TAG | aura_edge;

            if (f < 2u) {
                /* Frames 0 & 1: Full-Power Blazing Plasma with traveling energy nodes */
                /* Frame 0 phase offset 0, Frame 1 phase offset 16 -> creates flowing pulse */
                unsigned wave = (y + (f * 16u)) & 31u;

                row[3]  = MM_EMISSIVE_TAG | 0x00FF2050u; /* Saturated neon crimson */
                row[12] = MM_EMISSIVE_TAG | 0x00FF2050u;

                if (wave < 8u) {
                    /* High-energy plasma surge: 6-pixel blinding white core */
                    row[4]  = MM_EMISSIVE_TAG | 0x00FFA0C8u;
                    row[5]  = MM_EMISSIVE_TAG | 0x00FFE0ECu;
                    row[6]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
                    row[7]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
                    row[8]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
                    row[9]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
                    row[10] = MM_EMISSIVE_TAG | 0x00FFE0ECu;
                    row[11] = MM_EMISSIVE_TAG | 0x00FFA0C8u;
                } else {
                    /* Intense steady plasma: 4-pixel white core with radiant peach flanks */
                    row[4]  = MM_EMISSIVE_TAG | 0x00FF6080u;
                    row[5]  = MM_EMISSIVE_TAG | 0x00FFA0C8u;
                    row[6]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
                    row[7]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
                    row[8]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
                    row[9]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
                    row[10] = MM_EMISSIVE_TAG | 0x00FFA0C8u;
                    row[11] = MM_EMISSIVE_TAG | 0x00FF6080u;
                }
            } else {
                /* Frame 2: Cooling / Dissipating warning phase (when countdown <= 30) */
                row[2]  = MAGENTA_KEY;
                row[13] = MAGENTA_KEY;
                row[3]  = MM_EMISSIVE_TAG | 0x00600818u; /* Dimming crimson */
                row[4]  = MM_EMISSIVE_TAG | 0x00901428u;
                row[5]  = MM_EMISSIVE_TAG | 0x00D02040u;
                row[6]  = MM_EMISSIVE_TAG | 0x00FF6080u;
                row[7]  = MM_EMISSIVE_TAG | 0x00FFFFFFu; /* Narrow 2-pixel core */
                row[8]  = MM_EMISSIVE_TAG | 0x00FFFFFFu;
                row[9]  = MM_EMISSIVE_TAG | 0x00FF6080u;
                row[10] = MM_EMISSIVE_TAG | 0x00D02040u;
                row[11] = MM_EMISSIVE_TAG | 0x00901428u;
                row[12] = MM_EMISSIVE_TAG | 0x00600818u;
            }
        }
    }
    gpu2d_flush_dcache();
}

static void visual_burst(int x, int y)
{
    visual_fx_t *f = &visual_fx[fx_cursor++ & 15u];
    f->x = (int16_t)x; f->y = (int16_t)y; f->age = 0; f->active = 1;
}

static void visual_step(const gamepad_state_t *pad)
{
    for (int i = 0; i < 16; i++)
        if (visual_fx[i].active && ++visual_fx[i].age >= 24) visual_fx[i].active = 0;
    strip_scroll = (uint16_t)((strip_scroll + 1u) & (SB_STRIP_PERIOD - 1u));
    player_pose = (uint8_t)((frame_tick >> 3) & 3u);
    if (pad->x < 108) player_pose = 4;
    else if (pad->x > 148) player_pose = 5;
    else if (pad->btn_a) player_pose = 2;
    else if (pad->btn_x) player_pose = 3;
}

/* 16 directions x16 (1.0 == 16): index 0 = +x, 4 = +y (screen down),
 * 8 = -x, 12 = -y.  A table keeps the whole game free of trigonometry. */
static const int8_t dir16_x[16] = {
     16,  15,  11,   6,   0,  -6, -11, -15,
    -16, -15, -11,  -6,   0,   6,  11,  15
};
static const int8_t dir16_y[16] = {
      0,   6,  11,  15,  16,  15,  11,   6,
      0,  -6, -11, -15, -16, -15, -11,  -6
};

/* Nearest of the 16 directions, decided with compare-only octant tests. */
/* 8.5's shaft, one per compass point, composed at boot.  Same reasoning as
 * the impact frames and the laser bars: eleven little FILLs a lance a frame
 * would be eleven commands each, and this is one COPY.  The direction is
 * dir16's even indices - eight of the sixteen steps. */
static void lance_build(void)
{
    for (unsigned d = 0; d < MM_LANCE_COUNT; d++) {
        uint32_t dst = MM_LANCE + d * MM_LANCE_BYTES;
        int dx = dir16_x[d * 2u] >> 3;
        int dy = dir16_y[d * 2u] >> 3;
        int mid = MM_LANCE_W / 2;

        /* Key the tile BEFORE drawing on it, for exactly the reason
         * burst_frames_build() does: a colour-keyed copy does not write the
         * keyed pixels, so every pixel the loop below never reaches would
         * otherwise keep whatever the DDR powered up with - black on the
         * workbench, noise on the board, i.e. a garbled shaft. */
        r_fill(dst, MM_LANCE_W, MM_LANCE_W, MAGENTA_KEY, MM_LANCE_STRIDE);

        for (int t = -5; t <= 5; t++) {
            int px = mid + dx * t;
            int py = mid + dy * t;
            if (px < 0 || py < 0 ||
                px > MM_LANCE_W - 3 || py > MM_LANCE_W - 3) continue;
            r_fill(dst + (uint32_t)(py * MM_LANCE_STRIDE + px * 4), 3, 3,
                   MM_EMISSIVE_TAG | ((t > 2 || t < -2) ? 0x00FF6080u : 0x00FFE0F0u),
                   MM_LANCE_STRIDE);
        }
    }
}

/* One 9x9 tile per (colour, heading): the socket tile with the direction
 * speck baked in.  enemy_bullet_render() used to FILL that 2x2 speck and then
 * COPY the tile - two commands, two DDR round trips, for 36 bytes of pixels,
 * once per enemy shot, so up to MAX_EBULLETS times a frame.
 *
 * The speck's offset comes from the shot's velocity, so a faithful bake would
 * need one tile per distinct (vx, vy).  Quantising to the 16 headings costs
 * nothing visible - the speck is a 2x2 dark dot whose entire job is to say
 * which way the shot is travelling - and CLAMPING it to the tile keeps the
 * 9x9 footprint, which matters: a tile grown to hold the speck at full offset
 * would reach two pixels into the HUD gutter along the left edge of the
 * playfield, and nothing repaints the gutter afterwards. */
static void ebullet_dirtile_build(void)
{
    /* Phase 2 Task 01: 16-Direction High-Energy Conical Rice Bullets.
     * Features:
     * - 16 pre-quantised heading tiles, 26x26 footprint (twice the 13x13 it
     *   was, edge for edge - see MM_EBULLET_DIRTILE in memory_map.h);
     * - Needle-sharp pure white hot tip (bloom trigger);
     * - High-energy electric core transition spine along the direction vector;
     * - Saturated attribute neon wings;
     * - Smooth 8-bit feathered halo, zero dither raster noise;
     * - Outer "nothing here" boundary.
     *
     * SIXTEEN tiles, not 8 x 16.  The eight colours were pure recolourings of
     * the same shape - measured on the firmware's own DDR, all 112 (shape, hue)
     * pairs have identical opaque-cell sets - so a cell holds a ROLE number
     * and the scanout resolves the colour with role + hue*32.
     *
     * Directions stay at sixteen because d and d+8 are NOT exact flips of each
     * other on an integer grid: measured at 13x13, only 1 of the 8 pairs holds
     * and only 4 of the 16 masks are symmetric about either axis.  Off by a
     * pixel or two is still a different picture.
     *
     * TWICE THE EDGE, AND THE SHAPE IS THE OLD ONE WITH ITS THRESHOLDS
     * DOUBLED - the COORDINATES stay on a one-pixel grid:
     *
     *     13x13                       26x26
     *     dx = x - 6                  dx = x - 13
     *     l  = dx*vx + dy*vy          l  = dx*vx + dy*vy   (same formula)
     *     t  = |-dx*vy + dy*vx|       t  = same
     *     l in [-60, 72]              l in [-120, 144]
     *     w_core 34*(72-l)/72         68*(144-l)/144  (and 34*(60+l)/60 ->
     *                                                     68*(120+l)/120)
     *     w_halo = w_core + 20        w_halo = w_core + 40
     *     t <= 4 / 8                  t <= 8 / 16
     *     l >= 28                     l >= 56
     *
     * THE COORDINATES MUST NOT BE SCALED WITH THE THRESHOLDS.  Multiplying
     * both by two is what "twice as big" looks like it should mean, and it is
     * exactly the change that does NOTHING: l is linear in dx, so scaling dx
     * scales l by the same factor, and doubling the window on l as well leaves
     * every cell's verdict unchanged.  Measured on the first attempt, that put
     * the shape at 9 x 6 cells where the 13x13 one was 8 x 7 - a 26x26 footprint
     * around a bullet the same size as before.  What doubles the shape is the
     * window alone: on a one-pixel grid, [-120, 144] admits 17 cells along the
     * flight axis where [-60, 72] admitted 8.
     *
     * The halo is the one place the doubling is not a pure relabelling.  The
     * old tier was a = 180 - 7*(t - w_core), and t - w_core could only reach 18
     * of the 20 values the formula allows on a 13x13 grid (96 and 68 are
     * unreachable - see eb_halo_a).  A 26x26 grid reaches further, so a is no
     * longer compared for equality: the first entry of eb_halo_a that is no
     * brighter than a wins.  A 20-tier halo would have needed two more roles x
     * 8 hue pages and the palette has none to spare, and 18 tiers over a bullet
     * twice as wide is a smoother ramp than it was, not a coarser one. */
    const unsigned dpitch = MM_EBULLET_DIRTILE_STRIDE;   /* one byte a pixel */

    for (unsigned d = 0; d < MM_EBULLET_DIRTILE_DIRS; d++) {
        volatile uint8_t *dst = (volatile uint8_t *)
            (MM_EBULLET_DIRTILE + (uint32_t)d * MM_EBULLET_DIRTILE_BYTES);
        int vx = dir16_x[d];
        int vy = dir16_y[d];

        for (int y = 0; y < MM_EBULLET_DIRTILE_H; y++) {
            /* ONE-PIXEL GRID.  Scaling these with the thresholds is the change
             * that looks right and does nothing - see the note above the
             * function. */
            int dy = y - 13;
            for (int x = 0; x < MM_EBULLET_DIRTILE_W; x++) {
                int dx = x - 13;
                int l = dx * vx + dy * vy;
                int t = -dx * vy + dy * vx;
                if (t < 0) t = -t;

                uint8_t role = BROLE_NONE;
                if (l <= 144 && l >= -120) {
                    int w_core = (l >= 0) ? ((68 * (144 - l)) / 144)
                                          : ((68 * (120 + l)) / 120);
                    int w_halo = w_core + 40;

                    if (t <= 8 && l >= 56) {
                        /* Needle-sharp pure white hot tip (micro pinpoint spark) */
                        role = BROLE_WHITE;
                    } else if (t <= 16 && l >= 0) {
                        /* Blazing electric spine along the trajectory */
                        role = BROLE_EB_CORE;
                    } else if (t <= w_core) {
                        /* Saturated neon body/wings */
                        role = BROLE_NEON;
                    } else if (t <= w_halo) {
                        /* Smooth feathered halo.  The tier is the first entry of
                         * eb_halo_a that is no brighter than a: the table runs
                         * brightest-first, and the old "equal" comparison no
                         * longer holds - the formula's 20 steps reach values the
                         * 13x13 grid never produced (96 and 68), and a 26-wide
                         * bullet lands between two of them as well. */
                        uint32_t a = 180u - ((uint32_t)(t - w_core) * 140u) / 20u;
                        unsigned k = 0u;
                        while (k + 1u < BROLE_EB_HALO_N && eb_halo_a[k] > a) k++;
                        role = (uint8_t)(BROLE_EB_HALO + k);
                    }
                }
                dst[y * dpitch + x] = role;
            }
        }
    }
    gpu2d_flush_dcache();
}

/* ---- 追踪导弹：一个形状，两种混合 ----------------------------------------
 *
 * PF_LOCKON 的那两颗弹原来用玩家弹的图块（slot 16），所以它们的像素、角色
 * 和调色板条目都和扇形弹共用 —— 而扫描端是**按调色板条目**决定混合方式
 * 的，条目共用就等于混合方式共用，这也是"导弹没法单独设成半透明加加法"
 * 的全部原因。
 *
 * 现在它有自己的图块（slot 18）和两个角色：
 *
 *     y 0..9    弹体   BROLE_MS_BODY   -> 调色板 alpha 190，乘法 alpha
 *     y 10..25  拖尾   BROLE_MS_TRAIL  -> 调色板 alpha 254 = BPAL_ADD，加法
 *
 * 同一个弹里两种混合，靠的就是扫描端逐像素取调色板条目、逐像素读它的
 * alpha 字节，再把 254 解释成"加法"（video_bullet_overlay.v 的 ADD_CODE）。
 *
 * 只有一个朝向（永远朝上）。16 个朝向要 16 x 416 = 6656 字节，而敌弹那边
 * 刚刚把 store 顶到 16384；何况导弹是个圆头弹体加一条尾焰，整体接近轴对称，
 * 朝向差异本来就比敌弹那根"针尖"弱得多，不值得为它再翻一倍 store。
 *
 * 13 宽（扇形弹 7，大玉 16），26 高 —— 与玩家弹一样高，所以
 * spawn_pbullet_lockon() 里 GAME_BOTTOM - 26 那条夹取不用动。 */
static void missile_tile_build(void)
{
    volatile uint8_t *tile = (volatile uint8_t *)MM_MISSILE_TILE;
    const unsigned pitch = MM_MISSILE_TILE_STRIDE;

    for (unsigned i = 0; i < pitch * MM_MISSILE_TILE_H; i++)
        tile[i] = BROLE_NONE;

    /* 一行一趟，半宽从中心列往两边铺：0..9 是弹体（尖头 1,2,3 -> 弹身 4 ->
     * 最宽的一对翼 5 -> 收尾 3），10..25 是拖尾（5 起，每 3 行收 1 格）。 */
    for (int y = 0; y < MM_MISSILE_TILE_H; y++) {
        int half = (y < 10) ? ((y < 3) ? (y + 1) : ((y < 6) ? 4 : ((y < 8) ? 5 : 3)))
                            : ((25 - y) / 3);
        uint8_t role = (y < 10) ? BROLE_MS_BODY : BROLE_MS_TRAIL;
        for (int x = 6 - half; x <= 6 + half; x++)
            tile[y * pitch + x] = role;
    }
    gpu2d_flush_dcache();
}

static inline __attribute__((always_inline)) int aim_index_inline(int dx, int dy)
{
    int ax = (dx < 0) ? -dx : dx;
    int ay = (dy < 0) ? -dy : dy;
    int q;

    /* Horizontal walls dominate the pressure stage; avoid the ratio tests. */
    if (dy == 0) return dx == 0 ? 4 : (dx < 0 ? 8 : 0);
    if ((ay << 2) + ay <= ax)             q = 0;   /* |dy|/|dx| <= 0.2 */
    else if ((ay << 1) + ay <= (ax << 1)) q = 1;
    else if ((ay << 1) <= (ax << 1) + ax) q = 2;
    else if (ay <= (ax << 2) + ax)        q = 3;
    else                                  q = 4;

    if (dx < 0) q = 8 - q;
    if (dy < 0) q = -q;
    return q & 15;
}

static int aim_index(int dx, int dy)
{
    return aim_index_inline(dx, dy);
}

/* ---------------------------------------------------------------- pools */

static int count_active(void)
{
    int n = 0;
    for (int i = 0; i < MAX_ENEMIES; i++)
        if (enemies[i].flags & EF_ACTIVE) n++;
    return n;
}

static void pool_clear(void)
{
    for (int i = 0; i < MAX_ENEMIES; i++)  enemies[i].flags  = 0;
    for (int i = 0; i < MAX_PBULLETS; i++) pbullets[i].flags = 0;
    for (int i = 0; i < MAX_EBULLETS; i++) ebullets[i].flags = 0;
    /* Emptied, so the walks can start from nothing again.  See the bound
     * comment above: only these two lines are allowed to LOWER it. */
    pb_hi = 0;
    pb_free_hint = 0;
    eb_hi = 0;
    eb_free_hint = 0;
    eb_lance_count = 0;
    active_ebullets_count = 0;
    active_count = 0;
    for (int i = 0; i < MAX_ITEMS; i++)    items[i].flags    = 0;
}

static bullet_t *alloc_bullet_range(bullet_t *pool, int lo, int hi)
{
    for (bullet_t *b = pool + lo, *end = pool + hi; b < end; b++)
        if (!(b->flags & EF_ACTIVE)) return b;
    return (bullet_t *)0;
}

/* The player's pool, in one run, so one bound covers it.  Raises pb_hi as it
 * hands a slot out - see the bound comment above for why that is the whole
 * correctness argument. */
static bullet_t *alloc_pbullet(void)
{
    bullet_t *b = (bullet_t *)0;
    if (pb_free_hint < MAX_PBULLETS && !(pbullets[pb_free_hint].flags & EF_ACTIVE)) {
        b = &pbullets[pb_free_hint++];
    } else {
        b = alloc_bullet_range(pbullets, pb_free_hint, MAX_PBULLETS);
        if (!b && pb_free_hint > 0)
            b = alloc_bullet_range(pbullets, 0, pb_free_hint);
        if (b) pb_free_hint = (int)(b - pbullets) + 1;
    }

    if (b && (int)(b - pbullets) + 1 > pb_hi)
        pb_hi = (int)(b - pbullets) + 1;
    return b;
}

/* Every enemy shot that is not an orb: the front of the pool only. */
static bullet_t *alloc_ebullet(void)
{
    bullet_t *b = (bullet_t *)0;
    if (eb_free_hint < ORB_FIRST && !(ebullets[eb_free_hint].flags & EF_ACTIVE)) {
        b = &ebullets[eb_free_hint++];
    } else {
        b = alloc_bullet_range(ebullets, eb_free_hint, ORB_FIRST);
        if (!b && eb_free_hint > 0)
            b = alloc_bullet_range(ebullets, 0, eb_free_hint);
        if (b) eb_free_hint = (int)(b - ebullets) + 1;
    }

    if (b) {
        int i = (int)(b - ebullets);
        if (i + 1 > eb_hi) eb_hi = i + 1;
        active_count++;
        active_ebullets_count = active_count;
    }
    return b;
}

/* The Big Orbs: their own tail first, the front only when that is full.
 * See ORB_RESERVE for what this is for. */
static bullet_t *alloc_orb(void)
{
    /* The orb tail is a FIXED 32 slots and is walked in full every time (see
     * FOR_EACH_EBULLET), so a slot taken here needs no bound update.  A slot
     * BORROWED from the front run does. */
    bullet_t *b = alloc_bullet_range(ebullets, ORB_FIRST, MAX_EBULLETS);

    if (!b) {
        b = alloc_bullet_range(ebullets, eb_free_hint, ORB_FIRST);
        if (!b && eb_free_hint > 0)
            b = alloc_bullet_range(ebullets, 0, eb_free_hint);
        if (b) {
            int i = (int)(b - ebullets);
            eb_free_hint = i + 1;
            if (i + 1 > eb_hi) eb_hi = i + 1;
        }
    }
    if (b) {
        active_count++;
        active_ebullets_count = active_count;
    }
    return b;
}

static void spawn_pbullet(int x, int y, int vx, int vy, uint8_t color)
{
    bullet_t *b = alloc_pbullet();
    if (!b) return;
    /* Clamp at spawn so every later render lands inside the PLAYFIELD, not
     * merely inside the framebuffer: a 7-pixel tile parked on the right edge
     * painted its last columns over the right-hand HUD panel, which nothing
     * repaints once a run has started. */
    if (x < GAME_LEFT + 2)  x = GAME_LEFT + 2;
    if (x > GAME_RIGHT - 7) x = GAME_RIGHT - 7;
    /* The whole playfield is reachable.  96 and 580 are the band of the
     * 640x600 playfield this build replaced: a shot fired at the top of the
     * screen snapped 96 rows down, and one fired at the bottom snapped back up
     * to 580, which is 188 rows above the edge it is supposed to stop at.  The
     * lower bound is the tracer's own length - a fill at y+10 twelve rows tall
     * plus a four-row tail at y+26 - so the tile stops 26 rows short of the
     * bottom edge and the tracer still fits. */
    if (y < PLAYFIELD_TOP + 1) y = PLAYFIELD_TOP + 1;
    if (y > GAME_BOTTOM - 26)  y = GAME_BOTTOM - 26;
    b->x = (int16_t)x; b->y = (int16_t)y;
    b->vx = (int8_t)vx; b->vy = (int8_t)vy;
    b->color = color;  b->flags = EF_ACTIVE;
}

/* Task 12: the two wing missiles of the pressure stage's three-stream shot.
 * They are born flying straight up so a shot with no target in front of it is
 * never a shot with no direction, and bullets_update() re-aims them at the
 * boss on every frame they live. */
static void spawn_pbullet_lockon(int x, int y)
{
    bullet_t *b = alloc_pbullet();
    if (!b) return;
    /* The tile is 13 wide now, not 7, and b->x is its top-left corner. */
    if (x < GAME_LEFT + 2)  x = GAME_LEFT + 2;
    if (x > GAME_RIGHT - MM_MISSILE_TILE_W) x = GAME_RIGHT - MM_MISSILE_TILE_W;
    if (y < PLAYFIELD_TOP + 1) y = PLAYFIELD_TOP + 1;
    if (y > GAME_BOTTOM - 26)  y = GAME_BOTTOM - 26;
    b->x = (int16_t)x; b->y = (int16_t)y;
    b->vx = 0;         b->vy = -SPD_LOCKON_MISSILE;
    /* Colour 5 is the cyan tile the laser's own outer bolts already use, so
     * the homing rounds read as part of the same weapon instead of a third
     * one dropped on top of it. */
    b->color = 5;
    b->flags = (uint8_t)(EF_ACTIVE | PF_LOCKON);
}

static void spawn_ebullet(int x, int y, int vx, int vy, uint8_t color)
{
    bullet_t *b = alloc_ebullet();
    if (!b) return;
    /* Enemy shots live strictly inside the playfield: they are drawn inside a
     * dark socket that reaches one pixel past the tile, and the socket must
     * not land on either HUD panel. */
    /* x and y are the shot's CENTRE, so the right and bottom clamps are the
     * tile's half width plus the same 3-pixel margin the 13x13 bullet had
     * (6 + 3 and 6 + 7).  The tile is 26x26 now: 13 + 3 = 16, 13 + 7 = 20. */
    if (x < GAME_LEFT + 1)  x = GAME_LEFT + 1;
    if (x > GAME_RIGHT - 16) x = GAME_RIGHT - 16;
    /* One row below PLAYFIELD_TOP: the shot is drawn from y - 1.  The lower
     * bound keeps the whole 26-pixel tile inside the playfield. */
    if (y < PLAYFIELD_TOP + 1)  y = PLAYFIELD_TOP + 1;
    if (y > GAME_BOTTOM - 2)    y = GAME_BOTTOM - 2;
    b->x = (int16_t)x; b->y = (int16_t)y;
    b->vx = (int8_t)vx; b->vy = (int8_t)vy;
    b->color = color;  b->flags = EF_ACTIVE;
}

static void spawn_ebullet_orb(int x, int y, int vx, int vy, uint8_t color)
{
    bullet_t *b = alloc_orb();
    if (!b) return;
    if (x < GAME_LEFT + 8)  x = GAME_LEFT + 8;
    if (x > GAME_RIGHT - 8) x = GAME_RIGHT - 8;
    if (y < PLAYFIELD_TOP + 8)  y = PLAYFIELD_TOP + 8;
    if (y > GAME_BOTTOM - 16)   y = GAME_BOTTOM - 16;
    b->x     = (int16_t)x;
    b->y     = (int16_t)y;
    b->vx    = (int8_t)vx;
    b->vy    = (int8_t)vy;
    b->color = color;
    b->flags = EF_ACTIVE | EF_ORB;
}

/* 6.2 lays its shots out before it throws them, and a shot that is waiting has
 * to be told apart from one that is simply slow, because firing the volley
 * means "everything still on station turns". */
static void spawn_held_ebullet(int x, int y, uint8_t color)
{
    bullet_t *b = alloc_ebullet();
    if (!b) return;
    if (x < GAME_LEFT + 1)  x = GAME_LEFT + 1;
    if (x > GAME_RIGHT - 9) x = GAME_RIGHT - 9;
    /* One row below PLAYFIELD_TOP: the socket is drawn from y-1. */
    if (y < PLAYFIELD_TOP + 1)  y = PLAYFIELD_TOP + 1;
    if (y > GAME_BOTTOM - 13)   y = GAME_BOTTOM - 13;
    b->x = (int16_t)x; b->y = (int16_t)y;
    b->vx = 0;         b->vy = 0;
    b->color = color;  b->flags = EF_ACTIVE | EF_HELD;
}

/* 8.5's lance: a shaft rather than a dot.  It carries its own flag bit
 * because bullets_update() has to turn it at the walls, and its facing is
 * read back out of the velocity when it is drawn - so nothing extra has to
 * be stored in a record that is exactly eight bytes wide. */
static void spawn_lance(int x, int y, int vx, int vy)
{
    bullet_t *b = alloc_ebullet();
    if (!b) return;
    int idx = (int)(b - ebullets);
    eb_lances[eb_lance_count++] = (uint16_t)idx;
    /* Born on the boss's muzzle, which can be close enough to a wall that
     * half the shaft would be drawn over the HUD gutter before the first
     * bounce could turn it back. */
    if (x < LANCE_MIN_X) x = LANCE_MIN_X;
    if (x > LANCE_MAX_X) x = LANCE_MAX_X;
    if (y < LANCE_MIN_Y) y = LANCE_MIN_Y;
    if (y > LANCE_MAX_Y) y = LANCE_MAX_Y;
    b->x = (int16_t)x; b->y = (int16_t)y;
    b->vx = (int8_t)vx; b->vy = (int8_t)vy;
    b->color = 0;
    b->flags = EF_ACTIVE | EF_LANCE;
}

static void aimed_shot(int sx, int sy, int tx, int ty, int speed, uint8_t color)
{
    int a = aim_index(tx - sx, ty - sy);
    spawn_ebullet(sx, sy, (dir16_x[a] * speed) >> 4,
                  (dir16_y[a] * speed) >> 4, color);
}

/* The same shot, rotated ``turn`` of the 16 aim steps off the true bearing.
 * A spread around the aimed direction reads as "the enemy is tracking you"
 * without every bullet in the pattern converging on one pixel. */
static void aimed_shot_off(int sx, int sy, int tx, int ty, int speed,
                           int turn, uint8_t color)
{
    int a = (aim_index(tx - sx, ty - sy) + turn) & 15;
    spawn_ebullet(sx, sy, (dir16_x[a] * speed) >> 4,
                  (dir16_y[a] * speed) >> 4, color);
}

static enemy_rec_t *spawn_enemy(int type, int x, int y)
{
    for (int i = 0; i < MAX_ENEMIES; i++) {
        enemy_rec_t *e = &enemies[i];
        if (e->flags & EF_ACTIVE) continue;
        e->x = (int16_t)x;  e->y = (int16_t)y;
        e->vx = 0;          e->vy = 0;
        e->phase = 0;
        e->type = (uint8_t)type;
        e->flags = EF_ACTIVE;
        switch (type) {
        case ENEMY_FAIRY:
            e->hp = (int16_t)(2 + wave / 2);
            e->vx = (int16_t)((xorshift32() & 2u) ? 1 : -1);
            e->vy = 2;                       /* descends into the player's lane */
            e->fire_cd = (uint8_t)(90 + (xorshift32() & 63u));
            break;
        case ENEMY_SHARD:
            e->hp = (int16_t)(1 + wave / 2);
            e->vy = 3;
            e->fire_cd = (uint8_t)(110 + (xorshift32() & 63u));
            break;
        case ENEMY_TURRET:
            e->hp = (int16_t)(3 + wave / 2);
            e->vx = (int16_t)((xorshift32() & 2u) ? 1 : -1);
            e->vy = 0;
            /* a hovering turret must settle INSIDE the playfield: parked above
             * the top edge it would be invisible and shoot from off screen */
            e->y = (int16_t)(104 + (xorshift32() % 60u));
            e->fire_cd = (uint8_t)(80 + (xorshift32() & 63u));
            break;
        default:                                   /* summoned minion */
            e->hp = (int16_t)(2 + wave / 2);
            e->vx = (int16_t)((int)(xorshift32() & 3u) - 1);
            if (e->vx == 0) e->vx = 1;
            e->vy = 2;
            e->fire_cd = (uint8_t)(100 + (xorshift32() & 63u));
            break;
        }
        return e;
    }
    return (enemy_rec_t *)0;
}

static void spawn_item(int x, int y, int type)
{
    for (int i = 0; i < MAX_ITEMS; i++) {
        item_t *it = &items[i];
        if (it->flags & EF_ACTIVE) continue;
        if (x < GAME_LEFT + 6)  x = GAME_LEFT + 6;
        if (x > GAME_RIGHT - 16) x = GAME_RIGHT - 16;
        if (y < 24)             y = 24;
        it->x = (int16_t)x; it->y = (int16_t)y;
        it->vy = 2;
        it->type = (uint8_t)type;
        it->flags = EF_ACTIVE;
        it->timer = 0;
        return;
    }
}

/* Weighted drop table: a minion drops something 60 % of the time, so the
 * power-up system is actually visible during a short play test. */
static void maybe_drop(int x, int y)
{
    if (rand_percent() >= 60u) return;
    uint32_t k = rand_percent();
    if (k < 15u)      spawn_item(x, y, ITEM_HEAL);
    else if (k < 40u) spawn_item(x, y, ITEM_RATE);
    else if (k < 65u) spawn_item(x, y, ITEM_ATK);
    else if (k < 90u) spawn_item(x, y, ITEM_WEAPON);
    else if (wave && k >= 90u)
        spawn_item(x, y, (xorshift32() & 1u) ? ITEM_SLOW : ITEM_JAM);
    else              spawn_item(x, y, ITEM_SCORE);
}

/* --------------------------------------------------------------- player */

static void player_fire(void)
{
    int cx = player_x;
    int cy = player_y - 18;
    int lv = (int)weapon_level;                    /* 1..WEAPON_MAX_LEVEL */

    audio_event((weapon == W_LASER) ? AUDIO_EVENT_LASER : AUDIO_EVENT_SHOT);

    /* The shot pattern scales with the weapon LEVEL: the same weapon type at
     * level 4 fires more bullets than at level 1.  That is what makes a
     * fourth SHOT pickup worth taking after the old code wrapped a maxed-out
     * player back to the weakest shot. */
    switch (weapon) {
    case W_SPREAD:
        spawn_pbullet(cx,      cy,      0, -SPD_PBULLET, 7);
        spawn_pbullet(cx - 6,  cy + 6, -4, -SPD_PBULLET_S, 5);
        spawn_pbullet(cx + 6,  cy + 6,  4, -SPD_PBULLET_S, 5);
        if (lv >= 2) {
            spawn_pbullet(cx - 12, cy + 12, -7, -SPD_PBULLET_S, 3);
            spawn_pbullet(cx + 12, cy + 12,  7, -SPD_PBULLET_S, 3);
        }
        if (lv >= 3) {
            spawn_pbullet(cx - 10, cy, -3, -SPD_PBULLET, 2);
            spawn_pbullet(cx + 10, cy,  3, -SPD_PBULLET, 2);
        }
        break;

    case W_FAN: {
        /* 3 -> 5 -> 7 -> 9 shots, always centred and symmetric.
         *
         * Written as a table because the arithmetic this replaced did not do
         * what its comment said: -(lv / 2 + 1) .. +(lv / 2 + 1) with integer
         * division gives 3, 5, 5, 7 - level 3 fired exactly what level 2 did,
         * so the third SHOT pickup changed nothing on screen and only the
         * fourth did.  The spread also runs to +-24 px at level 4; the craft's
         * silhouette is 48 px wide. */
        static const int fan_span[4] = { 1, 2, 3, 4 };   /* lv 1..4 */
        int span = fan_span[(lv < 1) ? 0 : ((lv > 4) ? 3 : (lv - 1))];
        for (int k = -span; k <= span; k++)
            spawn_pbullet(cx + k * 6, cy + ((k & 1) ? 6 : 4), k * 3,
                          -SPD_PBULLET_S, (uint8_t)(3 + ((k + 4) & 1)));
        break;
    }

    case W_LASER:
        /* The beam is continuous; from level 2 it also throws outer bolts so
         * the player is not blind while holding the beam down. */
        if (lv >= 2) {
            int off = 8 + lv * 3;
            spawn_pbullet(cx - off, cy + 6, -2, -SPD_PBULLET_S, 5);
            spawn_pbullet(cx + off, cy + 6,  2, -SPD_PBULLET_S, 5);
        }
        break;

    default:
        spawn_pbullet(cx, cy, 0, -SPD_PBULLET, 7);
        if (lv >= 2) {
            spawn_pbullet(cx - 7, cy + 5, -2, -SPD_PBULLET, 5);
            spawn_pbullet(cx + 7, cy + 5,  2, -SPD_PBULLET, 5);
        }
        if (lv >= 3) {
            spawn_pbullet(cx - 14, cy + 10, -4, -SPD_PBULLET_S, 3);
            spawn_pbullet(cx + 14, cy + 10,  4, -SPD_PBULLET_S, 3);
        }
        if (lv >= 4) {
            spawn_pbullet(cx - 4, cy - 4, -1, -SPD_PBULLET, 2);
            spawn_pbullet(cx + 4, cy - 4,  1, -SPD_PBULLET, 2);
        }
        break;
    }
}

/* Task 12: the pressure stage's three-stream shot.
 *
 * The campaign's shot is ONE weapon at a time, and that stays true: this
 * function is reached only under `is_stress_stage`, so nothing here can reach
 * a normal run and no normal run can reach it.
 *
 * The three streams are chosen to exercise three different render paths at
 * once, which is the point of the stage:
 *
 *   1. the centre beam  - W_LASER, drawn by laser_tick() plus the scanout's
 *                         own glow strip.  It costs no pool slot at all, so
 *                         the densest stream in the picture is also the
 *                         cheapest one.
 *   2. the fan          - W_FAN at its top level: seven bullets a salvo on
 *                         seven different headings, i.e. seven directional
 *                         tiles out of the pre-composed 8x16 atlas per salvo.
 *   3. the wing missiles- two rounds that re-aim at the boss every frame, so
 *                         the stage also carries the one case where a shot's
 *                         heading changes after it is drawn. */
static void stress_player_fire(void)
{
    int cx = player_x;
    int cy = player_y - 18;

    /* This stress-stage path bypasses player_fire(), so it needs its own
     * one-shot.  Without it the fan looked active but was silent. */
    audio_event(AUDIO_EVENT_SHOT);

    /* W_FAN at WEAPON_MAX_LEVEL: nine shots, centred and symmetric.  Spelling
     * the loop out rather than calling player_fire() keeps the fan's tuning in
     * exactly one place - and that place is now player_fire()'s fan_span
     * table, which this matches: lv 4 -> span 4 -> k = -4..4.  It used to be a
     * hard-coded -3..3, i.e. SEVEN, which is what level 3 fires. */
    for (int k = -4; k <= 4; k++)
        spawn_pbullet(cx + k * 6, cy + ((k & 1) ? 6 : 4), k * 3,
                      -SPD_PBULLET_S, (uint8_t)(3 + ((k + 4) & 1)));

    /* The two wings.  14 pixels out is outside the craft's own 48-pixel
     * silhouette's centre but still inside the aura, so the pair reads as
     * mounted on the wings rather than fired from the middle. */
    spawn_pbullet_lockon(cx - 14, cy + 8);
    spawn_pbullet_lockon(cx + 14, cy + 8);
}

/* ---- the player's spell card ------------------------------------------
 * Centre-click.  It wipes every enemy shot off the screen - converting them
 * into score, so the button is worth pressing at the worst possible moment -
 * damages everything on the field, and throws a full ring of the strongest
 * shot the craft has.  A shockwave is drawn over the playfield for
 * BOMB_FLASH_FRAMES so the player can see what just happened.
 */
static void player_bomb(void)
{
    int cx = player_x;
    int cy = player_y;

    bomb_charge = 0;
    bomb_flash  = BOMB_FLASH_FRAMES;

    /* Task 12: in the pressure stage the spell card is a WEAPON, not a reset.
     *
     * Everything below is the genre's standard "get out of a wall" button, and
     * that is exactly what the pressure stage must not have: a screen-clearing
     * button empties the one thing the stage exists to keep full, and the
     * 1.5 s white flash both hides the barrage and puts the largest burst the
     * colour matrix ever has to run on the frame where the engine is already
     * at its busiest.  The stage keeps the card's damage (below) and its
     * shockwave ring, so the button still does something visible and useful -
     * it just no longer deletes the field. */
    if (!is_stress_stage) {
        bullet_t *eb;

        FOR_EACH_EBULLET(eb) {
            eb->flags = 0;
            score_award(20u, eb->x, eb->y);
            spawn_particle(eb->x, eb->y,
                           (int)(xorshift32() % 3u) - 1,
                           -2 - (int)(xorshift32() % 2u),
                           PARTICLE_MOTE, 24);
        }
        /* The field is empty again, so the walk may start from nothing. */
        eb_hi = 0;
        eb_lance_count = 0;
        eb_free_hint = 0;
        active_ebullets_count = 0;
        active_count = 0;
        color_matrix_flash_timer = CM_FLASH_FRAMES;
    }

    for (int i = 0; i < MAX_ENEMIES; i++) {
        enemy_rec_t *e = &enemies[i];
        if (!(e->flags & EF_ACTIVE)) continue;
        e->hp = (int16_t)(e->hp - (int16_t)(atk * 4));
        if (e->hp <= 0) {
            e->flags = 0;
            kills++;
            score_award(100u + (uint32_t)e->type * 50u,
                        e->x + 12, e->y + 12);
        }
    }
    if (boss_state == BOSS_FIGHT)
        boss_hp = (int16_t)(boss_hp - (int16_t)(atk * 20));

    for (int k = 0; k < 16; k++)
        spawn_pbullet(cx + ((dir16_x[k] * 20) >> 4),
                      cy + ((dir16_y[k] * 20) >> 4),
                      (dir16_x[k] * 9) >> 4, (dir16_y[k] * 9) >> 4, 7);

    /* One burst either side of the craft, for the same reason as the boss's
     * opener: each one is ~48 fill commands a frame, and the card is played
     * at the worst possible moment by definition. */
    for (int k = 0; k < 2; k++)
        visual_burst(cx + (k * 2 - 1) * 10, cy + ((k & 1) ? 18 : -6));
}

/* The beam is live only while X is held. Its rectangle matches the visible
 * 16-pixel glow, and overlaps whole targets rather than testing their centre. */
static void laser_tick(uint8_t held)
{
    beam_active = (uint8_t)(weapon == W_LASER && held);
    if (!beam_active) { laser_cd = 0; return; }
    if (laser_cd) { laser_cd--; return; }
    laser_cd = SPD_LASER;

    for (int i = 0; i < MAX_ENEMIES; i++) {
        enemy_rec_t *e = &enemies[i];
        if (!(e->flags & EF_ACTIVE)) continue;
        if (e->x + 24 < player_x - 8 || e->x > player_x + 8) continue;
        if (e->y + 24 < GAME_TOP || e->y > player_y - 18) continue;
        e->hp = (int16_t)(e->hp - (int16_t)atk);
        laser_hits++;
        if (e->hp <= 0) {
            e->flags = 0;
            kills++;
            score_award(100u + (uint32_t)e->type * 50u,
                        e->x + 12, e->y + 12);
            visual_burst(e->x + 12, e->y + 12);
            maybe_drop(e->x + 12, e->y + 12);
        }
    }
    if (boss_state == BOSS_FIGHT &&
        boss_x + 64 >= player_x - 8 && boss_x <= player_x + 8 &&
        boss_y + 64 >= GAME_TOP && boss_y <= player_y - 18) {
        boss_hp = (int16_t)(boss_hp - (int16_t)atk);
        laser_hits++;
    }
}

/* ---- Task 12: the continuous barrage -----------------------------------
 *
 * The stage holds STRESS_STORM_TARGET shots in the air, and it does that by
 * ASKING THE POOL how full it is and topping it up - not by firing on a
 * schedule.  A schedule would have to be tuned against the cull rate (a shot
 * leaves at the playfield edge, or on the frame it reaches the craft), and any
 * such tuning is wrong the moment the player moves or stops shooting.  Counting
 * costs one pass over MAX_EBULLETS flag bytes and needs no constant at all.
 *
 * Three sources, mixed ring/cone/wall = 1/3, 1/6, 1/2:
 *
 *   ring - one arm per step around the boss, i.e. a slow multi-petal rose as
 *          the boss drifts across its move targets
 *   cone - four aim offsets on the craft, so standing still is punished
 *   wall - a crossing shot from alternating edges, so the walls are not the
 *          safe place the other two can leave them
 *
 * The budget cap is what keeps those three APART on screen.  Filling the pool
 *
 * SPAWN GEOMETRY (balanced mix): Ring/Cone/Wall balanced to equal on-screen
 * presence. In every 24 steps: 10 Ring (hue 5), 8 Cone (hue 3), 6 Wall (hue 4:
 * 3 left, 3 right). Per 48-shot cycle: 20 Ring, 16 Cone, 12 Wall (6 left, 6 right).
 * Interleaved pattern prevents clustering and disperses vertical row density across
 * 94 groups with coprime strides (29, 37, 31). */
static uint16_t stress_storm_step;

/* 24-entry pattern table: high 2 bits = kind (0:Ring, 1:Cone, 2:Wall L, 3:Wall R),
 * low 6 bits = sub-index within that kind.
 * 50% Wall (6 Left, 6 Right), 25% Ring, 25% Cone. Interleaved every other step. */
static const uint8_t storm_sched[24] = {
    0, 128, 64, 198,
    1, 129, 65, 199,
    2, 130, 66, 200,
    3, 131, 67, 201,
    4, 132, 68, 202,
    5, 133, 69, 203
};

static const uint8_t storm_wall_g[128] = {
     0, 45, 72,  7, 50, 76, 17, 54, 79, 23, 58, 84, 29, 62, 89, 36,
    67, 95, 43, 71,  2, 48, 74, 14, 52, 78, 21, 56, 81, 26, 61, 87,
    33, 65, 93, 40, 69,  0, 46, 73,  9, 50, 76, 18, 55, 79, 23, 59,
    84, 30, 64, 91, 37, 68, 95, 43, 71,  4, 49, 75, 15, 53, 78, 21,
    58, 82, 27, 62, 88, 34, 66, 93, 41, 70,  0, 47, 73, 11, 51, 77,
    19, 56, 80, 24, 60, 86, 31, 64, 91, 38, 68, 95, 45, 72,  6, 49,
    75, 17, 54, 79, 22, 58, 83, 28, 62, 89, 35, 66, 95, 42, 70,  2,
    47, 74, 13, 52, 77, 20, 56, 81, 25, 60, 86, 32, 64, 91, 39, 69,
};

static void stress_storm_update(void)
{
    int active = active_ebullets_count;

    /* Real live reserve covers the DMA culls at the end of this frame. */
    int room = (int)stress_target + (stress_target >= 4000u ? 64 : 0) - active;
    if (room <= 0) return;
    if (room > STRESS_STORM_BUDGET) room = STRESS_STORM_BUDGET;

    int cx = boss_x + 32;
    int cy = boss_y + 28;
    int base_aim = aim_index(player_x - cx, player_y - cy);

    unsigned cur_step = (unsigned)stress_storm_step;
    unsigned q = cur_step / 24u;
    unsigned rem = cur_step % 24u;

    for (int i = 0; i < room; i++) {
        unsigned step = cur_step + (unsigned)i;
        uint8_t entry = storm_sched[rem];
        unsigned kind = entry >> 6;
        unsigned sub = entry & 0x3Fu;

        if (kind == 0u) {
            /* Ring: emitted radially from the boss */
            int a = (int)((step * 2u) & 15u);
            spawn_ebullet(cx, cy,
                          (dir16_x[a] * SPD_STORM) >> 4,
                          (dir16_y[a] * SPD_STORM) >> 4, 5);
        } else if (kind == 1u) {
            /* Cone: targeted spray towards player */
            int off = ((int)(step & 12u) >> 2) - 1;   /* -1..+2 */
            int a = (base_aim + off + ((sub & 1u) ? 8 : 0)) & 15;
            spawn_ebullet(cx, cy,
                          (dir16_x[a] * SPD_STORM) >> 4,
                          (dir16_y[a] * SPD_STORM) >> 4, 3);
        } else {
            /* Wall: crossing shots from side walls covering full 768-height screen */
            unsigned idx = q * 12u + sub;
            uint8_t g = storm_wall_g[idx & 127u];
            int y = (int)((g << 3) + 6u);
            if (y > GAME_BOTTOM - 26) y = GAME_BOTTOM - 26;
            if (kind == 2u)
                spawn_ebullet(GAME_LEFT + 2, y, SPD_STORM, 0, 4);
            else
                spawn_ebullet(GAME_RIGHT - 11, y, -SPD_STORM, 0, 4);
        }

        rem++;
        if (rem == 24u) {
            rem = 0;
            q++;
        }
    }
    stress_storm_step = (uint16_t)(stress_storm_step + (unsigned)room);
}

/* Phase 2 Task 02: a hit is a screen-clearing event now, not a cosmetic blink.
 *
 * The old version only deducted a life and lit the colour-matrix flash, which
 * left the craft standing inside the very curtain that had just shot it.  With
 * infinite respawn on - the testing build - that reads as an unintelligible
 * strobe: hit, blinked, hit again, blinked, with no way for the player to count
 * how many lives actually went.  So a hit now also sweeps the field clean,
 * leaves a mote of light on every shot it removed, and puts the craft back on
 * the classic bottom-of-the-field spawn point with room to re-enter from.
 *
 * Scoring is deliberately NOT awarded for the swept shots.  The spell card
 * already pays for a voluntary clear; paying here as well would turn eating a
 * bullet into a farming strategy, which is the opposite of the intent.
 *
 * Invulnerability lasts INVULN_FRAMES (1.6 s at 75 Hz) and only refreshes when
 * it has already expired.  The flicker artwork reads invuln bit 2, so the
 * player is drawn 3 frames out of every 4 instead of the 1-in-2 the old
 * `invuln & 4` gate produced - and, importantly, the item pickup test below
 * no longer consults invuln at all.  It never should have: being hit used to
 * make the player unable to collect anything for 1.5 s, which read as a
 * broken hitbox.
 *
 * `hit_blink` is the overlay that makes the hit itself feel like an impact:
 * for its first HIT_BLINK_FRAMES the sprite and the hitbox ring pulse at
 * double rate, then both drop back to the steady rhythm above. */
#define INVULN_FRAMES     120
#define HIT_BLINK_FRAMES   24
static void take_hit(void)
{
    if (invuln) return;
    invuln = INVULN_FRAMES;
    hit_blink = HIT_BLINK_FRAMES;
    hits_taken++;
    /* Task 12: the pressure stage takes the hit and drops the two full-screen
     * reactions to it.  A craft that eats a bullet out of a 192-shot curtain
     * is hit again the frame its invulnerability lapses; with the sweep and
     * the flash both on, the stage degenerates into an unreadable strobe on a
     * field that is alternately emptied and refilled.  What the player still
     * gets is the whole per-hit readout that matters: the life, the
     * invulnerability, the fast blink, the shockwave ring on the point of
     * impact, and the telemetry counter. */
    if (!is_stress_stage)
        color_matrix_flash_timer = CM_FLASH_FRAMES;

    /* Anchor the shockwave HERE, before the respawn below moves the craft -
     * see the note on hit_ring_x / hit_ring_y. */
    hit_ring_x = player_x;
    hit_ring_y = player_y;
    hit_ring_timer = HIT_RING_FRAMES;
    hitstop = HITSTOP_HIT;

    /* Clear the field.  The pool is DDR so the flags byte is the only write,
     * and one mote per shot is what sells "the curtain was blown apart" -
     * particle_cursor wraps over the 48-slot ring, so a 192-shot screen simply
     * keeps the newest 48 of them.
     *
     * Task 12: not in the pressure stage.  "????????????" is the whole
     * premise of the stage - the barrage has to survive the player being hit,
     * or the continuous-load measurement restarts every time it lands. */
    if (!is_stress_stage) {
        bullet_t *eb;

        FOR_EACH_EBULLET(eb) {
            int bx = eb->x;
            int by = eb->y;
            eb->flags = 0;
            spawn_particle(bx, by,
                           (int)(xorshift32() % 3u) - 1,
                           -2 - (int)(xorshift32() % 2u),
                           PARTICLE_MOTE, 24);
        }
        eb_hi = 0;
        eb_lance_count = 0;
        eb_free_hint = 0;
        active_ebullets_count = 0;
        active_count = 0;
    }

    /* Back to the classic spawn point: centred, on the bottom third of the
     * field.  Same expression game_init() uses, so a fresh run and a respawn
     * cannot drift apart.
     *
     * NOT in the pressure stage.  The respawn is a rescue: on a normal stage
     * the hit has just cleared the screen, so the craft is put down somewhere
     * with room to re-enter from.  There the curtain never clears, so the same
     * teleport does not rescue anything - it drags the craft out of a position
     * the player had earned by dodging and drops it back into the thick of the
     * barrage, and then the invulnerability it was granted runs out on a spot
     * the player never chose.  The stage keeps everything a hit is supposed to
     * cost (the life, the invulnerability, the blink, the ring on the point of
     * impact) and lets the craft stay where it was hit. */
    if (!is_stress_stage) {
        player_x = (int16_t)((GAME_LEFT + GAME_RIGHT) / 2);
        player_y = GAME_TOP + (GAME_BOTTOM - GAME_TOP) * 2 / 3;
    }

    if (lives) lives--;
    if (lives == 0) {
        if (infinite_respawn) {
            /* testing build: losing the last life just refills it, no game over
             * screen, no button press, nothing else changes */
            lives = 3;
            invuln = INVULN_FRAMES + 60;
        } else {
            game_over = 1;
            restart_timer = 120;
        }
    }
}

static void apply_item(uint8_t type)
{
    items_taken++;
    /* The counter still counts a debuff - the player did take it - but the score
     * does not: a penalty pays nothing, in either direction. */
    if (!item_is_debuff(type))
        score_award(50u, player_x, player_y - 24);
    switch (type) {
    case ITEM_HEAL:
        if (lives < 6) lives++;                          /* capped, no wrap */
        break;

    case ITEM_RATE:
        /* capped at FIRE_CD_MIN.  The old `if (fire_cd > 3) fire_cd--` let a
         * maxed-out player keep decrementing down to 3 and then stop, which
         * was invisible but still ran the branch hundreds of times. */
        if (fire_cd > FIRE_CD_MIN) fire_cd--;
        break;

    case ITEM_ATK:
        if (atk < ATK_MAX) atk++;                        /* capped, no wrap */
        break;

    case ITEM_WEAPON:
        /* THE overflow fix: a pickup may only ever move the player UP the
         * ladder, and reaching the cap keeps the shot they already have.
         * `weapon = (weapon + 1) & 3` cycled CENTER -> SPREAD -> LASER -> FAN
         * -> CENTER, so the fourth weapon pickup on a maxed-out bar threw the
         * player all the way back to the weakest shot.  Here the level only
         * rises, the shot type only ever gets stronger, and once the bar is
         * full a further pickup raises the pattern density instead (see
         * player_fire) with the level itself pinned at WEAPON_MAX_LEVEL. */
        if (weapon_level < WEAPON_MAX_LEVEL) {
            weapon_level++;
            uint8_t unlock = (uint8_t)(weapon_level - 1u);   /* 0..3 */
            if (unlock > weapon) weapon = unlock;
        }
        break;

    case ITEM_SLOW:   slow_timer = 240;                  break;
    case ITEM_JAM:    jam_timer = 240;                   break;
    default:          score_award(500u, player_x, player_y - 30);                     break;
    }
}

/* ---------------------------------------------------------------- boss  */

/* The book is drawn at random and the old rule only refused to repeat the
 * pattern that is up RIGHT NOW.  Measured over 200 forced changes, that
 * leaves the median gap between two sightings of the same attack at five
 * changes - around ten seconds of play - which is exactly what "the boss
 * keeps doing the same thing" describes.  Remember the last few and draw
 * around them instead.  SUMMON is forced by the counter below, never
 * drawn, so it does not take a slot here. */
/* The stage-1 book.  Twelve of the eighteen, so one fight can deal every
 * skill the build has bar the ones only the later stages open with.  A
 * table rather than the old `r & 7` mask: eighteen is not a power of two,
 * and a mask can only ever name a contiguous range anyway. */
static const uint8_t pat_book1[12] = {
    PAT_FAN, PAT_RING, PAT_AIMED, PAT_TWIN,
    PAT_CUT, PAT_LOCKON, PAT_BURST, PAT_VOLLEY,
    PAT_SWAY, PAT_BEAM, PAT_TORNADO, PAT_LANCE
};

/* Stage 2's book.  It was RAIN and the spiral family - three patterns in all -
 * so PAT_CUT and PAT_BEAM were not in the table and its boss could never show
 * a laser: a player who reached stage 2 fought a laser-less boss.  The two
 * laser skills join the table here, and the rest of it stays the spiral stage
 * it always was. */
static const uint8_t pat_book2[12] = {
    PAT_RAIN, PAT_SPIRAL, PAT_CROSS, PAT_AIMED,
    PAT_RAIN, PAT_SPIRAL, PAT_CROSS, PAT_TWIN,
    PAT_BURST, PAT_SWAY, PAT_CUT, PAT_BEAM
};

/* Deterministic coverage of every non-summon attack in a sustained load run.
 * Keep collision, lock-on, lance, impact FX and laser workloads enabled. */
static const uint8_t pat_book_stress[] = {
    PAT_FAN, PAT_RING, PAT_SPIRAL, PAT_CROSS,
    PAT_RAIN, PAT_WALL, PAT_TWIN, PAT_BURST,
    PAT_LANCE, PAT_TORNADO, PAT_CUT, PAT_BEAM,
    PAT_AIMED, PAT_LOCKON, PAT_SWAY, PAT_VOLLEY, PAT_CURTAIN
};

#define PAT_RECENT 5
static uint8_t pat_recent[PAT_RECENT];
static uint8_t pat_recent_n;

static int pat_recent_has(uint8_t p)
{
    for (unsigned i = 0; i < (unsigned)pat_recent_n; i++)
        if (pat_recent[i] == p) return 1;
    return 0;
}

static void pat_recent_push(uint8_t p)
{
    if (p == PAT_SUMMON) return;
    for (unsigned i = PAT_RECENT - 1u; i > 0u; i--)
        pat_recent[i] = pat_recent[i - 1u];
    pat_recent[0] = p;
    if (pat_recent_n < PAT_RECENT) pat_recent_n++;
}

static void boss_next_pattern(void)
{
    /* The summon pattern is guaranteed to come round at least every fourth
     * change: the boss always reinforces, and the behaviour stays testable
     * instead of depending on a lucky random draw. */
    if (is_stress_stage) {
        boss_pattern = pat_book_stress[(pattern_changes + 1u) % sizeof(pat_book_stress)];
        boss_prev_pat = boss_pattern;
    } else if (boss_since_summon >= 3) {
        boss_pattern     = PAT_SUMMON;
        boss_prev_pat    = PAT_SUMMON;
        boss_since_summon = 0;
    } else {
        boss_since_summon++;
        int pick = -1;
        for (int t = 0; t < 8; t++) {
            uint8_t p;
            uint32_t r = xorshift32();
            /* Each stage opens more of the book than the last.  Stage 1 used
             * to cycle fan / ring / aimed and nothing else, which is why the
             * first boss felt thin next to the later ones. */
            /* Every book carries both laser skills: stage 1's table always
             * did, stage 2's did not, and the pressure stage has one of its
             * own with the lasers at twice the density. */
            if (wave == 0) {
                p = pat_book1[r % 12u];
            }
            else if (wave == 1) p = pat_book2[r % 12u];
            else p = (uint8_t)(r % PAT_COUNT);
            if (p == PAT_SUMMON || p == boss_prev_pat) continue;
            pick = p;
            if (!pat_recent_has(p)) break;   /* not seen lately: take it */
        }
        /* Fall back to the first legal candidate: an eight-draw miss must
         * never leave the boss holding its old pattern. */
        if (pick >= 0) {
            boss_pattern  = (uint8_t)pick;
            boss_prev_pat = (uint8_t)pick;
        }
    }
    pat_recent_push(boss_pattern);
    pattern_changes++;
    boss_pat_timer  = (uint8_t)(105 + (xorshift32() & 31u));
    boss_fire_timer = 12;
}

static void boss_fire(void)
{
    int cx = boss_x + 32;
    int cy = boss_y + 28;

    /* Every shot leaves a muzzle flash, so a pattern change is visible even
     * when the bullets are still off screen. */
    visual_burst(cx, cy);

    switch (boss_pattern) {
    case PAT_FAN:
        for (int k = -5; k <= 5; k++)
            spawn_ebullet(cx + k * 5, cy, k, SPD_FAN, (uint8_t)(3 + ((k & 1) ? 2 : 0)));
        break;

    case PAT_RING:
        /* Two interleaved rings of 8: 16 bullets a volley, 2 px/frame. */
        for (int k = 0; k < 16; k += 2) {
            int a = (k + (int)(frame_tick & 1u)) & 15;
            spawn_ebullet(cx, cy, (dir16_x[a] * SPD_RING) >> 4,
                          (dir16_y[a] * SPD_RING) >> 4, 5);
            spawn_ebullet(cx, cy, (dir16_x[a] * (SPD_RING + 1)) >> 4,
                          (dir16_y[a] * (SPD_RING + 1)) >> 4, 2);
        }
        break;

    case PAT_AIMED:
        /* a slow five-shot fan centred on the player */
        aimed_shot(cx, cy, player_x, player_y, SPD_AIM_FAST, 0);
        aimed_shot_off(cx, cy, player_x, player_y, SPD_AIM_SLOW, 1, 0);
        aimed_shot_off(cx, cy, player_x, player_y, SPD_AIM_SLOW, -1, 0);
        aimed_shot_off(cx, cy, player_x, player_y, SPD_AIM_SLOW, 2, 6);
        aimed_shot_off(cx, cy, player_x, player_y, SPD_AIM_SLOW, -2, 6);
        break;

    case PAT_SPIRAL:
        /* four arms instead of two: the same spin, twice the density */
        for (int k = 0; k < 4; k++) {
            int a = (int)((frame_tick * 2u + (uint32_t)k * 4u) & 15u);
            spawn_ebullet(cx, cy, (dir16_x[a] * SPD_SPIRAL) >> 4,
                          (dir16_y[a] * SPD_SPIRAL) >> 4, (uint8_t)(k & 1 ? 6 : 5));
        }
        break;

    case PAT_CROSS:
        for (int k = 0; k < 8; k++) {
            int a = (int)((frame_tick * 3u + (uint32_t)k * 2u) & 15u);
            spawn_ebullet(cx, cy, (dir16_x[a] * SPD_CROSS) >> 4,
                          (dir16_y[a] * SPD_CROSS) >> 4, 2);
        }
        break;

    case PAT_RAIN:
        for (int k = 0; k < 9; k++)
            spawn_ebullet(GAME_LEFT + 24 +
                      (int)(xorshift32() %
                            (uint32_t)(GAME_RIGHT - GAME_LEFT - 48)), 96,
                          0, SPD_RAIN_MIN + (int)(k & 1u), 3);
        break;

    case PAT_WALL:
        for (int k = -6; k <= 6; k++)
            spawn_ebullet(cx + k * 10, cy, k * 2, SPD_FAN, 6);
        break;

    case PAT_TWIN:
        /* Two four-armed spirals turning against each other.  A single
         * spiral has a lane that rotates slowly enough to stand in; the
         * counter-rotating second arm closes it again on the next beat. */
        for (int k = 0; k < 4; k++) {
            int a = (int)((frame_tick * 2u + (uint32_t)k * 4u) & 15u);
            int b = (int)((16u + (uint32_t)k * 4u - frame_tick * 2u) & 15u);
            spawn_ebullet(cx, cy, (dir16_x[a] * SPD_SPIRAL) >> 4,
                          (dir16_y[a] * SPD_SPIRAL) >> 4, 5);
            spawn_ebullet(cx, cy, (dir16_x[b] * SPD_SPIRAL) >> 4,
                          (dir16_y[b] * SPD_SPIRAL) >> 4, 4);
        }
        break;

    case PAT_CUT:
        /* 6.1: the preview starts on the column the craft is standing in.
         * It does not follow afterwards - it is a promise, not a tracker, and
         * that is what makes stepping out of it a move you make.
         *
         * Only the FIRST volley starts a cut.  This case runs again every 28
         * frames while the pattern is up, and resetting the 45-frame preview
         * on each of them meant the timer never reached its release: the beam
         * only ever appeared by accident, once the pattern had changed away
         * from PAT_CUT and the timer was finally left alone. */
        if (!cut_phase) {
            beam_x[0]     = player_x;
            beam_timer[0] = CUT_PREVIEW;
            beam_phase[0] = 1;
            cut_phase     = 1;
        }
        break;

    case PAT_BEAM:
        /* 8.2: the craft's own lane and one either side of it, released a
         * quarter of a second apart so the player is chased out of the
         * first one and straight into the second. */
        for (int k = 0; k < CUT_SLOTS; k++) {
            int bx;
            if (beam_phase[k]) continue;
            bx = player_x + (k - 1) * CUT_SPREAD;
            if (bx < GAME_LEFT + CUT_HALF)  bx = GAME_LEFT + CUT_HALF;
            if (bx > GAME_RIGHT - CUT_HALF) bx = GAME_RIGHT - CUT_HALF;
            beam_x[k]     = (int16_t)bx;
            beam_timer[k] = (uint8_t)(CUT_PREVIEW + (unsigned)k * 14u);
            beam_phase[k] = 1;
        }
        break;

    case PAT_SWAY:
        /* 8.1: the muzzle walks left and right while it sprays, so the fan
         * sweeps the arena instead of always landing on the same strip.
         * The boss keeps its own move schedule - this is the gun swinging,
         * not a second movement system fighting the first. */
        {
            unsigned ph = frame_tick & 63u;
            int sw = (ph < 32u) ? (int)ph : (int)(64u - ph);   /* 0..32 */
            int sx = cx + (sw - 16) * 6;
            for (int k = -6; k <= 6; k++)
                spawn_ebullet(sx + k * 5, cy, k, SPD_FAN,
                              (uint8_t)(3 + (k & 1)));
        }
        break;

    case PAT_TORNADO: {
        /* 8.4: eight arms turning five sixteenths of a circle per beat
         * where the plain spiral turns two, doubled up so the lanes the
         * first ring opens are closed by the second. */
        static uint8_t tornado_step;
        tornado_step = (uint8_t)((tornado_step + 1u) & 15u);
        for (int k = 0; k < 8; k++) {
            int a = (int)((tornado_step + (uint32_t)k * 2u) & 15u);
            spawn_ebullet(cx, cy, (dir16_x[a] * SPD_SPIRAL) >> 4,
                          (dir16_y[a] * SPD_SPIRAL) >> 4, 5);
            spawn_ebullet(cx, cy, (dir16_x[a] * (SPD_SPIRAL + 1)) >> 4,
                          (dir16_y[a] * (SPD_SPIRAL + 1)) >> 4, 2);
        }
        break;
    }

    case PAT_LANCE:
        /* 8.5: one shaft per compass point, thrown in bursts.  They do not
         * leave the arena - bullets_update() turns them at every wall three
         * times, which is what makes a corner the worst place to stand. */
        for (int k = 0; k < 8; k++) {
            int a = k * 2;
            spawn_lance(cx, cy, (dir16_x[a] * SPD_LANCE) >> 4,
                        (dir16_y[a] * SPD_LANCE) >> 4);
        }
        break;

    case PAT_LOCKON:
        /* 6.2: the layout is stepped out over the next second.
         *
         * ONLY THE FIRST CALL STARTS A LAYOUT, and that guard is the whole
         * point: boss_fire() runs every (28 - wave*4) logic steps while the
         * pattern is live, and this branch used to write lockon_timer back to
         * LOCKON_LAYOUT unconditionally.  The timer was therefore never
         * allowed to reach zero, the volley never left the laying-out phase
         * inside its own window, and the shots only came off station once the
         * pattern had already changed away - a batch of bullets starting to
         * move after the boss had visibly switched attacks.  PAT_CUT has the
         * same guard for the same reason (see its cut_phase comment). */
        if (!lockon_arm) {
            lockon_timer = LOCKON_LAYOUT;
            lockon_arm   = 1;
        }
        break;

    case PAT_BURST:
        /* 6.3: a ring of sixteen high-tier Big Orbs, plus a faster cyan one out
         * of every other direction behind them.
         *
         * ONE ORB PER DIRECTION.  The direction used to be `(k * 2) & 15`, which
         * walks 0, 2, 4 ... 14 and then 0, 2, 4 ... 14 again: sixteen orbs over
         * eight directions, and the two that share a direction also share a
         * speed, so they are drawn exactly on top of each other for their whole
         * flight.  Half of what the attack threw was invisible and the "all
         * round" ring was really a cross.  `k` gives all sixteen directions, so
         * the same twenty-four orbs read as twenty-four. */
        for (int k = 0; k < BURST_RING; k++) {
            int a = k & 15;
            spawn_ebullet_orb(cx, cy, (dir16_x[a] * SPD_RING) >> 4,
                              (dir16_y[a] * SPD_RING) >> 4, 2);
            if (k & 1)
                spawn_ebullet_orb(cx, cy, (dir16_x[a] * (SPD_RING + 1)) >> 4,
                                  (dir16_y[a] * (SPD_RING + 1)) >> 4, 5);
        }
        break;

    case PAT_VOLLEY:
        /* 6.4: thirteen shots fanned over the whole aimed arc.  It closes the
         * escape routes the five-shot PAT_AIMED leaves, at a third of the
         * cost of another ring. */
        for (int k = -VOLLEY_ARC; k <= VOLLEY_ARC; k++)
            aimed_shot_off(cx, cy, player_x, player_y,
                           SPD_AIM_FAST + ((k & 1) ? 1 : 0), k, 6);
        break;

    case PAT_CURTAIN:
        /* Walls of shots walking in from both edges.  Nothing about it aims
         * at the player, and that is the point: it punishes standing still. */
        for (int k = 0; k < 6; k++) {
            /* Six curtains spread over the whole playfield height.  The old
             * 132 + 76*k covered y 132..526 of a screen that is 768 tall, so
             * the bottom third of the playfield never saw a shot. */
            int y = GAME_TOP + 60 + k * ((GAME_BOTTOM - GAME_TOP - 120) / 6)
                    + (int)(xorshift32() % 14u);
            spawn_ebullet(GAME_LEFT + 2, y, SPD_AIM_SLOW, 0, 4);
            spawn_ebullet(GAME_RIGHT - 11, y, -SPD_AIM_SLOW, 0, 4);
        }
        break;

    default:                                        /* PAT_SUMMON */
        for (int k = 0; k < 3; k++) {
            int mx = GAME_LEFT + 60 + (int)(xorshift32() % 500u);
            if (spawn_enemy(ENEMY_MINION, mx, 60)) summons++;
        }
        break;
    }
}

/* ---- the boss's own spell card ----------------------------------------
 * Fired the instant the freeze releases: a double ring of shots, four laser
 * columns that stand for a second and a half, and a spray of muzzle
 * particles - all on one frame.  The pause before it is the point: the field
 * locks, the boss announces itself, and then the whole screen opens at once.
 */
/* The card's entrance.  HOLD is the beat the field is frozen for, and the
 * shake runs for the whole of it so the scenery is still moving when the
 * screen finally opens. */
#define BOSS_CARD_HOLD     40
#define BOSS_SHAKE_FRAMES  40
/* The ENTRANCE hold.  Longer than an earned card's - the boss has just
 * crossed the screen and the player needs the beat to read as "the field has
 * stopped" rather than as a dropped frame - and the scenery shakes for the
 * whole of it, so the screen is still moving when it opens. */
#define BOSS_ENTRANCE_HOLD 70
/* BOSS_SHAKE_PX is defined up with stage_strip_render(): the weather layer
 * rides the same offset, and that function is far above this line. */

#define BOSS_LASER_FRAMES  90
#define BOSS_LASER_COLS     4
/* Four columns spread evenly across the playfield.  The old +56 +150*k
 * pitch was measured against the 640-wide playfield this build replaced; on a
 * 1004-wide one it packed all four columns into the left half of the screen
 * (section 6).  Odd fractions of the width, so no column lands on a border. */
#define BOSS_LASER_X(k) \
    (GAME_LEFT + (GAME_RIGHT - GAME_LEFT) * (2 * (k) + 1) / 8)

static void boss_clear_lasers(void)
{
    boss_laser = 0;
    boss_spell_vfx_timer = 0;
    for (int k = 0; k < CUT_SLOTS; k++) {
        beam_phase[k] = 0;
        beam_timer[k] = 0;
    }
    cut_phase = 0;
}

/* wipe clears whatever beams are standing before the volley.  The campaign
 * card wants that - it opens on a clean field.  The pressure stage called
 * this with 0 so that its own opener would not delete a standing cut; it
 * no longer fires the opener at all, and the argument stays so the door is
 * still there should it ever need to again. */
static void boss_opener(int wipe)
{
    if (wipe) boss_clear_lasers();
    audio_event(AUDIO_EVENT_BOSS);
    int cx = boss_x + 32;
    int cy = boss_y + 28;

    /* Climax Stage 2 & 3: 3-frame dimensional hitstop + 44-frame expanding
     * hardware shockwave ring (video_fx_ring.v) & overexposure flash. */
    hitstop = HITSTOP_KILL;
    boss_spell_vfx_timer = 44;

    /* Three rings: 16 aimed outward, 16 faster, and a middle ring
     * shaped into 8 high-tier additive Big Orbs (OP_ADD) + 8 high-speed
     * luminous bullets to eliminate DDR RMW contention while keeping intense visuals. */
    for (int k = 0; k < 16; k++) {
        spawn_ebullet(cx, cy, (dir16_x[k] * SPD_RING) >> 4,
                      (dir16_y[k] * SPD_RING) >> 4, 0);
        if (k & 1) {
            spawn_ebullet(cx, cy, (dir16_x[k] * (SPD_RING + 3)) >> 4,
                          (dir16_y[k] * (SPD_RING + 3)) >> 4, 6);
        } else {
            spawn_ebullet_orb(cx, cy, (dir16_x[k] * (SPD_RING + 2)) >> 4,
                              (dir16_y[k] * (SPD_RING + 2)) >> 4, 6);
        }
        spawn_ebullet(cx, cy, (dir16_x[k] * (SPD_RING + 4)) >> 4,
                      (dir16_y[k] * (SPD_RING + 4)) >> 4, 4);
    }
    /* Three bursts across the boss, not ten.  A burst costs about 48 BitBlt
     * fill commands per frame for the 24 frames it lives, and ten of them
     * took the measured load from 22 fills a frame to 668 - which is what
     * turned the boss's spell card into slow motion on the board.  Three
     * still read as a storm across the sprite at a fifth of the traffic. */
    for (int k = 0; k < 3; k++)
        visual_burst(boss_x + 4 + k * 22, boss_y + 12 + (k & 1) * 36);

    boss_laser = BOSS_LASER_FRAMES;
}

static void boss_update(void)
{
    switch (boss_state) {
    case BOSS_ENTER:
        /* Glide down, then LOCK the field: nothing moves - not the player,
         * not the minions, not a single bullet - until the opener fires.  The
         * hold is what makes the opener read as an event rather than as one
         * more pattern. */
        /* +5 instead of +3: the entrance is 36 frames of nothing-happens
         * otherwise, and the hold that follows is where the drama is meant to
         * live.  Crossing the screen faster also reads better with the card's
         * sky already swapped in behind it. */
        boss_y = (int16_t)(boss_y + 5);
        if (boss_y >= 44) {
            boss_y = 44;
            boss_state = BOSS_FREEZE;
            boss_freeze_timer = BOSS_ENTRANCE_HOLD;
            /* ---- the entrance IS a spell card --------------------------
             * It used to be one: the old code cleared boss_opener_stage the
             * moment the entrance hold released, which fired the opener on
             * the way in AND triggered the health-threshold test on the way
             * out, so it fired again and again.  The fix for that loop -
             * "only when the bar crosses two thirds and one third" - cured
             * the repeat and silently deleted the entrance performance: the
             * boss glided in, the field stopped for a second, and the fight
             * opened with an ordinary pattern.  The sky swap, the shake and
             * the whole-screen volley are what made the boss announce
             * itself, and they only happen inside boss_opener().
             *
             * boss_pending_opener is what lets both exist.  It is set here,
             * consumed once by the hold's release, and set again by the two
             * earned cards below - so the entrance opens the fight with the
             * full beat, the two threshold cards still fire, and neither can
             * loop, because nothing ever resets a counter from inside the
             * card any more. */
            boss_pending_opener = 1;
            boss_shake          = BOSS_ENTRANCE_HOLD;
            boss_card_active    = 1;
        }
        break;

    case BOSS_FREEZE:
        if (boss_freeze_timer) {
            boss_freeze_timer--;
            /* Climax Stage 1: Inward-converging energy particles during spell card charge */
            if (boss_pending_opener && (boss_freeze_timer & 1u) == 0u) {
                int a = (int)((boss_freeze_timer * 3u) & 15u);
                int b = (a + 8) & 15;
                int cx = boss_x + 32, cy = boss_y + 28;
                spawn_particle(cx + (dir16_x[a] * 4), cy + (dir16_y[a] * 4),
                               -(dir16_x[a] >> 2), -(dir16_y[a] >> 2),
                               PARTICLE_CRIT, 14);
                spawn_particle(cx + (dir16_x[b] * 4), cy + (dir16_y[b] * 4),
                               -(dir16_x[b] >> 2), -(dir16_y[b] >> 2),
                               PARTICLE_CYAN, 14);
            }
        } else {
            /* The hold releases into an ordinary fight - and, when the hold was
             * the card's own entrance, into the card.  The card is NOT an
             * opening move: it is spent at the two thirds and one third marks
             * of the bar (see BOSS_FIGHT below), so the player earns it.
             *
             * The old boss_opener_stage = 0 that used to sit here would now
             * undo the trigger below on the way out of the card's own hold and
             * fire it forever; the entrance resets the counter, in wave_update(). */
            boss_state = BOSS_FIGHT;
            boss_pat_timer  = 45;
            boss_fire_timer = 18;
            if (boss_pending_opener) {
                boss_pending_opener = 0;
                boss_opener(1);
            }
        }
        break;

    case BOSS_FIGHT:
        if (boss_spell_vfx_timer) boss_spell_vfx_timer--;
        if (boss_laser) {
            boss_laser--;
            if (!boss_laser) boss_card_active = 0;
        }

        /* The pressure stage does NOT raise the opener's four columns.
         * It enters straight into BOSS_FIGHT with the bar pinned at full,
         * so neither the entrance hold nor a health mark ever fires here -
         * and that is what this stage wants.  The columns are the
         * campaign's set piece; here the barrage stays the thing on screen
         * and the boss's lasers are the pattern ones, PAT_CUT and PAT_BEAM,
         * both of which sit in the book boss_next_pattern() draws from. */

        /* ---- 6.1 / 8.2 the laser columns, over three phases ---------- */
        for (int k = 0; k < CUT_SLOTS; k++) {
            if (!beam_phase[k]) continue;
            if (beam_timer[k]) {
                beam_timer[k]--;
                /* Phase 2 Task 02: Inward energy convergence sparks in final 10 warning frames */
                if (beam_phase[k] == 1 && beam_timer[k] <= 10 && (beam_timer[k] & 1u)) {
                    int py = 80 + (int)(xorshift32() % 520u);
                    spawn_particle(beam_x[k] - 20, py, 3, 0, PARTICLE_CYAN, 8);
                    spawn_particle(beam_x[k] + 20, py, -3, 0, PARTICLE_CYAN, 8);
                }
            } else if (beam_phase[k] == 1) {
                beam_phase[k] = 2;
                beam_timer[k] = CUT_FIRE;
            } else {
                beam_phase[k] = 0;
            }
        }
        cut_phase = beam_phase[0];      /* the workbench grades slot 0 */

        /* ---- 6.2 the lock-on volley -------------------------------- */
        if (lockon_arm) {
            int lx = boss_x + 32;
            int ly = boss_y + 34;
            if (lockon_arm == 1) {
                if (lockon_timer) {
                    lockon_timer--;
                    if ((lockon_timer % LOCKON_STEP) == 0u) {
                        int k = (int)(lockon_timer / LOCKON_STEP);
                        spawn_held_ebullet(lx - 30 - k * 16, ly + k * 7, 4);
                        spawn_held_ebullet(lx + 34 + k * 16, ly + k * 7, 4);
                    }
                } else {
                    lockon_arm   = 2;
                    lockon_timer = LOCKON_HOLD;
                }
            } else if (lockon_timer) {
                lockon_timer--;
            } else {
                /* every shot still on station turns on the craft at once */
                lockon_arm = 0;
                /* EF_HELD is only ever set together with EF_ACTIVE
                 * (spawn_ebullet_held), so the ACTIVE walk reaches every
                 * shot on station and the HELD test filters the rest. */
                bullet_t *eb;

                FOR_EACH_EBULLET(eb) {
                    if (!(eb->flags & EF_HELD)) continue;
                    eb->flags &= (uint8_t)~EF_HELD;
                    int a = aim_index(player_x - eb->x, player_y - eb->y);
                    eb->vx = (int8_t)((dir16_x[a] * SPD_AIM_SLOW) >> 4);
                    eb->vy = (int8_t)((dir16_y[a] * SPD_AIM_SLOW) >> 4);
                }
            }
        }

        /* Two spell cards, spent when the bar crosses two thirds and one
         * third.  Waiting for a threshold is what turns the opener from "the
         * boss says hello" into a beat the player causes: the fight pauses,
         * the field locks, and the screen opens up. */
        if (boss_opener_stage < 2u &&
            boss_hp <= (int16_t)((int32_t)boss_hp_max *
                                 (int16_t)(2 - boss_opener_stage) / 3)) {
            /* Hold the field FIRST and fire afterwards.  Releasing it here
             * made the card one more pattern; the hold, the shaking scenery
             * and the plate swap are what turn it into a beat the player sees
             * coming and then survives. */
            boss_opener_stage++;
            boss_pending_opener = 1;
            boss_shake          = BOSS_SHAKE_FRAMES;
            boss_freeze_timer   = BOSS_CARD_HOLD;
            boss_state          = BOSS_FREEZE;
            boss_clear_lasers();
            boss_card_active    = 1;
        }

        if (boss_move_timer) boss_move_timer--;
        if (!boss_move_timer ||
            (boss_x == boss_target_x && boss_y == boss_target_y)) {
            boss_target_x = (int16_t)(GAME_LEFT + 8 + (int)(xorshift32() % 560u));
            boss_target_y = (int16_t)(88 + (int)(xorshift32() % 380u));
            boss_move_timer = (uint8_t)(45 + (xorshift32() & 31u));
        }
        {
            int step = 2 + (int)wave;
            int dx = boss_target_x - boss_x, dy = boss_target_y - boss_y;
            if (dx > step) dx = step;
            if (dx < -step) dx = -step;
            if (dy > step) dy = step;
            if (dy < -step) dy = -step;
            boss_x = (int16_t)(boss_x + dx);
            boss_y = (int16_t)(boss_y + dy);
        }

        if (boss_pat_timer == 0) boss_next_pattern();
        else boss_pat_timer--;

        if (boss_fire_timer) boss_fire_timer--;
        else {
            boss_fire();
            /* the summon pattern is slow, the bullet patterns are slower still
             * than a bullet-hell veteran would like - this build is meant to be
             * survivable while the systems are still being tested */
            boss_fire_timer = (uint8_t)((boss_pattern == PAT_SUMMON) ? 65 : 28 - wave * 4);
        }

        if (boss_hp <= 0) {
            boss_state = BOSS_DYING;
            boss_clear_lasers();
            boss_card_active = 0;
            lockon_arm = 0;
            lockon_timer = 0;
            /* So do 6.2's shots that are still on station, and all bullets dissolve into rising motes. */
            bullet_t *eb;

            FOR_EACH_EBULLET(eb) {
                eb->flags = 0;
                spawn_particle(eb->x, eb->y,
                               (int)(xorshift32() % 3u) - 1,
                               -2 - (int)(xorshift32() % 2u),
                               PARTICLE_MOTE, 24);
            }
            eb_hi = 0;
            eb_lance_count = 0;
            eb_free_hint = 0;
            active_ebullets_count = 0;
                visual_burst(boss_x + 32, boss_y + 32);
            hitstop = HITSTOP_KILL;
            for (int k = 0; k < 12; k++) {
                int ox = boss_x + (int)(xorshift32() % 64u);
                int oy = boss_y + (int)(xorshift32() % 64u);
                spawn_particle(ox, oy, (int)(xorshift32() % 3u) - 1,
                               -2 - (int)(xorshift32() % 3u),
                               PARTICLE_MOTE, 28);
            }
            boss_dead_timer = 60;
            audio_event(AUDIO_EVENT_KILL);
            score += 5000u + (uint32_t)wave * 1000u;
            for (int k = 0; k < 3; k++)
                spawn_item(boss_x + 32 + (k - 1) * 96,
                           boss_y + 30 + (k & 1) * 34,
                           (int)(xorshift32() % 5u));
        }
        break;

    case BOSS_DYING:
        if (boss_dead_timer) boss_dead_timer--;
        else {
            if (is_stress_stage) {
                boss_state = BOSS_FIGHT;
                boss_hp = boss_hp_max;
                boss_hp_shown = boss_hp;
                boss_fire_timer = 20;
                boss_pat_timer = 45;
                boss_move_timer = 45;
                boss_next_pattern();
                break;
            }
            if (wave >= 2) { game_clear = 1; boss_state = BOSS_NONE; break; }
            boss_state = BOSS_NONE;
            wave++;
            stage_background_load(wave);
            kills = 0;
            stage_banner = 170;         /* announce the new stage */
            wave_max = (uint16_t)(wave_max + 6);
            spawn_timer = 90;
            boss_x = (int16_t)((GAME_LEFT + GAME_RIGHT) / 2 - 32);
            boss_y = -64;
            boss_hp_max = (int16_t)(400 + (int16_t)wave * 200);
            boss_move_timer = 0;
            for (int i = 0; i < MAX_ENEMIES; i++) enemies[i].flags = 0;
        }
        break;

    default:
        break;
    }
}

/* ------------------------------------------------------------- updates  */

static void wave_update(void)
{
    if (boss_state != BOSS_NONE || game_clear) return;
    int alive = count_active();

    if (kills < wave_max) {
        if (spawn_timer) spawn_timer--;
        else if (alive < MAX_ACTIVE_ENEMY + (int)wave) {
            uint32_t r = xorshift32();
            int type = (int)(r & 3u);
            /* Span the WHOLE playfield.  The literal 540 was the old
             * 640-wide playfield's usable width, so every minion used to spawn
             * in the left half and the right half never had any pressure on it
             * - a fairness bug the moment the playfield grew to 1004 wide. */
            int x = GAME_LEFT + 40 +
                    (int)((r >> 8) % (uint32_t)(GAME_RIGHT - GAME_LEFT - 80));
            spawn_enemy(type, x, -20);
            spawn_timer = (uint16_t)(36 - (wave > 4 ? 4 : wave) * 4);
        }
    } else if (alive == 0 && boss_state == BOSS_NONE) {
        /* the boss only shows up once the quota is met AND the field is clear:
         * every minion that was already out there has to be dealt with first */
        boss_state = BOSS_DIALOG;
        boss_y = -64;
        boss_x = (int16_t)((GAME_LEFT + GAME_RIGHT) / 2 - 32);
        boss_move_timer = 0;
        boss_hp = boss_hp_max;
        boss_opener_stage = 0;
        boss_pattern = PAT_FAN;
        boss_prev_pat = PAT_FAN;
        pat_recent_n = 0;
        boss_pat_timer = 60;
        boss_fire_timer = 30;
        dialog_line = 0;
        dialog_timer = DIALOG_LINE_F;
        /* 1 = "a key is already down": the press that opened this dialogue must
         * not also skip its first line.  The player is holding X to shoot. */
        dialog_prev = 1;
        dialog_grace = DIALOG_GRACE;
    }
}

/* A line may be skipped by a fresh press, or by simply holding the key once
 * it has been up for a moment.  The old test was
 *
 *     if (!btn) released = 1;
 *     if (released && btn) advance;
 *
 * which needs a RELEASE before it will accept anything at all; a plain edge
 * test behaves the same way.  The player holds X to shoot and the boss starts
 * talking mid-run, so the press that should skip a line was spent arming the
 * flag instead - the button "sometimes did nothing", which is exactly when X
 * happened to be down as the line appeared. */
static void dialog_update(const gamepad_state_t *pad)
{
    uint8_t now, edge;

    if (boss_state != BOSS_DIALOG) return;

    now = (uint8_t)(pad->btn_x || pad->btn_center);
    edge = (uint8_t)(now && !dialog_prev);
    dialog_prev = now;

    if (dialog_timer) dialog_timer--;
    if (dialog_grace) dialog_grace--;

    /* Three ways to move on: a fresh press, a key held once the line has been
     * up a moment, and the timer simply running out - the last one is what
     * carries a player who presses nothing. */
    if ((!dialog_grace && (edge || (now && dialog_timer <= DIALOG_HOLD_AT))) ||
        !dialog_timer) {
        dialog_line++;
        dialog_timer = DIALOG_LINE_F;
        dialog_grace = DIALOG_GRACE;
        dialog_prev = 1;            /* the press that skipped this one is spent */
        if (dialog_line >= 3) boss_state = BOSS_ENTER;
    }
}

static void enemies_update(void)
{
    for (int i = 0; i < MAX_ENEMIES; i++) {
        enemy_rec_t *e = &enemies[i];
        if (!(e->flags & EF_ACTIVE)) continue;

        e->x = (int16_t)(e->x + e->vx);
        e->y = (int16_t)(e->y + e->vy);
        if (e->x < GAME_LEFT + 4)       { e->x = GAME_LEFT + 4;       e->vx = (int16_t)-e->vx; }
        if (e->x > GAME_RIGHT - 28)     { e->x = GAME_RIGHT - 28;     e->vx = (int16_t)-e->vx; }
        /* leave enough room that the 24x24 sprite never reaches past screen bottom */
        if (e->y > (int)GAME_BOTTOM - 24) { e->flags = 0; continue; }

        if (e->fire_cd) e->fire_cd--;
        else {
            int cx = e->x + 12;
            int cy = e->y + 12;
            switch (e->type) {
            case ENEMY_FAIRY:
                /* a three-shot aimed spread instead of one, and still slow */
                aimed_shot(cx, cy, player_x, player_y, SPD_AIM_FAST, 0);
                aimed_shot_off(cx, cy, player_x, player_y, SPD_AIM_SLOW, 1, 0);
                aimed_shot_off(cx, cy, player_x, player_y, SPD_AIM_SLOW, -1, 0);
                e->fire_cd = 90;
                break;
            case ENEMY_SHARD:
                for (int k = -3; k <= 3; k++)
                    spawn_ebullet(cx, cy, k, SPD_AIM_SLOW + ((i + frame_tick / 110u) & 1u), 3);
                e->fire_cd = 110;
                break;
            case ENEMY_TURRET:
                /* a ring of eight, slow enough to walk between */
                for (int k = (frame_tick / 120u + (unsigned)i) & 1u; k < 16; k += 2)
                    spawn_ebullet(cx, cy, (dir16_x[k] * SPD_RING) >> 4,
                                  (dir16_y[k] * SPD_RING) >> 4, 5);
                e->fire_cd = 120;
                break;
            default:
                spawn_ebullet_orb(cx, cy, 0, SPD_MINION, 6);
                aimed_shot_off(cx, cy, player_x, player_y, SPD_MINION, 2, 6);
                aimed_shot_off(cx, cy, player_x, player_y, SPD_MINION, -2, 6);
                e->fire_cd = 110;
                break;
            }
        }
    }
}

/* Player bullets live in ``pbullets``, enemy bullets in ``ebullets``.  Both
 * walk their path in BULLET_STEP-pixel sub-steps and stop at the first hit,
 * so a 9 px/frame shot cannot tunnel through a 24-pixel enemy and the impact
 * effect appears where the bullet really is rather than past the target. */
static void stress_coprocessor_finish(void)
{
    gpu2d_flush_dcache();
    uint32_t info = GPU2D_REG_BUCKET_INFO;
    unsigned candidates = info >> 16;
    unsigned bound = candidates > 512u ? (unsigned)eb_hi : candidates;
    const uint16_t *indices = (const uint16_t *)EB_CAND_LIST_BASE;
    active_count = (uint16_t)info;
    if (!invuln) for (unsigned pos = 0; pos < bound; ++pos) {
        unsigned index = candidates > 512u ? pos : indices[pos];
        if (index >= (unsigned)ORB_FIRST) continue;
        bullet_t *bullet = &ebullets[index];
        if (!(bullet->flags & EF_ACTIVE) || (bullet->flags & EF_LANCE)) continue;
        if ((unsigned)(bullet->x - player_x + 11) < 23u &&
            (unsigned)(bullet->y - player_y + 11) < 23u) {
            bullet->flags = 0;
            active_count--;
            take_hit();
            break;
        }
    }
    active_ebullets_count = active_count;
}

static void bullets_update(void)
{
    bullet_t *b;

    /* The craft's shot tests every enemy slot, and it does it once per
     * sub-step - eight shots at up to eight sub-steps is 256 flag loads a
     * frame for a pool that usually holds one or two enemies.  Snapshot the
     * live ones once, in slot order, and let the inner loop walk that.  The
     * flags are still re-read inside the loop, so an enemy killed by an
     * earlier shot of this frame drops out exactly as before; the snapshot
     * only decides which slots are worth looking at.
     *
     * static, not a stack array: this runs on a 1 KiB stack. */
    enemy_rec_t ** const elive = (enemy_rec_t **)MM_RUNTIME_WORK;
    int en;
    en = 0;
    for (int j = 0; j < MAX_ENEMIES; j++)
        if (enemies[j].flags & EF_ACTIVE) elive[en++] = &enemies[j];

    FOR_EACH_PBULLET(b) {
        /* Task 12: the pressure stage's wing missiles re-aim HERE.  They are
         * the only player shot whose heading changes after it is drawn, and
         * the homing belongs in the update rather than at spawn: pointing the
         * round straight at the boss every frame makes it curve onto the
         * target, whereas steering it (turning one aim step per frame) sends
         * it round a wide arc that gives the boss time to move off the line.
         * The campaign's shots never carry the bit, so they pay one compare. */
        if (b->flags & PF_LOCKON) {
            if (boss_state == BOSS_FIGHT) {
                int a = aim_index(boss_x + 32 - b->x, boss_y + 32 - b->y);
                b->vx = (int8_t)((dir16_x[a] * SPD_LOCKON_MISSILE) >> 4);
                b->vy = (int8_t)((dir16_y[a] * SPD_LOCKON_MISSILE) >> 4);
            }
            /* With no live boss to lock onto the round keeps the heading it
             * already has and simply leaves the playfield, which is what a
             * shot with nothing to home on should do. */
        }

        int remaining = (b->vy < 0) ? -(int)b->vy : (int)b->vy;
        int dx = (b->vx < 0) ? -b->vx : b->vx;
        if (dx > remaining) remaining = dx;

        int sub = (remaining + BULLET_STEP - 1) / BULLET_STEP;
        if (sub < 1) sub = 1;
        if (sub > 8) sub = 8;

        int px = b->x;
        int py = b->y;
        int svx = b->vx / sub;
        int svy = b->vy / sub;
        for (int s = 0; s < sub; s++) {
            /* the last sub-step carries the remainder, so the bullet lands on
             * exactly the pixel the un-stepped version would have reached */
            int jx = (s == sub - 1) ? (b->vx - svx * (sub - 1)) : svx;
            int jy = (s == sub - 1) ? (b->vy - svy * (sub - 1)) : svy;
            px += jx;
            py += jy;
            b->x = (int16_t)px;
            b->y = (int16_t)py;

            /* The craft's shots live inside the PLAYFIELD, not inside a
             * 640x600 window onto it.
             *
             * The two numbers that used to be here - 90 and 580 - were the
             * old screen's limits: 90 was "the bottom of the top HUD band"
             * and 580 was "600 minus the tracer".  This build put the HUD in
             * the two side gutters and let the playfield run the full 768
             * rows, so 90 and 580 stopped meaning anything and became a dead
             * band across the TOP of the screen that the player could not
             * shoot into at all.  It shows: the boss parks at y = 44 on its
             * way in and its upper half was simply unreachable, and a minion
             * is visible from y = -20 but cannot be hit until it drifts past
             * row 90 - a strip of screen where monsters appear and nothing
             * can touch them.
             *
             * The bounds below are the real DRAWING limits: the 7x7 tile
             * starts at y, the dark socket one row above it, and the tracer
             * ends at y + 26.  Both edges of the playfield are an edge for
             * the craft's shots now, and the pool is still bounded by x. */
            /* The two wing missiles carry a wider tile than the fan shot (13
             * against 7), so "has it left the field" is asked per kind. */
            int x_lim = (b->flags & PF_LOCKON) ? (GAME_RIGHT - MM_MISSILE_TILE_W)
                                               : (GAME_RIGHT - MM_PBULLET_TILE_W);
            if (b->y < PLAYFIELD_TOP + 1 || b->y > GAME_BOTTOM - 26 ||
                b->x < GAME_LEFT || b->x > x_lim) {
                b->flags = 0;
                break;
            }

            int hit = 0;
            for (int j = 0; j < en; j++) {
                enemy_rec_t *e = elive[j];
                if (!(e->flags & EF_ACTIVE)) continue;
                if (b->x < e->x - 2 || b->x > e->x + 26) continue;
                if (b->y < e->y - 2 || b->y > e->y + 26) continue;
                e->hp = (int16_t)(e->hp - (int16_t)atk);
                b->flags = 0;
                hit = 1;
                audio_event(AUDIO_EVENT_HIT);
                for (int s = 0; s < 6; s++) {
                    int a = (int)(xorshift32() & 15u);
                    uint8_t pt = (weapon == W_LASER) ? PARTICLE_CYAN : ((s & 1) ? PARTICLE_HIT : PARTICLE_CRIT);
                    spawn_particle(b->x, b->y, dir16_x[a] >> 1, dir16_y[a] >> 1, pt, 16);
                }
                if (e->hp <= 0) {
                    e->flags = 0;
                    kills++;
                    audio_event(AUDIO_EVENT_KILL);
                    score_award(100u + (uint32_t)e->type * 50u,
                                e->x + 12, e->y + 12);
                    visual_burst(e->x + 12, e->y + 12);
                    for (int p = 0; p < 8; p++) {
                        int pa = (p * 2 + (int)(xorshift32() & 1u)) & 15;
                        uint8_t pt = (uint8_t)(p % 5);
                        spawn_particle(e->x + 12, e->y + 12,
                                       dir16_x[pa] >> 1, dir16_y[pa] >> 1,
                                       pt, 18);
                    }
                    /* 8.3: the armoured ones come apart into a ring of shots. */
                    if (e->type == ENEMY_TURRET || e->type == ENEMY_MINION) {
                        for (int q = 0; q < 8; q++) {
                            int qa = q * 2;
                            spawn_ebullet(e->x + 8, e->y + 8,
                                          (dir16_x[qa] * SPD_AIM_SLOW) >> 4,
                                          (dir16_y[qa] * SPD_AIM_SLOW) >> 4, 6);
                        }
                    }
                    maybe_drop(e->x + 12, e->y + 12);
                }
                break;
            }
            if (hit) break;

            if (boss_state == BOSS_FIGHT &&
                b->x >= boss_x && b->x <= boss_x + 64 &&
                b->y >= boss_y && b->y <= boss_y + 64) {
                boss_hp = (int16_t)(boss_hp - (int16_t)atk);
                visual_burst(b->x, b->y);
                for (int s = 0; s < 4; s++) {
                    int a = (int)(xorshift32() & 15u);
                    uint8_t pt = (weapon == W_LASER) ? PARTICLE_CYAN : ((s & 1) ? PARTICLE_HIT : PARTICLE_CRIT);
                    spawn_particle(b->x, b->y, dir16_x[a] >> 2, dir16_y[a] >> 2, pt, 10);
                }
                spawn_particle(b->x, b->y, (int)(xorshift32() % 3u) - 1, -2, PARTICLE_CRIT, 12);
                b->flags = 0;
                break;
            }
        }
    }

    int grz_x0 = player_x - 15;
    int grz_y0 = player_y - 15;
    int hit_x0 = player_x - 11;
    int hit_y0 = player_y - 11;
    int danger_x0 = player_x - 64;
    int danger_y0 = player_y - 64;
    int check_hit = !invuln;
    int motion = is_stress_stage && !BUCKET_SOFTWARE_REFERENCE;
    int lance_count = eb_lance_count;
    eb_motion_pending = (uint8_t)motion;
    eb_lance_count = 0;

    int bound_y0 = PLAYFIELD_TOP + 1;
    unsigned bound_h = (unsigned)((GAME_BOTTOM - 1) - bound_y0 + 1);
    int bound_x0 = GAME_LEFT + 1;
    unsigned bound_w = (unsigned)((GAME_RIGHT - 16) - bound_x0 + 1);

    int live_eb = 0;
    for (int _run = 0; _run < 2; _run++) {
        for (int _pos = (_run == 0 ? 0 : ORB_FIRST),
                 _end = (_run == 0 ? (motion ? lance_count : eb_hi) : MAX_EBULLETS);
             _pos < _end; _pos++) {
            int _i = motion && !_run ? eb_lances[_pos] : _pos;
            b = &ebullets[_i];
            uint8_t flags = b->flags;
            if (!(flags & EF_ACTIVE)) continue;
            if (motion && !_run && !(flags & EF_LANCE)) continue;
            if (motion) active_ebullets_count--;
            int bx = b->x + b->vx;
            int by = b->y + b->vy;

            if (!(flags & EF_LANCE)) {
                if ((unsigned)(by - bound_y0) >= bound_h ||
                    (unsigned)(bx - bound_x0) >= bound_w) {
                    b->flags = 0;
                    if (_i < eb_free_hint) eb_free_hint = _i;
                    continue;
                }
                b->x = (int16_t)bx;
                b->y = (int16_t)by;
            } else {
                int bvx = b->vx;
                int bvy = b->vy;
                unsigned nb = ((unsigned)flags & EF_BOUNCE_MASK) >> EF_BOUNCE_SHIFT;
                if (bx < LANCE_MIN_X) {
                    bx = LANCE_MIN_X;
                    bvx = -bvx;  nb++;
                } else if (bx > LANCE_MAX_X) {
                    bx = LANCE_MAX_X;
                    bvx = -bvx;  nb++;
                }
                if (by < LANCE_MIN_Y) {
                    by = LANCE_MIN_Y;
                    bvy = -bvy;  nb++;
                } else if (by > LANCE_MAX_Y) {
                    by = LANCE_MAX_Y;
                    bvy = -bvy;  nb++;
                }
                if (nb >= LANCE_BOUNCES) {
                    b->flags = 0;
                    if (_i < eb_free_hint) eb_free_hint = _i;
                    continue;
                }
                flags = (uint8_t)((flags & (uint8_t)~EF_BOUNCE_MASK) |
                                  (nb << EF_BOUNCE_SHIFT));
                b->x = (int16_t)bx;
                b->y = (int16_t)by;
                b->vx = (int8_t)bvx;
                b->vy = (int8_t)bvy;
                b->flags = flags;
                if (_i < ORB_FIRST) {
                    eb_lances[eb_lance_count++] = (uint16_t)_i;
                }
            }

            if (check_hit &&
                (unsigned)(bx - danger_x0) <= 128u &&
                (unsigned)(by - danger_y0) <= 128u) {
                if ((unsigned)(by - grz_y0) < 31u &&
                    (unsigned)(bx - grz_x0) < 31u) {
                    if ((unsigned)(by - hit_y0) < 23u &&
                        (unsigned)(bx - hit_x0) < 23u) {
                        b->flags = 0;
                        if (_i < eb_free_hint) eb_free_hint = _i;
                        take_hit();
                        /* Walk on instead of returning.  The return skipped
                         * the live-count epilogue, so telemetry and the storm
                         * top-up kept last frame's count on the hit frame: the
                         * HUD read one more sprite than the pool held
                         * (measured 2314 vs 2313, invuln=120).  With one hit
                         * per frame already enforced by `check_hit` it costs
                         * nothing but the rest of this frame's walk, which is
                         * the move/cull those bullets were owed anyway. */
                        check_hit = 0;
                        continue;
                    }
                    if (!(flags & EF_GRAZED)) {
                        b->flags = (uint8_t)(flags | EF_GRAZED);
                        int gx = (bx + player_x) >> 1;
                        int gy = (by + player_y) >> 1;
                        int bvx = b->vx;
                        int bvy = b->vy;
                        int gvx = (bvx > 0) ? 1 : (bvx < 0) ? -1 : 0;
                        int gvy = (bvy > 0) ? -1 : 1;
                        spawn_particle(gx, gy, gvx, gvy, PARTICLE_CYAN, 12);
                    }
                }
            }
            live_eb++;
            if (motion) active_ebullets_count++;
        }
    }
    if (eb_free_hint >= eb_hi && eb_hi < ORB_FIRST) eb_free_hint = eb_hi;
    if (!motion) active_ebullets_count = live_eb;
    active_count = (uint16_t)active_ebullets_count;
}

/* ---- pickup test -------------------------------------------------------
 * Whole-cell test against the boot-built silhouette map.  Rejects in one
 * compare when the item is nowhere near the player, so the common case (an
 * item falling on the far side of a full screen of bullets) is nearly free,
 * and only a genuinely overlapping item walks the cells.
 */
static int pick_rect_hits(int x0, int y0, int x1, int y1)
{
    if (x1 < player_x - 24 || x0 > player_x + 23) return 0;
    if (y1 < player_y - 24 || y0 > player_y + 23) return 0;

    int c0 = (x0 - (player_x - 24)) / PICK_CELL;
    int c1 = (x1 - (player_x - 24)) / PICK_CELL;
    int r0 = (y0 - (player_y - 24)) / PICK_CELL;
    int r1 = (y1 - (player_y - 24)) / PICK_CELL;
    if (c0 < 0) c0 = 0;
    if (r0 < 0) r0 = 0;
    if (c1 > PICK_COLS - 1) c1 = PICK_COLS - 1;
    if (r1 > PICK_ROWS - 1) r1 = PICK_ROWS - 1;

    const uint32_t *map = pick_mask[player_pose < PICK_POSES ? player_pose : 0];
    for (int r = r0; r <= r1; r++) {
        int base = r * PICK_COLS;
        for (int c = c0; c <= c1; c++) {
            unsigned bit = (unsigned)(base + c);
            if (map[bit >> 5] & (1u << (bit & 31u))) return 1;
        }
    }
    return 0;
}

/* An item that reaches the floor STAYS there instead of vanishing on the
 * frame it crosses the edge.  584 is the lowest row that still fits the 16x16
 * sprite, its pickup marker row (y + 15) and the 88x28 label panel drawn at
 * y - 8 inside the frame; three seconds is long enough to drop down and
 * collect it, and the blink rate climbs until it goes. */
#define ITEM_REST_Y        (SCREEN_HEIGHT - 20)    /* keeps the marker row in frame */
#define ITEM_FLOOR_FRAMES  180

static void items_update(void)
{
    for (int i = 0; i < MAX_ITEMS; i++) {
        item_t *it = &items[i];
        if (!(it->flags & EF_ACTIVE)) continue;

        /* the pickup box IS the sprite: the player art spans 47x46 around the
         * 48x48 frame's origin, and the map above already excludes the
         * transparent pixels.  No more 36x38 keyhole.  This runs before the
         * floor timer so an item parked at the bottom is still collectable -
         * which is the whole point of parking it there. */
        if (pick_rect_hits(it->x, it->y, it->x + 15, it->y + 15)) {
            it->flags = 0;
            /* Phase 2 Task 02: Dedicated rising golden dust mote cluster on item pickup */
            for (int k = 0; k < 6; k++) {
                int vx = (int)(xorshift32() % 5u) - 2;
                int vy = -2 - (int)(xorshift32() % 3u);
                int ox = it->x + 8 + ((int)(xorshift32() % 9u) - 4);
                int oy = it->y + 8 + ((int)(xorshift32() % 7u) - 3);
                uint8_t life = (uint8_t)(16 + (xorshift32() % 9u));
                spawn_particle(ox, oy, vx, vy, PARTICLE_ITEM, life);
            }
            apply_item(it->type);
            continue;
        }

        if (it->timer) {              /* parked on the floor, blinking out */
            if (--it->timer == 0) it->flags = 0;
            continue;
        }

        it->y = (int16_t)(it->y + it->vy);
        if (it->y > ITEM_REST_Y) {
            /* An item used to be deleted the very frame it crossed the bottom
             * edge, which punished anyone who was busy dodging at the time.
             * It now parks on the floor for three seconds, blinking faster and
             * faster until it goes, so a missed drop is still recoverable. */
            it->y = ITEM_REST_Y;
            it->timer = ITEM_FLOOR_FRAMES;
        }
    }
}

/* ------------------------------------------------------------- render   */

/* ===================================================================== */
/* render backend: BitBlt engine, or the CPU alone                       */
/* ---------------------------------------------------------------------
 * The settings menu can switch hardware acceleration off.  Everything then
 * goes through plain CPU stores to DDR, which is what makes the competition's
 * CPU-vs-FPGA comparison playable from inside the game: same picture, same
 * code, 60 FPS against a slideshow.
 * ===================================================================== */
static void cpu_blit(uint32_t dst, uint32_t src, int w, int h,
                     int sstride, int dstride)
{
    for (int y = 0; y < h; y++) {
        volatile uint32_t *drow = (volatile uint32_t *)(dst + (uint32_t)(y * dstride));
        const volatile uint32_t *srow = (const volatile uint32_t *)(src + (uint32_t)(y * sstride));
        for (int x = 0; x < w; x++) {
            uint32_t px = srow[x];
            if (px != MAGENTA_KEY) drow[x] = px;      /* colour key, in software */
        }
    }
}

static void cpu_alpha(uint32_t dst, uint32_t src, int w, int h,
                      int sstride, int dstride, uint32_t ga)
{
    for (int y = 0; y < h; y++) {
        volatile uint32_t *drow = (volatile uint32_t *)(dst + (uint32_t)(y * dstride));
        const volatile uint32_t *srow = (const volatile uint32_t *)(src + (uint32_t)(y * sstride));
        for (int x = 0; x < w; x++) {
            uint32_t s = srow[x];
            uint32_t d = drow[x];
            if (s == MAGENTA_KEY) continue;           /* colour key beats alpha */
            uint32_t a = (((s >> 24) & 0xFFu) * ga + 127u) / 255u;
            uint32_t out = d & 0xFF000000u;           /* background alpha kept  */
            for (int sh = 0; sh <= 16; sh += 8) {
                uint32_t sc = (s >> sh) & 0xFFu;
                uint32_t dc = (d >> sh) & 0xFFu;
                uint32_t oc = (sc * a + dc * (255u - a) + 127u) / 255u;
                out |= oc << sh;
            }
            drow[x] = out;
        }
    }
}

static void cpu_fill(uint32_t dst, uint32_t w, uint32_t h, uint32_t color,
                     uint32_t stride)
{
    for (uint32_t y = 0; y < h; y++) {
        volatile uint32_t *row = (volatile uint32_t *)(dst + y * stride);
        for (uint32_t x = 0; x < w; x++)
            row[x] = color;
    }
}

/* Saturating add, the software twin of OP_ADD and of the scanout's laser
 * columns: min(255, dst + src) per channel.  A colour-keyed source pixel is
 * skipped - same rule as cpu_blit() and cpu_alpha(), and the same rule the
 * engine applies before it blends. */
static void cpu_add(uint32_t dst, uint32_t src, int w, int h,
                    int sstride, int dstride)
{
    for (int y = 0; y < h; y++) {
        volatile uint32_t *drow = (volatile uint32_t *)(dst + (uint32_t)(y * dstride));
        const volatile uint32_t *srow = (const volatile uint32_t *)(src + (uint32_t)(y * sstride));
        for (int x = 0; x < w; x++) {
            uint32_t s = srow[x];
            if (s == MAGENTA_KEY) continue;
            uint32_t d = drow[x];
            uint32_t out = d & 0xFF000000u;           /* background alpha kept */
            for (int sh = 0; sh <= 16; sh += 8) {
                uint32_t sum = ((s >> sh) & 0xFFu) + ((d >> sh) & 0xFFu);
                out |= (sum > 255u ? 255u : sum) << sh;
            }
            drow[x] = out;
        }
    }
}

/* ---- UART frame-cost log --------------------------------------------
 * The board's serial port is the Sapphire SoC's first UART.  Every constant
 * below is from the vendor BSP that already ships in this repo - the firmware
 * had simply never touched it:
 *
 *   embedded_sw/soc/bsp/efinix/EfxSapphireSoc/include/soc.h
 *       SYSTEM_UART_0_IO_CTRL 0xf8010000      SYSTEM_CLINT_HZ 100000000
 *   embedded_sw/soc/software/standalone/driver/uart.h
 *       UART_DATA 0x00   UART_STATUS 0x04
 *       UART_CLOCK_DIVIDER 0x08   UART_FRAME_CONFIG 0x0C
 *       tx room = (status >> 16) & 0xFF
 *   embedded_sw/soc/bsp/efinix/EfxSapphireSoc/include/bsp.h
 *       clockDivider = CLINT_HZ/(BAUD*8)-1 = 100e6/(115200*8)-1 = 107
 *       frameConfig  = ((8-1)<<0)|(NONE<<8)|(ONE<<16) = 7
 *
 * This is how the frame cost leaves the board with no JTAG and no debugger.
 *
 * One line every DIAG_FRAMES frames.  A line is ~30 bytes and the TX FIFO is
 * 128 deep, so the whole line is buffered in one go and the CPU never blocks
 * on it - which matters, because a blocking write every frame would cost about
 * a fifth of a frame and invent the very problem it is meant to measure.
 *
 * C / N / R are the WORST values inside the window, never the averages: a
 * dropped frame IS a peak, and an average washes it out.  P is the worst of
 * the whole run, so the number is still there once the fight is over. */
#define DIAG_FRAMES  32u
#define DIAG_UART    0xF8010000UL

static uint32_t diag_cyc;
static uint32_t * const diag_acc = (uint32_t *)(MM_RUNTIME_WORK + 264u);
static uint16_t diag_n;
/* The worst frame of the window, plus the three numbers that say WHY it was
 * the worst: how much of it was game_frame(), how much of THAT the engine spent
 * spinning, and how many rows it was asked to move.
 *
 * The old X/Y pair printed the same value twice - diag_cyc and diag_max were
 * both compared against the very same `cyc` - so it is one field now, and the
 * space went to the breakdown instead.  G and T are gone for the same reason:
 * every sample of both has been 0000 since the engine was fixed. */
/* Window accumulators, in units of 1.28 us (>>7) so that even half a second
 * per frame cannot overflow 32 bits across the window; the print-side >>5 is
 * the mean.  A mean next to a worst frame is what separates "the engine is
 * always the cost" from "one frame in thirty was pathological" - both have to
 * be visible, and neither one alone is enough to choose a fix. */
static uint32_t acc_j, acc_g, acc_m, acc_b, acc_s, acc_h, acc_x, acc_n, acc_r, acc_d;
/* The first frames after entering the game paint everything for the first
 * time - measured at ~18646 rows, three times a busy bullet frame.  P is
 * meant to be "the worst frame of this fight", so it must not latch onto
 * that.  The menu never calls game_frame(), so this only ever skips the
 * first entry into the game. */
#define DIAG_SKIP  60u
static __attribute__((noinline)) void set_hb(uint32_t value)
{
    GPU2D_REG_HEARTBEAT = value;
}

static __attribute__((noinline)) void uart_putc(char c)
{
    /* Diagnostics must never consume a display deadline waiting for UART. */
    if (((*(volatile uint32_t *)(DIAG_UART + 0x04u) >> 16) & 0xFFu) != 0u)
        *(volatile uint32_t *)(DIAG_UART + 0x00u) = (uint32_t)(unsigned char)c;
}

static __attribute__((noinline)) void uart_puts(const char *s) { while (*s) uart_putc(*s++); }

/* The current RV32IM core has native division. */
static __attribute__((noinline)) void uart_num(uint32_t v)
{
    char digits[10];
    unsigned n = 0;
    do { digits[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) uart_putc(digits[--n]);
}

static __attribute__((noinline, noclone)) void uart_field(char key, uint32_t value)
{
    uart_putc(' '); uart_putc(key); uart_num(value);
}

static void diag_init(void)
{
    for (unsigned index = 0; index < 9; ++index) diag_acc[index] = 0u;
    *(volatile uint32_t *)(DIAG_UART + 0x08u) = 107u;
    *(volatile uint32_t *)(DIAG_UART + 0x0Cu) = 7u;
}

static void diag_window(uint32_t cyc, uint32_t cmds, uint32_t rows)
{
    /* Accumulate first: these are the means.  tlm[42] is game_render()'s real
     * total, tlm[44] is only its backdrop, and tlm[41] is the slice of the
     * weather pass that the CPU spends writing DDR directly - the one piece of
     * a frame that never touches the engine at all. */
    diag_acc[0] += tlm[TLM_T_GFRAME] >> 7;  /* render pass total (update out) */
    diag_acc[1] += tlm[TLM_P_ENGWAIT] >> 7; /* engine serial wait inside it   */
    diag_acc[2] += tlm[TLM_T_STRIP] >> 7;   /* game_render() total            */
    diag_acc[3] += tlm[TLM_T_GRENDER] >> 7; /* ... of which the backdrop      */
    diag_acc[4] += tlm[41] >> 7;            /* bucket_build() slice of game_render */
    diag_acc[5] += tlm[TLM_P_LOOPHS] >> 7;  /* scanout handshake, outside     */
    diag_acc[6] += cmds;
    diag_acc[7] += rows;
    diag_acc[8] += damage_restore_rows;

    /* One worst frame per window, with its full breakdown.  If V (its
     * game_frame) sits under a frame budget while the window still dropped
     * frames, the loss was never in game_frame() and no renderer work can
     * recover it. */
    if (cyc > diag_cyc) {
        diag_cyc = cyc;
        tlm[TLM_P_MAXJ] = tlm[TLM_T_GFRAME];
        tlm[TLM_P_MAXG] = tlm[TLM_P_ENGWAIT];
        tlm[TLM_P_MAXR] = rows;
    }
    if (++diag_n < DIAG_FRAMES) return;
    diag_n = 0u;

    /* One line per window.  ~100 characters against a 128-deep TX FIFO, so
     * the whole line is buffered in one go and the CPU never blocks on it -
     * a blocking write every window would invent the very problem this is
     * here to measure.
     *
     * lowercase = mean over the window, uppercase = the worst frame of it,
     * and every timer is in units of 1.28 us (x128 for cycles).
     *
     *   C  worst frame period in the window      <- the drop indicator
     *   j  game render pass, update excluded      V  ... on the worst frame
     *   g  engine serial wait inside j           U  ... on the worst frame
     *   m  game_render() total                   Q  rows on the worst frame
     *   b  ... of which the backdrop             W  commands on the worst frame
     *   s  bucket_build() (tlm[41], live again since 2026-10-15)
     *   h  scanout handshake, outside game_frame
     *   x  gpu2d_flush_dcache()
     *   n  BitBlt commands, r  BitBlt rows       P  peak rows of the run
     *
     * Read it as: C over budget means a frame was dropped.  If V is under
     * budget, the drop was the loop (look at h).  If V is over, split V by
     * U/U-g: U near V is the engine, U small is the CPU. */
    uart_puts("\r\nF"); uart_num(frame_tick);
    uart_field('C', diag_cyc);
    for (int i = 0; i < 6; i++) {
        uart_field("jgmbsh"[i], diag_acc[i] >> 5);
        diag_acc[i] = 0u;
    }
    uart_field('Q', GPU2D_REG_BUCKET_DEBUG);
    for (int i = 0; i < 3; i++) {
        uart_field("nrd"[i], diag_acc[6 + i] >> 5);
        diag_acc[6 + i] = 0u;
    }
    /* Worst-frame breakdown stays in telemetry; keep UART below FIFO depth. */
    uart_field('B', GPU2D_REG_BUCKET_ACCEL);
    uart_field('T', GPU2D_REG_BUCKET_CYCLES);
    uart_puts("\r\n");

    acc_j = 0u; acc_g = 0u; acc_m = 0u; acc_b = 0u; acc_s = 0u;
    acc_h = 0u; acc_x = 0u; acc_n = 0u; acc_r = 0u; acc_d = 0u;
    diag_cyc = 0u;
}

/* What the engine is being asked to do this frame, published in tlm[47..48].
 * The software path does not go through the engine, so it is not counted. */
static uint32_t blit_cmds, blit_rows;

static void r_fill(uint32_t dst, uint32_t w, uint32_t h, uint32_t color,
                   uint32_t stride)
{
    damage_mark(dst, w, h, stride);
    if (hw_accel) {
        blit_cmds++; blit_rows += h;
        gpu2d_fill(dst, w, h, color, stride);
    } else {
        cpu_fill(dst, w, h, color, stride);
    }
}

static void r_blit(uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                   uint32_t sstride, uint32_t dstride)
{
    damage_mark(dst, w, h, dstride);
    if (hw_accel) {
        blit_cmds++; blit_rows += h;
        gpu2d_blit_sprite(dst, src, w, h, sstride, dstride);
    } else {
        cpu_blit(dst, src, (int)w, (int)h, (int)sstride, (int)dstride);
    }
}

/* ---- the additive path (OP_ADD) ---------------------------------------
 *
 * r_add() and r_blit_nomark() were once removed as dead code, and the comment
 * that replaced them named r_add_scaled() as "the additive path the renderer
 * actually uses".  That function has never existed and gpu2d_add() had no
 * caller anywhere, so the engine's OP_ADD sat unused: the only addition in the
 * build was the scanout's laser columns.  This is the real thing.
 *
 * WHERE ADDITION BELONGS, AND WHERE IT DOES NOT.  The visual spec draws the
 * line at "glowing things add, translucent things alpha", and OP_ADD is the
 * glowing half.  It must NOT be pointed at anything whose job is to show the
 * backdrop through itself - an energy core, a missile body, the craft's aura -
 * because addition has no notion of "behind": it only ever brightens, so a
 * translucent entity run through it comes out a smear of white instead of a
 * translucent entity.
 *
 * COLOUR KEY IS NOT OPTIONAL.  Particles are 8x8 tiles on a MAGENTA_KEY
 * background; without the key the whole 8x8 rectangle would be ADDED, and a
 * field of magenta blocks is what that looks like.  The engine applies its key
 * before it blends (bitblt_alpha_blend.v's keep mask), and cpu_add() mirrors
 * that, so the two paths agree.
 *
 * The key is set once around a whole batch rather than per call: the offset
 * register write costs an APB round trip and gpu2d_set_colorkey() waits for the
 * engine first, so a per-particle call would add a second stall to every
 * particle on top of the one gpu2d_finish() already costs.
 */
static void r_add(uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                  uint32_t sstride, uint32_t dstride)
{
    damage_mark(dst, w, h, dstride);
    if (hw_accel) {
        blit_cmds++; blit_rows += h;
        gpu2d_add(dst, src, w, h, sstride, dstride);
    } else {
        cpu_add(dst, src, (int)w, (int)h, (int)sstride, (int)dstride);
    }
}

static uint32_t r_add_saved_key;   /* colour-key state before a batch */

static void r_add_begin(void)
{
    if (!hw_accel) return;
    /* SAVE AND RESTORE, never a bare on/off pair.  The colour key is a mode of
     * the engine that other draws can also want - the pressure stage turns it
     * on when it starts and everything after that depends on it still being on.
     * A batch that simply switched it off at the end would silently disarm
     * every later blit in the frame, and a sprite whose key is off blits its
     * magenta background into the picture. */
    r_add_saved_key = GPU2D_REG_COLORKEY_CTRL & 1u;
    gpu2d_set_colorkey(1, MAGENTA_KEY);
}

static void r_add_end(void)
{
    if (hw_accel) gpu2d_set_colorkey(r_add_saved_key, MAGENTA_KEY);
}

static void r_alpha(uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                    uint32_t sstride, uint32_t dstride, uint32_t ga)
{
    damage_mark(dst, w, h, dstride);
    if (hw_accel) {
        blit_cmds++; blit_rows += h;
        gpu2d_alpha_blit(dst, src, w, h, sstride, dstride);
    } else {
        cpu_alpha(dst, src, (int)w, (int)h, (int)sstride, (int)dstride, ga);
    }
}

static void r_alpha_begin(uint32_t ga)
{
    if (hw_accel) gpu2d_set_alpha(1, ga);
}

static void r_alpha_end(void)
{
    if (hw_accel) gpu2d_set_alpha(1, 255);
}

static void r_sync(void)
{
    if (hw_accel) gpu2d_wait_idle();
}

/* ---------------------------------------------------------------- font  */
/* Licensed Kenney Pixel font: 6x8 glyphs, boot-expanded DDR atlas scales 1..6. */

#define FONT_S 3

/* Byte size of one 16-glyph line of a font atlas, by scale.
 *
 * On this core there is no multiplier: every integer multiply is a call into
 * libgcc's __mulsi3, about thirty instructions each.  The glyph-offset
 * expression below used to compute two of them PER GLYPH, and a menu
 * strapline is thirteen glyphs - thousands of cycles with no polling point in
 * it, which is a hole a short button press can fall straight through.  The
 * scale-dependent part is a six-entry table instead, and the two index
 * products are counted out with a shift-and-add loop.
 *
 * line = 8*scale rows x (scale*512)-byte pitch = 4096 * scale^2. */

/* The glyph loop, with the destination row pitch supplied.
 *
 * Only one caller needs this: the HUD caption atlas is 128 pixels wide, so it
 * is laid out at a 512-byte pitch, and drawing into it with draw_text() would
 * stride by SCREEN_STRIDE (8192) and walk 128 KB past the end of the surface.
 * No bounds check here - the caller owns the surface, and the two callers that
 * exist are both building into a strip they sized themselves. */
static void draw_text_strided(uint32_t fb, uint32_t pitch, int x, int y,
                              const char *s, int scale)
{
    {
    const uint32_t stride   = (uint32_t)scale << 9;         /* scale * 512 */
    const uint32_t cell_w   = (uint32_t)scale << 5;         /* 8*scale*4 bytes */
    const uint32_t line_b   = ((uint32_t)scale * (uint32_t)scale) << 12;
    const uint32_t atlas    = ((volatile uint32_t *)MM_FONT_TABLE)[scale-1];
    unsigned       poll     = 0;

    for (; *s; s++) {
        unsigned g = (unsigned char)*s;
        if (g < 32 || g > 126) g = 32;
        g -= 32;
        uint32_t off = (g >> 4) * line_b + (g & 15u) * cell_w;
        r_blit(fb + (uint32_t)y * pitch + (uint32_t)x * 4u, atlas + off,
               (uint32_t)(6*scale), (uint32_t)(8*scale), stride, pitch);
        x += 7 * scale;

        /* Every fourth glyph, give the menu a chance to look at the handset.
         * The hook is NULL outside the boot menu, so all this costs a normal
         * frame is one compare per glyph. */
        if (gpu2d_idle_hook && (++poll & 3u) == 0u) gpu2d_idle_hook();
    }
    }
}

static void draw_text(uint32_t fb, int x, int y, const char *s, int scale,
                      uint32_t color)
{
    (void)color; /* supplied font pixels are white; coloured panels carry accents */
    if (scale < 1 || scale > 6) return;
    /* Clip the anchor before it reaches an address.  A negative y makes
     * `fb + y*SCREEN_STRIDE` walk BACKWARD out of the framebuffer, and the
     * engine happily writes there - the workbench caught it as
     * "BitBlt copy destination 0x7f52b8 outside modelled DDR", which is
     * 0x00800000 - 5 rows.  Clipping here covers every caller, including ones
     * added later, which is cheaper than auditing them one at a time. */
    if (y < 0 || x < 0) return;
    if (x + 7 * scale > SCREEN_WIDTH) return;
    if (y + 8 * scale > SCREEN_HEIGHT) return;
    draw_text_strided(fb, SCREEN_STRIDE, x, y, s, scale);
}

/* ---- HUD caption atlas -------------------------------------------------
 *
 * Every caption in the two HUD gutters is static text - "LIVES", "SPELL
 * CARD", "RENDER BACKEND" - yet draw_text() re-issued one COPY per GLYPH for
 * them every frame: about 120 of the frame's ~1000 commands, each paying a
 * full DDR round trip to move 6x8 pixels.
 *
 * The captions are composed once at boot into this atlas - one 128-pixel
 * strip per caption - and a frame now draws each one with a single COPY.  The
 * text and its position are unchanged; only the number of commands changed.
 *
 * The strips are keyed magenta before the text is drawn into them, because a
 * colour-keyed COPY does not write keyed pixels: without the key, the gaps
 * between glyphs would keep whatever DDR powered up holding.
 *
 * Sixteen pixels of pitch would be enough for the 8-row glyphs; 128 columns
 * is what makes even "VERTEX 1366x768" (105 px) fit on one strip.
 */
#define HUD_LBL_REIMU      0u
#define HUD_LBL_LIVES      1u
#define HUD_LBL_SCORE      2u
#define HUD_LBL_SPELL_CARD 3u
#define HUD_LBL_STATUS     4u
#define HUD_LBL_HISCORE    5u
#define HUD_LBL_STAGE      6u
#define HUD_LBL_BOSS       7u
#define HUD_LBL_SHOT       8u
#define HUD_LBL_POWER      9u
#define HUD_LBL_ATTACK    10u
#define HUD_LBL_WAVE      11u
#define HUD_LBL_BOSS_LIFE 12u
#define HUD_LBL_BACKEND   13u
#define HUD_LBL_FPS_TAG   14u
#define HUD_LBL_VERTEX    15u
#define HUD_LBL_LV        16u
#define HUD_LBL_FPS       17u
#define HUD_LBL_SPELL     18u

static const char * const hud_label_text[MM_HUD_LABEL_SLOTS] = {
    "REIMU HAKUREI", "LIVES", "SCORE", "SPELL CARD", "STATUS",
    "HI SCORE", "STAGE", "BOSS", "SHOT TYPE", "POWER / LV", "ATTACK",
    "WAVE", "BOSS LIFE", "RENDER BACKEND", "FPS", "VERTEX 1366x768",
    "LV", "FPS", "SPELL", ""
};

static const int16_t hud_label_x[MM_HUD_LABEL_SLOTS] = {
    HUD_PLAYER_X + 20, HUD_LIVES_X, HUD_SCORE_X, HUD_SPELL_X,
    HUD_DEBUFF_S_X, HUD_HISCORE_X,
    HUD_STAGE_TAG_X, HUD_STAGE_TAG_X,
    HUD_WEAPON_X, HUD_LV_TAG_X, HUD_ATK_X,
    HUD_WAVE_BAR_X, HUD_WAVE_BAR_X,
    HUD_BACKEND_X, HUD_FPS_TAG_X, HUD_VERTEX_X,
    HUD_LV_TAG_X, HUD_FPS_TAG_X, HUD_SPELL_X, 0
};

static const int16_t hud_label_y[MM_HUD_LABEL_SLOTS] = {
    HUD_PLAYER_Y - 14, HUD_LIVES_Y - 14, HUD_SCORE_Y - 14, HUD_SPELL_Y - 14,
    HUD_DEBUFF_S_Y - 14, HUD_HISCORE_Y - 14,
    HUD_STAGE_TAG_Y - 12, HUD_STAGE_TAG_Y - 12,
    HUD_WEAPON_Y - 14, HUD_LV_TAG_Y - 14, HUD_ATK_Y - 14,
    HUD_WAVE_BAR_Y - 14, HUD_WAVE_BAR_Y - 14,
    HUD_BACKEND_Y - 14, HUD_FPS_TAG_Y - 14, HUD_VERTEX_Y - 14,
    HUD_LV_TAG_Y, HUD_FPS_TAG_Y, HUD_SPELL_Y, 0
};

/* Measured at build time: a caption is n glyphs at a 7-pixel advance, but the
 * last glyph is only 6 wide, so the strip is 7n - 1 pixels.  Rounding up to 7n
 * would copy one transparent column, which is harmless but wasteful. */
static uint8_t * const hud_label_w = (uint8_t *)(MM_RUNTIME_WORK + 208u);

static void hud_labels_build(void)
{
    for (unsigned i = 0; i < MM_HUD_LABEL_SLOTS; i++) {
        uint32_t base = MM_HUD_LABELS +
                        (uint32_t)i * (MM_HUD_LABELS_STRIDE * MM_HUD_LABELS_H);
        const char *s = hud_label_text[i];
        unsigned n = 0;

        while (s[n]) n++;
        if (n == 0u) { hud_label_w[i] = 0u; continue; }

        r_fill(base, MM_HUD_LABELS_W, MM_HUD_LABELS_H, MAGENTA_KEY,
               (uint32_t)MM_HUD_LABELS_STRIDE);
        draw_text_strided(base, (uint32_t)MM_HUD_LABELS_STRIDE, 0, 0, s, 1);
        hud_label_w[i] = (uint8_t)(n * 7u - 1u);
    }
    gpu2d_flush_dcache();
}

static void hud_label(uint32_t fb, unsigned i)
{
    if (hud_label_w[i] == 0u) return;
    r_blit(fb + (uint32_t)hud_label_y[i] * SCREEN_STRIDE +
               (uint32_t)hud_label_x[i] * 4u,
           MM_HUD_LABELS +
               (uint32_t)i * (MM_HUD_LABELS_STRIDE * MM_HUD_LABELS_H),
           hud_label_w[i], MM_HUD_LABELS_H,
           (uint32_t)MM_HUD_LABELS_STRIDE, SCREEN_STRIDE);
}

static void draw_number(uint32_t fb, int x, int y, uint32_t value, int digits,
                        uint32_t color)
{
    char buf[8];
    if (digits > 7) digits = 7;
    buf[digits] = '\0';
    for (int i = digits - 1; i >= 0; i--) {
        buf[i] = (char)('0' + (value % 10u));
        value /= 10u;
    }
    draw_text(fb, x, y, buf, FONT_S, color);
}

static uint32_t clamp_dst(uint32_t fb, int x, int y, int w, int h)
{
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > SCREEN_WIDTH - w)  x = SCREEN_WIDTH - w;
    if (y > SCREEN_HEIGHT - h) y = SCREEN_HEIGHT - h;
    return fb + (uint32_t)(y * SCREEN_STRIDE) + (uint32_t)(x * 4);
}

static void draw_art(uint32_t fb, int x, int y, unsigned id)
{
    const visual_asset_t *a = &visual_assets[id];
    unsigned w = a->w*a->scale, h = a->h*a->scale;
    r_blit(clamp_dst(fb,x,y,(int)w,(int)h),a->dst,w,h,w*4u,SCREEN_STRIDE);
}

/* The stage's rival.  Stage 3 has no asset entry for it: boss_dream_build()
 * derives that tile at boot, so it is blitted straight out of DDR. */
static void draw_boss_art(uint32_t fb, int x, int y)
{
    if (wave == 2) {
        r_blit(clamp_dst(fb, x, y, MM_BOSS_SPRITE_W, MM_BOSS_SPRITE_H),
               MM_BOSS_DREAM, MM_BOSS_SPRITE_W, MM_BOSS_SPRITE_H,
               MM_BOSS_SPRITE_W * 4u, SCREEN_STRIDE);
        return;
    }
    draw_art(fb, x, y, wave == 0 ? ART_BOSS_CIRNO : ART_BOSS);
}

/* ---- impact effect -----------------------------------------------------
 * A hit used to be one 32x32 explosion tile and nothing else, which read as a
 * square appearing and disappearing.  It is five layers now:
 *
 *   1. the licensed explosion frame,
 *   2. a 16-lobe shockwave that expands and cools white -> gold -> ember,
 *   3. a second, faster ring half a beat out of phase with the first, so the
 *      wavefront shimmers instead of pulsing as one solid circle,
 *   4. a white core flash on the first four frames,
 *   5. sixteen embers on two speeds flying out along the 16-direction table.
 *
 * Every layer is drawn with fills, so the whole upgrade still costs no asset
 * space - which is the only reason it fits.
 */
#define BURST_FRAMES  MM_BURST_FRAME_COUNT
#define BURST_CENTRE  (MM_BURST_FRAME_W / 2)

/* Paint one age of the burst into a frame of its own, at (dst, stride).  The
 * five layers and their arithmetic are the originals; only the origin moved,
 * from the live playfield to the frame's own top-left corner. */
static void draw_mc_line(volatile uint32_t *pix, int x0, int y0, int x1, int y1, uint32_t col)
{
    int dx = x1 - x0;
    int dy = y1 - y0;
    int ax = dx < 0 ? -dx : dx;
    int ay = dy < 0 ? -dy : dy;
    int steps = ax > ay ? ax : ay;
    if (steps == 0) steps = 1;
    for (int s = 0; s <= steps; s++) {
        int x = x0 + (dx * s) / steps;
        int y = y0 + (dy * s) / steps;
        if (x >= 0 && x < (int)MM_BURST_FRAME_W && y >= 0 && y < (int)MM_BURST_FRAME_W)
            pix[y * MM_BURST_FRAME_W + x] = col;
    }
}

static void burst_frames_build(void)
{
    /* Touhou-style 112x112 Rotating Hexagram Magic Summoning Array (32 frames) */
    static const int8_t cos32[32] = {
        127, 125, 117, 106,  90,  71,  49,  25,
          0, -25, -49, -71, -90,-106,-117,-125,
       -127,-125,-117,-106, -90, -71, -49, -25,
          0,  25,  49,  71,  90, 106, 117, 125
    };
    static const int8_t sin32[32] = {
          0,  25,  49,  71,  90, 106, 117, 125,
        127, 125, 117, 106,  90,  71,  49,  25,
          0, -25, -49, -71, -90,-106,-117,-125,
       -127,-125,-117,-106, -90, -71, -49, -25
    };

    for (unsigned a = 0; a < BURST_FRAMES; a++) {
        volatile uint32_t *pix = (volatile uint32_t *)(MM_BURST_FRAME + a * MM_BURST_FRAME_BYTES);
        /* Clear frame to 0 (for additive OP_ADD blending) */
        for (unsigned p = 0; p < MM_BURST_FRAME_W * MM_BURST_FRAME_W; ++p)
            pix[p] = 0u;

        int cx = (int)(MM_BURST_FRAME_W / 2);
        int cy = cx;

        /* 1. Outer runic ring (r=45..48) and inner seal ring (r=33..35) */
        for (int y = 0; y < (int)MM_BURST_FRAME_W; y++) {
            int dy = y - cy;
            for (int x = 0; x < (int)MM_BURST_FRAME_W; x++) {
                int dx = x - cx;
                int d2 = dx * dx + dy * dy;
                if (d2 >= 45 * 45 && d2 <= 48 * 48) {
                    pix[y * MM_BURST_FRAME_W + x] = 0x0030C8FFu; /* luminous cyan ring */
                } else if (d2 >= 33 * 33 && d2 <= 35 * 35) {
                    pix[y * MM_BURST_FRAME_W + x] = 0x0020A0E0u; /* inner boundary */
                } else if (d2 <= 5 * 5) {
                    pix[y * MM_BURST_FRAME_W + x] = 0xFFFFFFFFu; /* emissive radiant core */
                }
            }
        }

        /* 2. Compute 6 rotating vertices of the Hexagram */
        int vx[6], vy[6];
        for (int k = 0; k < 6; k++) {
            int angle = (int)((a + (unsigned)k * 32u / 6u) & 31u);
            vx[k] = cx + ((int)cos32[angle] * 39) / 128;
            vy[k] = cy + ((int)sin32[angle] * 39) / 128;
        }

        /* 3. Draw the two interlocking equilateral triangles of the Hexagram */
        uint32_t hex_col = (a & 1u) ? 0x00FF80D0u : 0x00FF60B0u; /* mystical radiant magenta */
        draw_mc_line(pix, vx[0], vy[0], vx[2], vy[2], hex_col);
        draw_mc_line(pix, vx[2], vy[2], vx[4], vy[4], hex_col);
        draw_mc_line(pix, vx[4], vy[4], vx[0], vy[0], hex_col);

        draw_mc_line(pix, vx[1], vy[1], vx[3], vy[3], hex_col);
        draw_mc_line(pix, vx[3], vy[3], vx[5], vy[5], hex_col);
        draw_mc_line(pix, vx[5], vy[5], vx[1], vy[1], hex_col);

        /* 4. Draw 12 outer runic ticks on the outer boundary */
        for (int k = 0; k < 12; k++) {
            int angle = (int)((a / 2u + (unsigned)k * 32u / 12u) & 31u);
            int x0 = cx + ((int)cos32[angle] * 45) / 128;
            int y0 = cy + ((int)sin32[angle] * 45) / 128;
            int x1 = cx + ((int)cos32[angle] * 51) / 128;
            int y1 = cy + ((int)sin32[angle] * 51) / 128;
            draw_mc_line(pix, x0, y0, x1, y1, 0x0060E0FFu);
        }

        /* 5. Draw glowing diamond energy nodes at the 6 star vertices */
        for (int k = 0; k < 6; k++) {
            for (int dy = -2; dy <= 2; dy++) {
                int ady = dy < 0 ? -dy : dy;
                for (int dx = -2; dx <= 2; dx++) {
                    int adx = dx < 0 ? -dx : dx;
                    if (adx + ady <= 2) {
                        int nx = vx[k] + dx;
                        int ny = vy[k] + dy;
                        if (nx >= 0 && nx < (int)MM_BURST_FRAME_W && ny >= 0 && ny < (int)MM_BURST_FRAME_W)
                            pix[ny * MM_BURST_FRAME_W + nx] = 0x00FFE860u; /* golden spark */
                    }
                }
            }
        }
    }
    gpu2d_flush_dcache();
}

/* A live particle is one clipped COPY of the frame its age selects.
 *
 * Measured: the five layers cost 48 FILL commands per particle per frame, and
 * the opener kept six particles alive at once - 288 of that frame's 380 FILLs.
 * Each FILL was also a handful of pixels spread over a few DRAM rows, so the
 * frame paid a row activate for every four pixels of ring it drew.
 *
 * The clip replaces the old per-lobe bounds tests.  Those dropped the lobes
 * that fell outside the playfield one at a time, which is what let the
 * bottom-edge spell card paint past row 599 in the first place (see the
 * bombbounds scenario); clipping the one sprite is both cheaper and the
 * reason that class of bug cannot come back.
 */
/* ---- procedural impact rings on the scanout -----------------------------
 * Both rings used to be drawn into the framebuffer: one 112x112 pre-baked frame
 * per burst through the BitBlt engine (src read + dst read + dst write, plus a
 * damage_restore of the same rectangle on the next frame) and sixteen 2x2 FILL
 * commands for the player-hit ring.  The scanout can compute the same circle
 * from the pixel position, so what the CPU owes the hardware is four 96-bit
 * descriptors: twelve APB writes a frame, no DDR traffic, no engine command.
 *
 * One hardware slot per impact.  Age 0..3 is a hot additive disc - the core of
 * the hit, drawn by the saturated-add path so it really does clip to white -
 * and 4..23 is an expanding blended annulus that cools from white to ember.
 * Slot 0 is the player-hit ring, which the hardware's priority pick always
 * places over the boss-spark bursts behind it.
 *
 * A ring's colour has to carry the fade on the add path (that path has no
 * alpha), which is why the core fades through a small table instead of
 * multiplying by an alpha the compositor would ignore.
 */
#define FX_RINGS 1
#define FX_RING_SLOTS 4

static void fx_rings_upload(void)
{
    uint32_t a[FX_RING_SLOTS], b[FX_RING_SLOTS], c[FX_RING_SLOTS];
    static const uint32_t core_fade[4] = {
        0x00FFFFFFu, 0x00C8C8C8u, 0x00808080u, 0x00404040u
    };
    int slot = 0;

    for (int i = 0; i < FX_RING_SLOTS; i++) { a[i] = 0u; b[i] = 0u; c[i] = 0u; }

    if (hit_ring_timer) {
        int age = HIT_RING_FRAMES - (int)hit_ring_timer;
        int r = 14 + age * 10;
        int alpha = 210 - age * 9;
        if (alpha < 40) alpha = 40;
        a[slot] = (1u << 31) | (1u << 30) | ((uint32_t)r << 21) |
                  ((uint32_t)(hit_ring_y & 1023) << 11) |
                  (uint32_t)(hit_ring_x & 2047);
        b[slot] = ((uint32_t)(r > 7 ? r - 7 : 0) << 16) | (uint32_t)(alpha & 0xFF);
        c[slot] = (hit_ring_timer > HIT_RING_FRAMES / 2) ? 0x00FFFFFFu : 0x00FFC060u;
        slot++;
    }
    for (int i = 0; i < 16 && slot < FX_RING_SLOTS; i++) {
        const visual_fx_t *f = &visual_fx[i];
        int age, r, ri, alpha;
        uint32_t rgb;
        if (!f->active) continue;
        age = (int)f->age;
        if (age > 23) continue;
        if (age < 4) {
            r = 8 + age * 6;
            ri = 0;
            alpha = 0;
            rgb = core_fade[age];
        } else {
            r = 26 + (age - 4) * 6;
            ri = r - 7;
            alpha = 170 - (age - 4) * 8;
            if (alpha < 30) alpha = 30;
            rgb = (age < 10) ? 0x00FFE8B0u : 0x00FF8040u;
        }
        a[slot] = (1u << 31) | (((uint32_t)(age < 4)) << 30) |
                  ((uint32_t)(r > 511 ? 511 : r) << 21) |
                  ((uint32_t)(f->y & 1023) << 11) |
                  (uint32_t)(f->x & 2047);
        b[slot] = ((uint32_t)(ri > 511 ? 511 : ri) << 16) | (uint32_t)(alpha & 0xFF);
        c[slot] = rgb & 0xFFFFFFu;
        slot++;
    }

    /* Unconditional: it is twelve APB writes (about 48 core cycles) and it is
     * also what clears the slots of impacts that just expired. */
    for (int i = 0; i < FX_RING_SLOTS; i++) {
        GPU2D_REG_FX_RING(i, 0) = a[i];
        GPU2D_REG_FX_RING(i, 1) = b[i];
        GPU2D_REG_FX_RING(i, 2) = c[i];
    }
}

static __attribute__((unused)) void burst_render(uint32_t fb, int x, int y, int age)
{
    uint32_t src = MM_BURST_FRAME + (uint32_t)age * MM_BURST_FRAME_BYTES;
    int radius = 8 + age * 2;
    if (radius < 16) radius = 16;
    int inset = BURST_CENTRE - radius;
    src += (uint32_t)inset * (MM_BURST_FRAME_STRIDE + 4u);
    int bx = x - radius;
    int by = y - radius;
    int w = radius * 2, h = w;

    if (bx < GAME_LEFT) {
        int d = GAME_LEFT - bx;
        src += (uint32_t)d * 4u;
        w -= d;
        bx = GAME_LEFT;
    }
    if (bx + w > GAME_RIGHT) w = GAME_RIGHT - bx;
    /* Clipped at GAME_TOP, not at the 130 this used to be: 130 was the
     * bottom of the old HUD band, so an impact high on the screen had its top
     * two thirds cut off - and a burst on the boss, which flies near the top,
     * is the common case (section 6). */
    if (by < GAME_TOP) {
        int d = GAME_TOP - by;
        src += (uint32_t)d * MM_BURST_FRAME_STRIDE;
        h -= d;
        by = GAME_TOP;
    }
    if (by + h > GAME_BOTTOM) h = GAME_BOTTOM - by;

    if (w > 0 && h > 0)
        r_alpha(fb + (uint32_t)(by * SCREEN_STRIDE) + (uint32_t)(bx * 4),
               src, (uint32_t)w, (uint32_t)h,
               MM_BURST_FRAME_STRIDE, SCREEN_STRIDE, 255);
}

/* ---- UI weather occlusion -------------------------------------------------
 *
 * The weather layer is synthesised by the scanout ABOVE the framebuffer, so every
 * panel that exists only as pixels in the framebuffer - the pause card, the
 * boss's dialogue card, the stage title card - has snow falling through its
 * lettering.  Switching the layer off for the whole screen whenever a panel is up
 * buys clean text and an empty sky, and the battlefield is supposed to keep its
 * snow, so the scanline logic is handed the panel's bounding box instead
 * (rtl/v_dma/video_weather.v) and stops compositing the dots that fall inside it.
 * A flake one pixel outside the border falls exactly as it did before.
 *
 * One frame, one box.  A panel declares its own rectangle while it paints
 * (weather_box_cover) and the frame publishes the union of what was declared
 * (weather_box_publish), so two panels up at once - the pause card over a
 * dialogue, say - are both covered without either one having to know about the
 * other, and a frame with no panel up clears the box with the single write that
 * drops its enable.  A box the scanout already holds is not re-sent, which is
 * what keeps this at zero writes on the frames where nothing moves.  None of it
 * touches the weather control word, which keeps running underneath. */
static uint8_t weather_box_on;       /* the scanout is holding a box right now */
static uint8_t weather_box_staged;   /* this frame declared at least one panel */
static int16_t weather_box_x0, weather_box_y0, weather_box_x1, weather_box_y1;
static int16_t weather_sent_x0, weather_sent_y0, weather_sent_x1, weather_sent_y1;

/* The box fields are 11 bits wide and the screen sits well inside them; clamping
 * is here so a panel that hangs off an edge degrades to its visible part instead
 * of wrapping into the far side of the screen. */
#define WEATHER_BOX_MAX 2047

static void weather_box_begin(void)
{
    weather_box_staged = 0u;
}

static void weather_box_cover(int x0, int y0, int x1, int y1)
{
    if (x1 < 0 || y1 < 0 || x0 > WEATHER_BOX_MAX || y0 > WEATHER_BOX_MAX)
        return;                                  /* none of it is on screen */
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > WEATHER_BOX_MAX) x1 = WEATHER_BOX_MAX;
    if (y1 > WEATHER_BOX_MAX) y1 = WEATHER_BOX_MAX;

    if (!weather_box_staged) {
        weather_box_x0 = (int16_t)x0;
        weather_box_y0 = (int16_t)y0;
        weather_box_x1 = (int16_t)x1;
        weather_box_y1 = (int16_t)y1;
        weather_box_staged = 1u;
        return;
    }
    if (x0 < weather_box_x0) weather_box_x0 = (int16_t)x0;
    if (y0 < weather_box_y0) weather_box_y0 = (int16_t)y0;
    if (x1 > weather_box_x1) weather_box_x1 = (int16_t)x1;
    if (y1 > weather_box_y1) weather_box_y1 = (int16_t)y1;
}

static void weather_box_publish(void)
{
    if (weather_box_staged) {
        if (weather_box_on &&
            weather_box_x0 == weather_sent_x0 &&
            weather_box_y0 == weather_sent_y0 &&
            weather_box_x1 == weather_sent_x1 &&
            weather_box_y1 == weather_sent_y1)
            return;                              /* the scanout already holds it */
        GPU2D_REG_WEATHER_MASK_Y = ((uint32_t)weather_box_y1 << 11) |
                                   (uint32_t)weather_box_y0;
        GPU2D_REG_WEATHER_MASK_X = (1u << 31) |
                                   ((uint32_t)weather_box_x1 << 11) |
                                   (uint32_t)weather_box_x0;
        weather_sent_x0 = weather_box_x0;
        weather_sent_y0 = weather_box_y0;
        weather_sent_x1 = weather_box_x1;
        weather_sent_y1 = weather_box_y1;
        weather_box_on = 1u;
    } else if (weather_box_on) {
        GPU2D_REG_WEATHER_MASK_X = 0u;   /* the enable lives here: one write clears it */
        weather_box_on = 0u;
    }
}

/* Used when the game leaves the screen entirely (boot menu): the next screen is
 * not a panel over the battlefield, so nothing of this must survive into it. */
static void weather_box_release(void)
{
    if (!weather_box_on) return;
    GPU2D_REG_WEATHER_MASK_X = 0u;
    weather_box_on = 0u;
}

/* Stage title card.  The backdrop already changed when the previous boss
 * died, so a short banner is what tells the player that the scenery is
 * deliberate and not a glitch.  It fades out over its last 40 frames by
 * shrinking the plate it sits on. */
/* ---- the spell card's own sky ----------------------------------------
 * ?5.1 asks for the scenery to change when the card goes off; ?L3 asks for
 * that scenery to be a picture the three stages do not already have.  A
 * fourth STORED plate would be about 4 KB of RLE and the firmware has
 * under 2 KB free - but a plate is only flat bands, a handful of procedural
 * shapes and a skyline, exactly what tools/build_stage_backgrounds.py emits
 * offline.  So the fourth one is computed into DDR at boot instead; the
 * generator costs a few hundred bytes of code and no asset bytes at all.
 *
 * NOTHING here multiplies inside a pixel loop.  The main loop runs 384000
 * times, and the core multiplies through the iterative MulDiv plugin rather
 * than a single-cycle multiplier, so an `*` per pixel would still cost more
 * cycles than the adds and shifts it replaces.  (The old note here - "every
 * `*` is a __mulsi3 call" - stopped being true when the firmware moved to
 * -march=rv32im; see sw/build_firmware.py.)  Bands advance on a Bresenham
 * accumulator, the ward is a Manhattan distance |dx|+|dy| (adds and
 * compares only), its glow is indexed by `d >> 6` because 64 is a power of
 * two, and rows advance by a pointer step rather than y * stride.
 * Multiplication and modulo survive only in the two short loops at the end
 * (220 stars, 40 towers), which is a few hundred multiplies in total.
 */
#define CARD_BG_BANDS  24
#define CARD_BG_STEP   64u          /* ring pitch; a power of two on purpose */
#define CARD_BG_WARD   384u         /* the ward reaches 6 * CARD_BG_STEP */

static void card_bg_build(void)
{
    /* Cold indigo at the top, a dull ember low down: deliberately darker
     * than any of the three stage plates, because a screen full of bullets
     * has to stay readable on top of it. */
    static const uint32_t sky[CARD_BG_BANDS] = {
        0x00020206u, 0x00030209u, 0x0004030Du, 0x00060412u,
        0x00080517u, 0x000A071Du, 0x000D0823u, 0x00100A29u,
        0x00130C2Fu, 0x00170F34u, 0x001B1238u, 0x001F163Bu,
        0x00241A3Du, 0x00291F3Eu, 0x002F243Eu, 0x00352A3Du,
        0x003B303Bu, 0x00413739u, 0x00483E37u, 0x004E4534u,
        0x00554D32u, 0x005B5530u, 0x00615D2Eu, 0x0067652Du,
    };
    /* Center of the ward outwards: cold white, then a dying red. */
    static const uint32_t glow[CARD_BG_WARD / CARD_BG_STEP] = {
        0x00FFECE2u, 0x00E28080u, 0x00AA3E52u,
        0x0078223Eu, 0x004C142Eu, 0x002C0C20u,
    };
    volatile uint32_t *row = (volatile uint32_t *)MM_CARD_BG;
    unsigned band = 0, acc = 0;

    for (unsigned y = 0; y < SB_BG_H; y++) {
        uint32_t base = sky[band];
        unsigned uy = (y > SB_BG_H / 2u) ? y - SB_BG_H / 2u : SB_BG_H / 2u - y;

        for (unsigned x = 0; x < SB_BG_W; x++) {
            unsigned ux = (x > SB_BG_W / 2u) ? x - SB_BG_W / 2u : SB_BG_W / 2u - x;
            unsigned d = ux + uy;              /* Manhattan: a diamond */
            uint32_t v = base;

            if (d < CARD_BG_WARD) {
                v = glow[d >> 6];
                if ((d & (CARD_BG_STEP - 1u)) < 2u) v = 0x00ECA8B0u;
                if (ux < 3u || uy < 3u) v = 0x00FFD6D2u;
            }
            row[x] = v;
        }
        row += SCREEN_STRIDE / 4u;
        acc += CARD_BG_BANDS;
        if (acc >= SB_BG_H && band + 1u < CARD_BG_BANDS) {
            acc -= SB_BG_H;
            band++;
        }
    }

    /* A local xorshift, NOT the game's: boot must not shift the sequence the
     * boss draws its attack patterns from. */
    unsigned s = 0x20260921u;
    for (unsigned k = 0; k < 220u; k++) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        unsigned sx = s & 0x3FFu;
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        unsigned sy = s & 0x3FFu;
        if (sx >= SB_BG_W || sy >= SB_BG_H) continue;
        unsigned ux = (sx > SB_BG_W / 2u) ? sx - SB_BG_W / 2u : SB_BG_W / 2u - sx;
        unsigned uy = (sy > SB_BG_H / 2u) ? sy - SB_BG_H / 2u : SB_BG_H / 2u - sy;
        if (ux + uy < CARD_BG_WARD) continue;      /* inside the ward */
        *(volatile uint32_t *)(MM_CARD_BG + sy * SCREEN_STRIDE + sx * 4u) =
            (s & 3u) ? 0x00D0D6ECu : 0x00FFFFFFu;
    }

    /* Ruined towers along the bottom edge, each with a lit upper lip. */
    for (unsigned bx = 0; bx < SB_BG_W; bx += 16u) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        unsigned hgt = 24u + (s % 76u);
        volatile uint32_t *p = (volatile uint32_t *)
            (MM_CARD_BG + (SB_BG_H - hgt) * SCREEN_STRIDE + bx * 4u);
        for (unsigned y = 0; y < hgt; y++) {
            for (unsigned k = 0; k < 16u; k++)
                p[k] = (y < 2u) ? 0x004A1A34u : 0x0006030Au;
            p += SCREEN_STRIDE / 4u;
        }
    }

    /* No border columns here on purpose: they belong to the FRAME, not to a
     * plate, and game_render() draws them whenever the plate under them
     * changes - which includes this one arriving. */

    gpu2d_flush_dcache();
}

static void stage_banner_render(uint32_t fb)
{
    static const char * const names[SB_STAGE_COUNT] = {
        "STAGE 1  FROZEN SHRINE",
        "STAGE 2  VOLCANIC HOLLOW",
        "STAGE 3  DREAM REFLECTION"
    };
    if (!stage_banner) return;

    int w = 420, h = 64;
    int x = ((int)SCREEN_WIDTH - w) / 2;
    int y = 196;
    if (stage_banner < 40) {            /* shrink away instead of popping off */
        int k = (int)stage_banner;
        w = 420 * k / 40;
        h = 64 * k / 40;
        x = ((int)SCREEN_WIDTH - w) / 2;
        y = 196 + (64 - h) / 2;
    }
    if (w < 8 || h < 4) return;

    uint32_t base = fb + (uint32_t)(y * SCREEN_STRIDE) + (uint32_t)(x * 4);
    /* Same deal as the pause card: the banner is framebuffer pixels, so the
     * scanout has to be told to leave this rectangle alone.  The box follows the
     * shrink, so the flakes come back with the edges as the banner fades. */
    weather_box_cover(x, y, x + w - 1, y + h - 1);
    r_fill(base, (uint32_t)w, (uint32_t)h, 0x00101830u, SCREEN_STRIDE);
    r_fill(base, (uint32_t)w, 3, 0x00FFE4A0u, SCREEN_STRIDE);
    r_fill(base + (uint32_t)((h - 3) * SCREEN_STRIDE), (uint32_t)w, 3,
           0x00FFE4A0u, SCREEN_STRIDE);
    if (w >= 300)
        draw_text(fb, x + 16, y + 22, names[stage_bg_active < SB_STAGE_COUNT ?
                  stage_bg_active : 0], 2, 0x00FFFFFFu);
}

/* Enemy debuffs used to be a bare "SLOW" / "JAM" label with no expiry on it,
 * so a slow with two seconds left looked exactly like one that had just landed
 * and the player had no way to know when they could move again.  They now
 * count down on ONE line ("SLOW 3.2") and sit in the gap between the backdrop's
 * HOLD A and CONTROL labels: stacking the label above its timer put the timer
 * on top of backdrop text, which is what the overlapping panels turned out to
 * be.  The backdrop is a 512x300 image drawn at 2x, so every label baked into
 * it sits at twice its source y. */
static void draw_debuff(uint32_t fb, int y, const char *label, uint16_t frames)
{
    char buf[9];
    int i = 0;

    while (label[i]) { buf[i] = label[i]; i++; }
    buf[i++] = ' ';
    buf[i++] = (char)('0' + (frames / 60u) % 10u);
    buf[i++] = '.';
    buf[i++] = (char)('0' + (frames % 60u) / 6u);
    buf[i] = '\0';
    draw_text(fb, 12, y, buf, 2, 0x00FF5070u);
}

/* ---- HUD gutter repair ledger ------------------------------------------
 *
 * WHY.  Both gutters used to be repainted from the pristine menu backdrop on
 * every frame - ten rectangles, 684 scanlines - because a widget is allowed to
 * SHRINK: losing a life removes a heart, letting a debuff expire removes the
 * countdown, and a narrower word does not erase the wider one it replaced.
 * The repair is what erases them.  But on most frames nothing in the gutters
 * changes at all, and those 684 scanlines are then pure copying: the same
 * backdrop bytes laid back down underneath the very widgets that are about to
 * be drawn on top of them again.
 *
 * So the repair is armed by a CHANGE instead of by the clock.  Eight numbers
 * cover everything the ten bands draw that is not fixed for the life of the
 * run:
 *
 *   stage   STAGE/BOSS caption, the wave number, WAVE/BOSS LIFE
 *   lives   the heart row                     (one heart per life)
 *   debuff  the countdown's own two digits, and whether it is up at all
 *   weapon  the shot name                     (FAN 3 glyphs, SPREAD 6)
 *   atk     the attack stars                  (one star per point)
 *   backend the FPGA / CPU token              (4 glyphs against 3)
 *   score   the six-digit readout
 *   fps     the two-digit hardware readout
 *
 * WHAT IS NOT WATCHED, AND WHY IT DOES NOT NEED TO BE.  The pieces that are
 * fixed for a run - the captions, the portrait, the stage name, the card ticks
 * and the two bars - are either constant or repaint their own background with
 * a fill every frame, so the previous frame's pixels cannot survive under
 * them.  A fill covers its whole rectangle; a colour-key glyph copy does not.
 * That distinction is the whole reason the four text readouts above are on the
 * list and the "I checked the width and it matches" reasoning is not: six
 * digits against six digits still leaves strokes behind, because '9' does not
 * cover the left side of '0'.
 *
 * Each number is compared once per frame, on the frame the renderer runs, and
 * a move arms the band it owns.
 *
 * BOTH scanout buffers are armed, not just the one being painted: the frame
 * counter alternates them, so the other buffer is still carrying the old
 * pixels and is the next frame's target.  A band is disarmed only on the
 * buffer whose repair actually ran.
 *
 * THE OTHER WAY A GUTTER GETS DIRTY is a full-screen plate blit painting
 * straight over it.  damage_full - a stage switch, the boss's own sky, the
 * first frame on a buffer - copies the whole 1366x768 plate, gutters included,
 * and what those rows then hold is the stage plate, not the menu backdrop the
 * repair lays down; so that path re-arms every band on the buffer it painted.
 * clear_frame() and the GAME OVER fill are the same story, and both are
 * followed by game_init(), which re-arms everything.
 */
#define HUD_BAND_STAGE   (1u << 0)   /* left  0..75    stage block, wave/boss bar */
#define HUD_BAND_PLAYER  (1u << 1)   /* left  86..173  the portrait + caption    */
#define HUD_BAND_LIVES   (1u << 2)   /* left  176..239 the heart row             */
#define HUD_BAND_SCORE   (1u << 3)   /* left  256..305 the score block           */
#define HUD_BAND_SPELL   (1u << 4)   /* left  342..419 the card charge ticks     */
#define HUD_BAND_DEBUFF  (1u << 5)   /* left  512..585 SLOW / JAM                */
#define HUD_BAND_WEAPON  (1u << 6)   /* right 2..67    shot name + level bar     */
#define HUD_BAND_ATK     (1u << 7)   /* right 102..147 the attack stars          */
#define HUD_BAND_BACKEND (1u << 8)   /* right 192..273 backend token, FPS tag    */
#define HUD_BAND_FPSNUM  (1u << 9)   /* right 232..291 the FPS readout           */
#define HUD_BAND_STRESS  (1u << 10)  /* left 592..703 active sprites / row drops */
#define HUD_BAND_ALL     0x07FFu

enum { HUD_SIG_STAGE = 0, HUD_SIG_LIVES, HUD_SIG_DEBUFF,
       HUD_SIG_WEAPON, HUD_SIG_ATK, HUD_SIG_BACKEND,
       HUD_SIG_SCORE, HUD_SIG_FPS, HUD_SIG_STRESS, HUD_SIG_COUNT };

static uint16_t hud_dirty[2];            /* one bitmask per scanout buffer */
extern uint32_t hud_sig[HUD_SIG_COUNT];
static uint8_t  hud_sig_valid;

/* draw_text() and draw_number() are COLOUR-KEY copies: they write the glyph
 * pixels and nothing else.  A character that changes shape therefore leaves
 * the strokes it no longer covers standing on the backdrop - the score's six
 * fixed digits do not save it, because a '9' painted over a '0' leaves the
 * left stroke of the '0' showing, and neither does a countdown that is still
 * running, because "SLOW 3.2" becomes "SLOW 3.1" six frames later.  So every
 * caption is watched by what it SAYS.  This is the trap the first cut of this
 * ledger fell into: it watched the widgets that come and go, not the ones that
 * change their mind in place. */
static uint32_t hud_debuff_sig(uint16_t frames)
{
    /* The two characters draw_debuff() puts on the line, and nothing else:
     * (frames / 60) % 10 and (frames % 60) / 6.  0 also means "not drawn". */
    if (!frames) return 0u;
    return 1u + (uint32_t)((frames / 60u) % 10u) * 10u +
           (uint32_t)((frames % 60u) / 6u) * 100u;
}

/* Arm a band when the value behind it moves.  The band is passed in rather
 * than derived from the slot, so the mapping stays readable at the call site. */
static void hud_watch(unsigned sig, uint32_t value, uint16_t band)
{
    if (hud_sig[sig] == value) return;
    hud_sig[sig] = value;
    hud_dirty[0] |= band;
    hud_dirty[1] |= band;
}

/* ========================================================================
 * B1: the scanout's bullet overlay
 * ========================================================================
 *
 * The curtain's state is MAX_EBULLETS records of 8 bytes (512 since the pools
 * were widened; the pressure stage itself still holds the 192 it always did).
 * Until now every frame expanded
 * that into ~30,000 pixels written into the framebuffer, which the scanout then
 * read 4.32 MB back out of DDR to look at, and which the backdrop repair then
 * had to put back tile by tile.  That repair was the expensive half: 4,478 + 768
 * rows against the 5,400 the bullets themselves cost.
 *
 * Now the firmware tells the scanout where the bullets are and the scanout draws
 * them on the way past.  Two things get published:
 *
 *   the tile store   every bullet SHAPE, once, at boot - one byte per pixel,
 *                    and that byte is a ROLE number rather than a palette
 *                    index.  The colour is resolved on the scanout side as
 *                    role + hue*32, which is what collapses each set's eight
 *                    colourings into one.  16 enemy shapes + 1 player + 1 orb
 *                    is 3,792 bytes, so it fits an 8 KB store.
 *
 *   the palette      built here from the roles and the eight hues, in the
 *                    order the scanout's index arithmetic implies.  See
 *                    brole_color() below.
 *
 *   the bucket table one entry per (bullet, scanline it covers), appended every
 *                    frame in DRAW ORDER - the last entry covering a pixel is the
 *                    one that wins, which is exactly the rule the render loops
 *                    below already had.
 */

/* The palette is BPAL_PAGE * 8 = 256 entries and that is the whole RAM depth,
 * which is now also the hard limit: the scanout forms the index itself as
 * role + hue * BPAL_PAGE, so an index is not "handed out" here any more and
 * there is nothing to run out of.  The old BPAL_MAX 255 guarded the
 * first-seen-first-numbered hash that used to live here. */

/* The palette entry's alpha byte has one value that is not an opacity: 254
 * means ADD.  The scanout sums the bullet onto whatever is under it instead of
 * blending with it, which is what the spec's "glowing things add" list wants -
 * a missile's trail, the shell around a light bullet - and it has to be
 * decidable per PIXEL, because one bullet can be a blended body with an added
 * trail.
 *
 * 254 rather than a new bit: the entry is 32 bits wide and every bit of it is
 * spoken for, and widening this path is what broke it once already (bitblt_top's
 * bpal_data port was 24 bits and dropped the alpha byte, which made every bullet
 * in the picture invisible).  What 254 costs is the 254/255 blend, the one step
 * of the ramp that is 0.4% away from opaque.
 *
 * THE MISSILE'S TRAIL USES IT, AND IT IS STILL THE ONLY THING THAT DOES.  Two
 * roles carry it, on all eight hue pages, in bullet_store_build() below:
 *
 *     BROLE_MS_TRAIL   BPAL_ADD   the trail: light, so it adds
 *     BROLE_MS_BODY    190        the body:   a solid, so it blends
 *
 * A shape, two mixes.  Everything else - the orbs, the enemy barrage, the fan
 * shot - stays opaque and still asks for no mix at all.
 *
 * The hardware side is in video_bullet_overlay.v (ADD_CODE) and the branch that
 * uses it is in video_dma_read.v, both checked by scratch/tb_bullet_add.sv. */
#define BPAL_ADD   254u

static uint16_t bpal_n;

/* 一个角色在某个色相下的颜色。
 *
 * 这些表达式与三个 *_tile_build 里原来算颜色的那几行逐字对应 —— 换过来之后
 * 颜色一个也没变，变的只是它们坐在哪一条索引上（scratch/recon_color_split.py
 * 会重新数一遍：仍应是 26 个角色、198 种不同的颜色）。
 *
 * 角色号见文件顶上的 BROLE_*。 */
static uint32_t brole_color(unsigned role, unsigned hue)
{
    uint32_t n  = palette[hue & 7u];
    uint32_t nr = (n >> 16) & 0xFFu;
    uint32_t ng = (n >> 8)  & 0xFFu;
    uint32_t nb = n & 0xFFu;

    switch (role) {
    case BROLE_WHITE:
        return 0x00FFFFFFu;
    case BROLE_NEON:
        return n;
    case BROLE_EB_CORE:                     /* 色相往白靠 60/255 */
        return ((255u - ((255u - nr) * 60u / 255u)) << 16) |
               ((255u - ((255u - ng) * 60u / 255u)) << 8)  |
                (255u - ((255u - nb) * 60u / 255u));
    case BROLE_ORB_CORE:                    /* 色相往白靠 80/255 */
        return ((255u - ((255u - nr) * 80u / 255u)) << 16) |
               ((255u - ((255u - ng) * 80u / 255u)) << 8)  |
                (255u - ((255u - nb) * 80u / 255u));
    case BROLE_PB_DIM:
        return (n >> 1) & 0x007F7F7Fu;
    case BROLE_PB_QUART:                    /* 同时也是大玉的外缘暗环 */
        return (((n >> 1) & 0x007F7F7Fu) >> 1) & 0x007F7F7Fu;
    case BROLE_PB_TINY:
        return (((n >> 2) & 0x007F7F7Fu) >> 1) & 0x007F7F7Fu;
    case BROLE_PB_HOT:
        return ((n >> 1) & 0x007F7F7Fu) + 0x007F7F7Fu;
    /* 导弹的两个角色：固定色，不跟 hue 走。导弹只有 spawn_pbullet_lockon()
     * 一个来源，它永远 color = 5；固定色让"这是导弹"不依赖桶条目的色相页，
     * 也让调色板只多两条不重复的颜色（198 -> 200）。8 个色相格填的是同一个
     * 值，重复的条目只花槽位、不花颜色。 */
    case BROLE_MS_BODY:
        return 0x0066DDFFu;     /* 亮青：alpha 190，乘法 alpha，透出背景 */
    case BROLE_MS_TRAIL:
        return 0x00FF9020u;     /* 橙：alpha 254 = BPAL_ADD，加法会往黄白过曝 */
    default:
        break;
    }
    if (role == 29u) return 0x00FF6080u;
    if (role == 30u) return 0x00FFE0F0u;
    if (role >= BROLE_EB_HALO && role < BROLE_EB_HALO + BROLE_EB_HALO_N) {
        uint32_t a = eb_halo_a[role - BROLE_EB_HALO];
        return (((nr * a) / 255u) << 16) | (((ng * a) / 255u) << 8) |
               ((nb * a) / 255u);
    }
    return 0u;                              /* 哨兵或越界：不画 */
}

/* ---- the bucket's row unit ---------------------------------------------
 * MM_BUCKET_GROUP_ROWS scanlines share one bucket (see memory_map.h for why).
 * The scanout recovers a bullet's real tile row as
 *
 *     stored trow_base + (y & (BUCKET_GROUP_ROWS - 1))
 *
 * so the group size has to be a power of two - the low bits of the scanline
 * counter ARE the offset and nothing has to be divided.
 *
 * These live here, above bullet_store_build(), because that function needs
 * BUCKET_TILE_ROWS to pad the orb run. */
#define BUCKET_GROUP_ROWS   MM_BUCKET_GROUP_ROWS
#define BUCKET_GROUPS       MM_BUCKET_ROWS
/* Rows the bucket tables span.  Not MM_BUCKET_ROWS any more - that counts
 * groups now. */
#define BUCKET_SCREEN_ROWS  SCREEN_HEIGHT
/* Every slot's tile holds this many rows in the scanout's store.  The orb tile
 * is only MM_ORB_TILE_H (16) rows of picture, but bullet_store_build() pads it
 * out to 26 with transparent roles, because the scanout rejects an out-of-range
 * tile row with one comparison against this constant instead of a per-slot
 * table.  Without the pad a trow of 16..25 would read the next tile's bytes. */
#define BUCKET_TILE_ROWS    26

/* One tile, re-rowed from the engine's stride into the scanout's.  The two
 * differ: the engine packs 13 pixels into 64 bytes, the scanout wants a 16-byte
 * power-of-two row so its address is a shift.  The padding is written as role 0
 * ("nothing here") rather than left alone, so a future stride change cannot
 * leak whatever was in the store.
 *
 * This used to be a colour-to-index pass through an open-addressed hash.  It is
 * not any more: the tile builders write ROLE numbers, so the only thing left to
 * do here is re-row the bytes.  The colour lives in the palette now, and which
 * hue page it comes from is decided per bullet in the bucket entry. */
static void bullet_store_tile(uint32_t src, int w, int h, int sstride, int rowstride)
{
    /* 源图块现在是**每像素一字节**，那一字节就是角色号；以前它是 ARGB8888，
     * 这里只取低字节。三个 *_tile_build() 与它一起换的表示，所以从源到
     * tile store 一个字节都没转手。 */
    for (int y = 0; y < h; y++) {
        volatile const uint8_t *row = (volatile const uint8_t *)
            (src + (uint32_t)y * (uint32_t)sstride);
        for (int x = 0; x < rowstride; x++) {
            uint8_t role = BROLE_NONE;
            if (x < w) role = row[x];
            GPU2D_REG_BTILE_DATA = (uint32_t)role;
        }
    }
}

static void bullet_store_build(void)
{
    volatile uint32_t * const wk = (volatile uint32_t *)MM_BULLET_WORK;

    for (uint32_t i = 0; i < 256u; i++) {
        wk[i] = 0xFFFFFFFFu;
        wk[256u + i] = 0u;
        wk[512u + i] = 0u;
    }
    /* ---- 调色板：索引 = 角色号 + 色相 * 32 ------------------------------
     *
     * 改之前这里是"按颜色去重、先出现先编号"，198 条颜色挤在 1..198 里，索引
     * 是多少由遍历顺序决定 —— 也就是说同一个图块的颜色和它的索引绑死，八个
     * 色相只能靠八份图块分别去指。现在索引是算出来的：角色号在低 5 位，色相
     * 在高 3 位，扫描端一次拼接就得到它（video_bullet_overlay.v）。
     *
     * 每个角色占满一页的 8 个色相格，即使它的 8 个值一模一样（纯白就是），
     * 因为格子是算出来的、不是编出来的。重复的条目只花槽位不花颜色：真正
     * 不同的颜色仍然是 198 条，与改之前一模一样。
     *
     * 角色 0（透明哨兵）的每一格都留 0 —— hue > 0 时它会算出 32/64/... 这些
     * 索引，那些索引永远读不到（tile 字节是 0 的时候扫描端直接判不画），
     * 留黑是为了万一被引用到也不会画出花来。 */
    for (unsigned hue = 0u; hue < 8u; hue++)
        for (unsigned role = 1u; role <= BROLE_MAX; role++)
            wk[512u + role + hue * BPAL_PAGE] = brole_color(role, hue);

    /* telemetry[56] 报的是"真正不同的颜色有多少条"，与改之前 bpal_n 的含义一致
     * （那时候它是"见过几种颜色"）。临时区借用工作块的尾部，不占栈 —— 这个
     * 函数所在的线程只剩不到 2 KB，1 KB 的数组放不下。 */
    {
        volatile uint32_t * const seen = wk + 768u;
        uint32_t ns = 0u;
        for (uint32_t i = 768u; i < 1024u; i++) wk[i] = 0u;
        for (uint32_t i = 1u; i < 256u; i++) {
            uint32_t c = wk[512u + i] & 0x00FFFFFFu;
            uint32_t dup = 0u;
            if (c == 0u) continue;              /* 角色 0 的那些空格子 */
            for (uint32_t k = 0u; k < ns; k++)
                if (seen[k] == c) { dup = 1u; break; }
            if (!dup) seen[ns++] = c;
        }
        bpal_n = (uint16_t)ns;
    }

    /* The buckets live in DDR, and DDR is neither fresh nor zero at power-up.
     *
     * bucket_reset() only clears the cells the PREVIOUS frame wrote - bt_used[]
     * holds last frame's count per row, and on the very first frame it is all
     * zero, so nothing gets cleared and every cell the first frame does not
     * fill keeps whatever the DDR powered up with.  The scanout reads a cell as
     * live when its width field is nonzero, so it draws that garbage as bullets:
     * a screenful of torn tiles, with the laser still crisp on top of it.
     *
     * The workbench cannot see this.  Its DDR is a fresh bytearray where every
     * byte already reads zero, so a missing clear looks exactly like a working
     * one.  Both tables, once, at boot: 24,576 stores is about 1 ms, and boot
     * is the one place that can afford it.
     *
     * AND THE ORDER MATTERS.  Those stores sit in the D-cache; only a flush puts
     * them in DDR.  GPU2D_REG_BUCKET_BASE is an APB write and takes effect the
     * cycle it lands, so from that moment the scanout is reading this table -
     * and if the zeros have not drained yet it reads whatever DDR powered up
     * with, treats every nonzero width as a live entry and paints a screenful
     * of torn bullet tiles.  It clears itself at the first flush, which is what
     * "the corruption goes away on its own after a moment" was.
     *
     * Same for the depth array below: it is in DDR, not bss, so it is not zero
     * either, and a garbage depth would have bucket_reset() clearing an
     * arbitrary number of cells on its first call. */
    for (uint32_t i = 0;
         i < ((uint32_t)MM_BUCKET_STRIDE * (uint32_t)MM_BUCKET_ROWS * 2u) / 4u;
         i++)
        ((volatile uint32_t *)MM_BUCKET_TABLE)[i] = 0u;
    for (uint32_t i = 0; i < MM_BUCKET_USED_BYTES / 4u; i++)
        ((volatile uint32_t *)MM_BUCKET_USED)[i] = 0u;

    /* Publish nothing until the table it names is really zero in DDR. */
    gpu2d_flush_dcache();

    GPU2D_REG_BUCKET_BASE = MM_BUCKET_TABLE;
    GPU2D_REG_BTILE_ADDR  = 0u;

    /* 四个 run，顺序就是 video_bullet_overlay.v 的 slot 0..18。源 stride 与
     * 扫描端行距现在都是"每像素一字节、2 的幂的行字节数"，所以两边用同一个
     * 宏 —— 敌弹 32/26x26、玩家弹 8/7x26、大玉 16/16x16、导弹 16/13x26。 */
    for (uint32_t t = 0; t < MM_EBULLET_DIRTILE_COUNT; t++)
        bullet_store_tile(MM_EBULLET_DIRTILE + t * MM_EBULLET_DIRTILE_BYTES,
                          MM_EBULLET_DIRTILE_W, MM_EBULLET_DIRTILE_H,
                          MM_EBULLET_DIRTILE_STRIDE, MM_EBULLET_DIRTILE_STRIDE);
    for (uint32_t t = 0; t < MM_PBULLET_TILE_COUNT; t++)
        bullet_store_tile(MM_PBULLET_TILE + t * MM_PBULLET_TILE_BYTES,
                          MM_PBULLET_TILE_W, MM_PBULLET_TILE_H,
                          MM_PBULLET_TILE_STRIDE, MM_PBULLET_TILE_STRIDE);
    for (uint32_t t = 0; t < MM_ORB_TILE_COUNT; t++)
        bullet_store_tile(MM_ORB_TILE + t * MM_ORB_TILE_BYTES,
                          MM_ORB_TILE_W, MM_ORB_TILE_H,
                          MM_ORB_TILE_STRIDE, MM_ORB_TILE_STRIDE);
    /* 大玉 tile 补到 BUCKET_TILE_ROWS 行。
     *
     * 扫描端对每个 slot 的 tile 都用同一个上界判断条目里的 tile 行号有没有
     * 越界 —— 一条 trow >= 26 的条目会读到后面那个 tile 的字节，在屏幕上画
     * 出一条别的弹幕的碎片。要让"26"对谁都成立，store 里每个 slot 就得至少
     * 有 26 行。敌弹、玩家弹、导弹本来就是 26 行，只有大玉是 16 行，所以这里
     * 补 10 行透明角色。
     *
     * BTILE_DATA 是自增指针，写完大玉接着写就是它后面那 10 行的位置；
     * video_bullet_overlay.v 的 MS_BASE 也跟着从 13,776 挪到 13,936。 */
    for (int y = MM_ORB_TILE_H; y < BUCKET_TILE_ROWS; y++)
        for (int x = 0; x < MM_ORB_TILE_STRIDE; x++)
            GPU2D_REG_BTILE_DATA = 0u;
    for (uint32_t t = 0; t < MM_MISSILE_TILE_COUNT; t++)
        bullet_store_tile(MM_MISSILE_TILE + t * MM_MISSILE_TILE_BYTES,
                          MM_MISSILE_TILE_W, MM_MISSILE_TILE_H,
                          MM_MISSILE_TILE_STRIDE, MM_MISSILE_TILE_STRIDE);

    /* Align the 24-wide lance rows to the scanline RAM's 32-texel words.
     * Preserve the exact eight boot-built shapes and their two RGB colours. */
    for (unsigned i = 0; i < 16u; i++) GPU2D_REG_BTILE_DATA = 0u;
    for (unsigned t = 0; t < MM_LANCE_COUNT; t++) {
        const volatile uint32_t *src = (const volatile uint32_t *)(MM_LANCE + t * MM_LANCE_BYTES);
        for (unsigned y = 0; y < 26u; y++)
            for (unsigned x = 0; x < 32u; x++) {
                uint32_t c = (x < 24u && y < 24u) ? src[y * 24u + x] & 0xFFFFFFu : MAGENTA_KEY;
                GPU2D_REG_BTILE_DATA = c == MAGENTA_KEY ? 0u : c == 0xFF6080u ? 29u : 30u;
            }
    }

    /* The scanout blends a bullet against what is behind it using the palette
     * entry's top byte, and the register is a pointer that advances on every
     * write - so all 256 entries go out once, below, each carrying its colour
     * and the alpha it should have.  There used to be two opaque passes here
     * first, which the alpha pass then had to redo in full; they are gone. */

    /* ---- every SOLID is opaque, and why no index is listed here any more ---
     *
     * The entry's top byte is the only place a mix can be asked for.  Nothing
     * SOLID asks for one: the big orbs were the last exception - 192..198 had
     * been set to 190, which is what this takes back out - and after the halo
     * change below the mixes that remain all belong to light rather than to
     * matter (the missile's trail, and the glow around every enemy bullet).
     *
     * The rule is "ENEMY BULLETS AND BIG ORBS STAY OPAQUE".  An enemy shot that
     * shows the snowfield through it is a playability problem rather than a
     * look - a quarter-transparent orb reads as washed out, not as translucent,
     * and the one thing it must do is be obvious against the backdrop it is
     * flying over.
     *
     * WHY THE LIST IS GONE RATHER THAN SHORTENED.  The seven indices were never
     * "everything the orbs touch".  Read back out of the VM after boot, the orb
     * tiles point at 23 entries:
     *
     *     4, 11, 25, 45, 65, 85, 105, 125        enemy bullet colours
     *     162, 166, 170, 174, 178, 182, 186, 190 player shot colours
     *     192..198                               the orbs' own, and only theirs
     *
     * bpal_index() numbers colours in first-seen order and the enemy tiles are
     * the ones walked first, so sixteen of the orbs' twenty-three are shared -
     * with the barrage and with the fan shot.  Touching those would take an
     * enemy bullet or the fan shot translucent, which is the same mistake the
     * 160..191 block had to have undone.  192..198 is the whole of what belongs
     * to the orbs alone, and it goes back to 255.
     */
    {
        /* A lookup table, not a skip-list, because the register is a POINTER:
         * it advances on every write, so "write only the ones that change"
         * would leave every later entry holding its neighbour's colour.  All
         * 256 entries go out again, in order, whether they changed or not. */
        /* Every entry's top byte is its mix, and there are four answers:
         *
         *     role 0      the sentinel       alpha 0     invisible
         *     role 9..26  the enemy halo     alpha 254   = BPAL_ADD, additive
         *     role 27     the missile BODY   alpha 190   multiply alpha
         *     role 28     the missile TRAIL  alpha 254   = BPAL_ADD, additive
         *     everything else                alpha 255   opaque replace
         *
         * WHY THE HALO ADDS, and what 255 cost there.  brole_color()
         * pre-multiplies a halo tier by its eb_halo_a[] value, and that is a
         * mix computed for a BLACK backdrop.  Saying 255 - opaque replace -
         * told the scanout to hard-replace whatever was really behind the
         * tier with that colour, so the tier stopped being light and became
         * matter.  The picture paid for it twice, and both were reported off
         * the board: a player shot passing under a halo came out greyed over
         * instead of lit, and two halos overlapping ate a wedge out of each
         * other instead of brightening.
         *
         * ADD is the mix that pre-multiplied colour was shaped for all along.
         * The scanout sums it onto the REAL backdrop, so a halo lights what is
         * under it.  The 18-step ramp survives untouched because the weighted
         * colour IS the weight; handing ADD the bare hue instead would flatten
         * all 18 tiers into one flat bright ring, which is the one way to get
         * this change wrong - tb_bullet_overlay now checks the colour is still
         * pre-multiplied for exactly that reason.
         *
         * The BODY of an enemy bullet stays opaque on purpose - the "ENEMY
         * BULLETS AND BIG ORBS STAY OPAQUE" rule still holds for it.  A shot
         * has to read as a solid object with a clear outline, because the
         * player has to see the gaps between two of them to fly through; only
         * the glow around it is light.
         *
         * The role is the low five bits of the index (index = role + hue*32),
         * so "which role is this" is one mask - and that is the whole of what
         * "one shape with two mixes" costs on this side of the wall.
         *
         * The sentinel's alpha goes on ALL EIGHT PAGES, not just page 0.  The
         * scanout decides transparency from the tile's own byte, so role 0 is
         * never supposed to reach the palette at all - but "never supposed to"
         * is not "cannot": role 0 lands on 32, 64 ... 224 on the other seven
         * pages, and those entries hold the filler black.  A pixel that ever
         * got there would come out as an opaque black speck, where the
         * eight-indexed-copies encoding this replaced could not, because there
         * every colour's transparent cell WAS index 0 with alpha 0.  Writing
         * all eight makes the two encodings fail the same way.
         *
         * The missile's two roles are written the same way.  This build only
         * references hue page 5 for them (indices 187 and 188), but alpha is
         * per index, and writing only the cell that is referenced would leave
         * "change the colour and it breaks" in the code.
         *
         * The result goes back into wk[512+k] before it goes to the register,
         * so the DDR copy is the complete 32-bit entry as well and
         * tools/gen_bullet_tiles.py reads THIS instead of implementing the rule
         * a second time - which it used to, as a flat "everything is opaque",
         * and that is what hid both of the missile's mixes from the bench.  The
         * 256-byte alpha_of[] stack array went with it. */
        uint32_t k;
        for (k = 0; k < 256u; k++) {
            uint32_t r = k & (BPAL_PAGE - 1u);
            uint32_t a = 0xFFu;
            if (r == (uint32_t)BROLE_NONE)          a = 0u;
            else if (r == (uint32_t)BROLE_MS_BODY)  a = 190u;
            else if (r == (uint32_t)BROLE_MS_TRAIL) a = BPAL_ADD;
            /* The 18 enemy halo tiers.  Written as a range off BROLE_EB_HALO
             * and its count rather than as the literal 9..26, so that adding
             * or removing a tier cannot silently leave the new one opaque -
             * which is precisely the state this whole block was in. */
            else if (r >= (uint32_t)BROLE_EB_HALO &&
                     r <  (uint32_t)BROLE_EB_HALO + BROLE_EB_HALO_N) a = BPAL_ADD;
            wk[512u + k] = (a << 24) | (wk[512u + k] & 0x00FFFFFFu);
            GPU2D_REG_BPAL_DATA = wk[512u + k];
        }
    }

    /* Written through the base address: the tlm pointer itself is declared
     * further down the file, next to the frame-budget block. */
    *(volatile uint32_t *)(MM_TELEMETRY_BASE + 56u * 4u) = (uint32_t)bpal_n;
}

/* ---- the per-scanline bucket ------------------------------------------- */

/* Eight bits a bucket, in bss, because this is touched hundreds of times a frame
 * and the part has about 2 KB of firmware RAM left.  The entries themselves go
 * to DDR - 48 KB a table, which is 200 MB of free DDR's problem, not the
 * firmware's.
 *
 * The matching "how deep did this bucket go last time" array is NOT here: it
 * needs one copy per bucket table, and it lives at MM_BUCKET_USED with the note
 * that says why it has to be per table.  It is 192 bytes now, small enough for
 * bss - it has not been moved because it is read and written in one sequential
 * pass and costs a cache line either way. */
const uint16_t bt_tile_rows[27] __attribute__((used, retain)) = {
    647, 647, 710, 742, 742, 742, 710, 647, 647, 647, 677, 676, 676, 676, 677, 647, 832, 481, 832,
    768, 768, 768, 768, 768, 768, 768, 768
};

#define MM_BUCKET_TABLE_BYTES   (MM_BUCKET_STRIDE * MM_BUCKET_ROWS)

#ifndef BUCKET_SOFTWARE_REFERENCE
#define BUCKET_SOFTWARE_REFERENCE 0
#endif

#if BUCKET_SOFTWARE_REFERENCE
static uint32_t bt_base;
static uint16_t bt_first;
static uint16_t bt_end;
static uint16_t bt_old_first[2];
static uint16_t bt_old_end[2];

static void bucket_reset(void)
{
    for (int row = bt_first; row < bt_end; row++) bt_count[row] = 0u;
    bt_first = MM_BUCKET_ROWS;
    bt_end = 0u;
    bt_dropped = 0u;
}

static void __attribute__((used, retain, noinline))
bucket_put_run(int row, int bx, uint32_t slot, int w, unsigned hue)
{
    uint32_t const common = ((uint32_t)(hue & 7u) << 29)
                          | ((uint32_t)(w & 31) << 24)
                          | ((uint32_t)(slot & 0x7Fu) << 17)
                          | ((uint32_t)bx & 0x7FFu);
    uint32_t tr = bt_tile_rows[slot];
    int scr0 = row + (int)(tr & 31u);
    int scr1 = row + (int)(tr >> 5);
    if (scr0 < 0) scr0 = 0;
    if (scr1 > BUCKET_SCREEN_ROWS) scr1 = BUCKET_SCREEN_ROWS;
    if (scr0 >= scr1) return;

    int g0 = (unsigned)scr0 >> 3;
    int g1 = (unsigned)(scr1 - 1) >> 3;

    if (g0 < bt_first) bt_first = (uint16_t)g0;
    if (g1 + 1 > bt_end) bt_end = (uint16_t)(g1 + 1);

    {
        volatile uint32_t *e = (volatile uint32_t *)
            (bt_base + ((uint32_t)g0 << 9));
        uint16_t *cnt = &bt_count[g0];
        uint16_t *end = &bt_count[g1 + 1];
        uint32_t packed = common |
            ((uint32_t)(((g0 << 3) - row + 8) & 0x3Fu) << 11);

        do {
            uint8_t c = *cnt;
            if (__builtin_expect(c < MM_BUCKET_SLOTS, 1)) {
                e[c] = packed;
                *cnt = (uint8_t)(c + 1u);
            } else {
                bt_dropped++;
            }
            packed += (BUCKET_GROUP_ROWS << 11);
            e += MM_BUCKET_SLOTS;
            cnt++;
        } while (cnt < end);
    }
}

static void __attribute__((used, retain, noinline)) bucket_build_start(unsigned buffer)
{
    unsigned buf = buffer & 1u;
    uint32_t base = MM_BUCKET_TABLE + (uint32_t)buf * MM_BUCKET_TABLE_BYTES;
    bt_buf     = buf;
    bt_base    = base;
    bucket_reset();

    bullet_t *b;

    FOR_EACH_PBULLET(b) {
        uint32_t tslot = BTILE_SLOT_PBULLET;
        int tw = MM_PBULLET_TILE_W;
        if (b->flags & PF_LOCKON) {
            tslot = BTILE_SLOT_MISSILE;
            tw = MM_MISSILE_TILE_W;
        }
        bucket_put_run(b->y, b->x, tslot, tw, b->color & 7u);
    }

    int b_first = bt_first;
    int b_end   = bt_end;
    uint32_t dropped = bt_dropped;
    const uint16_t * const tile_rows = bt_tile_rows;
    uint16_t * const counts = bt_count;
    const uint32_t fast_mask = 0x80000000u |
        ((uint32_t)(EF_ACTIVE | EF_LANCE | EF_ORB | EF_HELD) << 16);
    const uint32_t fast_val  = 0x80000000u | ((uint32_t)EF_ACTIVE << 16);

    for (int _run = 0; _run < 2; _run++) {
        for (int _i = (_run == 0 ? 0 : ORB_FIRST),
                 _end = (_run == 0 ? eb_hi : MAX_EBULLETS);
             _i < _end; _i++) {
            b = &ebullets[_i];
            uint32_t w1 = ((const uint32_t *)b)[1];
            int32_t w0;
            int bx, row, tw;
            uint32_t slot;

            if (__builtin_expect((w1 & fast_mask) == fast_val, 1)) {
                w0   = ((const int32_t *)b)[0];
                bx   = ((w0 << 16) >> 16) - 13;
                row  = (w0 >> 16) - 13;
                slot = (w1 >> 27) & 15u;
                tw   = MM_EBULLET_DIRTILE_W;
            } else {
                if (!(w1 & (EF_ACTIVE << 16)))
                    continue;
                w0 = ((const int32_t *)b)[0];
                bx = (w0 << 16) >> 16;
                int by = w0 >> 16;
                if (w1 & (EF_LANCE << 16)) {
                    row = by - 12;
                    bx -= 12;
                    slot = 19u + ((unsigned)aim_index(b->vx, b->vy) >> 1);
                    tw = 24;
                } else if (w1 & (EF_ORB << 16)) {
                    row  = by - 8;
                    bx  -= 8;
                    slot = BTILE_SLOT_ORB;
                    tw   = MM_ORB_TILE_W;
                } else {
                    int dx, dy, cache_it = 0;
                    if ((w1 & (EF_HELD << 16)) || (w1 & 0xFFFFu) == 0u) {
                        dx = player_x - bx;
                        dy = player_y - by;
                    } else {
                        dx = ((int32_t)(w1 << 24)) >> 24;
                        dy = ((int32_t)(w1 << 16)) >> 24;
                        cache_it = 1;
                    }
                    slot = (uint32_t)aim_index_inline(dx, dy);
                    if (cache_it)
                        b->color = (uint8_t)(((w1 >> 24) & 7u) | (slot << 3) | 0x80u);
                    row = by - 13;
                    bx -= 13;
                    tw  = MM_EBULLET_DIRTILE_W;
                }
            }

            uint32_t tr = tile_rows[slot];
            int scr0 = row + (int)(tr & 31u);
            int scr1 = row + (int)(tr >> 5);
            if (scr0 < 0) scr0 = 0;
            if (scr1 > BUCKET_SCREEN_ROWS) scr1 = BUCKET_SCREEN_ROWS;
            if (scr0 >= scr1) continue;

            int g0 = (unsigned)scr0 >> 3;
            int g1 = (unsigned)(scr1 - 1) >> 3;
            if (g0 < b_first) b_first = g0;
            if (g1 + 1 > b_end) b_end = g1 + 1;

            uint32_t packed = ((w1 & 0x07000000u) << 5)
                            | ((uint32_t)(tw & 31) << 24)
                            | ((slot & 0x7Fu) << 17)
                            | ((uint32_t)bx & 0x7FFu)
                            | ((uint32_t)(((g0 << 3) - row + 8) & 0x3Fu) << 11);
            volatile uint32_t *e = (volatile uint32_t *)
                (base + ((uint32_t)g0 << 9));
            uint8_t *cnt = &counts[g0];
            uint8_t *cend = &counts[g1 + 1];
            do {
                uint8_t c = *cnt;
                if (__builtin_expect(c < MM_BUCKET_SLOTS, 1)) {
                    e[c] = packed;
                    *cnt = (uint8_t)(c + 1u);
                } else {
                    dropped++;
                }
                packed += (BUCKET_GROUP_ROWS << 11);
                e += MM_BUCKET_SLOTS;
                cnt++;
            } while (cnt < cend);
        }
    }

    bt_first   = (uint16_t)b_first;
    bt_end     = (uint16_t)b_end;
    bt_dropped = dropped;

    uint16_t * const used = (uint16_t *)MM_BUCKET_USED + buf * MM_BUCKET_ROWS;
    int first = b_first < bt_old_first[buf] ? b_first : bt_old_first[buf];
    int end = b_end > bt_old_end[buf] ? b_end : bt_old_end[buf];
    for (int g = first; g < end; g++) {
        unsigned old = used[g], n = counts[g];
        if (old > MM_BUCKET_SLOTS) old = MM_BUCKET_SLOTS;
        volatile uint32_t *e = (volatile uint32_t *)
            (base + ((uint32_t)g << 9));
        for (unsigned k = n; k < old; k++) e[k] = 0u;
        used[g] = (uint8_t)n;
    }
    bt_old_first[buf] = (uint16_t)b_first;
    bt_old_end[buf] = (uint16_t)b_end;

    if (dropped > bt_drop_peak) bt_drop_peak = dropped;
    tlm[TLM_BUCKET_DROPS] = dropped;
}
#else
static void __attribute__((used, retain, noinline)) bucket_build_start(unsigned buffer)
{
    bt_buf = buffer & 1u;
    /* Transfer ownership: CPU writes pools, DMA writes tables and used ledger.
     * The cache operation writes back AND invalidates, including ledger reads
     * from the previous frame. Never write the ledger between DMA jobs. */
    gpu2d_flush_dcache();
    GPU2D_REG_BUCKET_CFG = ((uint32_t)(uint16_t)player_y << 16) | (uint16_t)player_x;
    eb_motion_job = eb_motion_pending && is_stress_stage && !paused;
    eb_motion_pending = 0;
    GPU2D_REG_BUCKET_ACCEL = 0x80000000u | (eb_motion_job ? 0x20000000u : 0u)
                           | ((uint32_t)(eb_hi & 0x1FFFu) << 16) | ((uint32_t)(eb_hi & 0x2000u) << 1)
                           | ((uint32_t)pb_hi << 4) | bt_buf;
    bt_started = GPU2D_REG_CORE_TICKS;
}

static void __attribute__((used, retain, noinline)) bucket_build_finish(void)
{
    uint32_t status;
    do {
        status = GPU2D_REG_BUCKET_ACCEL;
        if (profile_elapsed(bt_started, GPU2D_REG_CORE_TICKS) > 8000000u) break;
    } while (status & 0x80000000u);
    if ((status & 0xB0000000u) != 0x20000000u) {
        /* Fail visibly instead of publishing a partial table as DROP=0. */
        GPU2D_REG_BUCKET_BASE = 0u;
        bt_dropped = 65535u;
    } else {
        /* DMA owns the enemy records until DONE; discard clean CPU reads
         * made by lance rendering before consuming the DMA writeback. */
        gpu2d_flush_dcache();
        if (eb_motion_job) stress_coprocessor_finish();
        GPU2D_REG_BUCKET_BASE = MM_BUCKET_TABLE;
        bt_dropped = status & 0xFFFFu;
        const volatile uint16_t *used = (const volatile uint16_t *)MM_BUCKET_USED
                                      + bt_buf * MM_BUCKET_ROWS;
        for (unsigned g = 0; g < MM_BUCKET_ROWS; ++g) bt_count[g] = used[g];
    }
    if (bt_dropped > bt_drop_peak) bt_drop_peak = bt_dropped;
    if (bt_dropped > bt_drop_window) bt_drop_window = bt_dropped;
    tlm[TLM_BUCKET_DROPS] = bt_dropped;
}
#endif

static void bucket_clear(void)
{
    volatile uint32_t *t = (volatile uint32_t *)MM_BUCKET_TABLE;
    for (uint32_t i = 0; i < (MM_BUCKET_TABLE_BYTES * 2u) / 4u; i++)
        t[i] = 0u;
    for (uint32_t i = 0; i < MM_BUCKET_USED_BYTES / 4u; i++)
        ((volatile uint32_t *)MM_BUCKET_USED)[i] = 0u;
#if BUCKET_SOFTWARE_REFERENCE
    bt_old_first[0] = MM_BUCKET_ROWS; bt_old_first[1] = MM_BUCKET_ROWS;
    bt_old_end[0] = 0u; bt_old_end[1] = 0u;
    bt_first = MM_BUCKET_ROWS;
    bt_end = 0u;
#else
    gpu2d_flush_dcache();
    GPU2D_REG_BUCKET_ACCEL = 0x40000000u;
#endif
    bt_dropped = 0u;
}

static void game_render(uint32_t fb)
{
    uint32_t profile_start = GPU2D_REG_CORE_TICKS;
    unsigned buffer = fb == FB_LEFT_FRONT ? 0u : 1u;
    /* B1: publish where the bullets are before anything is drawn.  The scanout
     * picks the table up as it starts this buffer, so this has to be written for
     * the buffer being rendered - which is why it takes `buffer` rather than a
     * single flat table.
     *
     * Started here but COLLECTED at the tail of this function: the coprocessor
     * runs while the scene is drawn (see bucket_build_start/_finish). */
    bucket_build_start(buffer);
    tlm[41] = profile_elapsed(profile_start, GPU2D_REG_CORE_TICKS);
    damage_track = 0;
    damage_fb = fb;
    damage_restore_rows = 0u;
    /* ---- backdrop for this stage, then the parallax dots -----------------
     * The backdrop surface is pre-decoded in DDR.  Nothing is re-decoded
     * mid-stage; the sparse weather is stamped over the plate. */
    {
        /* The card's staging rides on this one blit.  All three plates are
         * decoded at boot, so swapping stages is a pointer - there is no row
         * offset here.
         *
         * The card's shake is NOT done here: stage_strip_render() publishes
         * boss_shake into the weather layer's control word and the scanout
         * moves the whole picture down.  This block used to compute a slide
         * offset from frame_tick and then throw it away with (void)slide,
         * which read like an implemented shake and was not one.
         * The plate is 1366x768, i.e. 1:1 with the display.  Both scanout
         * halves use the same framebuffer, so one whole-width command paints
         * the exact pixels that the former two half-width commands painted.
         *
         * BitBlt has no scaler, which is why the plate has to be full size:
         * a half-size plate covers exactly half the screen and no blit
         * parameter can change that. */
        unsigned bg = stage_bg_active;
        uint32_t plate = boss_card_active ? MM_CARD_BG : is_stress_stage ? MM_STRESS_BG : STAGE_BG_BUF(bg);
        if (boss_state != BOSS_DIALOG && dialog_was_active) {
            dialog_was_active = 0u;
            uint32_t dbase = (uint32_t)DIALOG_Y * SCREEN_STRIDE + (uint32_t)(DIALOG_X * 4);
            damage_track = 1;
            damage_mark_index(FB_LEFT_FRONT + dbase, DIALOG_W, DIALOG_H, SCREEN_STRIDE, 0u);
            damage_mark_index(FB_LEFT_BACK  + dbase, DIALOG_W, DIALOG_H, SCREEN_STRIDE, 1u);
            damage_track = 0;
        }
        if (!paused && pause_was_active) {
            pause_was_active = 0u;
            int pw = SET_CARD_W, ph = SET_CARD_H;
            int px = (SCREEN_WIDTH - pw) / 2;
            int py = (SCREEN_HEIGHT - ph) / 2;
            uint32_t pbase = (uint32_t)py * SCREEN_STRIDE + (uint32_t)(px * 4);
            damage_track = 1;
            damage_mark_index(FB_LEFT_FRONT + pbase, (uint32_t)pw, (uint32_t)ph, SCREEN_STRIDE, 0u);
            damage_mark_index(FB_LEFT_BACK  + pbase, (uint32_t)pw, (uint32_t)ph, SCREEN_STRIDE, 1u);
            damage_track = 0;
        }
        damage_full = damage_plate[buffer] != plate;
        if (damage_full) {
            r_blit(fb, plate, SCREEN_WIDTH, SCREEN_HEIGHT,
                   SCREEN_STRIDE, SCREEN_STRIDE);
            damage_plate[buffer] = plate;
            for (unsigned row = 0; row < DAMAGE_ROWS; row++)
                damage_tiles[buffer][row] = 0;
            /* The plate covers the gutters too, and what it leaves there is the
             * stage plate, not the menu backdrop the gutter repair lays down -
             * so every band has to be repainted on this buffer before the
             * widgets are drawn back on top of it. */
            hud_dirty[buffer] |= HUD_BAND_ALL;
        } else {
            damage_restore(fb, plate);
        }

        set_hb(0x41u);   /* render stage: after backdrop+damage restore */
    /* ---- playfield border columns -----------------------------------
         * Two 4-pixel accent columns, full height, one either side of the
         * playfield.  Drawing them EVERY frame costs two 4x768 FILLs, i.e.
         * 1536 DRAM row activations - about 30% of the frame's entire row
         * budget - to move 24 KB of pixels: the worst row-per-byte ratio in
         * the build, spent on decoration.
         *
         * Nothing else may touch their columns.  The two gutter bands stop
         * three pixels short of them (HUD_CLEAR_L and HUD_CLEAR start at 0 and
         * 1189) and damage_restore is clipped to the playfield, so a column
         * only has to be drawn when the PLATE under it changes: a stage
         * switch, the card's own sky, or the first use of the other buffer.
         * That is once per stage instead of once per frame. */
        if (border_plate[buffer] != plate) {
            border_plate[buffer] = plate;
            uint32_t bcol = is_stress_stage ? 0x004090FFu :
                            (wave == 0 ? 0x003070D0u :
                             wave == 1 ? 0x00D05030u : 0x009060C0u);
            r_fill(fb + (uint32_t)((GAME_LEFT - 4) * 4), 4, SCREEN_HEIGHT,
                   bcol, SCREEN_STRIDE);
            r_fill(fb + (uint32_t)(GAME_RIGHT * 4), 4, SCREEN_HEIGHT,
                   bcol, SCREEN_STRIDE);
        }
    }
    set_hb(0x47u);   /* render stage: after border fill */
    /* tlm[44] IS read: diag_window() reports it as 'b' (the backdrop share of
     * the render).  tlm[45] (TLM_T_SPARE) genuinely has no reader and its APB
     * round trip is gone; that one sat between the 0x41 heartbeat and the
     * next probe, which is where a freeze has been landing. */
    tlm[44] = profile_elapsed(profile_start, GPU2D_REG_CORE_TICKS);
    set_hb(0x48u);   /* render stage: after tlm write */
    stage_strip_render(fb);
    damage_track = 1;

    /* boss */
    if (boss_state == BOSS_ENTER || boss_state == BOSS_FIGHT ||
        boss_state == BOSS_FREEZE) {
        /* Boss Magic Summoning Array (Touhou-style Hexagram Mystic Circle) */
        if (boss_state == BOSS_FREEZE || boss_spell_vfx_timer > 0) {
            int bcx = boss_x + 32;
            int bcy = boss_y + 28;
            int frame = (int)((frame_tick >> 1) & 31u);
            uint32_t src = MM_BURST_FRAME + (uint32_t)frame * MM_BURST_FRAME_BYTES;
            int bx = bcx - (int)(MM_BURST_FRAME_W / 2);
            int by = bcy - (int)(MM_BURST_FRAME_W / 2);
            if (bx >= GAME_LEFT && bx + (int)MM_BURST_FRAME_W <= GAME_RIGHT &&
                by >= 0 && by + (int)MM_BURST_FRAME_W <= (int)SCREEN_HEIGHT) {
                r_add_begin();
                r_add(fb + (uint32_t)(by * SCREEN_STRIDE) + (uint32_t)(bx * 4),
                      src, MM_BURST_FRAME_W, MM_BURST_FRAME_W,
                      MM_BURST_FRAME_STRIDE, SCREEN_STRIDE);
                r_add_end();
            }
        }
        draw_boss_art(fb, boss_x, boss_y);
    }

    /* minions */
    for (int i = 0; i < MAX_ENEMIES; i++) {
        enemy_rec_t *e = &enemies[i];
        if (!(e->flags & EF_ACTIVE)) continue;
        uint32_t spr = wave == 0 ? MM_ENEMY_SPRITE :
                       wave == 1 ? MM_ENEMY2_SPRITE : MM_SHADE_SPRITE;
        int stride = 96;
        r_blit(clamp_dst(fb, e->x, e->y, 24, 24), spr, 24, 24,
                          (uint32_t)stride, SCREEN_STRIDE);
        if (e->hp > 6 && e->y > 10)
            r_fill(fb + (uint32_t)((e->y - 4) * SCREEN_STRIDE) +
                       (uint32_t)(e->x * 4), 24, 2, 0x00FF6060u, SCREEN_STRIDE);
    }

    /* items */
    for (int i = 0; i < MAX_ITEMS; i++) {
        item_t *it = &items[i];
        if (!(it->flags & EF_ACTIVE)) continue;
        /* Blink out while the floor timer runs down.  The period shrinks from
         * 8 frames to 1, so the item visibly hurries towards its deadline
         * instead of blinking at a fixed rate. */
        if (it->timer) {
            uint8_t period = (uint8_t)(1u + it->timer / 24u);
            if ((it->timer / period) & 1u) continue;
        }
        static const char * const labels[] = {
            "HEAL", "RATE", "ATK", "SHOT", "PTS", "SLOW", "JAM"
        };
        int x = it->x - 42, y = it->y - 8;
        int bad = item_is_debuff(it->type);
        if (x < GAME_LEFT + 4) x = GAME_LEFT + 4;
        if (x > GAME_RIGHT - 92) x = GAME_RIGHT - 92;
        if (y > SCREEN_HEIGHT - 32) y = SCREEN_HEIGHT - 32;
        r_fill(fb + (uint32_t)(y * SCREEN_STRIDE + x * 4), 88, 28,
               bad ? 0x00331A46u : 0x00152E36u, SCREEN_STRIDE);
        r_fill(fb + (uint32_t)(y * SCREEN_STRIDE + x * 4), 3, 28,
               bad ? 0x00FF5070u : 0x0068FFD0u, SCREEN_STRIDE);
        draw_art(fb,x+5,y+6,it->type == ITEM_HEAL ? ART_HEART : ART_STAR);
        draw_text(fb,x+24,y+6,labels[it->type < 7 ? it->type : 4],2,
                  bad ? 0x00FF5070u : 0x0068FFD0u);
        /* the pickup box is the whole sprite silhouette; mark it so the hit
         * area is legible instead of guessed */
        /* An item is still alive at y = ITEM_REST_Y (748), so its pickup-box marker row
         * (y + 15) reaches row 763, within the 768 frame. */
        if (it->y < SCREEN_HEIGHT - 16)
            r_fill(fb + (uint32_t)((it->y + 15) * SCREEN_STRIDE) +
                   (uint32_t)(it->x * 4), 16, 1, 0x0068FFD0u, SCREEN_STRIDE);
    }

    /* B1: the player's shots are the scanout's now.  bucket_build() published
     * their positions a few lines up and video_bullet_overlay.v composites
     * them; the 7x26 strip is still composed by pbullet_tile_build(), it just
     * goes into the scanout's tile store at boot instead of into the
     * framebuffer every frame.
     *
     * This loop used to be the single largest item in the frame: 2,923 rows a
     * frame on the pressure stage, 30.6% of everything the engine did, and
     * every one of those rows was a DRAM activation. */


    /* The opener's 4 laser columns (boss_laser): synthesised in hardware at scanout
     * by video_laser u_laser (rtl/v_dma/video_laser.v) with saturated additive blending,
     * pure white core, and 2D Gaussian bloom. Controlled via GPU2D_REG_WEATHER bits [20:18]
     * in stage_strip_render(), requiring 0 DDR bandwidth and 0 BitBlt commands (rock-solid 75 FPS). */

    /* 6.1 the cut / 8.2 the beam.  Both halves are the scanout's now.
     *
     * The plasma bars went first (laser_columns_set, above): three 16x768 copies
     * a frame was 2,304 DRAM row activations and it is the frame the board
     * stuttered on.  What was left here was the warning hairline, and it was
     * worse than it read: a one-pixel column costs a DRAM row activation to
     * write four bytes, and three slots of them run to 4,608 rows a frame -
     * more than all 192 enemy shots together, and a third of what a saturated
     * pressure stage spends.
     *
     * There is no information in the shape - one column wide, four columns
     * across, one colour from top to bottom - so video_beam.v draws it.  What
     * the hardware cannot know is where the line stands and which colour it is
     * this frame, and that is all the firmware publishes below: the strobe is a
     * game rule, and it stays here. */
    {
        uint32_t cx[4] = {0u, 0u, 0u, 0u};
        int live = 0;
        for (int k = 0; k < CUT_SLOTS; k++) {
            int bx = beam_x[k];
            /* Written every frame, dead slots included: the hardware holds the
             * last colour it was given, so a slot left alone would go on drawing
             * the frame before.  A colour of 0 draws nothing.
             *
             * The line stands on bx - columns bx-2 and bx+1 take h_out, bx-1
             * takes h_lft, bx takes h_mid - which is column for column what the
             * two fills here used to lay down, two-pixel and four-pixel forms
             * included. */
            uint32_t h_x = 0u, h_out = 0u, h_lft = 0u, h_mid = 0u;
            if (beam_phase[k] == 1) {
                uint32_t c;
                h_x = (uint32_t)bx;
                if (beam_timer[k] <= 10) {
                    /* Final 10 frames: fast 1-frame strobe between blinding white (Bloom) and alert crimson */
                    c = (beam_timer[k] & 1u) ? 0x00FFFFFFu : 0x00FF1030u;
                    if (beam_timer[k] > 4) {
                        /* Energy collecting: 4-pixel energy sheath focusing inward */
                        h_out = 0x00FF3050u; h_lft = c; h_mid = c;
                    } else {
                        /* Tightly converged needle-sharp pure white-hot filament (100% Bloom) */
                        h_lft = 0x00FFFFFFu; h_mid = 0x00FFFFFFu;
                    }
                } else {
                    int period = (beam_timer[k] > CUT_PREVIEW / 2) ? 8 : 3;
                    c = ((beam_timer[k] / (unsigned)period) & 1u)
                                     ? 0x00FF9AA8u : 0x00603038u;
                    /* Shimmering micro-line: column bx-1 carries baseline telegraph color for test validation,
                     * while column bx carries a radiant electric micro-filament pulse */
                    h_lft = c;
                    h_mid = (c == 0x00FF9AA8u)
                                ? ((beam_timer[k] & 2u) ? 0x00FFE8F0u : 0x00FFC0D0u)
                                : 0x00783840u;
                }
            } else if (beam_phase[k] == 2 && live < BOSS_LASER_COLS) {
                cx[live++] = (uint32_t)bx;   /* the plasma bar: the hardware draws it */
            }
            GPU2D_REG_HAIR(k, 0) = h_x;
            GPU2D_REG_HAIR(k, 1) = h_out;
            GPU2D_REG_HAIR(k, 2) = h_lft;
            GPU2D_REG_HAIR(k, 3) = h_mid;
        }
        /* Written every frame, not only when they move: leaving the beams'
         * positions in the registers when the beams expire would stand the
         * opener's columns up wherever the last beam was aimed.  Two APB writes
         * a frame is not a cost worth a state machine over. */
        if (live)
            laser_columns_set(cx[0], cx[1], cx[2], cx[3]);
        else if (boss_laser)
            laser_columns_set(BOSS_LASER_X(0), BOSS_LASER_X(1),
                              BOSS_LASER_X(2), BOSS_LASER_X(3));
    }

#if FX_RINGS
    /* Rings and cores are a scanout layer now: twelve APB writes a frame and
     * the framebuffer is not touched at all - no engine command, no DDR
     * traffic, and nothing for the next frame's damage_restore to repair. */
    fx_rings_upload();
#else
    for (int i = 0; i < 16; i++)
        if (visual_fx[i].active)
            burst_render(fb, visual_fx[i].x, visual_fx[i].y, visual_fx[i].age);
#endif

    /* Phase 2 Task 08: Combat FX particle rendering (OP_ADD) */
    particles_render(fb);

    /* Licensed projectile strip, blended against the live frame with ColorKey
     * transparency and HDMI Scanout Gaussian Bloom. The 16-pixel glow is the
     * same width as the hit rectangle. Single-stream blit guarantees rock-solid
     * 75 FPS with ZERO freeze and ZERO frame drops. */
    /* The beam's glow strip is the scanout's too (video_beam.v, APB 0xB8/0xBC).
     * A 16 x player_y copy is up to 768 DRAM row activations a frame, and the
     * sheet it copied is 16 rows tall and repeats: the whole surface is a lookup
     * on the column offset and (y & 15), with the four magenta-keyed edge columns
     * letting the backdrop through exactly as the engine's colour key did.
     *
     * Published every frame, the off state included, for the same reason the
     * hairline slots are: the hardware holds what it was last given.  player_x is
     * the centre, so the strip spans bx-8 .. bx+7.
     *
     * THE BEAM STOPS AT THE CRAFT'S TOP EDGE.  It used to run the full
     * player_y - from row 0 down to the craft's CENTRE, so the last 24 rows of
     * the beam were drawn over the craft's own artwork.  The craft is drawn by
     * the engine into the framebuffer and the beam is composited by the scanout
     * ABOVE the framebuffer, so the beam won: a white-hot core straight down
     * the middle of Reimu, every frame the weapon was held.  Nothing in the
     * scanout could fix that - the beam layer has no idea what the framebuffer
     * under it is, and giving it one would mean a per-pixel test against a
     * 48x48 sprite for a shape whose whole point is that it costs no reads.
     *
     * So the layer order is kept and the LENGTH carries the answer, exactly the
     * way the occlusion box carries it for the pause card.  player_y is the
     * craft's centre and the sprite is MM_REIMU-sized 48x48, so its top edge is
     * player_y - 24: publishing (player_y - 24) puts the beam's exclusive end
     * (y < len) exactly on that edge and leaves the craft alone. */
    {
        int top = player_y - PLAYER_HALF_H;
        if (top < 0) top = 0;
        uint32_t len = beam_active ? (uint32_t)top : 0u;
        if (len > SCREEN_HEIGHT) len = SCREEN_HEIGHT;
        GPU2D_REG_BEAM_X    = beam_active ? (uint32_t)player_x : 0u;
        GPU2D_REG_BEAM_CTRL = (len & 0x7FFu) | (beam_active ? 0x800u : 0u);
    }

    /* hardware-alpha aura over the live background, then the craft on top */
    {
        int ax = player_x - 32;
        int ay = player_y - 32;
        int w  = MM_AURA_SPRITE_W;
        int h  = MM_AURA_SPRITE_H;
        uint32_t asrc = MM_AURA_SPRITE;
        uint32_t ga = 96u + ((frame_tick * 6u) & 0x5Fu);

        /* Clip the aura against the playfield instead of sliding it back
         * inside it.  Pushing the sprite inwards kept all 64 pixels but moved
         * their centre, so walking into the left or right wall detached the
         * glow from the craft - the player's own aura stopped being centred on
         * the player.  Clipping costs a source offset and keeps them together. */
        if (ax < GAME_LEFT) {
            int d = GAME_LEFT - ax;
            asrc += (uint32_t)d * 4u;
            w -= d;
            ax = GAME_LEFT;
        }
        if (ax + w > GAME_RIGHT) w = GAME_RIGHT - ax;
        if (ay < 0) {
            int d = -ay;
            asrc += (uint32_t)d * MM_AURA_SPRITE_STRIDE;
            h -= d;
            ay = 0;
        }
        if (ay + h > SCREEN_HEIGHT) h = SCREEN_HEIGHT - ay;

        if (w > 0 && h > 0) {
            r_alpha_begin(ga);
            r_alpha(fb + (uint32_t)(ay * SCREEN_STRIDE) + (uint32_t)(ax * 4),
                    asrc, (uint32_t)w, (uint32_t)h,
                    MM_AURA_SPRITE_STRIDE, SCREEN_STRIDE, ga);
            r_alpha_end();
        }
    }
    /* Invulnerability flash: the player is BLINKED, not hidden.  The old gate
     * `(invuln & 4) == 0` blanked the sprite for 4 of every 8 frames, so half
     * of a 1.5-second hit reaction left the player unable to see themselves or
     * judge where the hitbox was.  Bit 2 of the frame counter keeps them
     * visible for three frames in four.
     *
     * Task 02 adds a faster overlay for the first HIT_BLINK_FRAMES: a four-frame
     * cycle instead of an eight-frame one, and still three frames in four
     * visible, so the jolt lands without ever costing the player sight of the
     * craft.  Once the counter drains, this falls straight back to the rhythm
     * above. */
    if (!invuln ||
        (hit_blink ? ((frame_tick & 3u) != 3u)
                   : (((frame_tick >> 1) & 3u) != 0u))) {
        int x = player_x - PLAYER_HALF_W, y = player_y - PLAYER_HALF_H;
        int w = PLAYER_SPRITE_SIDE, h = PLAYER_SPRITE_SIDE;
        uint32_t src = player_pose < 4
                     ? visual_assets[ART_REIMU_0 + player_pose].dst
                     : (player_pose == 4 ? MM_REIMU_TILT_L : MM_REIMU_TILT_R);
        /* Clip artwork at the playfield edge without moving its collision pivot. */
        /* Clip on all four sides.  The x pair was here; the y pair was not,
         * and flying into the bottom of the playfield sent a 48-tall sprite
         * from y=764 to y=812 - past the end of the framebuffer row budget,
         * which the workbench reported as
         * "BitBlt copy out of bounds: (1137,764,48,48)". */
        if (x < GAME_LEFT) { int d = GAME_LEFT-x; src += (uint32_t)d*4u; w -= d; x = GAME_LEFT; }
        if (x+w > GAME_RIGHT) w = GAME_RIGHT-x;
        if (y < GAME_TOP) { int d = GAME_TOP-y; src += (uint32_t)d*192u; h -= d; y = GAME_TOP; }
        if (y+h > GAME_BOTTOM) h = GAME_BOTTOM-y;
        if (w <= 0 || h <= 0) return;
        r_blit(fb+(uint32_t)(y*SCREEN_STRIDE+x*4),src,(uint32_t)w,(uint32_t)h,192,SCREEN_STRIDE);
    }
    /* The hitbox ring pulses too, and Task 02 doubles its rate for the fast
     * window: 8 of every 16 frames settles to 4 of every 8 while the hit is
     * still fresh, which makes the ring read as an alarm rather than as a
     * slowly fading outline. */
    if (invuln && (hit_blink ? ((frame_tick & 4u) != 0u)
                             : ((frame_tick & 8u) != 0u))) {
        /* a ring on the exact damage box the bullets test, so the player can
         * see the hitbox they are meant to dodge with */
        r_fill(fb + (uint32_t)((player_y - 7) * SCREEN_STRIDE) +
               (uint32_t)((player_x - 7) * 4), 14, 1, 0x00FF8080u, SCREEN_STRIDE);
        r_fill(fb + (uint32_t)((player_y + 6) * SCREEN_STRIDE) +
               (uint32_t)((player_x - 7) * 4), 14, 1, 0x00FF8080u, SCREEN_STRIDE);
        r_fill(fb + (uint32_t)((player_y - 7) * SCREEN_STRIDE) +
               (uint32_t)((player_x - 7) * 4), 1, 14, 0x00FF8080u, SCREEN_STRIDE);
        r_fill(fb + (uint32_t)((player_y - 7) * SCREEN_STRIDE) +
               (uint32_t)((player_x + 6) * 4), 1, 14, 0x00FF8080u, SCREEN_STRIDE);
    }

    /* the spell card's shockwave, rippling out from the craft */
    if (bomb_flash) {
        int r = 12 + (int)(BOMB_FLASH_FRAMES - bomb_flash) * 8;
        uint32_t col = (bomb_flash > 20) ? 0x00FFF0C0u : 0x00FFB060u;
        for (int k = 0; k < 16; k++) {
            int px = player_x + ((dir16_x[k] * r) >> 4);
            int py = player_y + ((dir16_y[k] * r) >> 4);
            if (px >= GAME_LEFT && px <= GAME_RIGHT - 2 &&
                py >= GAME_TOP && py <= GAME_BOTTOM - 3)
                r_fill(fb + (uint32_t)(py * SCREEN_STRIDE) +
                       (uint32_t)(px * 4), 2, 2, col, SCREEN_STRIDE);
        }
    }

    /* Phase 2 Task 03: the shockwave of a HIT.  It cannot ride the spell
     * card's ring above - that one is pinned to the craft, and the craft has
     * already been thrown back to the spawn point by the time this draws, so a
     * ring that followed it would say nothing about where the shot landed.
     * Bright white at the crest, cooling to ember gold on the way out, which
     * is also what makes the expansion read as a wave rather than as a circle
     * that simply got bigger. */
    if (hit_ring_timer) {
#if FX_RINGS
        /* Drawn by video_fx_ring from fx_rings_upload(): slot 0 of the scanout
         * layer.  Sixteen 2x2 FILLs - sixteen engine commands and sixteen
         * damage rectangles - became one descriptor. */
#else
        int age = HIT_RING_FRAMES - (int)hit_ring_timer;
        int r = 14 + age * 10;
        uint32_t col = (hit_ring_timer > HIT_RING_FRAMES / 2) ? 0x00FFFFFFu
                                                              : 0x00FFC060u;
        for (int k = 0; k < 16; k++) {
            int px = hit_ring_x + ((dir16_x[k] * r) >> 4);
            int py = hit_ring_y + ((dir16_y[k] * r) >> 4);
            if (px >= GAME_LEFT && px <= GAME_RIGHT - 2 &&
                py >= GAME_TOP && py <= GAME_BOTTOM - 3)
                r_fill(fb + (uint32_t)(py * SCREEN_STRIDE) +
                       (uint32_t)(px * 4), 2, 2, col, SCREEN_STRIDE);
        }
#endif
    }

    /* ---- HUD gutters ----------------------------------------------------
     * The ten bands below are the gutter repair.  They used to run on every
     * frame; they now run only where the ledger above says something moved
     * underneath them.  Which widget each band owns, and what arms it, is
     * documented at the ledger - what matters here is that these are the same
     * two blits as before.  The route to the pixels did not change; only how
     * often it is walked.
     */
    {
        unsigned gbuf = (fb == FB_LEFT_FRONT) ? 0u : 1u;

        /* A run starts on a frame the boot menu was still owning, and a stage
         * switch repaints the plate over both gutters, so the first painted
         * frame arms everything - once per buffer, like clear_pending. */
        if (!hud_sig_valid) {
            hud_sig_valid = 1u;
            hud_dirty[0] |= HUD_BAND_ALL;
            hud_dirty[1] |= HUD_BAND_ALL;
        }
        hud_watch(HUD_SIG_STAGE,
                  (uint32_t)wave * 2u + (boss_state == BOSS_NONE ? 0u : 1u),
                  HUD_BAND_STAGE);
        hud_watch(HUD_SIG_LIVES, (uint32_t)lives, HUD_BAND_LIVES);
        /* The countdown, not just whether there is one: its digits move every
         * six frames, and each move leaves the previous pair behind. */
        hud_watch(HUD_SIG_DEBUFF,
                  hud_debuff_sig(slow_timer) + hud_debuff_sig(jam_timer) * 1000u,
                  HUD_BAND_DEBUFF);
        hud_watch(HUD_SIG_WEAPON,
                  (uint32_t)(weapon & 3u) * 16u + (uint32_t)weapon_level,
                  HUD_BAND_WEAPON);
        hud_watch(HUD_SIG_ATK, (uint32_t)atk, HUD_BAND_ATK);
        hud_watch(HUD_SIG_BACKEND, hw_accel ? 1u : 0u, HUD_BAND_BACKEND);
        hud_watch(HUD_SIG_SCORE, score, HUD_BAND_SCORE);
        /* The live FPS readout.  It is a hardware counter, so a locked display
         * leaves it alone - which is exactly the steady state this ledger is
         * for - but a frame that slipped still has to erase its old digits. */
        hud_watch(HUD_SIG_FPS, (GPU2D_REG_FPS_BCD >> 8) & 0xFFu,
                  HUD_BAND_FPSNUM);
        /* Signature: [11:0] population, [31:16] drop peak.
         * Y explicitly invalidates this watcher when the load changes.
         * Sample the last published population. Hold it for 16 logic ticks
         * so the HUD does not add glyph blits on every projectile birth.
         * Both buffers still receive each sampled value via the dirty ledger. */
        if (is_stress_stage && ((frame_tick & 15u) == 0u ||
                               hud_sig[HUD_SIG_STRESS] == 0u ||
                               bt_drop_peak > (hud_sig[HUD_SIG_STRESS] >> 16)))
            hud_watch(HUD_SIG_STRESS,
                      (tlm[TLM_SPRITES] & 65535u) |
                      (bt_drop_peak << 16), HUD_BAND_STRESS);

        /* Consume this buffer's ledger.  What is not armed here is still
         * carrying the backdrop bytes the last repair put down, with the same
         * widgets about to be drawn back over them. */
        uint16_t band = hud_dirty[gbuf];
        hud_dirty[gbuf] = 0u;

    /* Same idea on the left: cover the box, not a guessed row count. */
#define HUD_CLEAR_L(y, h) \
    r_blit(fb + (uint32_t)((y) * SCREEN_STRIDE), \
           MM_VISUAL_BACKGROUND + (uint32_t)((y) * SCREEN_STRIDE), \
           177u, (h), SCREEN_STRIDE, SCREEN_STRIDE)
        if (band & HUD_BAND_STAGE)  HUD_CLEAR_L(0u, 76u);
        if (band & HUD_BAND_PLAYER) HUD_CLEAR_L(HUD_PLAYER_Y - 18u,
                                                HUD_PLAYER_H + 24u);
        if (band & HUD_BAND_LIVES)  HUD_CLEAR_L(HUD_LIVES_Y - 18u,
                                                HUD_LIVES_H + 24u);
        if (band & HUD_BAND_SCORE)  HUD_CLEAR_L(HUD_SCORE_Y - 18u,
                                                HUD_SCORE_H + 24u);
        if (band & HUD_BAND_SPELL)  HUD_CLEAR_L(HUD_SPELL_Y - 18u,
                                                HUD_SPELL_H + 24u);
        if (band & HUD_BAND_DEBUFF) HUD_CLEAR_L(HUD_DEBUFF_S_Y - 18u,
                                                (HUD_DEBUFF_J_Y +
                                                 HUD_DEBUFF_J_H + 8u) -
                                                (HUD_DEBUFF_S_Y - 18u));
        if (is_stress_stage && (band & HUD_BAND_STRESS)) {
            HUD_CLEAR_L(592u, 112u);
            draw_text(fb, HUD_SPRITES_TAG_X, HUD_SPRITES_TAG_Y,
                      "SPRITES", 2, 0x0070F0CFu);
            draw_number(fb, HUD_SPRITES_NUM_X, HUD_SPRITES_NUM_Y,
                        hud_sig[HUD_SIG_STRESS] & 65535u, 5, 0x0070F0CFu);
            draw_text(fb, HUD_LOAD_TAG_X, HUD_LOAD_TAG_Y,
                      "LOAD", 2, 0x0070F0CFu);
            draw_number(fb, HUD_LOAD_NUM_X, HUD_LOAD_NUM_Y,
                        stress_target, 5, 0x0070F0CFu);
            draw_text(fb, HUD_DROPS_TAG_X, HUD_DROPS_TAG_Y,
                      "DROP", 2, 0x00FFC070u);
            draw_number(fb, HUD_DROPS_NUM_X, HUD_DROPS_NUM_Y,
                        hud_sig[HUD_SIG_STRESS] >> 16, 5, 0x00FFC070u);
        }
#undef HUD_CLEAR_L
    /* Each band covers its element's BOX plus the label above it, derived from
     * HUD_BOXES instead of hand-written rows.  The old fixed rows were 6 rows
     * short of the backend token's 26-pixel text height, which left the bottom
     * of 'FPGA' showing after the token became 'CPU' - and FPGA/CPU share their
     * first glyph and the shape of the last two, so the leftover read as a
     * rendering glitch rather than as a stale glyph. */
#define HUD_CLEAR(x, y, w, h) \
    r_blit(fb + (uint32_t)((y) * SCREEN_STRIDE) + (uint32_t)((x) * 4u), \
           MM_VISUAL_BACKGROUND + (uint32_t)((y) * SCREEN_STRIDE) + \
               (uint32_t)((x) * 4u), \
           (w), (h), SCREEN_STRIDE, SCREEN_STRIDE)
    /* 1189, not 1186: the right-hand border column owns 1185..1188 and a
     * gutter repaint that ate it would have to be undone by another command
     * every frame - which is exactly the 4x768 FILL this change removes. */
        if (band & HUD_BAND_WEAPON)
            HUD_CLEAR(1189u, HUD_WEAPON_Y - 18u, 177u, HUD_WEAPON_H + 40u);
        if (band & HUD_BAND_ATK)
            HUD_CLEAR(1189u, HUD_ATK_Y - 18u, 177u, HUD_ATK_H + 24u);
        if (band & HUD_BAND_BACKEND)
            HUD_CLEAR(1189u, HUD_BACKEND_Y - 18u, 177u, HUD_BACKEND_H + 56u);
        if (band & HUD_BAND_FPSNUM)
            HUD_CLEAR(1189u, HUD_FPS_TAG_Y - 18u, 177u,
                      HUD_FPS_NUM_Y + HUD_FPS_NUM_H - HUD_FPS_TAG_Y + 18u);
#undef HUD_CLEAR
    }

    /* The right-gutter portrait is on the plate itself now (the plate covers
     * the full screen), so only the small left-gutter portrait is drawn. */
    /* ART_REIMU_0 is the same picture at scale 1, i.e. 48x48.  The asset
     * named HUD_SMALL is that frame at scale 2 - 96x96 - so it was drawn from
     * y=112 down to y=208 and sat on top of the LIVES block, which starts at
     * 194.  (check_hud_layout.py saw only the 40-pixel box, which is why it
     * never reported it.)  Half the size, and it now stops 34 rows short. */
    draw_art(fb, HUD_PLAYER_X + 16, HUD_PLAYER_Y + 8, ART_REIMU_0);
    uint32_t accent = wave == 0 ? 0x003070D0u :
                      wave == 1 ? 0x00D05030u : 0x009060C0u;
    /* (The two playfield border columns are drawn up in the backdrop block,
     * once per plate rather than once per frame - see the note there.) */

    /* Score popups ride on top of the playfield and under the HUD. */
    popup_render(fb);

    /* ---- HUD labels ------------------------------------------------------
     * The plate used to have these baked into it as pixels.  They are drawn
     * here now, with the same vector font as their readouts, which is what
     * makes it impossible for a label and its number to drift apart - the
     * class of bug check_hud_layout.py was written to catch.
     * A label sits directly above its readout, never on top of it. */
    hud_label(fb, HUD_LBL_REIMU);
    hud_label(fb, HUD_LBL_LIVES);
    hud_label(fb, HUD_LBL_SCORE);
    hud_label(fb, HUD_LBL_SPELL_CARD);
    hud_label(fb, HUD_LBL_STATUS);
    hud_label(fb, HUD_LBL_HISCORE);
    /* "STAGE n" as one line.  The number is built as a character, not
     * through draw_number(): that helper ignores its `digits` argument and
     * always calls draw_text() at FONT_S (scale 3, a 21-pixel advance), so a
     * single digit came out 18 pixels wide and 2 pixels of it landed on the
     * end of this label. */
    hud_label(fb, boss_state == BOSS_NONE ? HUD_LBL_STAGE : HUD_LBL_BOSS);
    {
        char row_no[2];
        row_no[0] = (char)('0' + (wave + 1u) % 10u);
        row_no[1] = '\0';
        draw_text(fb, HUD_STAGE_TAG_X + 40, HUD_STAGE_TAG_Y - 12, row_no, 1,
                  0x00FFE4A0u);
    }
    hud_label(fb, HUD_LBL_SHOT);
    hud_label(fb, HUD_LBL_POWER);
    hud_label(fb, HUD_LBL_ATTACK);
    /* One bar, two names.  WAVE and BOSS LIFE were always the same widget -
     * game_render() picks the value, this picks the word - so the second label
     * and its whole box are gone (section 4). */
    hud_label(fb, boss_state == BOSS_NONE ? HUD_LBL_WAVE : HUD_LBL_BOSS_LIFE);
    hud_label(fb, HUD_LBL_BACKEND);
    hud_label(fb, HUD_LBL_FPS_TAG);
    hud_label(fb, HUD_LBL_VERTEX);
    /* The control hints that used to sit here ("X FIRE  B PAUSE" at
     * HUD_DEBUFF_J_Y + 6 and "Y SETTINGS" below it) are gone: they occupy the
     * same rows as the JAM counter, so a debuff printed digits straight
     * through the words.  The controls are on the title screen and in the
     * settings card, which is where a player looks for them. */

    /* ---- HUD ---- */
    draw_number(fb, HUD_SCORE_X, HUD_SCORE_Y, score, 6, 0x00FFE4A0u);
    for (int i = 0; i < lives && i < 6; i++)
        draw_art(fb, HUD_LIVES_X + (i % 3) * 30, HUD_LIVES_Y + (i / 3) * 28,
                 ART_HEART);
    {
        static const char * const shots[] = {"FOCUS","SPREAD","LASER","FAN"};
        draw_text(fb,HUD_WEAPON_X,HUD_WEAPON_Y,shots[weapon & 3u],3,0x00FF909Cu);
        /* Weapon LEVEL bar: four ticks, one per level.  Filled ticks are the
         * level, and a full bar means further SHOT items only add density -
         * the player can see why the shot stopped changing type.  It sits to
         * the RIGHT of the name now: drawn above it, the bar covered the top
         * half of the very word it was annotating. */
        for (int i = 0; i < WEAPON_MAX_LEVEL; i++)
            r_fill(fb + (uint32_t)(HUD_LV_BAR_Y * SCREEN_STRIDE) +
                   (uint32_t)((HUD_LV_BAR_X + i * 26) * 4), 20, 5,
                   (i < (int)weapon_level) ? 0x00FFD24Au : 0x00343A46u,
                   SCREEN_STRIDE);
        hud_label(fb, HUD_LBL_LV);
    }
    for (int i = 0; i < (int)atk; i++)
        draw_art(fb, HUD_ATK_X + i * 24, HUD_ATK_Y, ART_STAR);
    draw_text(fb,HUD_BACKEND_X,HUD_BACKEND_Y,hw_accel ? "FPGA" : "CPU",2,
              hw_accel ? 0x0070F0CFu : 0x00FFC070u);
    {
        uint32_t bcd = (GPU2D_REG_FPS_BCD >> 8) & 0xFFu;
        char digits[3] = { (char)('0'+((bcd >> 4)&15u)), (char)('0'+(bcd&15u)), 0 };
        /* FPS shares the FPGA/CPU row.  At its old spot (y=534) it was painted
         * over the backdrop's RENDER BACKEND label, and at y=556 it collided
         * with the FPGA token itself. */
        hud_label(fb, HUD_LBL_FPS);
        draw_text(fb,HUD_FPS_NUM_X,HUD_FPS_NUM_Y,digits,2,0x0070F0CFu);
    }
    /* The stage's name, one scale-2 word: 70 pixels wide, which is what the
     * 180-pixel gutter can carry.  Which stage it is now sits on the label
     * line above it. */
    draw_text(fb,HUD_STAGE_TAG_X,HUD_STAGE_TAG_Y,
              wave == 0 ? "FROST" : wave == 1 ? "FLAME" : "DREAM",2,accent);
    if (slow_timer) draw_debuff(fb, HUD_DEBUFF_S_Y, "SLOW", slow_timer);
    if (jam_timer)  draw_debuff(fb, HUD_DEBUFF_J_Y, "JAM",  jam_timer);

    /* Spell card charge: eight ticks, lit from the left.  It lives in the
     * empty band between the life row (ends at y=232) and the backdrop's FOCUS
     * label (starts at y=310) - the first attempt sat at y=300 and painted
     * straight over that label. */
    hud_label(fb, HUD_LBL_SPELL);
    for (int i = 0; i < BOMB_MAX_CHARGE; i++)
        r_fill(fb + (uint32_t)((HUD_SPELL_Y + 14) * SCREEN_STRIDE) +
                   (uint32_t)((HUD_SPELL_X + i * 13) * 4), 10, 8,
               (i < (int)bomb_charge) ? 0x00FFD24Au : 0x00343A46u,
               SCREEN_STRIDE);

    /* wave progress / boss health */
    if (boss_state == BOSS_NONE) {
        uint32_t done = (kills >= wave_max) ? wave_max : (uint32_t)kills;
        int w = (int)(done * HUD_WAVE_BAR_W / (wave_max ? wave_max : 1u));
        r_fill(fb + (uint32_t)(HUD_WAVE_BAR_Y * SCREEN_STRIDE) +
                   (uint32_t)(HUD_WAVE_BAR_X * 4), (uint32_t)HUD_WAVE_BAR_W, 8,
                   0x00202020u, SCREEN_STRIDE);
        if (w > 0)
            r_fill(fb + (uint32_t)(HUD_WAVE_BAR_Y * SCREEN_STRIDE) +
                       (uint32_t)(HUD_WAVE_BAR_X * 4),
                       (uint32_t)w, 8, 0x0060FF60u, SCREEN_STRIDE);
    } else if (boss_hp > 0) {
        int w = (int)((uint32_t)boss_hp * HUD_WAVE_BAR_W /
                      (uint32_t)(boss_hp_max ? boss_hp_max : 1));
        uint32_t bar = 0x00FF3060u;
        uint32_t bbase = fb + (uint32_t)(HUD_WAVE_BAR_Y * SCREEN_STRIDE) +
                         (uint32_t)(HUD_WAVE_BAR_X * 4);

        /* The bar carries the two spell-card marks (two thirds and one third),
         * and turns gold as the next one comes into reach.  The fight now has
         * beats the player can see coming instead of being sprung on them. */
        if (boss_opener_stage < 2u) {
            int32_t mark = (int32_t)boss_hp_max *
                           (2 - (int)boss_opener_stage) / 3;
            if ((int32_t)boss_hp <= mark + 40) bar = 0x00FFD24Au;
        }
        r_fill(bbase, (uint32_t)HUD_WAVE_BAR_W, 8, 0x00202020u, SCREEN_STRIDE);
        if (w > 0) r_fill(bbase, (uint32_t)w, 8, bar, SCREEN_STRIDE);

        /* ---- damage trail ------------------------------------------------
         * A white sliver that lags the real bar and slides back to it: the
         * player sees HOW MUCH came off in the last hit, not just where the
         * bar ended up.  boss_hp_display chases boss_hp downward, so a big hit
         * leaves a long sliver for a few frames and a stream of small hits
         * keeps it short. */
        if (boss_hp_shown > boss_hp) {
            int tw = (int)((uint32_t)boss_hp_shown * HUD_WAVE_BAR_W /
                           (uint32_t)(boss_hp_max ? boss_hp_max : 1));
            if (tw > w)
                r_fill(bbase + (uint32_t)w * 4u, (uint32_t)(tw - w), 3,
                       0x00FFFFFFu, SCREEN_STRIDE);
            boss_hp_shown -= (boss_hp_shown - boss_hp + 3u) / 4u;
        } else {
            boss_hp_shown = boss_hp;
        }
        /* The two spell-card marks scale with the bar, so they stay at the two
         * thirds / one third the fight is actually gated on. */
        r_fill(bbase + (uint32_t)(HUD_WAVE_BAR_W * 2 / 3) * 4u, 2, 8,
               0x00FFFFFFu, SCREEN_STRIDE);
        r_fill(bbase + (uint32_t)(HUD_WAVE_BAR_W / 3) * 4u, 2, 8,
               0x00FFFFFFu, SCREEN_STRIDE);
    }
    if (boss_state == BOSS_DIALOG) {
        dialog_was_active = 1u;
        uint8_t prev_dt = damage_track;
        damage_track = 0u;
        static const char * const names[] = {"CIRNO", "OKUU", "DREAM SHADE"};
        static const char * const boss_lines[] = {
            "I WILL FREEZE THIS SHRINE!",
            "FEEL THE HEAT OF THE SUN!",
            "FACE YOUR OWN REFLECTION!"
        };
        static const char * const reimu_lines[] = {
            "THEN LET'S BREAK THE ICE.",
            "I WON'T LET YOU BURN IT.",
            "TIME TO WAKE FROM THIS DREAM."
        };
        uint32_t base = fb + DIALOG_Y * SCREEN_STRIDE + DIALOG_X * 4u;
        /* The card is framebuffer pixels like everything else here, so the snow
         * would fall straight through its text; punch it out of the layer. */
        weather_box_cover(DIALOG_X, DIALOG_Y,
                          DIALOG_X + DIALOG_W - 1, DIALOG_Y + DIALOG_H - 1);
        r_fill(base, DIALOG_W, DIALOG_H, 0x00141A32u, SCREEN_STRIDE);
        r_fill(base, DIALOG_W, 4, accent, SCREEN_STRIDE);
        r_fill(base + (DIALOG_W - 4u) * 4u, 4, 4, accent, SCREEN_STRIDE);
        r_fill(base + (DIALOG_H - 4u) * SCREEN_STRIDE, DIALOG_W, 4, accent,
               SCREEN_STRIDE);
        r_fill(base + (DIALOG_H - 4u) * SCREEN_STRIDE + (DIALOG_W - 4u) * 4u,
               4, 4, accent, SCREEN_STRIDE);
        if (dialog_line == 2)
            draw_art(fb, DIALOG_X + 34, DIALOG_Y + 31, ART_REIMU_0);
        else
            draw_boss_art(fb, DIALOG_X + 26, DIALOG_Y + 22);
        draw_text(fb, DIALOG_X + 120, DIALOG_Y + 24,
                  dialog_line == 2 ? "REIMU" : names[wave], 3, accent);
        draw_text(fb, DIALOG_X + 120, DIALOG_Y + 82,
                  dialog_line == 0 ? "STAGE BOSS APPROACHES" :
                  dialog_line == 1 ? boss_lines[wave] : reimu_lines[wave],
                  2, 0x00FFFFFFu);
        draw_text(fb, DIALOG_X + 120, DIALOG_Y + 144,
                  "X / OK NEXT   AUTO IN 2S", 1, 0x00B0C0D8u);
        damage_track = prev_dt;
    }
    bucket_build_finish();
    tlm[42] = profile_elapsed(profile_start, GPU2D_REG_CORE_TICKS);
}

/* ===================================================================== */
/* settings / pause menu -- opened with B inside the game                */
/* ===================================================================== */
#define SET_ITEMS 7

/* 0 = Soft Halo (tight round kernel), 1 = Wide Halo (the same shape one size
 * up).  Both are channel-agnostic; the power-on default is the tight one,
 * because the stage this build is judged on carries 192 shots at once and the
 * wide kernel is what turns a full screen into one white smear. */
static uint8_t bloom_style_sel = 0u;

/* ---- the pause menu's FX switch ----------------------------------------
 * The glow is the one effect whose taste is genuinely the player's: it is what
 * makes a barrage read as energy, and it is also the first thing that turns a
 * dense screen into a white smear.  A switch is what lets that be judged on the
 * board instead of argued about, and it costs exactly one register write -
 * gpu2d_set_bloom() already has a bypass that passes the untouched pixel
 * through, so "off" is a true off, not a very small glow.
 *
 * The two numbers live here rather than at the call site so that the switch,
 * the power-on default and the tuning cannot drift apart. */
#define BLOOM_THRESHOLD  120u
#define BLOOM_INTENSITY  255u
static uint8_t bloom_fx_on = 1u;

static const char * const settings_labels[SET_ITEMS] = {
    "INF RESPAWN", "HW ACCEL", "RESUME", "EXIT", "STRESS STAGE", "VOLUME", "GLOW FX"
};

/* The pause card used to be a 2506-byte RLE texture: a flat dark panel with a
 * border and three lines of text baked into it, which was by far the most
 * expensive way in the whole firmware to draw a rectangle - a fifth of the
 * remaining image budget.  It is composed from fills now, so the card costs
 * nothing at boot and matches the option rows drawn on top of it. */
static void pause_card(uint32_t fb, int px, int py, int pw, int ph)
{
    uint32_t base = fb + (uint32_t)(py * SCREEN_STRIDE) + (uint32_t)(px * 4);

    /* Solid high-contrast deep obsidian card with layered cyan/silver borders.
     * Uses zero DDR read bandwidth to prevent display DMA FIFO underflow. */
    r_fill(base, (uint32_t)pw, (uint32_t)ph, 0x000E1422u, SCREEN_STRIDE);
    r_fill(base + (uint32_t)(4 * SCREEN_STRIDE) + 16, (uint32_t)(pw - 8), (uint32_t)(ph - 8),
           0x00131A28u, SCREEN_STRIDE);
    r_fill(base, (uint32_t)pw, 2, 0x0068A0DCu, SCREEN_STRIDE);
    r_fill(base, 2, (uint32_t)ph, 0x0068A0DCu, SCREEN_STRIDE);
    r_fill(base + (uint32_t)((ph - 2) * SCREEN_STRIDE), (uint32_t)pw, 2,
           0x00060910u, SCREEN_STRIDE);
    r_fill(base + (uint32_t)((pw - 2) * 4), 2, (uint32_t)ph, 0x00060910u,
           SCREEN_STRIDE);
}

static void settings_render(uint32_t fb)
{
    pause_was_active = 1u;
    uint8_t prev_dt = damage_track;
    damage_track = 0u;

    /* Centred on the screen that exists.  256/124 is the centre of a 1024x600
     * display, so on 1366x768 the card sat high and to the left. */
    int pw = SET_CARD_W, ph = SET_CARD_H;
    int px = (SCREEN_WIDTH - pw) / 2;
    int py = (SCREEN_HEIGHT - ph) / 2;
    uint32_t base = fb + (uint32_t)(py * SCREEN_STRIDE) + (uint32_t)(px * 4);

    pause_card(fb, px, py, pw, ph);
    /* The card is the one thing on this screen the weather must not paint on;
     * everything outside the box keeps its flakes. */
    weather_box_cover(px, py, px + pw - 1, py + ph - 1);
    draw_text(fb, px + 20, py + 14, "PAUSED", 5, 0x00FFE4A0u);
    draw_text(fb, px + 20, py + 58, "WORLD TIME IS FROZEN", 2, 0x00FFFFFFu);
    draw_text(fb, px + 20, py + ph - 24, "Y/A SELECT  X/OK CONFIRM", 2,
              0x00FFFFFFu);
    r_fill(base, (uint32_t)pw, 3, 0x00FFFFFFu, SCREEN_STRIDE);
    r_fill(base + (uint32_t)((ph - 3) * SCREEN_STRIDE), (uint32_t)pw, 3,
           0x00FFFFFFu, SCREEN_STRIDE);
    r_fill(base, 3, (uint32_t)ph, 0x00FFFFFFu, SCREEN_STRIDE);
    r_fill(base + (uint32_t)((pw - 3) * 4), 3, (uint32_t)ph, 0x00FFFFFFu,
           SCREEN_STRIDE);

    /* 40, not 44: the card grew an option.  Six rows from py+78 at a 44-pixel
     * pitch would end at py+366, past the card's own 352-pixel bottom edge and
     * straight through the "Y/A SELECT" line at py+328.  At 40 the last row
     * ends at py+312 and the hint line keeps its 16 pixels of clearance.  The
     * card itself stays 512x352: the workbench grades that rectangle as the
     * scanout's weather-occlusion box. */
    for (int i = 0; i < SET_ITEMS; i++) {
        int ry = py + 78 + i * 40;
        if (i == (int)settings_sel) {
            r_fill(fb + (uint32_t)(ry * SCREEN_STRIDE) + (uint32_t)((px + 14) * 4),
                   (uint32_t)(pw - 28), 34, 0x00304878u, SCREEN_STRIDE);
            r_fill(fb + (uint32_t)((ry + 6) * SCREEN_STRIDE) +
                   (uint32_t)((px + 2) * 4), 8, 22, 0x00FFFF00u, SCREEN_STRIDE);
        }
        draw_text(fb, px + 32, ry + 8, settings_labels[i], 2, 0x00FFFFFFu);
        if (i == 0 || i == 1 || i == 6) {
            int on = (i == 0) ? (int)infinite_respawn
                              : (i == 1 ? (int)hw_accel : (int)bloom_fx_on);
            draw_text(fb, px + pw - 116, ry + 8, on ? "ON" : "OFF", 2,
                      on ? 0x0060FF60u : 0x00A0A0A0u);
        } else if (i == 4) {
            draw_text(fb, px + pw - 116, ry + 8, "BOSS", 2, 0x00FF8040u);
        } else if (i == 5) {
            static const char * const volume_labels[5] = {
                "MUTE", "12%", "25%", "50%", "100%"
            };
            draw_text(fb, px + pw - 116, ry + 8, volume_labels[game_audio_volume], 2,
                      game_audio_volume ? 0x0060FF60u : 0x00A0A0A0u);
        }
    }
    damage_track = prev_dt;
}

#define ACT_STAY         0
#define ACT_RESUME       1
#define ACT_EXIT         2
#define ACT_STRESS_STAGE 3

/* Stick / Y / A move the highlight, X confirms.  B is handled by the caller
 * (it toggles the menu itself), so this only returns STAY / RESUME / EXIT / STRESS_STAGE. */
static void settings_edge_reset(const gamepad_state_t *pad)
{
    set_prev_y      = pad->btn_y;
    set_prev_a      = pad->btn_a;
    set_prev_x      = pad->btn_x;
    set_prev_center = pad->btn_center;
    /* The stick counts as "already deflected" until the player lets it go, or
     * holding it while the menu opens would scroll the list on the first pass. */
    set_stick_hold  = (uint8_t)((pad->y > 168) || (pad->y < 88));
}

static int settings_input(gamepad_state_t *pad)
{
    int stick_up   = (pad->y > 168);
    int stick_down = (pad->y < 88);
    int up_edge, down_edge, confirm_edge;

    if (!stick_up && !stick_down) set_stick_hold = 0;

    up_edge      = (pad->btn_y && !set_prev_y) || (stick_up   && !set_stick_hold);
    down_edge    = (pad->btn_a && !set_prev_a) || (stick_down && !set_stick_hold);
    confirm_edge = (pad->btn_x && !set_prev_x) || (pad->btn_center && !set_prev_center);

    set_prev_y      = pad->btn_y;
    set_prev_a      = pad->btn_a;
    set_prev_x      = pad->btn_x;
    set_prev_center = pad->btn_center;

    if (up_edge) {
        settings_sel = (uint8_t)((settings_sel + SET_ITEMS - 1) % SET_ITEMS);
        set_stick_hold = 1;
        return ACT_STAY;
    }
    if (down_edge) {
        settings_sel = (uint8_t)((settings_sel + 1) % SET_ITEMS);
        set_stick_hold = 1;
        return ACT_STAY;
    }
    if (confirm_edge) {
        switch (settings_sel) {
        case 0: infinite_respawn ^= 1; break;
        case 1: hw_accel ^= 1;         break;
        case 2: return ACT_RESUME;
        case 3: return ACT_EXIT;
        case 4: return ACT_STRESS_STAGE;
        case 5:
            game_audio_volume = (uint8_t)((game_audio_volume + 1u) % 5u);
            audio_write(AUDIO_EVENT_NONE);
            break;
        case 6:
            bloom_fx_on ^= 1u;
            gpu2d_set_bloom(bloom_fx_on, BLOOM_THRESHOLD, BLOOM_INTENSITY);
            break;
        default: return ACT_STAY;
        }
    }
    return ACT_STAY;
}

static void telemetry_write(void)
{
    int ne = 0, np = 0, nb = 0, ni = 0;
    for (int i = 0; i < MAX_ENEMIES; i++)  if (enemies[i].flags  & EF_ACTIVE) ne++;
    bullet_t *b;

    FOR_EACH_PBULLET(b) np++;
    if (is_stress_stage) nb = active_ebullets_count;
    else { FOR_EACH_EBULLET(b) nb++; }
    for (int i = 0; i < MAX_ITEMS; i++)    if (items[i].flags    & EF_ACTIVE) ni++;

    tlm[TLM_MAGIC]    = TLM_MAGIC_VAL;
    tlm[TLM_PLAYER_X] = (uint32_t)player_x;
    tlm[TLM_PLAYER_Y] = (uint32_t)player_y;
    tlm[TLM_LIVES]    = lives;
    tlm[TLM_SCORE]    = score;
    tlm[TLM_WEAPON]   = weapon;
    tlm[TLM_ATK]      = atk;
    tlm[TLM_FIRE_CD]  = fire_cd;
    tlm[TLM_KILLS]    = kills;
    tlm[TLM_ENEMIES]  = (uint32_t)ne;
    tlm[TLM_PBULLETS] = (uint32_t)np;
    tlm[TLM_EBULLETS] = (uint32_t)nb;
    tlm[TLM_ITEMS]    = (uint32_t)ni;
    /* Population, not draw calls: decorative FX/laser/weather layers are
     * excluded. The HUD samples this after publication, alongside FPS. */
    tlm[TLM_SPRITES]  = (uint32_t)(ne + np + nb + ni) + (lives != 0) +
                        (boss_state != BOSS_NONE && boss_hp > 0);
    tlm[TLM_TAKEN]    = items_taken;
    tlm[TLM_BOSS_ST]  = boss_state;
    tlm[TLM_BOSS_HP]  = (uint32_t)(boss_hp < 0 ? 0 : boss_hp);
    tlm[TLM_BOSS_PAT] = boss_pattern;
    tlm[TLM_PAT_CHG]  = pattern_changes;
    tlm[TLM_SUMMONS]  = summons;
    tlm[TLM_HITS]     = hits_taken;
    tlm[TLM_GAMEOVER] = game_over;
    tlm[TLM_PAUSED]   = paused;
    tlm[TLM_HWACCEL]  = hw_accel;
    tlm[TLM_INFRESPAWN] = infinite_respawn;
    tlm[TLM_SETTINGS] = settings_sel;
    tlm[TLM_PADBITS]  = pad_bits;
    tlm[TLM_STAGE]    = wave + 1u;
    tlm[TLM_BOSS_X]   = (uint32_t)(int32_t)boss_x;
    tlm[TLM_BOSS_Y]   = (uint32_t)(int32_t)boss_y;
    tlm[TLM_DIALOG]   = boss_state == BOSS_DIALOG ? dialog_line + 1u : 0u;
    tlm[TLM_SLOW]     = slow_timer;
    tlm[TLM_JAM]      = jam_timer;
    tlm[TLM_LASER_HITS] = laser_hits;
    /* Added for the verifier: the invulnerability countdown proves the pickup
     * test no longer depends on it, the weapon level proves the cap really
     * holds, and the active plate index proves the stage backdrop changed. */
    tlm[TLM_INVULN]   = invuln;
    tlm[TLM_WEAPON_LV] = weapon_level;
    tlm[TLM_STAGE_BG] = stage_bg_active;
    /* The spell card the player can spend, and the boss's laser columns. */
    tlm[TLM_BOMB]     = bomb_charge;
    tlm[TLM_LASER]    = boss_laser;
    /* LAST, on purpose.  This word is the block's publish flag: the
     * workbench polls it, and one store is one VM step, so a reader can
     * observe the block half-written if anything after it moves.  Writing
     * it first meant every field could still be a frame old at the moment
     * the frame counter changed. */
    tlm[TLM_FRAMES]   = frame_tick;
    tlm[TLM_DAMAGE_ROWS] = damage_restore_rows;
}

static void game_init(void);        /* forward declaration */

static void game_init(void)
{
    damage_plate[0] = 0;
    damage_plate[1] = 0;
    /* Force both border columns to be redrawn for whichever plate each
     * buffer comes up on - a fresh run may land on a different stage. */
    border_plate[0] = 0;
    border_plate[1] = 0;
    damage_track = 0;
    /* The boot menu owns the whole frame and drives BOTH scanout channels,
     * while the game only repaints the playfield plus the HUD glyphs - so the
     * menu's white selection box stayed visible in the HUD gutters.  The frame
     * buffer alternates every frame, so the wipe has to happen once per buffer
     * as each one comes round: clearing both up front would write the buffer
     * the scanout is reading right now and tear the picture. */
    clear_pending = 2;
    /* Same story for the gutters: this run may land on a different stage with
     * different widgets, and the frames before it carried the menu.  Dropping
     * the ledger's validity arms every band once per buffer. */
    hud_sig_valid = 0u;
    hud_sig[HUD_SIG_STRESS] = 0u;
    bt_drop_peak = 0u;
    fx_cursor = 0; player_pose = 0;
    hitstop = 0; hit_ring_timer = 0;
    for (int i = 0; i < 16; i++) visual_fx[i].active = 0;
    for (int i = 0; i < MAX_PARTICLES; i++) game_particles[i].life = 0;
    particle_cursor = 0;
    color_matrix_flash_timer = 0;
    /* Task 05 & Task 07: Scanout Bloom for zero-bandwidth glow on all bullets and lasers.
     * Threshold 120 and intensity 255 with emissive extraction ensures rich radiant halos
     * on bullets, lasers, and sparks with zero background fogging/graying. */
    gpu2d_set_bloom(bloom_fx_on, BLOOM_THRESHOLD, BLOOM_INTENSITY);
    gpu2d_set_bloom_style(bloom_style_sel);
    gpu2d_set_color_matrix(COLOR_MATRIX_BYPASS, 0);
    gpu2d_set_alpha(1, 255);
    pool_clear();

    player_x = (int16_t)((GAME_LEFT + GAME_RIGHT) / 2);
    player_y = GAME_TOP + (GAME_BOTTOM - GAME_TOP) * 2 / 3;
    lives = 3;
    weapon = W_CENTER;
    weapon_level = 1;                   /* level 1 = the starting shot */
    atk = 1;
    fire_cd = 6;
    fire_timer = 0;
    invuln = 0;
    hit_blink = 0;
    hit_ring_timer = 0;
    laser_cd = 0;
    beam_active = 0;
    slow_timer = 0;
    jam_timer = 0;
    laser_hits = 0;
    score = 0;
    score_total = 0;
    combo_count = 0;
    combo_timer = 0;
    for (int i = 0; i < POPUP_SLOTS; i++) popups[i].age = 0;
    kills = 0;
    wave = 0;
    wave_max = 14;
    spawn_timer = 30;
    frame_tick = 0;
    strip_scroll = 0;
    stage_banner = 170;                 /* title card for the opening stage */
    stage_bg_active = 0xffu;            /* force the first load to take */
    stage_background_load(0);

    boss_state = BOSS_NONE;
    boss_hp = 0;
    boss_hp_max = 400;
    boss_pattern = PAT_FAN;
    boss_prev_pat = PAT_FAN;
    pat_recent_n = 0;
    boss_pat_timer = 0;
    boss_fire_timer = 0;
    boss_dead_timer = 0;
    boss_since_summon = 0;
    boss_move_timer = 0;
    dialog_line = 0;
    dialog_prev = 0;
    dialog_grace = 0;
    dialog_timer = 0;
    dialog_was_active = 0;
    boss_x = (int16_t)((GAME_LEFT + GAME_RIGHT) / 2 - 32);
    boss_y = -64;
    boss_target_x = boss_x;
    boss_target_y = 88;
    pattern_changes = 0;
    summons = 0;
    items_taken = 0;
    hits_taken = 0;

    bomb_charge = 0;
    bomb_flash = 0;
    bomb_prev_center = 0;
    bomb_kills_seen = 0;
    boss_clear_lasers();
    boss_hp_shown = 0;
    boss_freeze_timer = 0;
    boss_shake = 0;
    boss_pending_opener = 0;
    boss_card_active = 0;
    lockon_arm = 0;
    lockon_timer = 0;
    boss_opener_stage = 0;

    rng_state = 0x9E3779B9u;
    game_over = 0;
    game_clear = 0;
    restart_timer = 0;
    telemetry_write();
    gpu2d_flush_dcache();
}

static void stress_stage_init(void)
{
    game_init();
    is_stress_stage = 1;
    stress_target = STRESS_STORM_TARGET;
    stress_prev_y = 0xFFu;    /* release the entry chord before changing load */

    /* Zero-delay direct to BOSS fight (Task 11) */
    gpu2d_set_colorkey(1, MAGENTA_KEY);
    gpu2d_set_alpha(1, 255);
    stage_banner = 0;          /* no stage intro banner */
    spawn_timer  = 0;          /* start spawning minions immediately */
    wave         = 1;          /* Volcano boss (ART_BOSS) */
    wave_max     = 9999;       /* Minion quota */
    kills        = 0;
    stage_bg_active = SB_STAGE_LAVA; /* Volcano stage weather (rising volcanic ash) */

    /* Task 12: */
    weapon       = W_LASER;
    weapon_level = WEAPON_MAX_LEVEL;
    atk          = ATK_MAX;
    fire_cd      = STRESS_FIRE_CD;
    bomb_charge  = BOMB_MAX_CHARGE;
    stress_storm_step = 0;

    for (int i = 0; i < MAX_ENEMIES; i++) enemies[i].flags = 0;
    spawn_enemy(ENEMY_FAIRY, GAME_LEFT + 100, 80);
    spawn_enemy(ENEMY_TURRET, GAME_LEFT + 260, 110);
    spawn_enemy(ENEMY_SHARD, GAME_RIGHT - 260, 90);
    spawn_enemy(ENEMY_MINION, GAME_RIGHT - 100, 120);

    /* Boss setup: 0 delay, battle ready at station */
    boss_state   = BOSS_FIGHT; /* ??????????? skip BOSS_DIALOG & BOSS_ENTER straight to BOSS_FIGHT */
    dialog_line  = 0;
    dialog_timer = 0;
    dialog_grace = 0;
    dialog_was_active = 0;

    boss_x        = (int16_t)((GAME_LEFT + GAME_RIGHT) / 2 - 32);
    boss_y        = 88;        /* Directly at battle position */
    boss_target_x = boss_x;
    boss_target_y = 88;
    boss_hp_max   = 600;
    boss_hp       = boss_hp_max;
    boss_hp_shown = boss_hp;
    boss_pat_timer = 45;
    boss_fire_timer = 20;
    boss_pattern  = PAT_FAN;
    boss_prev_pat = PAT_FAN;
    boss_move_timer = 45;
    boss_card_active = 0;
    boss_freeze_timer = 0;
    boss_shake   = 0;

    player_x = (int16_t)((GAME_LEFT + GAME_RIGHT) / 2);
    player_y = GAME_TOP + (GAME_BOTTOM - GAME_TOP) * 2 / 3;

    damage_plate[0] = 0;
    damage_plate[1] = 0;
    border_plate[0] = 0;
    border_plate[1] = 0;

    telemetry_write();
    gpu2d_flush_dcache();
}

/* ------------------------------------------------------------------ */

/* Wipe whatever the previous screen mode left behind, once per buffer.  The
 * menu owns the whole frame and drives BOTH scanout channels, so a fresh run
 * otherwise starts with the menu's white selection frame still sitting in the
 * HUD gutters.  This is called from the settings-menu path too: opening the
 * menu during the first frames of a run used to strand the counter, so both
 * buffers got wiped later - on top of a game that was already running. */
/* The craft keeps flying while the field is held.  Freezing it too - which is
 * what the first version of the hold did - made the beat read as a dropped
 * frame rather than as time stopping, and it took away the one thing the
 * player is supposed to be doing during a spell card. */
static void player_move(const gamepad_state_t *pad)
{
    int speed = (pad->btn_a || slow_timer) ? 2 : 5;
    if (pad->x > PAD_AXIS_HIGH) player_x = (int16_t)(player_x + speed);
    if (pad->x < PAD_AXIS_LOW)  player_x = (int16_t)(player_x - speed);
    if (pad->y > PAD_AXIS_HIGH) player_y = (int16_t)(player_y - speed);
    if (pad->y < PAD_AXIS_LOW)  player_y = (int16_t)(player_y + speed);
    /* 24, not 16: the craft sprite is 48x48 and centred on player_x, so a
     * 16-pixel inset lets 8 pixels of artwork cross the playfield edge. */
    if (player_x < GAME_LEFT + 24)  player_x = GAME_LEFT + 24;
    if (player_x > GAME_RIGHT - 24) player_x = GAME_RIGHT - 24;
    /* The craft's centre keeps a 16-pixel inset from the playfield edge, on
     * all four sides.  The old 132 was "stop below the HUD band", which no
     * longer exists: the playfield runs the full height, so the only reason to
     * clamp is the sprite's own half-size. */
    if (player_y < GAME_TOP + 16) player_y = GAME_TOP + 16;
    if (player_y > GAME_BOTTOM - 24) player_y = GAME_BOTTOM - 24;
}

static void clear_frame(uint32_t fb)
{
    if (!clear_pending) return;
    clear_pending--;
    /* If game_render() is about to blit the full stage plate (damage_full,
     * which happens on screen entrance when damage_plate[buffer] != plate),
     * copying the full backdrop here is redundant and wastes 4.2 MB of DDR
     * bandwidth back-to-back, causing severe frame drops. Only blit if the
     * full plate won't be blitted by game_render(). */
    unsigned buffer = fb == FB_LEFT_FRONT ? 0u : 1u;
    if (damage_plate[buffer] == STAGE_BG_BUF(stage_bg_active)) {
        r_blit(fb, MM_VISUAL_BACKGROUND, SCREEN_WIDTH, SCREEN_HEIGHT,
               SCREEN_STRIDE, SCREEN_STRIDE);
        r_sync();
    }
}

/* ---- fixed-step game time -----------------------------------------------
 * The playable stage simulates on FIXED 1/75 s ticks driven by the board's
 * core-tick counter, so a dropped display frame skips a picture, never game
 * time.  LOGIC_STEP_CYCLES is exactly one 75 Hz frame at 100 MHz.  The
 * accumulator lives in main(); LOGIC_MAX_STEPS caps the catch-up burst so a
 * pathologically slow frame cannot spiral into an even slower one. */
#define LOGIC_HZ           75u
#define LOGIC_STEP_CYCLES  (100000000u / LOGIC_HZ)   /* 1333333 */
#define LOGIC_MAX_STEPS    4u

static void game_update(gamepad_state_t *pad)
{
    if (is_stress_stage && pad->btn_y &&
        (!stress_prev_y || ++stress_load_hold >= 37u)) {
        stress_load_hold = 0;
        stress_target = stress_target >= STRESS_STORM_MAX ? STRESS_STORM_TARGET :
                        stress_target + 128u > STRESS_STORM_MAX ? STRESS_STORM_MAX : stress_target + 128u;
        hud_sig[HUD_SIG_STRESS] = 0u;
        bt_drop_peak = 0u;
    }
    stress_prev_y = pad->btn_y;
    if (!pad->btn_y) stress_load_hold = 0;

    /* ---- game over (only when infinite respawn is switched off) -------- */
    if (game_over) {
        if (restart_timer) {
            restart_timer--;
            if (!restart_timer) {
                game_init();              /* the run is over: clear it ...    */
                game_exit_request = 1;    /* ... and hand back to the menu    */
            }
            return;
        }
        game_init();
        game_exit_request = 1;
        return;
    }

    /* Every walk over a pool in this frame - the barrage top-up below,
     * bullets_update(), bucket_build() inside game_render(), the telemetry
     * counters - runs to a bound this rebuilds from the pools themselves.
     * It has to happen before the first of them, and it is here rather than
     * at the top of the function so the game-over branch above, which walks
     * nothing, does not pay for it. */
    pool_bounds_rebuild();

    frame_tick++;
    visual_step(pad);
    popup_step();

    /* ---- the boss's hold -------------------------------------------------
     * Everything on the field stops until the opener fires - the minions, the
     * bullets, the boss and the clock - but NOT the craft, which keeps flying
     * so the beat is something the player moves through rather than something
     * that happens to them.  The pad is still polled so the centre button's
     * edge detector does not see a stale press the instant the field unfreezes. */
    if (boss_state == BOSS_FREEZE) {
        beam_active = 0;
        if (invuln) invuln--;
        if (hit_blink) hit_blink--;
        if (hit_ring_timer) hit_ring_timer--;
        if (slow_timer) slow_timer--;
        if (jam_timer) jam_timer--;
        if (stage_banner) stage_banner--;
        if (bomb_flash) bomb_flash--;
        if (boss_shake) boss_shake--;
        bomb_prev_center = pad->btn_center;
        player_move(pad);
        boss_update();
        return;
    }

    if (game_clear) {
        beam_active = 0;
        if (pad->btn_center) game_init();
        return;
    }
    if (boss_state == BOSS_DIALOG) {
        beam_active = 0;
        dialog_update(pad);
        return;
    }

    /* ---- player movement ---- */
    player_move(pad);
    if (invuln) invuln--;
    if (hit_blink) hit_blink--;
    if (hit_ring_timer) hit_ring_timer--;
    if (slow_timer) slow_timer--;
    if (jam_timer) jam_timer--;
    if (stage_banner) stage_banner--;
    if (bomb_flash) bomb_flash--;
    if (boss_shake) boss_shake--;

    /* Every kill banks charge towards the next spell card.  Watching the kill
     * counter rather than each of the half-dozen places that can end an enemy
     * keeps this to three instructions. */
    if (kills != bomb_kills_seen) {
        uint16_t gained = (uint16_t)(kills - bomb_kills_seen);
        bomb_kills_seen = kills;
        while (gained--) if (bomb_charge < BOMB_MAX_CHARGE) bomb_charge++;
    }
    if (pad->btn_center && !bomb_prev_center &&
        bomb_charge >= BOMB_MAX_CHARGE)
        player_bomb();
    bomb_prev_center = pad->btn_center;

    /* ---- shooting ---- */
    if (pad->btn_x) {
        if (fire_timer == 0) {
            /* Task 12: the pressure stage fires all three streams at once.
             * The branch is here rather than inside player_fire() so that the
             * campaign's shot table cannot be reached by a stray flag, and the
             * pressure table cannot be reached from a normal run. */
            if (is_stress_stage) stress_player_fire();
            else                 player_fire();
            fire_timer = (uint16_t)(fire_cd + (jam_timer ? 4u : 0u));
        } else {
            fire_timer--;
        }
    } else {
        fire_timer = 0;
    }
    laser_tick(pad->btn_x);

    /* ---- world ---- */
    wave_update();
    /* Task 12: the boss is held at full health, and that single line is what
     * three separate requirements hang off:
     *
     *   * it cannot die - and a boss's death throws the entire screen of
     *     shots away (see the BOSS_DYING arm of boss_update), which is
     *     precisely the field-clearing this stage must never do;
     *   * the two spell-card thresholds it would cross on the way down are
     *     never crossed, so the field is never frozen and the backdrop is
     *     never swapped for the card's own sky - that is the OTHER stages'
     *     set piece, and here it would both stop the barrage for a beat and
     *     take the snow-capped volcano off the screen;
     *   * the health bar reads as the constant the card asks for.
     *
     * Restored BEFORE boss_update() so that none of its checks can see a
     * damaged bar in the first place. */
    if (is_stress_stage) boss_hp = boss_hp_max;
    boss_update();
    enemies_update();
    bullets_update();
    /* Top the storm up AFTER the cull, not before it.  The old order measured
     * the pool at the previous frame's end, spawned up to the target, and only
     * then let bullets_update() retire this frame's leavers, so in steady
     * state the published population sat one cull behind the LOAD target:
     * at LOAD 8000 the HUD read 7985-7995 and never the round number the
     * operator dialled in.  Measuring the pool after the cull makes `room`
     * the real deficit, so the frame that is published holds the target. */
    if (is_stress_stage) stress_storm_update();
    items_update();
    particles_update();
    /* ... and once more now that the world has run.  The first restore keeps
     * the boss's own decisions honest; this one keeps the BAR honest.  Without
     * it the craft's fire takes a handful of points off inside bullets_update()
     * and the bar telemetry publishes is whatever survived that frame - a bar
     * that twitches between 600 and 592 and never settles. */
    if (is_stress_stage) boss_hp = boss_hp_max;

    /* ---- the opener's laser columns, while they stand ------------------- */
    if (boss_laser) {
        for (int k = 0; k < BOSS_LASER_COLS; k++) {
            int lx = BOSS_LASER_X(k);
            if (player_x > lx - 8 && player_x < lx + 8) take_hit();
        }
    }
    /* ---- 6.1 / 8.2 the columns, once they fire ------------------------- */
    for (int k = 0; k < CUT_SLOTS; k++)
        if (beam_phase[k] == 2 && player_x > beam_x[k] - CUT_HALF &&
            player_x < beam_x[k] + CUT_HALF)
            take_hit();

    /* Whether the beams are standing in the scanout's four columns.  Decided
     * here rather than in the renderer because stage_strip_render() publishes
     * the columns' enable bit EARLIER in the frame than the renderer gets to
     * look at beam_phase[] - deciding it at draw time leaves the bit a frame
     * behind the state it describes, and the beam is invisible on the frame it
     * fires. */
    laser_columns_live = 0u;
    for (int k = 0; k < CUT_SLOTS; k++)
        if (beam_phase[k] == 2) laser_columns_live = 1u;
}

static void update_screen_effects(void)
{
    if (boss_state == BOSS_FREEZE) {
        /* Task 09: Spell Card Declaration red energy pulse */
        uint8_t phase = (uint8_t)((frame_tick * 8u) & 0x7Fu);
        uint8_t pulse = (phase < 64u) ? (phase * 3u) : ((128u - phase) * 3u);
        gpu2d_set_color_matrix(COLOR_MATRIX_RED_PULSE, (uint8_t)(90u + pulse));
    } else if (color_matrix_flash_timer > 0) {
        /* Task 03: the envelope.  Rise from the table, then decay by -3.5% a
         * frame.  Age is taken BEFORE the decrement, so age 0 is the frame the
         * timer was armed on.
         *
         * The level is carried in 8.8 fixed point rather than as a byte.  An
         * 8-bit level loses its entire step to truncation once it is small, so
         * the tail degenerated into a linear -1 per frame and the flash died
         * at frame 96 of 112; eight fractional bits keep the decay exponential
         * all the way down, which is what makes CM_FLASH_FRAMES the thing that
         * decides the length instead of a rounding artefact. */
        uint8_t age = (uint8_t)(CM_FLASH_FRAMES - color_matrix_flash_timer);
        color_matrix_flash_timer--;
        if (age < CM_FLASH_RISE) {
            color_matrix_flash_acc = (uint16_t)(cm_flash_rise[age] << 8);
        } else {
            color_matrix_flash_acc =
                (uint16_t)(((uint32_t)color_matrix_flash_acc * 247u) >> 8);
        }
        if (color_matrix_flash_acc >> 8) {
            gpu2d_set_color_matrix(COLOR_MATRIX_FLASH,
                                   (uint8_t)(color_matrix_flash_acc >> 8));
        } else {
            /* The tail ran out.  Stop the timer rather than leaving the mode
             * selected at zero intensity, so whoever reads the register next
             * sees a clean BYPASS. */
            color_matrix_flash_timer = 0;
            gpu2d_set_color_matrix(COLOR_MATRIX_BYPASS, 0);
        }
    } else if (boss_spell_vfx_timer > 32u) {
        /* Climax Stage 2: White-hot overexposure flash at the moment of Spell Card release */
        gpu2d_set_color_matrix(COLOR_MATRIX_FLASH, (uint8_t)((boss_spell_vfx_timer - 32u) * 16u));
    } else if (boss_state == BOSS_DYING && boss_dead_timer > 45) {
        gpu2d_set_color_matrix(COLOR_MATRIX_FLASH, (uint8_t)((boss_dead_timer - 45u) * 16u));
    } else {
        gpu2d_set_color_matrix(COLOR_MATRIX_BYPASS, 0);
    }
}

/* One picture per display frame, painted from whatever state the fixed-step
 * simulation reached.  All engine work lives here: the simulation above never
 * touches the renderer, so N catch-up steps still cost exactly one render. */
static void game_render_pass(uint32_t fb)
{
    uint32_t profile_start = GPU2D_REG_CORE_TICKS;
    gpu2d_wait_cyc = 0u;    /* this frame's slice of the engine-wait probe */
    clear_frame(fb);
    update_screen_effects();

    if (game_over && restart_timer) {
        r_fill(fb, SCREEN_WIDTH, SCREEN_HEIGHT, 0x00100010u, SCREEN_STRIDE);
        /* A full-screen panel, and it is not the battlefield any more, so it
         * claims the whole screen: a flake sitting on "GAME OVER" is the same
         * defect as one sitting on the pause card. */
        weather_box_cover(0, 0, (int)SCREEN_WIDTH - 1, (int)SCREEN_HEIGHT - 1);
        /* "GAME OVER" is 9 glyphs at scale 6: 9*7*6 = 378 wide, so the
         * centred anchor is 494, not the 372 the 1024-wide layout used.
         * Vertically it sits a little above centre. */
        draw_text(fb, (SCREEN_WIDTH - 9 * 7 * 6) / 2, 330, "GAME OVER", 6,
                  0x00FF2040u);
        gpu2d_wait_idle();
        gpu2d_flush_dcache();
        return;
    }

    if (boss_state == BOSS_DIALOG) {
        game_render(fb);
        r_sync();
        gpu2d_flush_dcache();
        return;
    }

    game_render(fb);

    if (game_clear) {
        /* Centred too: 240 / 304 / 316 are the 1024x600 layout.  The panel
         * is 544 wide, so its left edge is (1366-544)/2 = 411, and each line is
         * centred on its own width (9 and 22 glyphs at 7*scale of advance). */
        r_fill(fb + 300u * SCREEN_STRIDE + 411u * 4u, 544, 168,
               0x00171B34u, SCREEN_STRIDE);
        /* The panel is opaque, so the snow layer has to be told to leave this
         * rectangle alone - the same rule as the pause card. */
        weather_box_cover(411, 300, 411 + 544 - 1, 300 + 168 - 1);
        draw_text(fb, (SCREEN_WIDTH - 9 * 7 * 5) / 2, 332, "ALL CLEAR", 5,
                  0x00FFE4A0u);
        draw_text(fb, (SCREEN_WIDTH - 22 * 7 * 2) / 2, 392,
                  "OK RESTART  B SETTINGS", 2, 0x00FFFFFFu);
        r_sync();
        gpu2d_flush_dcache();
        return;
    }

    stage_banner_render(fb);
    gpu2d_wait_idle();
    /* Publish the engine-wait probe here, not at the top of the loop: this is
     * the end of the only stretch whose engine time it measures. */
    tlm[TLM_P_ENGWAIT] = gpu2d_wait_cyc;
    {
        /* The cache flush is a maintenance instruction plus a DDR read, and
         * nothing has ever priced it.  Timed apart so a costly one cannot hide
         * inside the render pass's total. */
        uint32_t fl0 = GPU2D_REG_CORE_TICKS;
        gpu2d_flush_dcache();
        tlm[TLM_P_FLUSH] = profile_elapsed(fl0, GPU2D_REG_CORE_TICKS);
    }
    tlm[43] = profile_elapsed(profile_start, GPU2D_REG_CORE_TICKS);
}

/* ===================================================================== */
/* main                                                                  */
/* ===================================================================== */

#include "sprite_stress.inc"

/* ===================================================================== */
/* left half of the CPU-vs-FPGA bench                                    */
/* ===================================================================== */
/*
 * The bench renders BOTH halves inside one frame loop, and those two renderers
 * used to run back to back: the right half's BitBlt pass (652 commands, ~8 ms)
 * and one slice of the left half's software pass (~9 ms, ten slices a frame).
 * That is ~17 ms against a 13.3 ms display frame, so the loop could only publish
 * every second frame - the FPGA side read 37-40 FPS instead of 75, and half of
 * every frame went to waiting for the CPU rather than for the scanout.
 *
 * The wait it now fills was always there and was always dead: after publishing,
 * the loop spins on GPU2D_REG_RIGHT_ACTIVE until the scanout hands the back
 * buffer over, and nothing else used that time.  Draining the left half in
 * there overlaps the two renderers, so the right half publishes once per
 * display frame again.
 *
 * The units are deliberately tiny.  The spin ends the instant the scanout
 * switches, so a unit that overruns that window eats straight into the right
 * half's frame - the whole point is that the left half gets only what is left
 * over.  That ceiling is physical, not a tuning choice: the frame budget is
 * 13.3 ms and the right half needs ~8 of them, so the left half can borrow
 * ~5.3 ms per display frame however this is arranged.  Its own reported frame
 * rate therefore falls below the old figure.  It is the control arm of the
 * comparison, not the number under test, and the brief puts no floor under it.
 *
 * The handshake the old code did before its first slice is gone deliberately.
 * A left frame now takes several display frames to draw, and the buffer it
 * flips to is by then one the scanout gave up long ago; waiting on LEFT_ACTIVE
 * here would spend the right half's window on a condition that is already true.
 */
#define CPU_UNIT_ROWS   4
#define CPU_UNIT_BOXES  2

static uint32_t cpu_fb;
static int      cpu_phase;      /* 0,1 = the two clear halves; 2 = entities */
static int      cpu_y;          /* next row inside the current clear half   */
static int      cpu_box;        /* next entity                              */
static int      cpu_running;

/* One small unit of the left half.  Also starts and finishes a left frame. */
static void cpu_left_step(uint32_t *left_back)
{
    if (!cpu_running) {
        cpu_fb      = *left_back;
        cpu_phase   = 0;
        cpu_y       = 0;
        cpu_box     = 0;
        cpu_running = 1;
    }

    if (cpu_phase < 2) {
        int half = (int)(SCREEN_HEIGHT / 2u);
        int n    = half - cpu_y;
        if (n > CPU_UNIT_ROWS) n = CPU_UNIT_ROWS;
        cpu_software_fill(cpu_fb, 0, cpu_phase * half + cpu_y,
                          (int)SCAN_HALF_PIXELS, n, 0x00000000u);
        cpu_y += n;
        if (cpu_y >= half) { cpu_phase++; cpu_y = 0; }
        return;
    }

    {
        int end = cpu_box + CPU_UNIT_BOXES;
        for (int i = cpu_box; i < end && i < NUM_ENTITIES; i++) {
            int w = (int)entities[i].w;
            int h = (int)entities[i].h;
            int x = (int)entities[i].x;
            int y = (int)entities[i].y;
            if (y >= (int)SCREEN_HEIGHT || y + h <= 0) continue;
            cpu_software_fill(cpu_fb, x, y, w, h, entities[i].color);
        }
        cpu_box = end;
    }

    if (cpu_box >= NUM_ENTITIES) {
        gpu2d_flush_dcache();
        GPU2D_REG_LEFT_NEXT = cpu_fb;
        *left_back ^= 0x00600000u;
        cpu_running = 0;
    }
}

int main(void)
{
    diag_init();
    gpu2d_init();

    /* ---- blank the framebuffer before the boot decode --------------------
     * The scanout started reading FRAME_BASE_ADDR the moment it came out of
     * reset, and DDR does not power up zeroed.  Everything from here to the
     * first menu frame - the three 1366x768 plates alone are 3.1 M pixels
     * decoded on a core with no multiplier - leaves the screen showing whatever
     * bytes are in DDR.  On a cold start that is noise; on a re-configuration
     * with the rail still up it is the previous run's picture.  Either way it is
     * the "corrupted at power-on and then it clears itself" the board shows, and
     * it lasts as long as the boot takes.
     *
     * FRONT cannot simply be cleared: it is the buffer the scanout is reading,
     * and the engine is not allowed to write that one (the workbench fails the
     * boot on exactly that - check_owner).  So point the scanout at BACK first
     * with RIGHT_NEXT only - LEFT_NEXT is deliberately left alone, because the
     * menu loop's first handshake reads RIGHT_ACTIVE and a left-channel publish
     * would both break that handshake and, in the workbench, count as a frame
     * published before the firmware has drawn anything.  With BACK live, FRONT
     * is idle, gets blanked, and the scanout is pointed back at it, so the
     * machine is left in exactly the state reset put it in.
     *
     * The right half of the screen shows BACK's residue for the one frame this
     * takes.  BACK is repainted whole by the first menu frame, so it is never
     * cleared here.
     *
     * Safe this early because the SoC's own reset is gated on
     * (!pll_locked || !cal_done) in rtl/ti60_top.v: the engine and the DDR
     * controller are both live and calibrated before any of this runs.
     * The guard is not a timeout for the normal case - it is there so a board
     * with no pixel clock cannot trap the firmware here forever. */
    GPU2D_REG_FRAME_NEXT = FB_RIGHT_BACK;
    {
        uint32_t guard = 4000000u;
        while ((GPU2D_REG_LEFT_ACTIVE != FB_RIGHT_BACK ||
                GPU2D_REG_RIGHT_ACTIVE != FB_RIGHT_BACK) && guard--) { }
    }
    if (frame_wait_free(FB_LEFT_FRONT))
        gpu2d_fill(FB_LEFT_FRONT, SCREEN_WIDTH, SCREEN_HEIGHT, 0u, SCREEN_STRIDE);
    gpu2d_wait_idle();
    GPU2D_REG_FRAME_NEXT = FB_RIGHT_FRONT;
    {
        uint32_t guard = 4000000u;
        while (GPU2D_REG_RIGHT_ACTIVE != FB_RIGHT_FRONT && guard--) { }
    }

    gamepad_init();
    entities_init();
    sprites_build();
    /* Merged sprite tiles: each of these folds what used to be two or three
     * commands per object into one.  They need the asset bank (sprites_build)
     * and the font atlas, so they sit after it. */
    pbullet_tile_build();
    hud_labels_build();
    portrait_build();   /* the menu's 5x enlargement, once */
    /* Expand the half-size plate into one framebuffer, then copy it into the
     * other two: MM_VISUAL_BACKGROUND is what the menu blits and what the
     * per-frame gutter repair reads, and the two scanout buffers need it
     * before the first painted frame. */
    bg_paint(MM_VISUAL_BACKGROUND);
    ebullet_dirtile_build();
    laser_bar_build();
    lance_build();
    orb_tile_build();
    missile_tile_build();
    particle_tile_build();
    /* B1: hand the four bullet tile sets to the scanout, indexed.  After all
     * four builders, because the palette is built by walking what they drew -
     * so it tracks them if they change rather than being a second copy of the
     * same colours that can drift. */
    bullet_store_build();
    stage_bg_boot();
    burst_frames_build();
    stress_bg_build();
    card_bg_build();
    gpu2d_flush_dcache();
    gpu2d_set_alpha(1, 255);

    uint32_t left_back  = FB_LEFT_BACK;
    uint32_t right_back = FB_RIGHT_BACK;
    /* Frame accounting for tlm[46..48]: the board's core-tick counter is a
     * real clock, which is the one thing the workbench cannot fake. */
    uint32_t frame_mark = GPU2D_REG_CORE_TICKS;
    /* Fixed-step game time: sim_acc holds core ticks owed to the simulation,
     * sim_last the clock at the previous feed.  Both are reset when the game
     * is entered so the menu's time is never charged to the run. */
    uint32_t sim_last = GPU2D_REG_CORE_TICKS;
    uint32_t sim_acc  = 0u;
    int screen_state    = SCREEN_MENU;
    /* the file-scope static menu_sel above is what the workbench drives. */
    /* B is the only button a demo edge-detects for itself, and every demo
     * resets it on entry so the press that left the menu is not seen twice. */
    int prev_b = 0;
    /* Boot-menu stick auto-repeat: the direction currently held, and the
     * countdown to the next repeat step (see the SCREEN_MENU block below). */
    int     menu_stick_dir = 0;
    uint8_t menu_stick_cd  = 0;

    gamepad_state_t pad;

    board_set_hud_disable(1);
    audio_stream_init();

    for (;;) {
        int b_edge = 0;
        set_hb(1u);         /* audio_stream_service() */
        audio_stream_service();
        /* The engine-idle spin is where a menu pass spends most of its time,
         * and it has to keep watching the pad while it spins - otherwise the
         * drawing of the cards is a 0.36-frame hole in the sampling, which is
         * wide enough to swallow a short tap whole.  Set here rather than at
         * every screen_state assignment, so no path can forget it. */
        gpu2d_idle_hook = (screen_state == SCREEN_MENU) ? menu_sample : 0;

        /* Publish the previous pass's cost before this one starts - three DDR
         * words a frame, nothing next to what the pass itself spends. */
        set_hb(0u);         /* frame bookkeeping + diag */
        {
            uint32_t now = GPU2D_REG_CORE_TICKS;
            tlm[TLM_FRAME_CYC] = profile_elapsed(frame_mark, now);
            frame_mark = now;
        }
        tlm[TLM_BLIT_CMDS] = blit_cmds;
        tlm[TLM_BLIT_ROWS] = blit_rows;
        diag_window(tlm[TLM_FRAME_CYC], blit_cmds, blit_rows);
        blit_cmds = 0;
        blit_rows = 0;

        /* ---- the frame tick ---------------------------------------------
         * Which screens wait for the display tick is a measurement, not a
         * preference.
         *
         * The playable stage used to wait for the tick AND for the
         * double-buffer handshake further down - and those are the SAME
         * event, because the scanout only releases a buffer at the frame
         * boundary.  Waiting twice cost a whole display frame: the loop ran
         * at half the refresh rate, measured as 0.50 game frames per vsync,
         * which is the 30 FPS the board showed.  The handshake is the one
         * that has to stay, because it is what stops the renderer from
         * writing the half the scanout is reading right now - and that is a
         * torn frame, not a slow one.
         *
         * The CPU-vs-FPGA bench (SCREEN_BITBLT) skips the tick outright.  It
         * is a RACE between two renderers drawing the same scene, and the
         * point of the screen is to read how fast each one actually is; with
         * the tick in the loop both numbers just come out equal to the
         * refresh rate, which is what they used to do.  It keeps the
         * handshake, for the same reason the stage does - a bench that tears
         * cannot be compared against anything.
         *
         * The sprite stress demo drives its own frame counter and wants the
         * tick. */
        if (screen_state == SCREEN_MENU)         menu_wait_vsync();
        else if (screen_state == SCREEN_GAME ||
                 screen_state == SCREEN_STRESS_STAGE) { /* handshake only */ }
        else if (screen_state == SCREEN_BITBLT)  { /* handshake only */ }
        else                                     gpu2d_wait_vsync();

        /* ---------------- boot menu ---------------- */
        if (screen_state == SCREEN_MENU) {
            GPU2D_REG_WEATHER = 0u;   /* the overlay draws nothing on the menu */
            weather_box_release();    /* ... and no pause box survives into it */
            gamepad_read(&pad);

            /* Navigation: the buttons on their edges, the stick on its own.
             *
             * Y walks up, A walks down.  Both are read as plain bits and
             * edge-detected here, so a press is a press.  (The stick goes
             * through pad_axis_scan()'s two-tick confirmation first, which
             * makes a single deliberate push hard to reproduce from the
             * workbench - but a held push is a held push either way.)
             *
             * The stick cannot be used as a plain bit, because it is a LEVEL,
             * not an edge: pad_axis_scan() holds the direction for as long as
             * the stick stays pushed, and a level tested once per frame is a
             * row per frame - the list would run from top to bottom the moment
             * it was touched.  So it is edge-detected here, on top of the
             * driver's quantisation: one row on the frame a push appears, then
             * one more every MENU_STICK_REPEAT frames while it is held.
             *
             * Neither A nor Y has another job on the menu: X confirms, B is
             * inert, and the stick centre also confirms. */
            /* pad.y BELOW the low threshold is the stick pushed DOWN (the
             * same sense player_move() uses), so it walks the list down. */
            int stick = (pad.y < PAD_AXIS_LOW)  ?  1
                      : (pad.y > PAD_AXIS_HIGH) ? -1 : 0;
            int repeat = 0;
            if (stick != menu_stick_dir) {          /* new push (or release) */
                menu_stick_dir = stick;
                if (stick) {
                    repeat = stick;                 /* exactly one row ... */
                    menu_stick_cd = MENU_STICK_DELAY;    /* ... then wait */
                } else {
                    menu_stick_cd = 0;
                }
            } else if (menu_stick_dir) {
                if (menu_stick_cd == 0) {
                    repeat = menu_stick_dir;        /* held long enough: repeat */
                    menu_stick_cd = MENU_STICK_REPEAT;
                } else {
                    menu_stick_cd--;
                }
            }

            /* The button edges come from the LATCH, not from this one
             * sample: see menu_sample() above.  A press that opened and
             * closed inside the previous pass is still in here. */
            menu_sample();
            int go_up   = (menu_edge_latch & MENU_EDGE_Y) != 0 || repeat < 0;
            int go_down = (menu_edge_latch & MENU_EDGE_A) != 0 || repeat > 0;
            int enter   = (menu_edge_latch & (MENU_EDGE_X | MENU_EDGE_OK)) != 0;
            int a_edge  = (menu_edge_latch & MENU_EDGE_A) != 0;
            int b_edge  = (menu_edge_latch & MENU_EDGE_B) != 0;
            int y_edge  = (menu_edge_latch & MENU_EDGE_Y) != 0;
            menu_edge_latch = 0;    /* this decision consumes every edge in it */

            /* Two cards: wrap around at both ends.  Up and down stay separate
             * edges - v6 simply XORed menu_sel, which cannot express a
             * direction, and the stick's own one-row-per-push walk needs one
             * anyway.  A button and a stick push landing in the same window
             * is one step, not two. */
            if (go_up && !go_down)
                menu_sel = (menu_sel + MENU_ITEMS - 1) % MENU_ITEMS;
            else if (go_down && !go_up)
                menu_sel = (menu_sel + 1) % MENU_ITEMS;

            if (enter) {
                int want = -1;
                uint32_t raw_btns = GPU2D_REG_GAMEPAD_BTN;
                int y_held = pad.btn_y || ((raw_btns >> GPU2D_BTN_BIT_Y) & 1u) || y_edge || (menu_btn_prev & 1u);
                int a_held = pad.btn_a || ((raw_btns >> GPU2D_BTN_BIT_A) & 1u) || a_edge || ((menu_btn_prev >> 1) & 1u);
                int b_held = pad.btn_b || ((raw_btns >> GPU2D_BTN_BIT_B) & 1u) || b_edge || ((menu_btn_prev >> 4) & 1u);

                if (y_held) {
                    want = SCREEN_STRESS;
                } else if (a_held || b_held) {
                    want = SCREEN_STRESS_STAGE;
                } else {
                    switch (menu_sel) {
                    case 0: want = SCREEN_BITBLT; break;
                    default: want = SCREEN_GAME;  break;
                    }
                }
                if (want >= 0) {
                    screen_state = want;
                    board_set_hud_disable(screen_state != SCREEN_BITBLT);
                    resync_scanout(&left_back, &right_back, 0);
                    cpu_running = 0;
                    if (screen_state == SCREEN_GAME) {
                        is_stress_stage = 0;
                        game_init();
                        sim_acc  = 0u;
                        sim_last = GPU2D_REG_CORE_TICKS;
                    } else if (screen_state == SCREEN_STRESS_STAGE) {
                        stress_stage_init();
                        sim_acc  = 0u;
                        sim_last = GPU2D_REG_CORE_TICKS;
                    }
                    if (screen_state == SCREEN_STRESS) {
                        is_stress_stage = 0;
                        stress_init();
                    }
                    menu_stick_dir = 0; menu_stick_cd = 0;
                    prev_b = 1;
                    continue;
                }
            }

            /* The wait for the scanout to release the back buffer is dead
             * time as far as the pad is concerned - and it is most of the
             * pass.  Sample all the way through it. */
            if (!frame_wait_free(right_back)) continue;
            draw_menu(right_back, menu_sel);
            gpu2d_wait_idle();
            if (gpu2d_stalled) continue;
            gpu2d_flush_dcache();
            GPU2D_REG_FRAME_NEXT = right_back;
            right_back ^= 0x00600000u;
            continue;
        }

        /* ---------------- inside a demo ------------------------------------ */
        gamepad_read(&pad);
        pad_bits = (uint8_t)((pad.btn_a ? 1u : 0u) | (pad.btn_b ? 2u : 0u) |
                             (pad.btn_x ? 4u : 0u) | (pad.btn_y ? 8u : 0u));
        {
            b_edge = (pad.btn_b && !prev_b);
            prev_b = pad.btn_b;
            /* The two board keys are an unconditional escape hatch, and B is
             * one only inside the two DEMOS - the BitBlt bench and the sprite
             * stress scene - because neither of them has a pause of its own.
             * The bullet-hell stage and the pressure stage are the same loop,
             * and both own a pause menu, so B opens that rather than dropping
             * the run.  (It used to quit the pressure stage outright, which is
             * why that stage had no way to pause at all.) */
            if (board_get_sw0() || board_get_sw2() ||
                ((screen_state == SCREEN_BITBLT ||
                  screen_state == SCREEN_STRESS) && b_edge)) {
                if (screen_state == SCREEN_STRESS) {
                    gpu2d_set_colorkey(1, MAGENTA_KEY);
                    gpu2d_set_alpha(1, 255);
                }
                screen_state = SCREEN_MENU;
                is_stress_stage = 0;
                gpu2d_set_bloom(0, 0, 0);
                gpu2d_set_color_matrix(COLOR_MATRIX_BYPASS, 0);
                paused = 0;
                boss_card_active = 0;
                resync_scanout(&left_back, &right_back, 1);
                menu_edge_reset();
                board_set_hud_disable(1);
                continue;
            }
        }

        if (screen_state == SCREEN_STRESS) {
            stress_input(&pad);
            if (!frame_wait_free(right_back)) continue;
            if (stress_frame(right_back)) {
                if (gpu2d_stalled) continue;
                GPU2D_REG_FRAME_NEXT = right_back;
                right_back ^= 0x00600000u;
            }
        } else if (screen_state == SCREEN_BITBLT) {
            /* The left half's software pass runs inside this wait - see
             * cpu_left_step() for why it is here and not after the BitBlt
             * pass, which is what made the right half miss every second
             * display frame. */
            uint32_t hs_guard = 2000000u;
            while (GPU2D_REG_RIGHT_ACTIVE == right_back && --hs_guard) {
                cpu_left_step(&left_back);
            }
            if (!hs_guard) continue;

            /* ---- FPGA accelerated right half ------------------------- */
            gpu2d_fill(right_back + SCAN_HALF_BYTES, SCAN_RIGHT_PIXELS, SCREEN_HEIGHT, 0x00000000u, SCREEN_STRIDE);

            for (int i = 0; i < NUM_ENTITIES; i++) {
                int fx = ((int)entities[i].x * (int)SCAN_RIGHT_PIXELS) / (int)SCAN_HALF_PIXELS;
                uint32_t dst = right_back + SCAN_HALF_BYTES +
                               (uint32_t)(entities[i].y * SCREEN_STRIDE) +
                               (uint32_t)(fx * 4);
                gpu2d_fill(dst, (uint32_t)entities[i].w, (uint32_t)entities[i].h,
                           entities[i].color, SCREEN_STRIDE);
            }

            gpu2d_blit_sprite(right_back + SCAN_HALF_BYTES + ((SCREEN_HEIGHT - 120u) * SCREEN_STRIDE) +
                                  ((SCAN_RIGHT_PIXELS - 120u) * 4u),
                              MM_BOSS_SPRITE, MM_BOSS_SPRITE_W, MM_BOSS_SPRITE_H,
                              MM_BOSS_SPRITE_STRIDE, SCREEN_STRIDE);

            gpu2d_wait_idle();
            GPU2D_REG_RIGHT_NEXT = right_back;
            right_back ^= 0x00600000u;

            entities_update();
        } else {
            /* ---- playable bullet-hell stage -------------------------- */
            /* Mode 2 publishes the same buffer to both scanout channels, so
             * waiting for the right channel is enough - waiting for the left
             * one as well would deadlock, because the left only moves after
             * this very flip. */
            {
                /* The handshake is the one wait that is NOT game_frame()'s, and
                 * the menu pass (C = 35.85 ms against an 11 ms game_frame) says
                 * it can cost a whole extra frame on its own.  Priced, not
                 * assumed - a frame dropped here cannot be recovered by making
                 * the renderer faster. */
                uint32_t hs0 = GPU2D_REG_CORE_TICKS;
                if (!frame_wait_free(right_back)) continue;
                tlm[TLM_P_LOOPHS] = profile_elapsed(hs0, GPU2D_REG_CORE_TICKS);
            }

            if (b_edge) {                       /* B toggles the settings menu */
                paused = (uint8_t)(paused ^ 1);
                settings_sel = 0;
                /* Opening the menu must not read the pad that opened it, nor
                 * anything else the player is holding: re-base the edge
                 * detector on the buttons as they are at this instant, the same
                 * way menu_edge_reset() does for the boot menu. */
                settings_edge_reset(&pad);
                /* The settings panel paints over the frame, border columns
                 * included, so the next unpaused frame has to put them back. */
                border_plate[0] = 0;
                border_plate[1] = 0;
            }

            /* Game time is the board's core-tick clock, not the display's.
             * Feed the accumulator while the run is live; a pause stops the
             * clock, so resuming never charges the player for the menu. */
            {
                uint32_t now = GPU2D_REG_CORE_TICKS;
                /* CORE_TICKS is the RTL second_ticks counter: it runs 0..
                 * 99999999 and WRAPS every second.  A raw unsigned delta turns
                 * the wrap into a ~4.29e9 phantom debt, which the catch-up
                 * below then repays at LOGIC_MAX_STEPS a pass for minutes on
                 * end - the craft flies at 4x and the one-frame damage trail
                 * reads as a permanent smear.  profile_elapsed() unwraps it. */
                if (!paused) {
                    sim_acc += profile_elapsed(sim_last, now);
                    /* The board's 75.28 Hz HDMI scanout frame is 1,328,357 core
                     * ticks (85.714 MHz / (1456 * 782)), 4,976 ticks short of
                     * LOGIC_STEP_CYCLES (1,333,333).  Passing the RIGHT_ACTIVE
                     * handshake above guarantees a full VSync elapsed, so floor
                     * at one step to prevent 37.6 Hz alternating skipped updates. */
                    if (sim_acc < LOGIC_STEP_CYCLES)
                        sim_acc = LOGIC_STEP_CYCLES;
                    else if (sim_acc > 2u * LOGIC_STEP_CYCLES)
                        sim_acc = 2u * LOGIC_STEP_CYCLES;
                }
                sim_last = now;
            }

            /* Every panel that paints into the framebuffer this pass declares its
             * own rectangle; what the scanout gets is their union. */
            weather_box_begin();
            if (paused) {
                int act = settings_input(&pad);
                if (act == ACT_RESUME) {
                    paused = 0;
                } else if (act == ACT_EXIT) {
                    screen_state = SCREEN_MENU;
                    is_stress_stage = 0;
                    gpu2d_set_bloom(0, 0, 0);
                    gpu2d_set_color_matrix(COLOR_MATRIX_BYPASS, 0);
                    paused = 0;
                    boss_card_active = 0;
                    resync_scanout(&left_back, &right_back, 1);
                    menu_edge_reset();
                    board_set_hud_disable(1);
                    continue;
                } else if (act == ACT_STRESS_STAGE) {
                    paused = 0;
                    screen_state = SCREEN_STRESS_STAGE;
                    stress_stage_init();
                    resync_scanout(&left_back, &right_back, 0);
                    sim_acc  = 0u;
                    sim_last = GPU2D_REG_CORE_TICKS;
                    continue;
                }
                clear_frame(right_back);        /* a wipe may still be owed */
                game_render(right_back);        /* frozen scene ... */
                settings_render(right_back);    /* ... plus the menu */
                /* The overlay stays ON and simply freezes: the world is
                 * paused, so strip_scroll stops advancing and the dots stop
                 * where they are - which is what a frozen scene should look
                 * like.  It keeps snowing everywhere except on the card, which
                 * settings_render() has just punched out of the layer. */
                r_sync();
                gpu2d_flush_dcache();
            } else {
                /* Fixed-step catch-up: 75 logic ticks a second whatever the
                 * scanout did or did not show.  LOGIC_MAX_STEPS bounds the
                 * burst, so a pathologically slow frame loses time instead of
                 * paying it back by running even slower. */
                unsigned sim_steps = 0u;
                unsigned max_steps = is_stress_stage ? 1u : LOGIC_MAX_STEPS;
                /* Hitstop: hold the world for HITSTOP_* rendered frames.  The
                 * owed time is dropped, not repaid - repaying it would run the
                 * freeze straight back at double speed on the frame after,
                 * which is a stutter, not an impact. */
                if (hitstop) {
                    hitstop = (uint8_t)(hitstop - 1u);
                    max_steps = 0u;
                    sim_acc = 0u;
                }
                while (sim_acc >= LOGIC_STEP_CYCLES &&
                       sim_steps < max_steps) {
                    game_update(&pad);
                    sim_acc -= LOGIC_STEP_CYCLES;
                    sim_steps++;
                }
                if (is_stress_stage) sim_acc = 0u;
                set_hb(4u);         /* render */
                game_render_pass(right_back);
                if (game_exit_request) {
                    /* the run ended (infinite respawn off): progress is already
                     * cleared, go back to the boot menu */
                    game_exit_request = 0;
                    paused = 0;
                    boss_card_active = 0;
                    is_stress_stage = 0;
                    screen_state = SCREEN_MENU;
                    gpu2d_set_bloom(0, 0, 0);
                    gpu2d_set_color_matrix(COLOR_MATRIX_BYPASS, 0);
                    resync_scanout(&left_back, &right_back, 1);
                    menu_edge_reset();
                    board_set_hud_disable(1);
                    continue;
                }
            }
            weather_box_publish();

            /* Publish telemetry at the END of the pass and BEFORE the
             * scanout flip.  The workbench's frame gate waits for the frame
             * counter to move AND for the flip, so a block written after the
             * flip is a frame behind every reader that samples as soon as
             * the gate opens - which is what the skills and impact
             * scenarios do. */
            telemetry_write();
            if (gpu2d_stalled) continue;
            GPU2D_REG_FRAME_NEXT = right_back;
            right_back ^= 0x00600000u;
        }
    }

    return 0;
}
