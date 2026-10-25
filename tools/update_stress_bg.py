#!/usr/bin/env python3
import sys

NEW_STRESS_C = r'''void stress_bg_build(void)
{
    /* Japanese Torii Sanctuary & Silk Aurora Curtains 3D Perspective Scene:
     * 1. Rigorous central perspective, low camera angle, foreground meadow & flagstone path,
     *    midground vermillion Japanese Myojin Torii gate, background deep midnight sky & mountain ridge.
     * 2. Grand ethereal silk aurora curtains: multi-layer emerald green core, lavender, cyan and soft pink fringes.
     * 3. Aged cinnabar vermillion Torii with cast iron clamps, dark patina, soft cold aurora rim lighting.
     * 4. S-curved weathered flagstone path with moss crevices, wet puddle reflections.
     * 5. Symmetrical twin stone lanterns (Toro) casting warm amber candlelight glow.
     * 6. Wild grass meadow with wind-tilted blades, glinting dewdrops, and low ground fog. */
    static const int8_t sin_lut[32] = {
         0,  6, 12, 17, 22, 26, 29, 31,
        32, 31, 29, 26, 22, 17, 12,  6,
         0, -6,-12,-17,-22,-26,-29,-31,
       -32,-31,-29,-26,-22,-17,-12, -6
    };

    volatile uint32_t *fb = (volatile uint32_t *)MM_STRESS_BG;

    /* Base pass: Sky, Aurora Curtains, Mountains, Ground Meadow & Flagstone Path */
    for (unsigned y = 0; y < SB_BG_H; y++) {
        volatile uint32_t *row = fb + (y * (SCREEN_STRIDE / 4u));
        if (y < 512u) {
            uint32_t sky_t = (y * 256u) / 512u;
            uint32_t base_r = 2u + ((6u * sky_t) >> 8);
            uint32_t base_g = 3u + ((12u * sky_t) >> 8);
            uint32_t base_b = 8u + ((28u * sky_t) >> 8);

            for (unsigned x = 0; x < SB_BG_W; x++) {
                uint32_t r = base_r, g = base_g, b = base_b;

                /* Translucent night clouds */
                int cloud_val = (int)sin_lut[(x >> 5) & 31u] + (int)sin_lut[((x >> 4) + (y >> 4)) & 31u];
                if (cloud_val > 8) {
                    uint32_t cw = ((uint32_t)(cloud_val - 8) * (512u - y)) >> 9;
                    r += (cw * 6u) >> 5;
                    g += (cw * 14u) >> 5;
                    b += (cw * 18u) >> 5;
                }

                /* Sparse twinkling stars */
                uint32_t h = (x * 1664525u + y * 1013904223u) ^ 0x20261025u;
                h ^= h >> 16;
                if ((h & 0xFFFu) == 0x111u) {
                    r = 220u; g = 240u; b = 255u;
                } else if ((h & 0x7FFu) == 0x333u) {
                    r = 110u; g = 160u; b = 220u;
                } else if ((h & 0x3FFu) == 0x255u) {
                    r = 55u;  g = 80u;  b = 135u;
                }

                /* Vertical ray flutter texture for aurora silk curtains */
                int ray_flutter = (int)(((x * 13u + (y >> 2)) & 15u) - 8u);

                /* Aurora Ribbon 1: Upper High-altitude Emerald Ribbon (y ~ 110) */
                int w1 = (int)sin_lut[(x >> 6) & 31u] + ((int)sin_lut[((x >> 4) + 6u) & 31u] >> 1);
                int d1 = (int)y - (110 + w1 + ray_flutter);
                if (d1 < 0) d1 = -d1;
                if (d1 < 50) {
                    uint32_t aw1 = (uint32_t)(50 - d1);
                    r += (aw1 * 10u) >> 6;
                    g += (aw1 * 48u) >> 6;
                    b += (aw1 * 36u) >> 6;
                    if (d1 < 10) {
                        g += (uint32_t)(10 - d1) * 3u;
                        b += (uint32_t)(10 - d1) * 2u;
                    }
                }

                /* Aurora Ribbon 2: Primary Folding Silk Curtain (y ~ 220) */
                int w2 = (int)sin_lut[((x >> 5) + 3u) & 31u] + ((int)sin_lut[(x >> 3) & 31u] >> 2);
                int d2 = (int)y - (220 + w2 + ray_flutter * 2);
                if (d2 < 0) d2 = -d2;
                if (d2 < 68) {
                    uint32_t aw2 = (uint32_t)(68 - d2);
                    r += (aw2 * 14u) >> 6;
                    g += (aw2 * 58u) >> 6;
                    b += (aw2 * 46u) >> 6;
                    if (d2 > 35) {
                        uint32_t fringe = (uint32_t)(d2 - 35);
                        r += (fringe * 28u) >> 5;
                        b += (fringe * 24u) >> 5;
                    }
                }

                /* Aurora Ribbon 3: Dreamy Lower Violet & Soft Pink Ribbon (y ~ 340) */
                int w3 = (int)sin_lut[((x >> 5) + 14u) & 31u];
                int d3 = (int)y - (340 + w3 + ray_flutter);
                if (d3 < 0) d3 = -d3;
                if (d3 < 54) {
                    uint32_t aw3 = (uint32_t)(54 - d3);
                    r += (aw3 * 40u) >> 6;
                    g += (aw3 * 16u) >> 6;
                    b += (aw3 * 50u) >> 6;
                }

                /* Distant Mountains Silhouette */
                int mtn_y = 494 + (((int)sin_lut[(x >> 4) & 31u] * 12 + (int)sin_lut[(x >> 3) & 31u] * 5) >> 6);
                if ((int)y >= mtn_y) {
                    r = 4u; g = 8u; b = 16u;
                    if ((int)y <= mtn_y + 1) {
                        r = 16u; g = 64u; b = 80u;
                    }
                }

                if (r > 255u) r = 255u;
                if (g > 255u) g = 255u;
                if (b > 255u) b = 255u;
                row[x] = (r << 16) | (g << 8) | b;
            }
        } else {
            /* Ground Perspective (y >= 512) */
            uint32_t dy = y - 512u;
            uint32_t z = 12000u / (dy + 14u);
            uint32_t path_hw = 65u + 300u / (z + 20u);
            int xw_path = (35 * (int)sin_lut[(z >> 2) & 31u]) >> 5;
            uint32_t aurora_ambient = (dy < 250u) ? ((250u - dy) * 18u) / 250u : 0u;
            int dy_l = (int)y - 540;
            int dy_l_sq = dy_l * dy_l;

            for (unsigned x = 0; x < SB_BG_W; x++) {
                int dx_c = (int)x - 683;
                int xw = ((dx_c * (int)z) * 182) >> 16;
                int dist_path = xw - xw_path;
                if (dist_path < 0) dist_path = -dist_path;

                /* Twin stone lanterns warm amber candlelight */
                int dx_l = (int)x - 485;
                int d2_l = dx_l * dx_l + dy_l_sq;
                int dx_r = (int)x - 881;
                int d2_r = dx_r * dx_r + dy_l_sq;
                uint32_t warm_glow = 0u;
                if (d2_l < 14000) warm_glow += (uint32_t)(14000 - d2_l) / 120u;
                if (d2_r < 14000) warm_glow += (uint32_t)(14000 - d2_r) / 120u;

                uint32_t r, g, b;
                if ((uint32_t)dist_path < path_hw) {
                    /* Weathered Flagstone Path */
                    int xw_lut = (xw < 0 ? -xw : xw);
                    uint32_t z_slab = (z + (uint32_t)(((int)sin_lut[(xw_lut >> 2) & 31u] * 5) >> 5)) % 80u;
                    uint32_t x_slab = ((uint32_t)dist_path + (uint32_t)(((int)sin_lut[((z >> 1) + 8u) & 31u] * 4) >> 5)) % 70u;
                    if (z_slab < 5u || x_slab < 5u) {
                        r = 4u  + (warm_glow >> 2);
                        g = 14u + ((warm_glow * 9u) >> 5) + ((aurora_ambient * 4u) >> 3);
                        b = 10u + ((aurora_ambient * 3u) >> 3);
                    } else {
                        r = 18u + ((warm_glow * 29u) >> 5);
                        g = 25u + ((warm_glow * 3u) >> 2) + ((aurora_ambient * 6u) >> 3);
                        b = 34u + ((aurora_ambient * 5u) >> 2);
                        if (z_slab == 5u || x_slab == 5u) {
                            r += 10u; g += 20u; b += 24u;
                        }
                        if (z_slab > 20u && z_slab < 50u && x_slab > 15u && x_slab < 45u) {
                            g += 12u; b += 16u;
                        }
                    }
                } else {
                    /* Wild Grassland Meadow with Emerald tone */
                    uint32_t blade_freq = (x * 37u + y * 71u) ^ 0x5DEECE66u;
                    int blade_tilt = (int)(blade_freq & 7u) - 3;
                    int blade_hatch = (((int)x + blade_tilt) & 3) == 0;
                    r = 6u  + ((warm_glow * 19u) >> 5);
                    g = 20u + (warm_glow >> 1) + (blade_hatch ? 10u : 0u) + ((aurora_ambient * 7u) >> 3);
                    b = 14u + ((aurora_ambient * 10u) >> 4) + (blade_hatch ? 8u : 0u);
                    if (((blade_freq >> 3) & 63u) == 7u && dy > 30u) {
                        r += 50u; g += 160u; b += 180u;
                    }
                }

                /* Low-lying ground fog */
                if (dy < 60u) {
                    uint32_t fog = (dy < 20u) ? (dy * 2u) : (60u - dy);
                    r = (r * (64u - fog) + 14u * fog) >> 6;
                    g = (g * (64u - fog) + 36u * fog) >> 6;
                    b = (b * (64u - fog) + 50u * fog) >> 6;
                }

                if (r > 255u) r = 255u;
                if (g > 255u) g = 255u;
                if (b > 255u) b = 255u;
                row[x] = (r << 16) | (g << 8) | b;
            }
        }
    }

    /* Pass 2: Japanese Myojin Torii Columns (y: 370..619) */
    for (int col_i = 0; col_i < 2; col_i++) {
        int x_min = (col_i == 0) ? 370 : 962;
        int slant = (col_i == 0) ? 1 : -1;
        for (int y = 370; y < 620; y++) {
            volatile uint32_t *row = fb + (y * (SCREEN_STRIDE / 4));
            int dx_slant = ((620 - y) * 35 * slant) / 1000;
            int col_x0 = x_min + dx_slant;
            int col_x1 = col_x0 + 34;
            uint32_t wb = (y > 500) ? (((uint32_t)(y - 500) * 3u) >> 3) : 0u;
            uint32_t is_clamp = ((y >= 445 && y <= 462) || (y >= 595 && y <= 618));
            uint32_t is_seam = (y == 445 || y == 462 || y == 595 || y == 618);

            for (int x = col_x0; x <= col_x1; x++) {
                int shd = (x - col_x0) * (col_x1 - x);
                int shd_s = (shd * 227) >> 16;
                uint32_t r = 70u + ((shd_s * 51u) >> 6);
                uint32_t g = 14u + ((shd_s * 10u) >> 6);
                uint32_t b = 12u + ((shd_s * 10u) >> 6);
                if ((y + (x >> 1)) & 2) {
                    r = (r * 115u) >> 7; g = (g * 115u) >> 7;
                }
                if ((x - col_x0) >= 22 && (x - col_x0) <= 28) {
                    r += 20u; g += 38u; b += 45u;
                }
                if ((slant == 1 && (x - col_x0) <= 3) || (slant == -1 && (col_x1 - x) <= 3)) {
                    r = 20u; g = 190u; b = 175u; /* Soft emerald aurora rim-light */
                }
                if (wb) {
                    r += wb; g += wb / 2u;
                }
                if (is_clamp) {
                    r = 110u + ((shd_s * 22u) >> 6);
                    g = 90u  + ((shd_s * 19u) >> 6);
                    b = 35u  + ((shd_s * 10u) >> 6);
                    if (is_seam) {
                        r = 30u; g = 80u; b = 70u;
                    }
                }
                if (r > 255u) r = 255u;
                if (g > 255u) g = 255u;
                if (b > 255u) b = 255u;
                row[x] = (r << 16) | (g << 8) | b;
            }
        }
    }

    /* Pass 3: Unified Crossbeams (Kasagi, Shimaki, Nuki) */
    for (int bi = 0; bi < 3; bi++) {
        int bx0 = (bi == 0) ? 310 : (bi == 1) ? 334 : 345;
        int bx1 = (bi == 0) ? 1056 : (bi == 1) ? 1032 : 1021;
        int by0 = (bi == 0) ? 360 : (bi == 1) ? 398 : 446;
        int bh  = (bi == 0) ? 24 : (bi == 1) ? 16 : 14;
        for (int x = bx0; x <= bx1; x++) {
            int curve = (bi == 0) ? (((x - 683) * (x - 683)) / 9950) : 0;
            int y_beam = by0 + curve;
            for (int dy = 0; dy < bh; dy++) {
                int y = y_beam + dy;
                if ((unsigned)y < SB_BG_H) {
                    uint32_t shd = ((uint32_t)(bh - dy) << 6) / (uint32_t)bh;
                    uint32_t r = (dy <= 2) ? ((bi == 0) ? 40u : 35u) : (60u + ((shd * 70u) >> 6));
                    uint32_t g = (dy <= 2) ? ((bi == 0) ? 210u : 165u) : (12u + ((shd * 16u) >> 6));
                    uint32_t b = (dy <= 2) ? ((bi == 0) ? 195u : 160u) : (10u + ((shd * 16u) >> 6));
                    if (r > 255u) r = 255u;
                    if (g > 255u) g = 255u;
                    if (b > 255u) b = 255u;
                    fb[y * (SCREEN_STRIDE / 4) + x] = (r << 16) | (g << 8) | b;
                }
            }
        }
    }

    /* Gakuzuka Plaque (y: 396..448, x: 673..693) */
    for (int y = 396; y <= 448; y++) {
        volatile uint32_t *prow = fb + (y * (SCREEN_STRIDE / 4));
        for (int x = 673; x <= 693; x++) {
            prow[x] = (x == 673 || x == 693 || y == 396 || y == 448) ? 0x008C732Du : 0x001E1612u;
        }
    }

    /* Pass 4: Twin Stone Lanterns (Toro) at (485, 540) and (881, 540) */
    for (int li = 0; li < 2; li++) {
        int lx = (li == 0) ? 485 : 881, ly = 540;
        /* Roof */
        for (int ry = ly - 24; ry < ly - 12; ry++) {
            int w_roof = 14 + ((ly - 12 - ry) * 3) / 2;
            volatile uint32_t *rrow = fb + (ry * (SCREEN_STRIDE / 4));
            for (int rx = lx - w_roof; rx <= lx + w_roof; rx++) {
                rrow[rx] = (((rx * 13 + ry * 7) & 7) < 3) ? 0x00143723u : 0x00232D3Cu;
            }
        }
        /* Fire chamber */
        for (int wy = ly - 12; wy < ly + 8; wy++) {
            volatile uint32_t *wrow = fb + (wy * (SCREEN_STRIDE / 4));
            int dy_w = wy - (ly - 2); if (dy_w < 0) dy_w = -dy_w;
            for (int wx = lx - 12; wx <= lx + 12; wx++) {
                int dx_w = wx - lx; if (dx_w < 0) dx_w = -dx_w;
                uint32_t c = (dx_w <= 7 && dy_w <= 6 && (dx_w % 3) && (dy_w % 3)) ? 0x00FFBE3Cu : 0x00283041u;
                wrow[wx] = c;
            }
        }
        /* Base */
        for (int py = ly + 8; py < ly + 40; py++) {
            int pw = (py < ly + 30) ? 8 : 16;
            volatile uint32_t *prow = fb + (py * (SCREEN_STRIDE / 4));
            for (int px = lx - pw; px <= lx + pw; px++) {
                prow[px] = (((px * 11 + py * 5) & 7) < 2) ? 0x0012301Eu : 0x00232A37u;
            }
        }
    }

    gpu2d_flush_dcache();
}
'''

with open('tools/build_stage_backgrounds.py', 'r', encoding='utf-8') as f:
    code = f.read()

search_marker = "'#include \"gpu2d.h\"',\n             '',"
pos = code.find(search_marker)
if pos == -1:
    print("Error: search_marker not found")
    sys.exit(1)

prefix = code[:pos + len(search_marker)]

end_marker = "(ROOT / 'sw' / 'app' / 'stage_bg.c').write_text"
end_pos = code.find(end_marker)
if end_pos == -1:
    print("Error: end_marker not found")
    sys.exit(1)

suffix = code[end_pos:]

c_lines = NEW_STRESS_C.strip().split('\n')
c_py_lines = ["\n             " + repr(line) + "," for line in c_lines]
c_py_block = ''.join(c_py_lines) + "\n             '']\n    "

new_code = prefix + c_py_block + suffix

with open('tools/build_stage_backgrounds.py', 'w', encoding='utf-8') as f:
    f.write(new_code)

print("Updated tools/build_stage_backgrounds.py with Aurora successfully!")
