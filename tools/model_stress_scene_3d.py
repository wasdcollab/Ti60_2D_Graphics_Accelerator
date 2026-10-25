#!/usr/bin/env python3
"""
tools/model_stress_scene_3d.py

3D Scene Modeler and Renderer for Stress Test Stage:
1. Generates complete 3D Wavefront OBJ model:
   assets/source/stress_scene/cyber_shrine_3d.obj & cyber_shrine_3d.mtl
   - Japanese Myojin Torii (slanted cylindrical pillars, Kasagi/Shimaki/Nuki beams, cast iron clamps)
   - Twin Japanese Stone Lanterns (Toro) with fire chambers and tiered roofs
   - S-curved winding flagstone path with weathered stone slabs
   - Surrounding terrain and distant mountain silhouette
2. Renders 1366x768 cinematic true-color scene:
   - Low-angle, central-perspective camera
   - Sky with geometric lasers (Tyndall volumetric scattering) & night clouds
   - Cinnabar vermillion Torii with dark-gold clamps and cool laser rim-light
   - Twin stone lanterns casting warm amber glow
   - Winding flagstone path with moss crevices and wet reflections
   - Wild wind-tilted grass meadow with dew glints and low ground fog
3. Saves assets/source/stress_scene/stress_scene_rendered.png
"""

import os
import math
import numpy as np
from PIL import Image

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "assets", "source", "stress_scene")
os.makedirs(OUTPUT_DIR, exist_ok=True)

OBJ_PATH = os.path.join(OUTPUT_DIR, "cyber_shrine_3d.obj")
MTL_PATH = os.path.join(OUTPUT_DIR, "cyber_shrine_3d.mtl")
PNG_PATH = os.path.join(OUTPUT_DIR, "stress_scene_rendered.png")

W = 1366
H = 768

