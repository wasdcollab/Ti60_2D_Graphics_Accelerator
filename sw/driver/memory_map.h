/**
 * @file memory_map.h
 * @brief Single source of truth for every DDR scratch address the firmware uses.
 *
 * The legacy game tables use 64 KiB at 0x0160_0000; the display-only art and
 * font bank extends to 0x01C2_2000 within DDR. The complete layout is
 * shared with:
 *
 *   * simulator/test_runner.py   (reads pools and the telemetry block)
 *   * simulator/rv32i_soc_vm.py  (bounds checks on BitBlt destinations)
 *   * the tools/ scripts        (vector generation uses the SRC/DST bases)
 *
 * Keeping the addresses here stops the "hand written addresses collided"
 * class of bug that the previous version had to work around - and it did not
 * stop it: measured on 2026-09-22, MM_REIMU_TILT_L/R, MM_BURST_FRAME and
 * MM_LASER_BAR all sat inside MM_STRIP_LAYER, which is (re)built the first time
 * a stage is entered and therefore wiped all three.  The two leaning craft
 * poses (the craft vanishes while the stick is pushed), every impact burst and
 * every boss laser column were reading the parallax layer's pixels.
 *
 * The ranges below are disjoint.  tools/check_ddr_layout.py re-derives every
 * one of them from this file and the drawing code, and fails the build if two
 * of them overlap again:
 *
 *   0x01D0_0000  MM_STAGE_BG          0x1200000  three 1366x768 stage plates
 *   0x02F0_0000  MM_STAGE_STRIP       0x0018000  32x768 weather tile @128
 *   0x02F2_0000  MM_STAGE_ALT         0x0030000  ash / mote repaints
 *   0x02F6_0000  MM_WEATHER_RESTORE_CACHE 0x2B0000  four plate/phase caches
 *   0x0328_0000  MM_REIMU_TILT_L      0x0002400  sheared walk-lean pose
 *   0x0328_2400  MM_REIMU_TILT_R      0x0002400  ... and its mirror
 *   0x0329_0000  MM_BURST_FRAME       0x126000   24 impact frames, 112x112
 *   0x033C_0000  MM_LASER_BAR         0x0016800  three 16x480 glow bars
 *   0x033E_0000  MM_LANCE             0x0004800  eight 24x24 shafts
 *   0x0340_0000  MM_CARD_BG           0x0600000  the spell card's own sky
 *   0x03A0_0000  MM_VISUAL_BACKGROUND 0x0600000  menu / game backdrop
 *   0x0400_0000  MM_STRESS_BG         0x0600000  procedural snow-capped volcano plate
 *
 *   0x0480_0000  MM_BUCKET_TABLE      0x018000   96 groups x 128 x 4 B, B1
 *   0x048C_0000  MM_BULLET_WORK       0x001000   palette + lookup, boot only
 *
 *     The bucket table is the one surface the scanout READS that the firmware
 *     writes: one entry per (bullet, GROUP of scanlines it covers), appended in
 *     draw order, so the last entry covering a pixel is the one that should win.
 *     48 KB per table, or 2.2% of one frame's scanout traffic (4.32 MB).  The
 *     bullet state used to be expanded a thousand-fold into the framebuffer
 *     instead, and the backdrop repair then had to put back every tile that
 *     expansion damaged.
 *
 *     The row unit is a group of MM_BUCKET_GROUP_ROWS scanlines, not one
 *     scanline - see the definition below for why.  The tail of the reserved
 *     run (0x0481_8000 .. 0x048C_0000) is unused now; MM_BULLET_WORK and
 *     MM_BUCKET_USED keep the addresses the tools and the workbench know them
 *     by.
 *
 *     It sits past MM_STRESS_BG because nothing else is out there: every other
 *     surface packs into the first 70 MB of a 256 MB part.
 *
 *   0x0160_0000  mode-1 entity table   650 x 28 B   -> 0x0160_4718
 *   0x0160_5000  enemy pool             32 x 16 B   -> 0x0160_5200
 *   0x0160_5400  enemy bullet pool     512 x  8 B   -> 0x0160_6400  (MOVED, see below)
 *   0x0160_5A00  item pool              16 x  8 B   -> 0x0160_5A80
 *   0x0160_5B00  telemetry block        64 x  4 B   -> 0x0160_5C00
 *   0x0160_5C00  player sprite 32x32 stride 128     -> 0x0160_6C00
 *   0x0160_6C00  minion sprite 24x24 stride  96     -> 0x0160_7500
 *   0x0160_7500  minion sprite 24x24 stride  96     -> 0x0160_7E00
 *   0x0160_8000  boss sprite   64x64 stride 256     -> 0x0160_C000
 *   0x0160_C000  alpha aura    64x64 stride 256     -> 0x0161_0000
 *
 *   0x0162_0000  player bullet pool    512 x  8 B   -> 0x0162_1000
 *     The player's own pool outgrew the 64 slots it used to sit in between
 *     the enemy pool and the item pool.  A maxed-out FAN shot puts ~90 shots
 *     in the air at once, and alloc_bullet() hands out slots from the front,
 *     so the shots on the right half of the fan were the ones that vanished.
 *     Every other pool is addressed by name from the firmware and the
 *     workbench, so rather than shift all of them along, the pool moved into
 *     the free gap between the visual-FX block and the boss artwork.
 *
 *   0x0166_0C00  enemy bullet pool     512 x  8 B   -> 0x0167_0C00
 *
 *     Both pools are 512 slots now, and the enemy pool could not stay where it
 *     was.  512 x 8 = 0x1000, and the run it sat in is 0x600 long: growing it
 *     in place would have run enemy shots through MM_ITEM_BASE (0x0160_5A00),
 *     MM_TELEMETRY_BASE (0x0160_5B00) and the first 0x800 bytes of
 *     MM_PLAYER_SPRITE (0x0160_5C00) - the telemetry the workbench reads every
 *     frame, and the craft's own artwork.  The pool is cleared at boot and the
 *     sprite is built at boot, so the overlap is a real one, not a theoretical
 *     one: one of the two would have eaten the other.
 *
 *     It moved into the free run that starts where the last bullet tile ends:
 *     MM_EBULLET_DIRTILE is the sixteen 13x13 heading tiles at 0x0167_2000,
 *     0x3400 bytes, so it ends at 0x0167_5400 - and MM_LASER_GLOW is only
 *     0x0166_0000 .. 0x0166_C000 of the 0x0166_0000 block it owns (its table
 *     size is 16 x 768 pixels at a 64-byte pitch, i.e. 0xC000 and not the
 *     0xC00 the stride times height reads as).  So 0x0167_5400 .. 0x0167_9400
 *     sits between the tile bank and MM_EBULLET_TILE's own directory with
 *     nothing else in it.  Everything else in this file keeps its address,
 *     which is the point: the item pool, the telemetry block, the sprites and
 *     the bucket tables all stay where the tools that read them by name
 *     expect.
 *
 *     The player pool takes the page 0x0162_0000 .. 0x0162_1000 and ends
 *     exactly where MM_BOSS_CIRNO begins, so it cost one neighbour rather than
 *     a chain of them: MM_VISUAL_FX, the 16 x 8 B combat-FX array.  That one
 *     moves 0x7000 bytes up to 0x0161_9000, which is the free run between the
 *     last walk pose (0x0161_9000) and the player pool - nothing else is in
 *     there, and the array is indexed by name from main.c and from the
 *     workbench, so the move is a one-line change in each.
 */
