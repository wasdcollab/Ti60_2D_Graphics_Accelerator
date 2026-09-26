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
 *
 *   0x0160_0000  mode-1 entity table   650 x 28 B   -> 0x0160_4718
 *   0x0160_5000  enemy pool             32 x 16 B   -> 0x0160_5200
 *   0x0160_5400  enemy bullet pool     192 x  8 B   -> 0x0160_5A00
 *   0x0160_5A00  item pool              16 x  8 B   -> 0x0160_5A80
 *   0x0160_5B00  telemetry block        52 x  4 B   -> 0x0160_5BD0
 *   0x0160_5C00  player sprite 32x32 stride 128     -> 0x0160_6C00
 *   0x0160_6C00  minion sprite 24x24 stride  96     -> 0x0160_7500
 *   0x0160_7500  minion sprite 24x24 stride  96     -> 0x0160_7E00
 *   0x0160_8000  boss sprite   64x64 stride 256     -> 0x0160_C000
 *   0x0160_C000  alpha aura    64x64 stride 256     -> 0x0161_0000
 *
 *   0x0162_0400  player bullet pool    128 x  8 B   -> 0x0162_0800
 *     The player's own pool outgrew the 64 slots it used to sit in between
 *     the enemy pool and the item pool.  A maxed-out FAN shot puts ~90 shots
 *     in the air at once, and alloc_bullet() hands out slots from the front,
 *     so the shots on the right half of the fan were the ones that vanished.
 *     Every other pool is addressed by name from the firmware and the
 *     workbench, so rather than shift all of them along, the pool moved into
 *     the free gap between the visual-FX block and the boss artwork.
 */
#ifndef MEMORY_MAP_H
#define MEMORY_MAP_H

/* ---- mode 1 ---------------------------------------------------------- */
#define MM_ENTITY_BASE          0x01600000UL   /* 650 entity records, 28 B each */

/* ---- bullet-hell pools ----------------------------------------------- */
#define MM_ENEMY_BASE           0x01605000UL   /* 32 x 16 B */
#define MM_PBULLET_BASE         0x01620400UL   /* 128 x 8 B, see the layout note above */
#define MM_EBULLET_BASE         0x01605400UL   /* 192 x 8 B */
#define MM_ITEM_BASE            0x01605A00UL   /* 16 x  8 B */
#define MM_TELEMETRY_BASE       0x01605B00UL   /* MM_TELEMETRY_WORDS x 32-bit */

#define MM_ENEMY_COUNT          32
#define MM_PBULLET_COUNT        128
#define MM_EBULLET_COUNT        192
#define MM_ITEM_COUNT           16
/* 64, not 52: the block starts at 0x0160_5B00 and the next surface starts at
 * 0x0160_5C00, so the twelve words from 0x5BD0 to 0x5C00 were already reserved
 * to nobody.  The frame-budget probe set at the bottom of this file uses them. */
#define MM_TELEMETRY_WORDS      64

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
#define MM_VISUAL_FX            0x01620000UL   /* 16 x 8 B, never used for collision */
#define MM_BOSS_CIRNO           0x01621000UL   /* 64x64, stride 256 */
#define MM_BOSS_DREAM           0x01625000UL   /* 64x64, stride 256 */
#define MM_LASER_GLOW           0x01660000UL   /* 16x768, stride 64 */
#define MM_SHADE_SPRITE         0x01631000UL   /* 24x24, stride 96 */
/* The menu/game plate is PAINTED by bg_paint() straight into this surface at
 * SCREEN_STRIDE, which is the pitch the scanout reads, so it needs the full
 * 768 x 8192 = 0x600000 bytes.  (Storing it as RLE instead cost 12452 encoded
 * bytes and overflowed the image region by 7768.) */
#define MM_VISUAL_BACKGROUND    0x03A00000UL   /* 1366x768 ARGB8888, painted */
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
 * Enemy bullet: socket + licensed 7x7 tile + core dot, one tile per shot
 * colour.  Stride 48 rather than 36 - the engine rejects strides that are
 * not a multiple of 16. */
#define MM_EBULLET_TILE        0x01632000UL
#define MM_EBULLET_TILE_W      9
/* STRIDE is a BYTE count: it is what r_blit() takes, and the engine requires
 * a multiple of 16.  Anyone indexing a uint32_t pointer with it must divide by
 * four first - ebullet_dirtile_build() did not, and every composed tile came
 * out as garbage four rows out of place. */
#define MM_EBULLET_TILE_STRIDE 48
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
 * y+22, both at x+1.  One tile per shot colour. */
#define MM_PBULLET_TILE        0x01633000UL
#define MM_PBULLET_TILE_W      7
#define MM_PBULLET_TILE_H      26
#define MM_PBULLET_TILE_STRIDE 32      /* BYTES: 7 px -> 28 B rounded to 16 */
#define MM_PBULLET_TILE_BYTES  (MM_PBULLET_TILE_STRIDE * MM_PBULLET_TILE_H)
#define MM_PBULLET_TILE_COUNT  8

/* Enemy shot: the same 9x9 socket tile, but one copy per (colour, direction).
 * The 2x2 speck enemy_bullet_render() FILLed at (x - vx, y - vy) is baked in,
 * so the tile is a function of the shot's colour AND its heading.  Keeping the
 * 9x9 footprint (instead of growing it to hold the speck at full offset) is
 * deliberate: a grown tile would reach two pixels into the HUD gutter at the
 * left edge of the playfield, and nothing repaints the gutter afterwards, so
 * the speck is CLAMPED inside the tile instead.  It is a 2x2 dark dot whose
 * whole job is to show which way the shot is going. */
#define MM_EBULLET_DIRTILE        0x01635000UL
#define MM_EBULLET_DIRTILE_W      9
#define MM_EBULLET_DIRTILE_STRIDE 48   /* BYTES, as above */
#define MM_EBULLET_DIRTILE_BYTES  (MM_EBULLET_DIRTILE_STRIDE * MM_EBULLET_DIRTILE_W)
#define MM_EBULLET_DIRTILE_DIRS   16
#define MM_EBULLET_DIRTILE_COUNT  (8 * MM_EBULLET_DIRTILE_DIRS)

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
#define MM_ORB_TILE             0x033F5000UL
#define MM_ORB_TILE_W           16
#define MM_ORB_TILE_H           16
#define MM_ORB_TILE_STRIDE      64
#define MM_ORB_TILE_COUNT       8
#define MM_ORB_TILE_BYTES       (MM_ORB_TILE_STRIDE * MM_ORB_TILE_H)

/* Combat FX particle tiles (OP_ADD saturated sparks, graze dust, motes) */
#define MM_PARTICLE_TILE        0x033F7000UL
#define MM_PARTICLE_TILE_W      8
#define MM_PARTICLE_TILE_H      8
#define MM_PARTICLE_TILE_STRIDE 32
#define MM_PARTICLE_TILE_COUNT  4
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

#define TLM_MAGIC_VAL 0x544C4D32UL   /* "TLM2" */

#endif /* MEMORY_MAP_H */