def build_3d_obj():
    """Builds a rich 3D Wavefront OBJ mesh of the Japanese Torii Shrine scene."""
    verts = []
    faces = []

    def add_box(cx, cy, cz, sx, sy, sz, rx=0.0):
        hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
        base_v = len(verts) + 1
        corners = [
            (-hx, -hy, -hz), ( hx, -hy, -hz), ( hx,  hy, -hz), (-hx,  hy, -hz),
            (-hx, -hy,  hz), ( hx, -hy,  hz), ( hx,  hy,  hz), (-hx,  hy,  hz)
        ]
        for dx, dy, dz in corners:
            # Optional slant rotation
            if rx != 0.0:
                dx += dy * rx
            verts.append((cx + dx, cy + dy, cz + dz))
        quad_indices = [
            (0, 1, 2, 3), # front
            (5, 4, 7, 6), # back
            (4, 0, 3, 7), # left
            (1, 5, 6, 2), # right
            (3, 2, 6, 7), # top
            (4, 5, 1, 0), # bottom
        ]
        for q in quad_indices:
            faces.append((base_v + q[0], base_v + q[1], base_v + q[2]))
            faces.append((base_v + q[0], base_v + q[2], base_v + q[3]))

    # 1. Ground Plateau
    add_box(0.0, -1.0, 20.0, 60.0, 2.0, 70.0)

    # 2. Torii Gate (Z = 22.0)
    # Left & Right Pillars with subtle inward incline (Hashira)
    add_box(-6.2, 5.0, 22.0, 1.1, 12.0, 1.1, rx= 0.035)
    add_box( 6.2, 5.0, 22.0, 1.1, 12.0, 1.1, rx=-0.035)

    # Stone Bases (Daiishi)
    add_box(-6.4, 0.4, 22.0, 1.8, 0.8, 1.8)
    add_box( 6.4, 0.4, 22.0, 1.8, 0.8, 1.8)

    # Lower Crossbeam (Nuki) passing through columns
    add_box(0.0, 8.2, 22.0, 16.5, 0.7, 0.9)
    # Secondary Upper Beam (Shimaki)
    add_box(0.0, 10.4, 22.0, 17.5, 0.6, 1.0)
    # Primary Upper Beam (Kasagi) with curved overhang
    add_box(0.0, 11.1, 22.0, 19.5, 0.8, 1.3)
    # Center Plaque (Gakuzuka)
    add_box(0.0, 9.3, 22.0, 1.2, 1.6, 0.4)

    # Corner Cast Iron Clamps (Kuwagata)
    add_box(-6.2, 10.4, 22.0, 1.3, 0.8, 1.3)
    add_box( 6.2, 10.4, 22.0, 1.3, 0.8, 1.3)
    add_box(-6.2, 8.2, 22.0, 1.3, 0.9, 1.3)
    add_box( 6.2, 8.2, 22.0, 1.3, 0.9, 1.3)

    # 3. Twin Japanese Stone Lanterns (Toro) at Z = 16.0
    for lx in (-4.2, 4.2):
        # Base (Kiso)
        add_box(lx, 0.3, 16.0, 1.5, 0.6, 1.5)
        # Shaft (Sao)
        add_box(lx, 1.4, 16.0, 0.7, 1.6, 0.7)
        # Middle Platform (Chudai)
        add_box(lx, 2.3, 16.0, 1.4, 0.3, 1.4)
        # Fire Chamber (Hibukuro) with stone windows
        add_box(lx, 2.9, 16.0, 1.0, 0.9, 1.0)
        # Umbrella Roof (Kasa) with flared corners
        add_box(lx, 3.5, 16.0, 1.8, 0.4, 1.8)
        # Jewel Finial (Hoju)
        add_box(lx, 3.9, 16.0, 0.4, 0.5, 0.4)

    # 4. S-Curved Flagstone Path Slabs
    for i in range(16):
        pz = 5.0 + i * 2.5
        # Gentle S-curve
        px = 0.8 * math.sin(i * 0.45)
        pw = 2.8 - i * 0.06
        add_box(px, 0.05, pz, pw, 0.12, 1.9)

    # Write OBJ and MTL files
    with open(OBJ_PATH, "w", encoding="utf-8") as f:
        f.write("# Japanese Shrine & Torii 3D Model\n")
        f.write("mtllib cyber_shrine_3d.mtl\n")
        f.write("o ToriiSanctuary\n")
        for v in verts:
            f.write(f"v {v[0]:.4f} {v[1]:.4f} {v[2]:.4f}\n")
        f.write("usemtl Cinnabar_Wood\n")
        f.write("s 1\n")
        for face in faces:
            f.write(f"f {face[0]} {face[1]} {face[2]}\n")

    with open(MTL_PATH, "w", encoding="utf-8") as f:
        f.write("# Japanese Shrine Materials\n")
        f.write("newmtl Cinnabar_Wood\n")
        f.write("Ka 0.12 0.02 0.01\n")
        f.write("Kd 0.54 0.10 0.06\n")
        f.write("Ks 0.20 0.25 0.30\n")
        f.write("Ns 15.0\n")
        f.write("newmtl Weathered_Stone\n")
        f.write("Ka 0.04 0.06 0.08\n")
        f.write("Kd 0.14 0.18 0.22\n")
        f.write("Ks 0.35 0.40 0.50\n")
        f.write("Ns 25.0\n")

    print(f"[3D] Generated OBJ model: {OBJ_PATH} ({len(verts)} vertices, {len(faces)} faces)")