#ifndef MEMORY_MAP_H
#define MEMORY_MAP_H

/* CPU-owned BGM store; never read by a new AXI master. */
#define MM_BGM_PCM      0x05000000u
#define MM_BGM_CAPACITY 0x00800000u

/* ---- mode 1 ---------------------------------------------------------- */
#define MM_ENTITY_BASE          0x01600000UL   /* 650 entity records, 28 B each */

/* ---- bullet-hell pools ----------------------------------------------- */
#define MM_ENEMY_BASE           0x04900000UL   /* 75 x 16 B */
#define MM_PBULLET_BASE         0x01620000UL   /* 512 x 8 B -> 0x0162_1000, see the layout note above */
#define MM_EBULLET_BASE         0x01675400UL
#define MM_EBULLET_ACTIVE_BASE  (MM_EBULLET_BASE + MM_EBULLET_COUNT * 8UL)
#define EB_CAND_LIST_BASE       (MM_EBULLET_ACTIVE_BASE + (MM_EBULLET_COUNT - 512UL) * 2UL)
#define MM_ITEM_BASE            0x01605A00UL   /* 16 x  8 B */
#define MM_TELEMETRY_BASE       0x01605B00UL   /* MM_TELEMETRY_WORDS x 32-bit */

#define MM_ENEMY_COUNT          75
#define MM_PBULLET_COUNT        512
/* 30720 records. The coprocessor front run is COUNT-128 and the last 128 slots
 * are the orb tail. The stress stage's Y/A control steps up to 30000, inside
 * that front run. APB 0x120 carries this count in 15 bits: [28:16] =
 * count[12:0], [15:14] = count[14:13]. */
#define MM_EBULLET_COUNT        30720
#define MM_ITEM_COUNT           16
/* 64, not 52: the block starts at 0x0160_5B00 and the next surface starts at
 * 0x0160_5C00, so the twelve words from 0x5BD0 to 0x5C00 were already reserved
 * to nobody.  The frame-budget probe set at the bottom of this file uses them. */
#define MM_TELEMETRY_WORDS      64

/* ---- Emissive Mask / Tag for Hardware Scanout Bloom (Task Card 10) ------- */
/* Written into the unused Alpha byte [31:24] during sprite/tile build time.  */
/* Fully transparent key remains MAGENTA_KEY (0x00FF00FF with Alpha = 0).     */
#define MM_EMISSIVE_ALPHA       0xFFu
#define MM_EMISSIVE_TAG         0xFF000000UL

/* ---- sprites (ARGB8888, magenta 0x00FF00FF = transparent key) -------- */
#define MM_PLAYER_SPRITE        0x01605C00UL   /* 32x32, stride 128 -> 0x0160_6C00 */
#define MM_PLAYER_SPRITE_W      32
#define MM_PLAYER_SPRITE_H      32
#define MM_PLAYER_SPRITE_STRIDE 128

#define MM_ENEMY_SPRITE         0x01606C00UL   /* 24x24, stride  96 -> 0x0160_7500 */
#define MM_ENEMY_SPRITE_W       24
#define MM_ENEMY_SPRITE_H       24
#define MM_ENEMY_SPRITE_STRIDE  96

