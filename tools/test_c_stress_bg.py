#!/usr/bin/env python3
"""
Simulate Japanese Torii Sanctuary with Ethereal Silk Aurora Ribbons and Stone Bases.
"""
import numpy as np
from PIL import Image

W = 1366
H = 768

sin_lut = [
     0,  6, 12, 17, 22, 26, 29, 31,
    32, 31, 29, 26, 22, 17, 12,  6,
     0, -6,-12,-17,-22,-26,-29,-31,
   -32,-31,-29,-26,-22,-17,-12, -6
]

pixels = np.zeros((H, W, 3), dtype=np.uint8)

def clamp(v):
    return max(0, min(255, int(v)))

print("Simulating Torii Sanctuary with Majestic Aurora...")

for y in range(H):
    if y < 512:
        base_r = 2 + ((3 * y) >> 8)
        base_g = 3 + ((3 * y) >> 7)
        base_b = 8 + ((7 * y) >> 7)

        for x in range(W):
            r = base_r
            g = base_g
            b = base_b

            # Night clouds
            cloud_val = sin_lut[(x >> 5) & 31] + sin_lut[((x >> 4) + (y >> 4)) & 31]
            if cloud_val > 8:
                cw = ((cloud_val - 8) * (512 - y)) >> 9
                r += (cw * 6) >> 5
                g += (cw * 14) >> 5
                b += (cw * 18) >> 5

            # Twinkling Stars
            h = ((x * 1664525) + (y * 1013904223)) ^ 0x20261025
            h = (h ^ (h >> 16)) & 0xFFFFFFFF
            if (h & 0xFFF) == 0x111:
                r = 220; g = 240; b = 255
            elif (h & 0x7FF) == 0x333:
                r = 110; g = 160; b = 220
            elif (h & 0x3FF) == 0x255:
                r = 55;  g = 80;  b = 135

            # Vertical ray flutter texture for aurora curtains
            ray_flutter = (((x * 13 + (y >> 2)) & 15) - 8)

            # -----------------------------------------------------------
            # Aurora Curtain 1: Upper High-altitude Emerald Ribbon (y ~ 110)
            # -----------------------------------------------------------
            w1 = sin_lut[(x >> 6) & 31] + (sin_lut[((x >> 4) + 6) & 31] >> 1)
            ay1 = 110 + w1 + ray_flutter
            d1 = abs(y - ay1)
            if d1 < 50:
                aw1 = 50 - d1
                r += (aw1 * 10) >> 6
                g += (aw1 * 48) >> 6
                b += (aw1 * 36) >> 6
                if d1 < 10:
                    g += (10 - d1) * 3
                    b += (10 - d1) * 2

            # -----------------------------------------------------------
            # Aurora Curtain 2: Primary Magnificent Folding Curtain (y ~ 220)
            # -----------------------------------------------------------
            w2 = sin_lut[((x >> 5) + 3) & 31] + (sin_lut[(x >> 3) & 31] >> 2)
            ay2 = 220 + w2 + ray_flutter * 2
            d2 = abs(y - ay2)
            if d2 < 68:
                aw2 = 68 - d2
                r += (aw2 * 14) >> 6
                g += (aw2 * 58) >> 6
                b += (aw2 * 46) >> 6
                if d2 > 35:
                    fringe = d2 - 35
                    r += (fringe * 28) >> 5
                    b += (fringe * 24) >> 5

            # -----------------------------------------------------------
            # Aurora Curtain 3: Dreamy Lower Violet & Soft Pink Ribbon (y ~ 340)
            # -----------------------------------------------------------
            w3 = sin_lut[((x >> 5) + 14) & 31]
            ay3 = 340 + w3 + ray_flutter
            d3 = abs(y - ay3)
            if d3 < 54:
                aw3 = 54 - d3
                r += (aw3 * 40) >> 6
                g += (aw3 * 16) >> 6
                b += (aw3 * 50) >> 6

            # Distant Mountains Silhouette
            mtn_y = 494 + (((sin_lut[(x >> 4) & 31] * 12 + sin_lut[(x >> 3) & 31] * 5)) >> 6)
            if y >= mtn_y:
                r = 4; g = 8; b = 16
                if y <= mtn_y + 1:
                    r = 16; g = 64; b = 80 # Soft aurora sky rim

            pixels[y, x, 0] = clamp(r)
            pixels[y, x, 1] = clamp(g)
            pixels[y, x, 2] = clamp(b)
    else:
        # Ground Perspective (y >= 512)
        dy = y - 512
        z = 12000 // (dy + 14)
        path_hw = 65 + 300 // (z + 20)
        xw_path = (35 * sin_lut[(z >> 2) & 31]) >> 5
        aurora_ambient = ((250 - dy) * 74) >> 10 if dy < 250 else 0
        dy_l = y - 540
        dy_l_sq = dy_l * dy_l

        for x in range(W):
            dx_c = x - 683
            xw = ((dx_c * z) * 182) >> 16
            dist_path = abs(xw - xw_path)

            # Lanterns warm glow
            dx_l = x - 485
            d2_l = dx_l * dx_l + dy_l_sq
            dx_r = x - 881
            d2_r = dx_r * dx_r + dy_l_sq
            warm_glow = 0
            if d2_l < 14000: warm_glow += (14000 - d2_l) >> 7
            if d2_r < 14000: warm_glow += (14000 - d2_r) >> 7

            if dist_path < path_hw:
                # Weathered Flagstone Path
                xw_lut = abs(xw)
                z_slab = (z + (((sin_lut[(xw_lut >> 2) & 31] * 5)) >> 5)) & 63
                x_slab = (dist_path + (((sin_lut[((z >> 1) + 8) & 31] * 4)) >> 5)) & 63
                if z_slab < 4 or x_slab < 4:
                    r = 4  + (warm_glow >> 2)
                    g = 14 + ((warm_glow * 9) >> 5) + ((aurora_ambient * 4) >> 3)
                    b = 10 + ((aurora_ambient * 3) >> 3)
                else:
                    r = 18 + ((warm_glow * 29) >> 5)
                    g = 25 + ((warm_glow * 3) >> 2) + ((aurora_ambient * 6) >> 3)
                    b = 34 + ((aurora_ambient * 5) >> 2)
                    if z_slab == 4 or x_slab == 4:
                        r += 10; g += 20; b += 24
                    if 16 < z_slab < 44 and 12 < x_slab < 40:
                        g += 12; b += 16
            else:
                # Wild Grass Meadow with Emerald tone
                blade_freq = ((x * 37 + y * 71) ^ 0x5DEECE66) & 0xFFFFFFFF
                blade_tilt = (blade_freq & 7) - 3
                blade_hatch = ((x + blade_tilt) & 3) == 0
                r = 6  + ((warm_glow * 19) >> 5)
                g = 20 + (warm_glow >> 1) + (10 if blade_hatch else 0) + ((aurora_ambient * 7) >> 3)
                b = 14 + ((aurora_ambient * 10) >> 4) + (8 if blade_hatch else 0)
                if ((blade_freq >> 3) & 63) == 7 and dy > 30:
                    r += 50; g += 160; b += 180

            # Low ground fog
            if dy < 60:
                fog = (dy * 2) if dy < 20 else (60 - dy)
                r = (r * (64 - fog) + 14 * fog) >> 6
                g = (g * (64 - fog) + 36 * fog) >> 6
                b = (b * (64 - fog) + 50 * fog) >> 6

            pixels[y, x, 0] = clamp(r)
            pixels[y, x, 1] = clamp(g)
            pixels[y, x, 2] = clamp(b)