def render_3d_scene():
    """Renders the comprehensive 1366x768 cinematic scene."""
    img = np.zeros((H, W, 3), dtype=np.float32)

    y_coords = np.arange(H, dtype=np.float32)[:, None]
    x_coords = np.arange(W, dtype=np.float32)[None, :]

    # -------------------------------------------------------------
    # 1. Sky: Midnight Dark Navy to Deep Charcoal Gradient (y: 0..520)
    # -------------------------------------------------------------
    sky_t = np.clip(y_coords / 520.0, 0.0, 1.0)
    sky_r = 2.0 + 8.0 * (sky_t ** 1.8)
    sky_g = 3.0 + 10.0 * (sky_t ** 1.8)
    sky_b = 8.0 + 26.0 * (sky_t ** 1.8)
    img[:, :, 0] = sky_r
    img[:, :, 1] = sky_g
    img[:, :, 2] = sky_b

    # Translucent Night Cirrus Clouds
    cloud1 = np.sin(x_coords * 0.004 + y_coords * 0.008) * np.cos(x_coords * 0.002)
    cloud1 = np.clip(cloud1 * 0.5 + 0.5, 0.0, 1.0) * (1.0 - sky_t)
    img[:, :, 0] += cloud1 * 10.0
    img[:, :, 1] += cloud1 * 14.0
    img[:, :, 2] += cloud1 * 25.0

    # Twinkling Stars
    np.random.seed(0x20261025)
    for _ in range(180):
        sx = np.random.randint(0, W)
        sy = np.random.randint(8, 480)
        mag = np.random.uniform(60.0, 220.0)
        img[sy, sx, 0] = min(255.0, img[sy, sx, 0] + mag * 0.8)
        img[sy, sx, 1] = min(255.0, img[sy, sx, 1] + mag * 0.9)
        img[sy, sx, 2] = min(255.0, img[sy, sx, 2] + mag)

    # -------------------------------------------------------------
    # 2. Majestic Silk Aurora Curtains (y: 80 ~ 380)
    # -------------------------------------------------------------
    # Multi-layer ethereal aurora curtains: emerald green core, cyan,
    # lavender/violet folds, and soft pink fringes with vertical ray curtains.
    
    # Vertical ray flutter texture across the sky
    ray_flutter = (((x_coords.astype(np.int32) * 13 + (y_coords.astype(np.int32) >> 2)) & 15) - 8).astype(np.float32)

    # Ribbon 1: Upper High-altitude Emerald Ribbon (y ~ 110)
    w1 = np.sin(x_coords * 0.0098) * 16.0 + np.sin(x_coords * 0.0245 + 1.2) * 8.0
    ay1 = 110.0 + w1 + ray_flutter
    d1 = np.abs(y_coords - ay1)
    mask1 = d1 < 52.0
    aw1 = np.clip(52.0 - d1, 0.0, 52.0)
    img[:, :, 0] += mask1 * ((aw1 * 12.0) / 64.0)
    img[:, :, 1] += mask1 * ((aw1 * 54.0) / 64.0)
    img[:, :, 2] += mask1 * ((aw1 * 40.0) / 64.0)
    # Intense core
    core1 = np.clip(12.0 - d1, 0.0, 12.0)
    img[:, :, 1] += core1 * 3.5
    img[:, :, 2] += core1 * 2.2

    # Ribbon 2: Primary Folding Silk Curtain (y ~ 220)
    w2 = np.sin(x_coords * 0.0125 + 0.6) * 24.0 + np.sin(x_coords * 0.039) * 10.0
    ay2 = 220.0 + w2 + ray_flutter * 2.0
    d2 = np.abs(y_coords - ay2)
    mask2 = d2 < 72.0
    aw2 = np.clip(72.0 - d2, 0.0, 72.0)
    # Emerald green core
    img[:, :, 0] += mask2 * ((aw2 * 16.0) / 64.0)
    img[:, :, 1] += mask2 * ((aw2 * 68.0) / 64.0)
    img[:, :, 2] += mask2 * ((aw2 * 52.0) / 64.0)
    # Soft lavender / lilac and pink fringes on folding edges
    fringe2 = np.clip(d2 - 36.0, 0.0, 36.0)
    img[:, :, 0] += fringe2 * 1.05
    img[:, :, 1] += fringe2 * 0.25
    img[:, :, 2] += fringe2 * 0.95

    # Ribbon 3: Dreamy Lower Violet & Soft Pink Ribbon (y ~ 340)
    w3 = np.sin(x_coords * 0.011 + 2.8) * 18.0
    ay3 = 340.0 + w3 + ray_flutter
    d3 = np.abs(y_coords - ay3)
    mask3 = d3 < 56.0
    aw3 = np.clip(56.0 - d3, 0.0, 56.0)
    img[:, :, 0] += mask3 * ((aw3 * 45.0) / 64.0)
    img[:, :, 1] += mask3 * ((aw3 * 18.0) / 64.0)
    img[:, :, 2] += mask3 * ((aw3 * 56.0) / 64.0)

    # -------------------------------------------------------------
    # 3. Distant Mountains Silhouette (Horizon y ~ 500..525)
    # -------------------------------------------------------------
    horiz_base = 512
    mtn_h = (
        np.sin(x_coords * 0.012) * 16.0 +
        np.sin(x_coords * 0.038 + 1.2) * 9.0 +
        np.sin(x_coords * 0.082) * 4.0
    ).astype(np.int32)
    mtn_line = horiz_base - 18 + mtn_h

    mtn_mask = (y_coords >= mtn_line) & (y_coords < horiz_base)
    rim_mask = (y_coords >= mtn_line) & (y_coords <= mtn_line + 2)
    img[mtn_mask, 0] = 5.0
    img[mtn_mask, 1] = 7.0
    img[mtn_mask, 2] = 15.0
    # Laser backlight rim
    img[rim_mask, 0] = 20.0
    img[rim_mask, 1] = 60.0
    img[rim_mask, 2] = 95.0

    # -------------------------------------------------------------
    # 4. Ground Perspective: Wild Meadow & S-Curved Flagstone Path (y >= 512)
    # -------------------------------------------------------------
    # Low-angle camera perspective: Eye height 1.4m, horizon y=512
    lantern_l = (485, 540) # Left lantern screen center (x, y)
    lantern_r = (881, 540) # Right lantern screen center (x, y)

    for y in range(horiz_base, H):
        dy = y - horiz_base + 1
        # Depth z ~ 1 / dy
        z = 12000.0 / (dy + 14.0)

        for x in range(W):
            dx_c = x - 683
            # World X in perspective
            xw = (dx_c * z) / 360.0

            # S-curved path center line xw_path
            xw_path = 35.0 * math.sin(z * 0.032)
            dist_path = abs(xw - xw_path)
            # Path width expands near foreground (z decreases)
            path_hw = 65.0 + (300.0 / (z + 20.0))

            # ------------------------------------
            # Local Lighting Calculations
            # ------------------------------------
            # Warm amber light from twin stone lanterns
            d2_l = (x - lantern_l[0]) ** 2 + (y - lantern_l[1]) ** 2
            d2_r = (x - lantern_r[0]) ** 2 + (y - lantern_r[1]) ** 2
            att_l = math.exp(-d2_l / 12000.0)
            att_r = math.exp(-d2_r / 12000.0)
            warm_glow = (att_l + att_r) * 1.3 # 0.0 .. 1.3

            # Top cold laser ambient fill
            cold_laser_fill = max(0.0, 1.0 - dy / 260.0) * 18.0

            if dist_path < path_hw:
                # ------------------------------------
                # A. Weathered Flagstone Path
                # ------------------------------------
                # Stone slab joint tiling
                z_slab = int(z + 5.0 * math.sin(xw * 0.08)) % 80
                x_slab = int(abs(xw - xw_path) + 4.0 * math.cos(z * 0.1)) % 70
                is_crevice = (z_slab < 5) or (x_slab < 5)

                if is_crevice:
                    # Dark green moss & wet fern crevice
                    r = 4.0 + warm_glow * 25.0
                    g = 12.0 + warm_glow * 35.0
                    b = 10.0 + cold_laser_fill * 0.4
                else:
                    # Weathered blue-grey sandstone slab
                    r = 18.0 + warm_glow * 90.0
                    g = 24.0 + warm_glow * 75.0
                    b = 36.0 + cold_laser_fill * 1.2
                    # Wet specular highlight
                    if z_slab == 5 or x_slab == 5:
                        r += 12.0; g += 18.0; b += 28.0
                    # Mirror-like wet puddle reflections of laser cyan
                    if (z_slab > 20 and z_slab < 50) and (x_slab > 15 and x_slab < 45):
                        g += 10.0; b += 20.0
            else:
                # ------------------------------------
                # B. Wild Grassland Meadow
                # ------------------------------------
                # Wind-tilted grass blade simulation
                blade_freq = (x * 37 + y * 71) ^ 0x5DEECE66
                blade_tilt = (blade_freq & 7) - 3
                blade_hatch = ((x + blade_tilt) & 3) == 0

                # Deep emerald and blue-green cold tones
                r = 6.0  + warm_glow * 60.0
                g = 18.0 + warm_glow * 50.0 + (10.0 if blade_hatch else 0.0)
                b = 14.0 + cold_laser_fill * 0.8 + (8.0 if blade_hatch else 0.0)

                # Dewdrop glint on blade tips
                if ((blade_freq >> 3) & 63) == 7 and dy > 30:
                    r += 60.0; g += 140.0; b += 190.0

            # Low-lying ground mist over the meadow (thin cool fog layer)
            fog_t = math.exp(-((dy - 20.0) ** 2) / 1200.0) * 0.45
            r = r * (1.0 - fog_t) + 16.0 * fog_t
            g = g * (1.0 - fog_t) + 32.0 * fog_t
            b = b * (1.0 - fog_t) + 54.0 * fog_t

            img[y, x, 0] = r
            img[y, x, 1] = g
            img[y, x, 2] = b

    # -------------------------------------------------------------
    # 5. Japanese Myojin Torii (中景视觉中心)
    # -------------------------------------------------------------
    # Cinnabar Vermillion Red: (138, 24, 16)
    # Aged wood shadow: (68, 12, 10)
    # Laser cool rim-light: (0, 240, 255)
    # Dark-gold cast iron clamps: (145, 120, 48)

    torii_top = 370
    torii_bot = 620
    # Left column: x in [370..404], Right column: x in [962..996]
    for (x_min, x_max, slant) in [(370, 404, 1), (962, 996, -1)]:
        for y in range(torii_top, torii_bot):
            # Inward slant
            dx_slant = int((torii_bot - y) * 0.035 * slant)
            col_x0 = x_min + dx_slant
            col_x1 = x_max + dx_slant
            col_w = col_x1 - col_x0
            for x in range(col_x0, col_x1 + 1):
                norm_x = (x - col_x0) / float(col_w) # 0.0 .. 1.0
                cyl_shd = math.sin(norm_x * math.pi)

                # Cinnabar vermillion lacquer with wood grain micro-texture
                grain = 0.85 + 0.15 * math.sin(y * 0.4 + x * 0.2)
                r = (70.0 + 80.0 * cyl_shd) * grain
                g = (14.0 + 16.0 * cyl_shd) * grain
                b = (12.0 + 15.0 * cyl_shd)

                # Wet night sheen
                if norm_x > 0.65 and norm_x < 0.85:
                    r += 25.0; g += 35.0; b += 55.0

                # Laser cold back rim-light outline (outer edges)
                if (slant == 1 and norm_x < 0.15) or (slant == -1 and norm_x > 0.85):
                    r = 30.0; g = 180.0; b = 255.0

                # Warm amber lantern bounce on lower columns
                if y > 500:
                    warm_boost = (y - 500) / 120.0
                    r += warm_boost * 45.0
                    g += warm_boost * 25.0

                # Dark-gold cast iron clamps at joints
                if (y >= 445 and y <= 462) or (y >= 595 and y <= 618):
                    r = 110.0 + 35.0 * cyl_shd
                    g = 90.0  + 30.0 * cyl_shd
                    b = 35.0  + 15.0 * cyl_shd
                    # Verdigris / patina in seams
                    if y == 445 or y == 462 or y == 595 or y == 618:
                        r = 30.0; g = 80.0; b = 70.0

                img[y, x, 0] = r
                img[y, x, 1] = g
                img[y, x, 2] = b

    # Stone Bases (Daiishi) for Torii Columns (y: 618..630)
    for col_i in (0, 1):
        cx = 387 if col_i == 0 else 979
        for y in range(618, 631):
            for x in range(cx - 22, cx + 23):
                grain = 0.85 + 0.15 * math.sin(x * 0.7 + y * 1.3)
                r = 32.0 + 8.0 * grain
                g = 42.0 + 10.0 * grain
                b = 52.0 + 12.0 * grain
                if ((x * 7 + y * 13) & 7) < 2:
                    r = 20.0; g = 38.0; b = 30.0 # moss
                img[y, x, 0] = r
                img[y, x, 1] = g
                img[y, x, 2] = b

    # Upper Curved Kasagi Beam (y: 358..384, x: 310..1056)
    for x in range(310, 1057):
        # Subtle upward curve at tips
        curve = int(((x - 683) / 373.0) ** 2 * 14.0)
        y_beam = 360 + curve
        for dy in range(24):
            y = y_beam + dy
            if 0 <= y < H:
                shd = 1.0 - dy / 26.0
                # Vermillion lacquer
                r = 65.0 + 75.0 * shd
                g = 12.0 + 18.0 * shd
                b = 10.0 + 18.0 * shd
                # Sharp cold laser rim light along upper edge
                if dy <= 2:
                    r = 80.0; g = 230.0; b = 255.0
                elif dy == 3:
                    r = 40.0; g = 140.0; b = 210.0
                img[y, x, 0] = r
                img[y, x, 1] = g
                img[y, x, 2] = b

    # Lower Shimaki Crossbeam (y: 398..416, x: 334..1032)
    for x in range(334, 1033):
        for dy in range(16):
            y = 398 + dy
            if 0 <= y < H:
                shd = 1.0 - dy / 18.0
                r = 60.0 + 65.0 * shd
                g = 12.0 + 15.0 * shd
                b = 10.0 + 15.0 * shd
                if dy <= 1:
                    r = 50.0; g = 160.0; b = 220.0
                img[y, x, 0] = r
                img[y, x, 1] = g
                img[y, x, 2] = b

    # Lower Nuki Crossbeam (y: 446..460, x: 345..1021)
    for x in range(345, 1022):
        for dy in range(14):
            y = 446 + dy
            if 0 <= y < H:
                shd = 1.0 - dy / 16.0
                r = 55.0 + 60.0 * shd
                g = 10.0 + 14.0 * shd
                b = 10.0 + 14.0 * shd
                img[y, x, 0] = r
                img[y, x, 1] = g
                img[y, x, 2] = b

    # Central Gakuzuka Plaque (x: 673..693, y: 396..448)
    for x in range(673, 694):
        for y in range(396, 449):
            img[y, x, 0] = 30.0; img[y, x, 1] = 22.0; img[y, x, 2] = 18.0
            if x == 673 or x == 693 or y == 396 or y == 448:
                img[y, x, 0] = 140.0; img[y, x, 1] = 115.0; img[y, x, 2] = 45.0 # gold trim

    # -------------------------------------------------------------
    # 6. Twin Japanese Weathered Stone Lanterns (Toro)
    # -------------------------------------------------------------
    for lx, ly in [lantern_l, lantern_r]:
        # Umbrella roof (Kasa) flared stone
        for ry in range(ly - 24, ly - 12):
            w_roof = int(14.0 + (ly - 12 - ry) * 1.5)
            for rx in range(lx - w_roof, lx + w_roof + 1):
                img[ry, rx, 0] = 35.0; img[ry, rx, 1] = 45.0; img[ry, rx, 2] = 60.0
                # Moss patches on roof
                if ((rx * 13 + ry * 7) & 7) < 3:
                    img[ry, rx, 0] = 20.0; img[ry, rx, 1] = 55.0; img[ry, rx, 2] = 35.0

        # Fire Chamber (Hibukuro) with warm amber glowing lattice window
        for wy in range(ly - 12, ly + 8):
            for wx in range(lx - 12, lx + 13):
                # Stone frame
                img[wy, wx, 0] = 40.0; img[wy, wx, 1] = 48.0; img[wy, wx, 2] = 65.0
                # Window lattice aperture: luminous warm amber candlelight
                if abs(wx - lx) <= 7 and abs(wy - (ly - 2)) <= 6:
                    if (wx - lx) % 3 != 0 and (wy - (ly - 2)) % 3 != 0:
                        img[wy, wx, 0] = 255.0
                        img[wy, wx, 1] = 190.0
                        img[wy, wx, 2] = 60.0

        # Pedestal & Base (Sao & Kiso)
        for py in range(ly + 8, ly + 40):
            pw = 8 if py < ly + 30 else 16
            for px in range(lx - pw, lx + pw + 1):
                img[py, px, 0] = 35.0; img[py, px, 1] = 42.0; img[py, px, 2] = 55.0
                if ((px * 11 + py * 5) & 7) < 2:
                    img[py, px, 0] = 18.0; img[py, px, 1] = 48.0; img[py, px, 2] = 30.0

    # Final contrast clamp
    img = np.clip(img, 0.0, 255.0).astype(np.uint8)
    out_im = Image.fromarray(img, mode='RGB')
    out_im.save(PNG_PATH)
    print(f"[3D] Saved high-resolution reference render: {PNG_PATH}")

if __name__ == "__main__":
    build_3d_obj()
    render_3d_scene()