#define MM_ENEMY2_SPRITE        0x01607500UL   /* 24x24, stride  96 -> 0x0160_7E00 */
#define MM_ENEMY2_SPRITE_W      24
#define MM_ENEMY2_SPRITE_H      24
#define MM_ENEMY2_SPRITE_STRIDE 96

#define MM_BOSS_SPRITE          0x01608000UL   /* 64x64, stride 256 -> 0x0160_C000 */
#define MM_BOSS_SPRITE_W        64
#define MM_BOSS_SPRITE_H        64
#define MM_BOSS_SPRITE_STRIDE   256

#define MM_AURA_SPRITE          0x0160C000UL   /* 64x64, stride 256 -> 0x0161_0000 */
#define MM_AURA_SPRITE_W        64
#define MM_AURA_SPRITE_H        64
#define MM_AURA_SPRITE_STRIDE   256

/* The walk frames sit at a fixed 0x2400 pitch.  The fourth is NOT stored:
 * the supplied sheet repeats frame 1 in that slot and the build only nudges
 * it up two rows, so reimu_bob_build() derives it at boot.  These addresses
 * must stay in step with the ones tools/build_visual_assets.py hands out. */
#define MM_REIMU_BASE           0x01610000UL
#define MM_REIMU_PITCH          0x00002400UL   /* 48x48 at a 192-byte pitch */
#define MM_REIMU_ROW            192UL
#define MM_REIMU_1              (MM_REIMU_BASE + MM_REIMU_PITCH)
#define MM_REIMU_3              (MM_REIMU_BASE + 3UL * MM_REIMU_PITCH)

/* Display-only bank: legacy game pools above are unchanged. Background ends
 * at 0x0338_4000; pause texture is separately allocated at 0x01900000. */
#define MM_VISUAL_FX            0x01619000UL   /* 16 x 8 B, never used for collision */
#define MM_DAMAGE_TILES         0x0161A000UL   /* 2 x 96 x 4 B = 768 B damage tracking buffer */
#define MM_BOSS_CIRNO           0x01621000UL   /* 64x64, stride 256 */
#define MM_BOSS_DREAM           0x01625000UL   /* 64x64, stride 256 */
#define MM_LASER_GLOW           0x01660000UL   /* 16x768, stride 64 */
#define MM_SHADE_SPRITE         0x01631000UL   /* 24x24, stride 96 */
/* The menu/game plate is PAINTED by bg_paint() straight into this surface at
 * SCREEN_STRIDE, which is the pitch the scanout reads, so it needs the full
 * 768 x 8192 = 0x600000 bytes.  (Storing it as RLE instead cost 12452 encoded
 * bytes and overflowed the image region by 7768.) */
#define MM_VISUAL_BACKGROUND    0x03A00000UL   /* 1366x768 ARGB8888, painted */
/* Procedural snow-capped volcano backdrop for stress test stage (Task Card 11).
 * 1366x768 plate at SCREEN_STRIDE (8192 bytes pitch), 768 x 8192 = 0x600000 bytes.
 * Zero on-chip ROM cost, procedurally generated by stress_bg_build() at boot directly into DDR. */
#define MM_STRESS_BG            0x04000000UL
/* The menu's portrait: the player's 48x48 walk frame expanded 5x by
 * portrait_build() at boot.  BitBlt cannot scale, and building the enlargement
 * out of per-row copies at draw time does not work either - a 1-pixel-tall
 * COPY can only place a WHOLE source row, so five of them produce five copies
 * side by side rather than a 5x stretch (measured: the identical byte string
 * repeating at x = 1010/1058/1106/1154).  Expand once, blit once per frame.
 *   240 x 240 x 4 = 230400 = 0x38400 */
/* The menu's 240x240 portrait (portrait_build).  It sat at 0x01CB8000,
 * which is inside the surface ART_REIMU_HUD_LARGE decodes into (48x48 at
 * scale 3 = 144x144 from 0x01CB1000, ending at 0x01CC5400) - so boot-time
 * asset decoding painted bright pixels over the top 56 rows of the portrait,
 * which is what the white lines across the title screen's character were.
 * Moved past the stress block into the free run before the stage plates:
 *   0x01CC6000 + 240*240*4 = 0x01CFE400  <  MM_STAGE_BG 0x01D00000 */
#define MM_PORTRAIT             0x01CC6000UL   /* 240x240 ARGB8888, pitch 240 */
/* The display-only bank ends where the font table starts; there is no separate
 * MM_VISUAL_END any more - one address with two names invited the two to drift
 * apart, and nothing ever used the end marker. */
#define MM_FONT_TABLE           0x019B0000UL   /* six uint32_t atlas bases */
#define MM_FONT_ATLASES         0x01A00000UL   /* scales 1..6; end 0x01C22000 */

/* Stage backdrops and the parallax strip: decoded once at boot, then only
 * ever read.  Every one of these surfaces uses SCREEN_STRIDE (5120 B) as its
 * ROW PITCH, exactly like the framebuffer does, so a 640x600 plate occupies
 * 600 * 5120 = 0x2EE000 bytes - not 640*600*4, and certainly not the 0x47000
 * it used to claim.  With too small a stride the three plates overlap and
 * every stage renders as a splice of two or three different backdrops. */
#define MM_STAGE_BG           0x01D00000UL   /* 3 plates, 0x600000 bytes each */
#define MM_STAGE_BG_STRIDE    0x00600000UL   /* one 1366x768 plate: 768 rows x SCREEN_STRIDE */
/* The 32x600 parallax tile follows the last plate.  It is 32 COLUMNS wide,
 * so it is laid out at SB_STRIP_STRIDE (128) and not at the framebuffer pitch:
 * at SCREEN_STRIDE it claimed 0x600000 bytes for 0x18000 of data. */