# Torii Columns with Stone Bases (Daiishi)
for (col_i, x_min, slant) in [(0, 370, 1), (1, 962, -1)]:
    for y in range(370, 630):
        if y >= 620:
            for x in range(x_min - 4, x_min + 39):
                pixels[y, x] = (26, 36, 32) if (((x * 7 + y * 13) & 7) < 2) else (43, 52, 61)
            continue
        dx_slant = ((620 - y) * 9 * slant) >> 8
        col_x0 = x_min + dx_slant
        col_x1 = col_x0 + 34
        wb = (((y - 500) * 3) >> 3) if y > 500 else 0
        is_clamp = (445 <= y <= 462) or (595 <= y <= 618)
        is_seam = y in (445, 462, 595, 618)
        for x in range(col_x0, col_x1 + 1):
            shd = (x - col_x0) * (col_x1 - x)
            shd_s = (shd * 227) >> 16
            r = 70 + ((shd_s * 51) >> 6)
            g = 14 + ((shd_s * 10) >> 6)
            b = 12 + ((shd_s * 10) >> 6)
            if (y + (x >> 1)) & 2:
                r = (r * 115) >> 7; g = (g * 115) >> 7
            if 22 <= (x - col_x0) <= 28:
                r += 20; g += 38; b += 45
            # Outer edge receives soft emerald aurora rim-light
            if (slant == 1 and (x - col_x0) <= 3) or (slant == -1 and (col_x1 - x) <= 3):
                r = 20; g = 190; b = 175
            if wb:
                r += wb; g += wb // 2
            if is_clamp:
                r = 110 + ((shd_s * 22) >> 6)
                g = 90  + ((shd_s * 19) >> 6)
                b = 35  + ((shd_s * 10) >> 6)
                if is_seam:
                    r = 30; g = 80; b = 70
            pixels[y, x, 0] = clamp(r)
            pixels[y, x, 1] = clamp(g)
            pixels[y, x, 2] = clamp(b)

