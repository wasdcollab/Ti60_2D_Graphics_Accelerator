`timescale 1ns / 1ps
// =============================================================================
// video_pixel_compositor.v
// -----------------------------------------------------------------------------
// Real-time Multi-Layer Video Pixel Compositor & Color Blender.
// Extracted from video_dma_read.v as part of the Triad Architecture refactoring.
//
// Layer Stacking Priority (Top to Bottom):
//   1. HUD Layer (OSD FPS Dashboard)
//   2. Beam & Hairlines (Plasma Cannon & Cut Warning Lines)
//   3. Boss Laser Columns (4 White-Core High-Energy Pillars)
//   4. Weather Layer (Falling Snow / Embers Particles)
//   5. Bullet Curtain Layer (192 Bullet Sprites via Line Bucket)
//   6. Baseboard (Framebuffer from DDR3 DMA)
//
// Mathematical Kernels:
// - Divisionless 8-bit normalizer div255: (n + 1 + (n >> 8)) >> 8
// - Signed linear alpha interpolator blend8: (fg*a + bg*(255-a) + 127) / 255
// - Saturated additive blender: min(255, A + B)
// =============================================================================

module video_pixel_compositor (
    input  wire        pixel_clk,
    input  wire        pixel_rst_n,

    // Timing Reference (Pipeline Stage 1 delayed)
    input  wire        t_hsync_d1,
    input  wire        t_vsync_d1,
    input  wire        t_de_d1,

    // Baseboard Framebuffer Pixel (from DMA)
    input  wire [31:0] cur_pixel,

    // Layer 1: Weather (Snow / Embers)
    input  wire        w_visible,
    input  wire [23:0] w_rgb,

    // Layer 2: Bullet Curtain
    input  wire        u_visible,
    input  wire        u_add_sel,
    input  wire [23:0] u_rgb,
    input  wire [7:0]  u_alpha,

    // Layer 3: Boss Laser Columns
    input  wire        l_visible,
    input  wire        l_laser_add,
    input  wire [7:0]  l_laser_alpha,
    input  wire [23:0] l_rgb,

    // Layer 4: Player Beam & Hairlines
    input  wire        b_visible,
    input  wire        b_beam_vis,
    input  wire        b_hair_vis,
    input  wire        b_beam_add,
    input  wire [7:0]  b_beam_alpha,
    input  wire [23:0] b_rgb,

    // Impact layer: procedural rings/discs from 2_layer_generators/video_fx_ring.
    // Already on the stage-2 cycle, so it is blended in its own stage between
    // the laser and the beam rather than widening stage 2's blend chain.
    input  wire        f_visible,
    input  wire        f_add,
    input  wire [7:0]  f_alpha,
    input  wire [23:0] f_rgb,

    // Layer 5: HUD OSD
    input  wire        hud_visible,
    input  wire [23:0] hud_rgb,
    input  wire        hud_enable,

    // Composited Stream Output (Registered)
    output reg  [7:0]  comp_a,       // Bloom radiance mask (a >= 32 radiates)
    output reg  [7:0]  comp_r,
    output reg  [7:0]  comp_g,
    output reg  [7:0]  comp_b,
    output reg         comp_hs,
    output reg         comp_vs,
    output reg         comp_de
);

    // -------------------------------------------------------------------------
    // Math Functions: div255 and blend8
    // -------------------------------------------------------------------------
    function [17:0] div255;
        input [17:0] n;
        begin
            div255 = (n + 18'd1 + (n >> 8)) >> 8;
        end
    endfunction

    function [7:0] blend8;
        input [7:0] fg;
        input [7:0] bg;
        input [7:0] a;
        reg [17:0] base;
        reg signed [8:0]  diff;
        reg signed [17:0] prod;
        reg [17:0] n;
        begin
            base = ({10'd0, bg} * 18'd255) + 18'd127;
            diff = $signed({1'b0, fg}) - $signed({1'b0, bg});
            prod = diff * $signed({1'b0, a});
            n = base + prod[17:0];
            blend8 = div255(n);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Stage 1: Weather & Bullets over Framebuffer
    // -------------------------------------------------------------------------
    wire [7:0] u_under_r = w_visible ? w_rgb[23:16] : cur_pixel[23:16];
    wire [7:0] u_under_g = w_visible ? w_rgb[15:8]  : cur_pixel[15:8];
    wire [7:0] u_under_b = w_visible ? w_rgb[7:0]   : cur_pixel[7:0];

    wire       u_opaque  = (u_alpha == 8'hFF);
    wire       u_add     = u_visible && u_add_sel;

    wire [8:0] u_sum_r   = {1'b0, u_under_r} + {1'b0, u_rgb[23:16]};
    wire [8:0] u_sum_g   = {1'b0, u_under_g} + {1'b0, u_rgb[15:8]};
    wire [8:0] u_sum_b   = {1'b0, u_under_b} + {1'b0, u_rgb[7:0]};

    wire [7:0] u_add_r   = u_sum_r[8] ? 8'd255 : u_sum_r[7:0];
    wire [7:0] u_add_g   = u_sum_g[8] ? 8'd255 : u_sum_g[7:0];
    wire [7:0] u_add_b   = u_sum_b[8] ? 8'd255 : u_sum_b[7:0];

    wire [7:0] u_out_r   = u_add    ? u_add_r
                         : u_opaque ? u_rgb[23:16]
                         : blend8(u_rgb[23:16], u_under_r, u_alpha);
    wire [7:0] u_out_g   = u_add    ? u_add_g
                         : u_opaque ? u_rgb[15:8]
                         : blend8(u_rgb[15:8],  u_under_g, u_alpha);
    wire [7:0] u_out_b   = u_add    ? u_add_b
                         : u_opaque ? u_rgb[7:0]
                         : blend8(u_rgb[7:0],   u_under_b, u_alpha);

    wire [7:0] s1_comb_r = u_visible ? u_out_r : u_under_r;
    wire [7:0] s1_comb_g = u_visible ? u_out_g : u_under_g;
    wire [7:0] s1_comb_b = u_visible ? u_out_b : u_under_b;
    wire [7:0] s1_comb_a = w_visible ? 8'd0 : u_visible ? 8'hFF : cur_pixel[31:24];

    // Pipeline Stage 1 Registers
    reg [7:0]  s1_r, s1_g, s1_b, s1_a;
    reg        s1_hs, s1_vs, s1_de;

    reg        s1_l_visible, s1_l_laser_add;
    reg [7:0]  s1_l_laser_alpha;
    reg [23:0] s1_l_rgb;

    reg        s1_b_visible, s1_b_beam_vis, s1_b_hair_vis, s1_b_beam_add;
    reg [7:0]  s1_b_beam_alpha;
    reg [23:0] s1_b_rgb;

    reg        s1_hud_visible, s1_hud_enable;
    reg [23:0] s1_hud_rgb;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            s1_r             <= 8'd0;
            s1_g             <= 8'd0;
            s1_b             <= 8'd0;
            s1_a             <= 8'd0;
            s1_hs            <= 1'b0;
            s1_vs            <= 1'b0;
            s1_de            <= 1'b0;
            s1_l_visible     <= 1'b0;
            s1_l_laser_add   <= 1'b0;
            s1_l_laser_alpha <= 8'd0;
            s1_l_rgb         <= 24'd0;
            s1_b_visible     <= 1'b0;
            s1_b_beam_vis    <= 1'b0;
            s1_b_hair_vis    <= 1'b0;
            s1_b_beam_add    <= 1'b0;
            s1_b_beam_alpha  <= 8'd0;
            s1_b_rgb         <= 24'd0;
            s1_hud_visible   <= 1'b0;
            s1_hud_enable    <= 1'b0;
            s1_hud_rgb       <= 24'd0;
        end else begin
            s1_r             <= s1_comb_r;
            s1_g             <= s1_comb_g;
            s1_b             <= s1_comb_b;
            s1_a             <= s1_comb_a;
            s1_hs            <= t_hsync_d1;
            s1_vs            <= t_vsync_d1;
            s1_de            <= t_de_d1;
            s1_l_visible     <= l_visible;
            s1_l_laser_add   <= l_laser_add;
            s1_l_laser_alpha <= l_laser_alpha;
            s1_l_rgb         <= l_rgb;
            s1_b_visible     <= b_visible;
            s1_b_beam_vis    <= b_beam_vis;
            s1_b_hair_vis    <= b_hair_vis;
            s1_b_beam_add    <= b_beam_add;
            s1_b_beam_alpha  <= b_beam_alpha;
            s1_b_rgb         <= b_rgb;
            s1_hud_visible   <= hud_visible;
            s1_hud_enable    <= hud_enable;
            s1_hud_rgb       <= hud_rgb;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2: Boss Laser Columns over Stage 1
    // -------------------------------------------------------------------------
    wire [7:0] l_bg_r = s1_r;
    wire [7:0] l_bg_g = s1_g;
    wire [7:0] l_bg_b = s1_b;

    wire [8:0] l_sum_r = {1'b0, l_bg_r} + {1'b0, s1_l_rgb[23:16]};
    wire [8:0] l_sum_g = {1'b0, l_bg_g} + {1'b0, s1_l_rgb[15:8]};
    wire [8:0] l_sum_b = {1'b0, l_bg_b} + {1'b0, s1_l_rgb[7:0]};

    wire [7:0] l_add_r = l_sum_r[8] ? 8'd255 : l_sum_r[7:0];
    wire [7:0] l_add_g = l_sum_g[8] ? 8'd255 : l_sum_g[7:0];
    wire [7:0] l_add_b = l_sum_b[8] ? 8'd255 : l_sum_b[7:0];

    wire [7:0] l_mix_r = blend8(s1_l_rgb[23:16], l_bg_r, s1_l_laser_alpha);
    wire [7:0] l_mix_g = blend8(s1_l_rgb[15:8],  l_bg_g, s1_l_laser_alpha);
    wire [7:0] l_mix_b = blend8(s1_l_rgb[7:0],   l_bg_b, s1_l_laser_alpha);

    wire [7:0] s2_comb_r = s1_l_visible && s1_l_laser_add ? l_add_r
                         : s1_l_visible                    ? l_mix_r : s1_r;
    wire [7:0] s2_comb_g = s1_l_visible && s1_l_laser_add ? l_add_g
                         : s1_l_visible                    ? l_mix_g : s1_g;
    wire [7:0] s2_comb_b = s1_l_visible && s1_l_laser_add ? l_add_b
                         : s1_l_visible                    ? l_mix_b : s1_b;

    wire [7:0] s2_comb_a = s1_l_visible ? 8'hFF : s1_a;

    // Pipeline Stage 2 Registers
    reg [7:0]  s2_r, s2_g, s2_b, s2_a;
    reg        s2_hs, s2_vs, s2_de;

    reg        s2_b_visible, s2_b_beam_vis, s2_b_hair_vis, s2_b_beam_add;
    reg [7:0]  s2_b_beam_alpha;
    reg [23:0] s2_b_rgb;

    reg        s2_hud_visible, s2_hud_enable;
    reg [23:0] s2_hud_rgb;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            s2_r            <= 8'd0;
            s2_g            <= 8'd0;
            s2_b            <= 8'd0;
            s2_a            <= 8'd0;
            s2_hs           <= 1'b0;
            s2_vs           <= 1'b0;
            s2_de           <= 1'b0;
            s2_b_visible    <= 1'b0;
            s2_b_beam_vis   <= 1'b0;
            s2_b_hair_vis   <= 1'b0;
            s2_b_beam_add   <= 1'b0;
            s2_b_beam_alpha <= 8'd0;
            s2_b_rgb        <= 24'd0;
            s2_hud_visible  <= 1'b0;
            s2_hud_enable   <= 1'b0;
            s2_hud_rgb      <= 24'd0;
        end else begin
            s2_r            <= s2_comb_r;
            s2_g            <= s2_comb_g;
            s2_b            <= s2_comb_b;
            s2_a            <= s2_comb_a;
            s2_hs           <= s1_hs;
            s2_vs           <= s1_vs;
            s2_de           <= s1_de;
            s2_b_visible    <= s1_b_visible;
            s2_b_beam_vis   <= s1_b_beam_vis;
            s2_b_hair_vis   <= s1_b_hair_vis;
            s2_b_beam_add   <= s1_b_beam_add;
            s2_b_beam_alpha <= s1_b_beam_alpha;
            s2_b_rgb        <= s1_b_rgb;
            s2_hud_visible  <= s1_hud_visible;
            s2_hud_enable   <= s1_hud_enable;
            s2_hud_rgb      <= s1_hud_rgb;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2b: Impact rings over the laser stage
    // -------------------------------------------------------------------------
    // Same two ways of compositing the rest of the chain uses: a saturated add
    // for light, an alpha blend for matter.  This is its own register stage so
    // stage 2 and stage 3 keep the combinational depth (and the slack) they had.
    wire [8:0] f_sum_r = {1'b0, s2_r} + {1'b0, f_rgb[23:16]};
    wire [8:0] f_sum_g = {1'b0, s2_g} + {1'b0, f_rgb[15:8]};
    wire [8:0] f_sum_b = {1'b0, s2_b} + {1'b0, f_rgb[7:0]};

    wire [7:0] f_add_r = f_sum_r[8] ? 8'd255 : f_sum_r[7:0];
    wire [7:0] f_add_g = f_sum_g[8] ? 8'd255 : f_sum_g[7:0];
    wire [7:0] f_add_b = f_sum_b[8] ? 8'd255 : f_sum_b[7:0];

    wire [7:0] f_mix_r = blend8(f_rgb[23:16], s2_r, f_alpha);
    wire [7:0] f_mix_g = blend8(f_rgb[15:8],  s2_g, f_alpha);
    wire [7:0] f_mix_b = blend8(f_rgb[7:0],   s2_b, f_alpha);

    wire [7:0] s2b_comb_r = f_visible && f_add ? f_add_r
                          : f_visible          ? f_mix_r : s2_r;
    wire [7:0] s2b_comb_g = f_visible && f_add ? f_add_g
                          : f_visible          ? f_mix_g : s2_g;
    wire [7:0] s2b_comb_b = f_visible && f_add ? f_add_b
                          : f_visible          ? f_mix_b : s2_b;

    wire [7:0] s2b_comb_a = f_visible ? 8'hFF : s2_a;

    reg [7:0]  s2b_r, s2b_g, s2b_b, s2b_a;
    reg        s2b_hs, s2b_vs, s2b_de;

    reg        s2b_b_visible, s2b_b_beam_vis, s2b_b_hair_vis, s2b_b_beam_add;
    reg [7:0]  s2b_b_beam_alpha;
    reg [23:0] s2b_b_rgb;

    reg        s2b_hud_visible, s2b_hud_enable;
    reg [23:0] s2b_hud_rgb;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            s2b_r            <= 8'd0;
            s2b_g            <= 8'd0;
            s2b_b            <= 8'd0;
            s2b_a            <= 8'd0;
            s2b_hs           <= 1'b0;
            s2b_vs           <= 1'b0;
            s2b_de           <= 1'b0;
            s2b_b_visible    <= 1'b0;
            s2b_b_beam_vis   <= 1'b0;
            s2b_b_hair_vis   <= 1'b0;
            s2b_b_beam_add   <= 1'b0;
            s2b_b_beam_alpha <= 8'd0;
            s2b_b_rgb        <= 24'd0;
            s2b_hud_visible  <= 1'b0;
            s2b_hud_enable   <= 1'b0;
            s2b_hud_rgb      <= 24'd0;
        end else begin
            s2b_r            <= s2b_comb_r;
            s2b_g            <= s2b_comb_g;
            s2b_b            <= s2b_comb_b;
            s2b_a            <= s2b_comb_a;
            s2b_hs           <= s2_hs;
            s2b_vs           <= s2_vs;
            s2b_de           <= s2_de;
            s2b_b_visible    <= s2_b_visible;
            s2b_b_beam_vis   <= s2_b_beam_vis;
            s2b_b_hair_vis   <= s2_b_hair_vis;
            s2b_b_beam_add   <= s2_b_beam_add;
            s2b_b_beam_alpha <= s2_b_beam_alpha;
            s2b_b_rgb        <= s2_b_rgb;
            s2b_hud_visible  <= s2_hud_visible;
            s2b_hud_enable   <= s2_hud_enable;
            s2b_hud_rgb      <= s2_hud_rgb;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3: Player Beam & HUD over Stage 2b -> Final Output Registration
    // -------------------------------------------------------------------------
    wire [8:0] b_sum_r = {1'b0, s2b_r} + {1'b0, s2b_b_rgb[23:16]};
    wire [8:0] b_sum_g = {1'b0, s2b_g} + {1'b0, s2b_b_rgb[15:8]};
    wire [8:0] b_sum_b = {1'b0, s2b_b} + {1'b0, s2b_b_rgb[7:0]};

    wire [7:0] b_add_r = b_sum_r[8] ? 8'd255 : b_sum_r[7:0];
    wire [7:0] b_add_g = b_sum_g[8] ? 8'd255 : b_sum_g[7:0];
    wire [7:0] b_add_b = b_sum_b[8] ? 8'd255 : b_sum_b[7:0];

    wire [7:0] b_mix_r = blend8(s2b_b_rgb[23:16], s2b_r, s2b_b_beam_alpha);
    wire [7:0] b_mix_g = blend8(s2b_b_rgb[15:8],  s2b_g, s2b_b_beam_alpha);
    wire [7:0] b_mix_b = blend8(s2b_b_rgb[7:0],   s2b_b, s2b_b_beam_alpha);

    wire b_add = s2b_b_visible && s2b_b_beam_vis &&  s2b_b_beam_add;
    wire b_mix = s2b_b_visible && s2b_b_beam_vis && !s2b_b_beam_add;

    wire [7:0] b_out_r = b_add        ? b_add_r
                       : b_mix        ? b_mix_r
                       : s2b_b_visible ? s2b_b_rgb[23:16]
                       : s2b_r;
    wire [7:0] b_out_g = b_add        ? b_add_g
                       : b_mix        ? b_mix_g
                       : s2b_b_visible ? s2b_b_rgb[15:8]
                       : s2b_g;
    wire [7:0] b_out_b = b_add        ? b_add_b
                       : b_mix        ? b_mix_b
                       : s2b_b_visible ? s2b_b_rgb[7:0]
                       : s2b_b;

    wire [7:0] b_out_a = s2b_b_visible ? 8'hFF : s2b_a;

    wire hud_active = s2b_hud_visible && s2b_hud_enable;

    wire [7:0] final_comb_r = hud_active ? s2b_hud_rgb[23:16] : b_out_r;
    wire [7:0] final_comb_g = hud_active ? s2b_hud_rgb[15:8]  : b_out_g;
    wire [7:0] final_comb_b = hud_active ? s2b_hud_rgb[7:0]   : b_out_b;
    wire [7:0] final_comb_a = hud_active ? 8'd0             : b_out_a;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            comp_hs <= 1'b0;
            comp_vs <= 1'b0;
            comp_de <= 1'b0;
            comp_a  <= 8'd0;
            comp_r  <= 8'd0;
            comp_g  <= 8'd0;
            comp_b  <= 8'd0;
        end else begin
            comp_hs <= s2b_hs;
            comp_vs <= s2b_vs;
            comp_de <= s2b_de;

            if (s2b_de) begin
                comp_a <= final_comb_a;
                comp_r <= final_comb_r;
                comp_g <= final_comb_g;
                comp_b <= final_comb_b;
            end else begin
                comp_a <= 8'd0;
                comp_r <= 8'd0;
                comp_g <= 8'd0;
                comp_b <= 8'd0;
            end
        end
    end

endmodule