#define MM_STAGE_STRIP        (MM_STAGE_BG + 3UL * MM_STAGE_BG_STRIDE)
#define MM_STAGE_STRIP_STRIDE (32UL * 4UL)
/* Repaints of that tile, one per stage after the first: 32 columns by 600 rows
 * at a 128-byte pitch instead of the framebuffer's 5120, so all three weathers
 * together cost 150 KiB of DDR instead of 7 MiB.  The firmware derives them at
 * boot (strip_variants_build) rather than storing three tiles. */
#define MM_STAGE_ALT          0x02F20000UL
#define MM_STAGE_ALT_BYTES    (32UL * 4UL * 768UL)
/* MM_STRIP_LAYER used to be named here: a 1088x736 copy of the 32-pixel
 * weather tile, blitted whole over the playfield once a frame.  Nothing blits
 * it any more - stage_strip_render() stamps the sparse dots directly - so the
 * NAME had been dead for a while while the ADDRESS it named stayed live and
 * belonged to MM_WEATHER_RESTORE_CACHE below.  Two names for one address is
 * exactly the layout bug this file's header lists twice, and
 * tools/check_ddr_layout.py never caught it because MM_STRIP_LAYER was not in
 * its size table.
 *
 * It matters because MM_WEATHER_RESTORE_CACHE is REBUILT every time the stage
 * changes: 2.7 MiB written straight over that range.  Reviving MM_STRIP_LAYER
 * at this address would hand the parallax layer a buffer that is silently
 * erased at every stage transition.  The name is retired; do not bring it back
 * without giving it an address of its own.
 *
 *   0x02F6_0000 .. 0x0321_0000  MM_WEATHER_RESTORE_CACHE
 *   0x0321_0000  MM_STAGE_RLE     0x0004000  the plates' RLE, copied from
 *                                              the bitstream at boot
 *   0x0328_0000                 MM_REIMU_TILT_L
 */
/* The two leaning player poses are the idle frame sheared by +-12 degrees; the
 * firmware derives them at boot (tilt_poses_build) instead of carrying 1570
 * bytes of RLE for two pictures it can produce itself.  48x48 at a 192-byte
 * row pitch = 9216 bytes each. */
#define MM_REIMU_TILT_L       0x03280000UL
#define MM_REIMU_TILT_R       0x03282400UL
#define MM_REIMU_TILT_BYTES   (48UL * 4UL * 48UL)
/* Composed-once surfaces.  Each one replaces a handful of FILL commands a
 * frame with a single COPY: the engine pays per command and per DRAM row,
 * and these shapes were paying both for a few dozen pixels.
 *
 * Enemy bullet: 13x13 high-visibility Touhou-style energy orb with pure white hot core
 * and multi-layer pseudo-alpha halo. Stride 64 (13 px -> 52 B rounded to 16). */
/* The eight-colour socket tiles that used to live here are GONE: nothing had
 * read them since the barrage moved to the scanout's direction tiles, and the
 * address was costing ~300 bytes of .text in an image with 100 free.  The name
 * and its range stay declared - check_ddr_layout.py requires every MM_ address
 * to have a size - but no code writes this surface any more. */
#define MM_EBULLET_TILE        0x01670000UL
#define MM_EBULLET_TILE_W      13
#define MM_EBULLET_TILE_STRIDE 64
#define MM_EBULLET_TILE_BYTES  (MM_EBULLET_TILE_STRIDE * MM_EBULLET_TILE_W)

/* ---- merged sprite tiles ------------------------------------------------
 *
 * The engine pays PER COMMAND and every command costs a full DDR round trip,
 * because bitblt_apb_regs only latches START while the engine is idle - so the
 * firmware waits for each one.  A 9x9 sprite moves 32 bytes in a round trip
 * that could have moved 3 KiB: 0.8% efficient.  With ~1000 commands in a busy
 * frame those round trips add up in front of a DDR bus that the backdrop and
 * the scanout have already filled, and THAT is what made the game drop frames
 * as soon as anything was shooting.
 *
 * The fix is to draw each moving object with ONE command instead of three, by
 * composing the whole thing at boot:
 *
 *   player shot  = bullet tile + its two trail segments      3 -> 1
 *   enemy shot   = socket tile + the 2x2 direction speck     2 -> 1
 *   HUD labels   = each static caption strung out as one run N -> 1
 *
 * Nothing is removed - every pixel each of these drew before is still drawn,
 * it just costs one round trip instead of three.
 * ---------------------------------------------------------------------- */

/* Player shot: the 7x7 tile at the top, then the two trail segments below it,
 * exactly where pbullet_render() used to FILL them: 2x12 at y+10 and 2x4 at
 * y+22, both at x+1.
 *
 * ONE tile, not eight.  The eight colours were the same shape with different
 * pixel VALUES (verified on the firmware's own data, scratch/recon_color_split.py),
 * so the colour is no longer stored here at all: the tile holds a ROLE number
 * per cell and the scanout picks the colour with role + hue*32 out of the
 * palette.  The hue rides in the bucket entry. */