# Unified Beams (Kasagi, Shimaki, Nuki)
for bi in range(3):
    bx0 = 310 if bi == 0 else (334 if bi == 1 else 345)
    bx1 = 1056 if bi == 0 else (1032 if bi == 1 else 1021)
    by0 = 360 if bi == 0 else (398 if bi == 1 else 446)
    bh  = 24 if bi == 0 else (16 if bi == 1 else 14)
    for dy in range(bh):
        shd = ((bh - dy) << 6) // bh
        r = (40 if bi == 0 else 35) if dy <= 2 else (60 + ((shd * 70) >> 6))
        g = (210 if bi == 0 else 165) if dy <= 2 else (12 + ((shd * 16) >> 6))
        b = (195 if bi == 0 else 160) if dy <= 2 else (10 + ((shd * 16) >> 6))
        col = (clamp(r), clamp(g), clamp(b))
        for x in range(bx0, bx1 + 1):
            curve = (((x - 683) * (x - 683)) // 9950) if bi == 0 else 0
            y = by0 + dy + curve
            if y < H:
                pixels[y, x] = col

# Gakuzuka Plaque
for y in range(396, 449):
    for x in range(673, 694):
        c = (140, 115, 45) if (x in (673, 693) or y in (396, 448)) else (30, 22, 18)
        pixels[y, x] = c

# Twin Lanterns (Toro)
for lx in (485, 881):
    ly = 540
    # Roof
    for ry in range(ly - 24, ly - 12):
        w_roof = 14 + ((ly - 12 - ry) * 3) // 2
        for rx in range(lx - w_roof, lx + w_roof + 1):
            pixels[ry, rx] = (20, 55, 35) if (((rx * 13 + ry * 7) & 7) < 3) else (35, 45, 60)
    # Fire Chamber
    for wy in range(ly - 12, ly + 8):
        dy_w = abs(wy - (ly - 2))
        for wx in range(lx - 12, lx + 13):
            dx_w = abs(wx - lx)
            pixels[wy, wx] = (255, 190, 60) if (dx_w <= 7 and dy_w <= 6 and (dx_w & 3) and (dy_w & 3)) else (40, 48, 65)
    # Base
    for py in range(ly + 8, ly + 40):
        pw = 8 if py < ly + 30 else 16
        for px in range(lx - pw, lx + pw + 1):
            pixels[py, px] = (18, 48, 30) if (((px * 11 + py * 5) & 7) < 2) else (35, 42, 55)

out_im = Image.fromarray(pixels, mode='RGB')
out_im.save("tools/test_c_stress_bg.png")
print("Saved tools/test_c_stress_bg.png with Aurora and Stone Bases successfully!")