#define MM_PBULLET_TILE        0x01633000UL
#define MM_PBULLET_TILE_W      7
#define MM_PBULLET_TILE_H      26
#define MM_PBULLET_TILE_STRIDE 8       /* BYTES: ONE BYTE A PIXEL, a shape ROLE */
#define MM_PBULLET_TILE_BYTES  (MM_PBULLET_TILE_STRIDE * MM_PBULLET_TILE_H)
#define MM_PBULLET_TILE_COUNT  1

/* The pressure stage's two wing missiles.  Until now they borrowed the player
 * shot's tile - same slot 16, same roles, same palette entries - and that is
 * exactly why they could not be given a blend of their own: the scanout picks
 * a bullet's blend from its palette ENTRY, and those entries are shared with
 * the fan shot by construction.
 *
 * Their own tile, then, and their own two roles (BROLE_MS_BODY / BROLE_MS_TRAIL
 * in main.c): the BODY is a multiply-alpha entry at 190 so the snowfield reads
 * through it, and the TRAIL is BPAL_ADD (254) so it adds.  One shape, two
 * blends, decided per pixel - which is what video_bullet_overlay.v's ADD_CODE
 * path was built for and has been waiting for since it landed.
 *
 * 13 wide (the fan shot is 7, the big orb 16) and 26 tall, the same height as
 * the player shot so spawn_pbullet_lockon()'s GAME_BOTTOM - 26 clamp still
 * holds.  One shape only, flying up: sixteen headings would be 6,656 bytes for
 * a shape whose silhouette is nearly symmetric about its own axis, unlike the
 * enemy rice bullet whose needle tip IS its heading.  It sits at 0x0163_4000
 * because the player-shot tile shrank to 208 bytes when it went one byte a
 * pixel, and MM_HUD_LABELS does not begin until 0x0164_3000. */
#define MM_MISSILE_TILE        0x01634000UL
#define MM_MISSILE_TILE_W      13
#define MM_MISSILE_TILE_H      26
#define MM_MISSILE_TILE_STRIDE 16      /* BYTES: one byte a pixel, a shape ROLE */
#define MM_MISSILE_TILE_BYTES  (MM_MISSILE_TILE_STRIDE * MM_MISSILE_TILE_H)
#define MM_MISSILE_TILE_COUNT  1

/* Enemy shot: 26x26 aerodynamic sharp directional rice/arrow bullet, one copy
 * per DIRECTION.  Sixteen tiles, not 8 x 16: the eight colours were pure
 * recolourings of the same shape, and the colour now comes from the hue page
 * the bucket entry names (see the player-shot note above).  Directions stay at
 * 16 because d and d+8 are NOT exact flips of each other on an integer grid -
 * measured at 13x13, only 1 of 8 pairs holds - so there is nothing to derive.
 *
 * TWICE THE EDGE, edge for edge, from the 13x13 it was.  The player reads a
 * bullet's size off its edge; doubling the AREA instead would have grown the
 * edge by only 41%, which reads as "slightly bigger" rather than "twice".
 * The shape arithmetic is the old one with every coordinate and every
 * threshold multiplied by two - see ebullet_dirtile_build().
 *
 * ONE BYTE A PIXEL, and that byte is a shape ROLE rather than an ARGB colour.
 * ebullet_dirtile_build() writes the role straight in, and the only reader -
 * bullet_store_tile() - was taking the low byte of an ARGB word all along; the
 * three bytes above it were never read by anything.
 *
 * That is what keeps this surface at its old 0x3400 bytes: 16 x 32 x 26 is
 * exactly what 16 x 64 x 13 was.  It matters here more than anywhere else
 * because the enemy bullet POOL starts at 0x0167_5400, immediately after this
 * range - an ARGB stride for a 26-wide tile (104 -> 112 B) would have run to
 * 0x0167_D600 and written over the pool's first 0x8200 bytes. */
#define MM_EBULLET_DIRTILE        0x01672000UL
#define MM_EBULLET_DIRTILE_W      26
#define MM_EBULLET_DIRTILE_H      26
#define MM_EBULLET_DIRTILE_STRIDE 32   /* BYTES: 26 px -> 32, a power of two */
#define MM_EBULLET_DIRTILE_BYTES  (MM_EBULLET_DIRTILE_STRIDE * MM_EBULLET_DIRTILE_H)
#define MM_EBULLET_DIRTILE_DIRS   16
#define MM_EBULLET_DIRTILE_COUNT  MM_EBULLET_DIRTILE_DIRS

/* HUD caption atlas: one 8-row strip per caption, 128 pixels wide so even
 * "VERTEX 1366x768" fits.  Row pitch 512 bytes (128 px), NOT SCREEN_STRIDE -
 * drawing into it with draw_text() would stride by 8192 and walk 128 KB past
 * the end of the surface, so the strided variant below exists for this. */
#define MM_HUD_LABELS          0x01643000UL
#define MM_HUD_LABELS_W        128
#define MM_HUD_LABELS_STRIDE   512
#define MM_HUD_LABELS_H        8
#define MM_HUD_LABEL_SLOTS     20
#define MM_HUD_LABELS_BYTES    (MM_HUD_LABELS_STRIDE * MM_HUD_LABELS_H * MM_HUD_LABEL_SLOTS)

/* Impact effect: 24 frames of the five-layer burst, 112x112, centred on the
 * particle.  112 and not 152 because the outer ring's radius is capped at
 * 48 (see burst_paint) - at 2 pixels across it reads the same and the frames
 * cost a third less DDR and a third fewer rows per copy. */
#define MM_BURST_FRAME         0x03290000UL
#define MM_BURST_FRAME_W       112
#define MM_BURST_FRAME_STRIDE  448
#define MM_BURST_FRAME_COUNT   24
#define MM_BURST_FRAME_BYTES   (MM_BURST_FRAME_STRIDE * MM_BURST_FRAME_W)

/* The boss spell card's laser columns, one 16x768 bar per brightness band. */
#define MM_LASER_BAR           0x033C0000UL
#define MM_LASER_BAR_W         16
#define MM_LASER_BAR_H         768
#define MM_LASER_BAR_STRIDE    64
#define MM_LASER_BAR_COUNT     3
#define MM_LASER_BAR_BYTES     (MM_LASER_BAR_STRIDE * MM_LASER_BAR_H)

/* The spell card's own sky (planning doc L3: the card must not reuse one of
 * the three stage plates).  A fourth stored plate is about 4 KB of RLE and
 * the firmware has under 2 KB free, so the plate is COMPUTED at boot by
 * card_bg_build() instead - same 640x600 at SCREEN_STRIDE, no asset bytes.
 * The card sky is a 1366x768 plate at SCREEN_STRIDE, 0x600000 bytes, and it
 * sits past the laser bars and the lance bank with a clear gap. */
#define MM_CARD_BG              0x03400000UL

/* Four plates x 32 scroll phases x 256 dot rows x 43 repeated pixels.
 * The 5.64 MB cache ends below the 64 MB DDR aperture.  Its reads are linear
 * during play, avoiding thousands of random plate reads per frame. */
#define MM_WEATHER_RESTORE_CACHE 0x02F60000UL
#define MM_WEATHER_RESTORE_BYTES (2UL * 32UL * 256UL * 43UL * 4UL)

/* Boot-time staging buffer for the three stage plates' RLE streams.
 *
 * Those 12,313 bytes used to be .rodata: part of the firmware image inside the
 * CPU's own 64 KiB on-chip RAM, which had 80 bytes free.  They now ship in the
 * bitstream's asset ROM (rtl/bitblt/bg_rle.hex, read back through the BitBlt
 * APB window at 0x80/0x84) and are copied here once at boot, so the decoder
 * reads them out of DDR and the CPU's RAM is left for code.  This range was
 * already a documented hole between the weather cache and the leaning poses;
 * it is claimed now instead of being described as free. */
#define MM_STAGE_RLE          0x03210000UL
#define MM_STAGE_RLE_BYTES    0x00004000UL   /* 16 KiB reserved, 12,313 B used */

/* 8.5's shaft, one 24x24 facing per compass point, composed at boot. */
#define MM_LANCE                0x033F0000UL
#define MM_LANCE_W              24
#define MM_LANCE_STRIDE         96
#define MM_LANCE_COUNT          8
#define MM_LANCE_BYTES          (MM_LANCE_STRIDE * MM_LANCE_W)

/* High-tier Big Orb (大玉) tiles for spell cards (OP_ADD saturated additive blend) */
/* ---- B1: the scanout's bullet overlay --------------------------------- */
/* One bucket per GROUP of scanlines: MM_BUCKET_SLOTS four-byte entries,
 * appended in draw order.  The scanout fetches one group's bucket, so the
 * stride stays MM_BUCKET_SLOTS * 4 and dma_bucket_prefetch.v reads it as two
 * bursts of 16 beats.
 *
 * WHY THE ROW UNIT IS A GROUP AND NOT A SCANLINE.  A bullet occupies 13 or 26
 * consecutive scanlines, and until now the firmware appended one entry per
 * scanline it covered.  Every one of those stores landed 512 bytes after the
 * previous one, and the part's D-cache is 4 KB direct mapped (see
 * ip/soc/settings.json: DCacheSize 4096, DCACHEWAY 1), i.e. 128 lines of 32
 * bytes.  A 512-byte stride walks 16 lines per row, so row r only ever maps
 * onto line (r mod 8) * 16 - eight consecutive rows fill the whole cache and
 * the ninth evicts the first.  Measured on the pressure stage: 11,755 stores a
 * frame at 576 bullets with the player firing, essentially every one of them a
 * miss that has to fetch its line from DDR before it can be written.  That is
 * the 600-bullet frame drop.
 *
 * So the entry now carries the tile row of the GROUP'S FIRST SCANLINE instead
 * of the row it sits on, and the scanout adds the position within the group
 * back on:
 *
 *     real tile row = stored trow_base + (y mod MM_BUCKET_GROUP_ROWS)
 *
 * which is identically y - (the bullet's tile top), so nothing about the
 * picture changes.  What changes is that a bullet now appends to ONE bucket per
 * group it crosses - two or three of them instead of thirteen or twenty-six.
 * The group size is a power of two because the scanout gets the offset for
 * free from the low bits of y. */
#define MM_BUCKET_TABLE         0x04800000UL
#define MM_BUCKET_SLOTS         1024
/* Literal, not MM_BUCKET_SLOTS * 4: tools/check_ddr_layout.py and the
 * workbench's mm_value() read these by name and only understand a plain
 * constant.  The two must agree - dma_bucket_prefetch.v reads a bucket as two
 * bursts of 16 beats, which is exactly 512 bytes. */
#define MM_BUCKET_STRIDE        4096
/* Scanlines sharing one bucket.  Must match BUCKET_GROUP_ROWS in
 * rtl/dma/dma_bucket_prefetch.v and BUCKET_GROUP_ROWS in
 * rtl/display_engine/2_layer_generators/video_bullet_overlay.v - the scanout's
 * y[2:0] offset is this number's log2.  Measured peak occupancy at 960
 * bullets: 72 entries in the busiest scanline, so a bucket still has to carry
 * all 128 slots - the group is what shrank, not the bucket. */
#define MM_BUCKET_GROUP_ROWS    8
#define MM_BUCKET_ROWS          (768 / MM_BUCKET_GROUP_ROWS)   /* 96 buckets per table */
/* Boot-time workspace for building the palette: a 256-entry colour table, a
 * 256-slot open-addressed lookup, and the packed store on its way to the APB.
 * In DDR rather than bss on purpose - the part has 200 MB free and the firmware
 * has 4 KB. */
/* AFTER both bucket tables, not after one of them: the tables are double
 * buffered (96 x 512 x 2 = 0x18000).  This used to sit at 0x0483_C000 - the
 * start of the second table - where the boot clear zeroed it and took the
 * palette lookup's empty-slot marker with it.  With no 0xFFFFFFFF left in the
 * probe table, bpal_index() never finds a free slot and spins forever.
 *
 * The address stays where it was even though the tables now end at 0x04818000
 * and leave a gap: tools and the workbench read MM_BULLET_WORK by name, and
 * moving it closer would only save address space nobody is short of. */
#define MM_BULLET_WORK          0x048C0000UL
#define MM_BULLET_WORK_BYTES    0x00001000UL

/* One byte per bucket per table: how many slots that table's last write put in
 * that bucket.  bucket_reset() clears the cells the PREVIOUS write left behind,
 * and "the previous write" means the previous write OF THAT TABLE - the two
 * tables are written on alternate frames, so a single shared array hands table
 * A the write depth of table B.  The cells that miss the clear keep a nonzero
 * width, the scanout counts them as live entries, and they are never recorded
 * in the depth - so they accumulate frame after frame until the row's 128 slots
 * are full and real bullets start being dropped.
 *
 * In DDR rather than bss: 192 bytes now, but it was 1536 when the tables were
 * per-scanline, and it has always lived here rather than in the 64 KiB image
 * that has under 2 KB left.  The address is the first free run after
 * MM_BULLET_WORK. */
#define MM_BUCKET_USED          0x048C1000UL
#define MM_BUCKET_USED_BYTES    (4UL * MM_BUCKET_ROWS)
#define MM_BUCKET_COUNT_DEBUG  0x048C1200UL
#define MM_BUCKET_COUNT_DEBUG_BYTES 192UL
#define MM_PARTICLE_STATE       0x048C1300UL
#define MM_PARTICLE_STATE_BYTES 384UL
#define MM_POPUP_STATE          0x048C1480UL
#define MM_POPUP_STATE_BYTES    64UL
#define MM_PICK_MASK            0x048C14C0UL
#define MM_PICK_MASK_BYTES      120UL
#define MM_RUNTIME_WORK         0x048C6700UL
#define MM_RUNTIME_WORK_BYTES   320UL
/* CPU-owned special-shot indices: lances, Q4 trajectories and timed lasers.
 * Kept after the Q4 auxiliary arena; a full index falls back to a pool scan. */
#define MM_LANCE_INDEX          0x04940000UL
#define MM_LANCE_INDEX_MAX      4096
#define MM_LANCE_INDEX_BYTES    (MM_LANCE_INDEX_MAX * 2UL)

#define MM_ORB_TILE             0x033F5000UL
#define MM_ORB_TILE_W           16
#define MM_ORB_TILE_H           16
#define MM_ORB_TILE_STRIDE      16   /* BYTES: one byte a pixel, a shape ROLE */
#define MM_ORB_TILE_COUNT       1
#define MM_ORB_TILE_BYTES       (MM_ORB_TILE_STRIDE * MM_ORB_TILE_H)

/* Combat FX particle tiles (OP_ADD saturated sparks, graze dust, motes) */
#define MM_PARTICLE_TILE        0x033F7000UL
#define MM_PARTICLE_TILE_W      8
#define MM_PARTICLE_TILE_H      8
#define MM_PARTICLE_TILE_STRIDE 32
#define MM_PARTICLE_TILE_COUNT  8
#define MM_PARTICLE_TILE_BYTES  (MM_PARTICLE_TILE_STRIDE * MM_PARTICLE_TILE_H)

#define MM_STRESS_SPRITE        0x01C22000UL   /* 64x64, stride 256 + guard beat */
#define MM_STRESS_PANEL         0x01C27000UL   /* 1024x128, stride 4096 */
#define MM_STRESS_TELEMETRY     0x01CA7000UL   /* 14 uint32_t words */

/* Telemetry block: a 32-bit word per field, written once per game frame.
 * It is what the simulation workbench reads for positions and counters (far
 * cheaper and far less brittle than scanning the framebuffer), and it doubles
 * as a hardware debug window over JTAG. */
#define TLM_MAGIC     0u
#define TLM_FRAMES    1u
#define TLM_PLAYER_X  2u
#define TLM_PLAYER_Y  3u
#define TLM_LIVES     4u
#define TLM_SCORE     5u
#define TLM_WEAPON    6u
#define TLM_ATK       7u
#define TLM_FIRE_CD   8u
#define TLM_KILLS     9u
#define TLM_ENEMIES   10u
#define TLM_PBULLETS  11u
#define TLM_EBULLETS  12u
#define TLM_ITEMS     13u
#define TLM_TAKEN     14u
#define TLM_BOSS_ST   15u
#define TLM_BOSS_HP   16u
#define TLM_BOSS_PAT  17u
#define TLM_PAT_CHG   18u
#define TLM_SUMMONS   19u
#define TLM_HITS      20u
#define TLM_GAMEOVER  21u
#define TLM_PAUSED    22u
#define TLM_HWACCEL   23u
#define TLM_INFRESPAWN 24u
#define TLM_SETTINGS  25u
#define TLM_PADBITS   26u
#define TLM_STAGE     27u
#define TLM_BOSS_X    28u
#define TLM_BOSS_Y    29u
#define TLM_DIALOG    30u
#define TLM_SLOW      31u
#define TLM_JAM       32u
#define TLM_LASER_HITS 33u
#define TLM_INVULN    34u
#define TLM_WEAPON_LV 35u
#define TLM_STAGE_BG  36u
#define TLM_BOMB      37u
#define TLM_LASER     38u
/* Per-frame BitBlt cost for the board-side profiler.  tlm[40..45] already
 * carry the render segments; these answer the other half - what a whole frame
 * cost, and how much of it the engine owned.
 *
 * ROWS is the one that matters.  bitblit_stride_gen's row_done requires every
 * in-flight read AND write to clear, so it drains its pipelines once per row:
 * a 9x9 tile pays nine drains for 324 bytes, a 4x768 separator pays 768 for
 * 12 KiB.  Command count and byte count both hide that; rows does not. */
/* Phase timers.  These were already being written by profile_elapsed() and
 * nobody ever read them out: tlm[42]/[43]/[44]/[45] are live measurements of
 * where a frame's time actually goes, published in DDR and, until now, only
 * reachable by a JTAG debugger.  Reading stage1/stage2 out of the firmware
 * is what separates "the renderer is slow" from "the board was not drawing
 * at all", which is the one thing the frame counter alone cannot tell. */
#define TLM_T_STRIP    42u   /* game_render() TOTAL - despite the name  */
#define TLM_T_GFRAME   43u   /* game render pass total (update excluded) */
#define TLM_T_GRENDER  44u   /* game_render(): the BACKDROP only        */
#define TLM_T_SPARE    45u   /* reserved                                */
#define TLM_FRAME_CYC  46u   /* core clocks between two frame starts */
#define TLM_BLIT_CMDS  47u   /* BitBlt commands issued this frame    */
#define TLM_BLIT_ROWS  48u   /* sum of their rectangle heights       */

/* ---- frame-budget probe set ------------------------------------------
 * The J/K pair answered "what did the frame cost" but not "which half of it
 * was the engine".  K (TLM_T_GRENDER) stops measuring 51 lines into a 652-line
 * game_render() - it is written immediately after the backdrop blit and never
 * again - while the value that really holds the total, tlm[42], carries a
 * label that says "weather dots".  K is therefore the backdrop, and the
 * remaining 600 lines of the renderer have never had a probe on them at all.
 *
 * TLM_P_ENGWAIT is the one that decides the next change.  gpu2d_finish()
 * waits for the engine before every single command, so all of the engine's
 * serial time - the part a read/write-parallel engine would win back - lands
 * in that counter.  Compare it against TLM_T_GFRAME: if it owns most of the
 * frame, the fix is RTL; if it owns little, the fix is the frame loop and the
 * RTL work would buy nothing.
 */
#define TLM_P_ENGWAIT  49u   /* engine idle-wait cycles, whole frame    */
#define TLM_P_LOOPHS   50u   /* main loop: scanout handshake wait       */
#define TLM_P_FLUSH    51u   /* gpu2d_flush_dcache(), main path only    */
#define TLM_P_MAXJ     52u   /* worst frame: its game_frame() total     */
#define TLM_P_MAXG     53u   /* worst frame: its engine idle-wait total */
#define TLM_P_MAXR     54u   /* worst frame: its BitBlt row count       */
#define TLM_DAMAGE_ROWS 55u   /* damage_restore rows this frame          */
#define TLM_SPRITES     57u   /* actors, items, pooled shots and BOSS beams */
#define TLM_BUCKET_DROPS 58u  /* rejected scanline entries, not whole sprites */
#define TLM_BOSS_BEAMS   59u  /* warning/live scanout beams, one per descriptor */

#define TLM_MAGIC_VAL 0x544C4D32UL   /* "TLM2" */

#define MM_ENEMY_WORK 0x04901000UL
#define MM_ENEMY_WORK_BYTES (MM_ENEMY_COUNT * 4UL)
#define MM_BOSS1_CAST 0x04902000UL
#define MM_BOSS1_CAST_BYTES 16UL
#define MM_BULLET_FRAC 0x04944000UL
#define MM_BULLET_FRAC_BYTES MM_EBULLET_COUNT

#define MM_BOSS23_CAST 0x0490A000UL
#define MM_BOSS23_CAST_BYTES 0x1000UL
#define MM_ASSET_UNPACK 0x04910000UL
#define MM_ASSET_UNPACK_BYTES 0x8000UL
#define MM_BULLET_AUX 0x04920000UL
#define MM_BULLET_AUX_BYTES (MM_EBULLET_COUNT * 4UL)

#endif /* MEMORY_MAP_H */
