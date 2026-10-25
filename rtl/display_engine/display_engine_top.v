`timescale 1ns / 1ps
// =============================================================================
// display_engine_top.v
// -----------------------------------------------------------------------------
// Pure Streaming Scanout Rendering & Post-Processing Engine (rtl/display_engine/)
//
// Triad Architecture Role: "Pure Art Workshop" (rtl/display_engine/)
// - Protocol Decoupled: Zero AXI bus dependencies, zero APB MMIO logic.
// - Receives baseboard stream from rtl/dma/ and control signals from rtl/apb/.
// - Stage 1 (1_timing/): video_timing_gen generates 1366x768 @ 75Hz digital timing.
// - Stage 2 (2_layer_generators/): 5 hardware layers generated on-the-fly:
//     * Layer 1: Weather snow/particle generator
//     * Layer 2: Bullet overlay curtain (from line bucket table)
//     * Layer 3: Boss 4-column high-energy lasers
//     * Layer 4: Player plasma beam & warning hairlines
//     * Layer 5: Dual HUD OSD telemetry
// - Stage 3 (3_compositor/): video_pixel_compositor performs priority blending.
// - Stage 4 (4_post_process/): 2D Bloom glow filter + DSP 3x3 color matrix.
// =============================================================================

module display_engine_top #(
    parameter H_ACT        = 1366,
    parameter H_FP         = 8,
    parameter H_SYNC       = 56,
    parameter H_BP         = 26,
    parameter H_TOTAL      = 1456,
    parameter V_ACT        = 768,
    parameter V_FP         = 2,
    parameter V_SYNC       = 3,
    parameter V_BP         = 9,
    parameter V_TOTAL      = 782,
    // Depth of the scanout's active pool (video_bullet_overlay's SLOTS).  This is
    // NOT the DDR bucket table depth - that is dma_top's BUCKET_SLOTS, which stays
    // at one entry per sprite per group.  See rtl/dma/dma_bucket_prefetch.v.
    parameter POOL_SLOTS   = 128,
    parameter BUCKET_SLOTS = 128,
    parameter SCANLINE_EN = 0
)(
    // Pixel Clock & Reset (85.714 MHz)
    input  wire                       pixel_clk,
    input  wire                       pixel_rst_n,

    // Timing Reference Outputs (to rtl/dma/)
    output wire [11:0]                h_cnt,
    output wire [10:0]                v_cnt,
    output wire                       t_de,
    output wire                       t_frame_start,
    output wire                       t_frame_clear,

    // Pure Baseboard Pixel Input (from rtl/dma/)
    input  wire [31:0]                fb_pixel,

    // Bullet Bucket Prefetch Data (from rtl/dma/)
    input  wire [32*POOL_SLOTS-1:0]   bucket_row,
    input  wire                       bucket_ready,
    input wire [31:0] bucket_entry_data,
    output wire [$clog2(BUCKET_SLOTS)-1:0] bucket_entry_addr,
    output wire bucket_entry_group,

    // Boot-time Tile Store & Palette Write Port (from rtl/apb/)
    input  wire                       cfg_clk,
    input  wire                       cfg_rst_n,
    input  wire                       btile_we,
    input  wire [14:0]                btile_addr,
    input  wire [7:0]                 btile_data,
    input  wire                       bpal_we,
    input  wire [7:0]                 bpal_addr,
    input  wire [31:0]                bpal_data,

    // Control Inputs (from rtl/apb/, synchronized internally)
    input  wire [31:0]                weather_ctrl,
    input  wire [31:0]                weather_mask_x,
    input  wire [31:0]                weather_mask_y,
    input  wire [47:0]                laser_colx,
    input  wire [11:0]                beam_x,
    input  wire [11:0]                beam_len,
    input  wire                       beam_en,
    input  wire [35:0]                hair_x,
    input  wire [71:0]                hair_out,
    input  wire [71:0]                hair_lft,
    input  wire [71:0]                hair_mid,

    // Procedural impact rings (from rtl/apb/apb_command_dispatcher.v, bank 2).
    // 4 slots x 32 bits each, see 2_layer_generators/video_fx_ring.v.
    input  wire [127:0]               fx_a,
    input  wire [127:0]               fx_b,
    input  wire [127:0]               fx_c,

    // HUD & FPS Telemetry
    input  wire                       hud_enable,
    input  wire [7:0]                 cpu_fps_bcd,
    input  wire [7:0]                 fpga_fps_bcd,

    // Post-Processing Filter Controls
    input  wire [31:0]                bloom_ctrl,
    input  wire [31:0]                color_matrix_ctrl,

    // Final Video Output Stream (to rtl/hdmi/dvi_encoder)
    output wire [7:0]                 video_r,
    output wire [7:0]                 video_g,
    output wire [7:0]                 video_b,
    output wire                       video_hs,
    output wire                       video_vs,
    output wire                       video_de
);

    // =========================================================================
    // Stage 1: Timing Generator (1_timing/)
    // =========================================================================
    wire t_hsync;
    wire t_vsync;

    video_timing_gen #(
        .H_ACT   (H_ACT),
        .H_FP    (H_FP),
        .H_SYNC  (H_SYNC),
        .H_BP    (H_BP),
        .H_TOTAL (H_TOTAL),
        .V_ACT   (V_ACT),
        .V_FP    (V_FP),
        .V_SYNC  (V_SYNC),
        .V_BP    (V_BP),
        .V_TOTAL (V_TOTAL)
    ) u_timing (
        .pixel_clk   (pixel_clk),
        .rst_n       (pixel_rst_n),
        .h_cnt       (h_cnt),
        .v_cnt       (v_cnt),
        .hsync       (t_hsync),
        .vsync       (t_vsync),
        .de          (t_de),
        .frame_start (t_frame_start),
        .frame_clear (t_frame_clear)
    );

    // Pipeline Alignment (1 cycle latency to match fb_pixel from DMA)
    reg        t_hsync_d1, t_vsync_d1, t_de_d1;
    reg [11:0] pixel_x_d1;
    reg [10:0] pixel_y_d1;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            t_hsync_d1 <= 1'b0;
            t_vsync_d1 <= 1'b0;
            t_de_d1    <= 1'b0;
            pixel_x_d1 <= 12'd0;
            pixel_y_d1 <= 11'd0;
        end else begin
            t_hsync_d1 <= t_hsync;
            t_vsync_d1 <= t_vsync;
            t_de_d1    <= t_de;
            pixel_x_d1 <= h_cnt;
            pixel_y_d1 <= v_cnt;
        end
    end

    // =========================================================================
    // CDC Synchronization & VSync-Atomic Register Shadowing
    // =========================================================================
    reg [15:0] fps_sync1, fps_sync2, fps_stable, fps_display;
    reg        hud_en_sync1, hud_en_sync2;

    reg [31:0] wctl_s1, wctl_s2, wctl_latched;
    reg [31:0] wbox_x_s1, wbox_x_s2, wbox_x_latched;
    reg [31:0] wbox_y_s1, wbox_y_s2, wbox_y_latched;
    reg [47:0] lcol_s1, lcol_s2, lcol_latched;
    reg [11:0] bmx_s1, bmx_s2, bmx_latched;
    reg [11:0] bml_s1, bml_s2, bml_latched;
    reg        bme_s1, bme_s2, bme_latched;
    reg [35:0] hx_s1,  hx_s2,  hx_latched;
    reg [71:0] ho_s1,  ho_s2,  ho_latched;
    reg [71:0] hl_s1,  hl_s2,  hl_latched;
    reg [71:0] hm_s1,  hm_s2,  hm_latched;
    reg [127:0] fxa_s1, fxa_s2, fxa_latched;
    reg [127:0] fxb_s1, fxb_s2, fxb_latched;
    reg [127:0] fxc_s1, fxc_s2, fxc_latched;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            fps_sync1      <= 16'd0;
            fps_sync2      <= 16'd0;
            fps_stable     <= 16'd0;
            fps_display    <= 16'd0;
            hud_en_sync1   <= 1'b1;
            hud_en_sync2   <= 1'b1;
            wctl_s1        <= 32'd0;
            wctl_s2        <= 32'd0;
            wctl_latched   <= 32'd0;
            wbox_x_s1      <= 32'd0;
            wbox_x_s2      <= 32'd0;
            wbox_x_latched <= 32'd0;
            wbox_y_s1      <= 32'd0;
            wbox_y_s2      <= 32'd0;
            wbox_y_latched <= 32'd0;
            lcol_s1        <= 48'd0;
            lcol_s2        <= 48'd0;
            lcol_latched   <= 48'd0;
            bmx_s1         <= 12'd0;
            bmx_s2         <= 12'd0;
            bmx_latched    <= 12'd0;
            bml_s1         <= 12'd0;
            bml_s2         <= 12'd0;
            bml_latched    <= 12'd0;
            bme_s1         <= 1'b0;
            bme_s2         <= 1'b0;
            bme_latched    <= 1'b0;
            hx_s1          <= 36'd0;
            hx_s2          <= 36'd0;
            hx_latched     <= 36'd0;
            ho_s1          <= 72'd0;
            ho_s2          <= 72'd0;
            ho_latched     <= 72'd0;
            hl_s1          <= 72'd0;
            hl_s2          <= 72'd0;
            hl_latched     <= 72'd0;
            hm_s1          <= 72'd0;
            hm_s2          <= 72'd0;
            hm_latched     <= 72'd0;
            fxa_s1 <= 128'd0; fxa_s2 <= 128'd0; fxa_latched <= 128'd0;
            fxb_s1 <= 128'd0; fxb_s2 <= 128'd0; fxb_latched <= 128'd0;
            fxc_s1 <= 128'd0; fxc_s2 <= 128'd0; fxc_latched <= 128'd0;
        end else begin
            fps_sync1      <= {fpga_fps_bcd, cpu_fps_bcd};
            fps_sync2      <= fps_sync1;
            fps_stable     <= fps_sync2;
            hud_en_sync1   <= hud_enable;
            hud_en_sync2   <= hud_en_sync1;
            if (v_cnt == V_ACT && h_cnt == 12'd32 && fps_stable == fps_sync2)
                fps_display <= fps_stable;

            wctl_s1        <= weather_ctrl;
            wctl_s2        <= wctl_s1;
            wbox_x_s1      <= weather_mask_x;
            wbox_x_s2      <= wbox_x_s1;
            wbox_y_s1      <= weather_mask_y;
            wbox_y_s2      <= wbox_y_s1;
            lcol_s1        <= laser_colx;
            lcol_s2        <= lcol_s1;
            bmx_s1         <= beam_x;
            bmx_s2         <= bmx_s1;
            bml_s1         <= beam_len;
            bml_s2         <= bml_s1;
            bme_s1         <= beam_en;
            bme_s2         <= bme_s1;
            hx_s1          <= hair_x;
            hx_s2          <= hx_s1;
            ho_s1          <= hair_out;
            ho_s2          <= ho_s1;
            hl_s1          <= hair_lft;
            hl_s2          <= hl_s1;
            hm_s1          <= hair_mid;
            hm_s2          <= hm_s1;
            fxa_s1         <= fx_a;
            fxa_s2         <= fxa_s1;
            fxb_s1         <= fx_b;
            fxb_s2         <= fxb_s1;
            fxc_s1         <= fx_c;
            fxc_s2         <= fxc_s1;

            if (v_cnt == V_ACT && h_cnt == 12'd0) begin
                wctl_latched   <= wctl_s2;
                wbox_x_latched <= wbox_x_s2;
                wbox_y_latched <= wbox_y_s2;
                lcol_latched   <= lcol_s2;
                bmx_latched    <= bmx_s2;
                bml_latched    <= bml_s2;
                bme_latched    <= bme_s2;
                hx_latched     <= hx_s2;
                ho_latched     <= ho_s2;
                hl_latched     <= hl_s2;
                hm_latched     <= hm_s2;
                fxa_latched    <= fxa_s2;
                fxb_latched    <= fxb_s2;
                fxc_latched    <= fxc_s2;
            end
        end
    end

    // =========================================================================
    // Stage 2: Real-time Layer Generators (2_layer_generators/)
    // =========================================================================
    // Layer 1: Weather (Snow / Embers)
    wire        w_visible;
    wire [23:0] w_rgb;
    video_weather u_weather (
        .pixel_clk   (pixel_clk),
        .pixel_rst_n (pixel_rst_n),
        .x           (pixel_x_d1),
        .y           (pixel_y_d1),
        .de          (t_de_d1),
        .ctrl        (wctl_latched),
        .mask_x      (wbox_x_latched),
        .mask_y      (wbox_y_latched),
        .visible     (w_visible),
        .rgb         (w_rgb)
    );

    // Layer 2: Bullet Curtain Overlay
    wire        u_visible;
    wire        u_add_sel;
    wire [23:0] u_rgb;
    wire [7:0]  u_alpha;
    generate if (SCANLINE_EN) begin : g_scanline
    video_bullet_scanline #(.SLOTS(BUCKET_SLOTS),.H_TOTAL(H_TOTAL),.V_TOTAL(V_TOTAL))
    u_bullets (
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),
        .x(pixel_x_d1),.y(pixel_y_d1),.de(t_de_d1),
        .entry_data(bucket_entry_data),.entry_addr(bucket_entry_addr),
        .entry_group(bucket_entry_group),.entry_ready(bucket_ready),
        .mask_x(wbox_x_latched),.mask_y(wbox_y_latched),
        .cfg_clk(cfg_clk),.cfg_rst_n(cfg_rst_n),
        .tile_we(btile_we),.tile_waddr(btile_addr),.tile_wdata(btile_data),
        .pal_we(bpal_we),.pal_waddr(bpal_addr),.pal_wdata(bpal_data),
        .visible(u_visible),.bullet_add(u_add_sel),.rgb(u_rgb),.alpha(u_alpha)
    );
    end else begin : g_legacy
    assign bucket_entry_addr = 0;
    assign bucket_entry_group = 0;
    video_bullet_overlay #(
        .SLOTS (BUCKET_SLOTS)
    ) u_bullets (
        .pixel_clk    (pixel_clk),
        .pixel_rst_n  (pixel_rst_n),
        .x            (pixel_x_d1),
        .y            (pixel_y_d1),
        .de           (t_de_d1),
        .bucket       (bucket_row),
        .bucket_ready (bucket_ready),
        .mask_x       (wbox_x_latched),
        .mask_y       (wbox_y_latched),
        .cfg_clk      (cfg_clk),
        .cfg_rst_n    (cfg_rst_n),
        .tile_we      (btile_we),
        .tile_waddr   (btile_addr),
        .tile_wdata   (btile_data),
        .pal_we       (bpal_we),
        .pal_waddr    (bpal_addr),
        .pal_wdata    (bpal_data),
        .visible      (u_visible),
        .bullet_add   (u_add_sel),
        .rgb          (u_rgb),
        .alpha        (u_alpha)
    );
    end endgenerate

    // Layer 3: Boss Laser Columns
    wire        l_visible;
    wire        l_laser_add;
    wire [7:0]  l_laser_alpha;
    wire [23:0] l_rgb;
    video_laser u_laser (
        .pixel_clk   (pixel_clk),
        .pixel_rst_n (pixel_rst_n),
        .x           (pixel_x_d1),
        .y           (pixel_y_d1),
        .de          (t_de_d1),
        .ctrl        (wctl_latched),
        .colx        (lcol_latched),
        .mask_x      (wbox_x_latched),
        .mask_y      (wbox_y_latched),
        .visible     (l_visible),
        .laser_add   (l_laser_add),
        .laser_alpha (l_laser_alpha),
        .rgb         (l_rgb)
    );

    // Layer 4: Player Beam & Hairlines
    wire        b_visible;
    wire        b_beam_vis;
    wire        b_hair_vis;
    wire        b_beam_add;
    wire [7:0]  b_beam_alpha;
    wire [23:0] b_rgb;
    video_beam u_beam (
        .pixel_clk   (pixel_clk),
        .pixel_rst_n (pixel_rst_n),
        .x           (pixel_x_d1),
        .y           (pixel_y_d1),
        .de          (t_de_d1),
        .beam_x      (bmx_latched),
        .beam_len    (bml_latched),
        .beam_en     (bme_latched),
        .hair_x      (hx_latched),
        .hair_out    (ho_latched),
        .hair_lft    (hl_latched),
        .hair_mid    (hm_latched),
        .mask_x      (wbox_x_latched),
        .mask_y      (wbox_y_latched),
        .visible     (b_visible),
        .beam_vis    (b_beam_vis),
        .hair_vis    (b_hair_vis),
        .beam_add    (b_beam_add),
        .beam_alpha  (b_beam_alpha),
        .rgb         (b_rgb)
    );

    // Layer 4b: Procedural impact rings / cores (no DDR traffic at all)
    wire        f_visible;
    wire        f_add;
    wire [7:0]  f_alpha;
    wire [23:0] f_rgb;
    video_fx_ring u_fx (
        .pixel_clk   (pixel_clk),
        .pixel_rst_n (pixel_rst_n),
        .x           (pixel_x_d1),
        .y           (pixel_y_d1),
        .de          (t_de_d1),
        .p_a         (fxa_latched),
        .p_b         (fxb_latched),
        .p_c         (fxc_latched),
        .mask_x      (wbox_x_latched),
        .mask_y      (wbox_y_latched),
        .visible     (f_visible),
        .add         (f_add),
        .alpha       (f_alpha),
        .rgb         (f_rgb)
    );

    // Layer 5: HUD OSD
    wire        hud_visible;
    wire [23:0] hud_rgb;
    video_dual_hud u_hud (
        .x           (pixel_x_d1),
        .y           (pixel_y_d1),
        .cpu_fps_bcd (fps_display[7:0]),
        .fpga_fps_bcd(fps_display[15:8]),
        .visible     (hud_visible),
        .rgb         (hud_rgb)
    );

    // =========================================================================
    // Stage 3: Multi-Layer Compositor (3_compositor/)
    // =========================================================================
    wire [7:0] comp_a, comp_r, comp_g, comp_b;
    wire       comp_hs, comp_vs, comp_de;

    video_pixel_compositor u_compositor (
        .pixel_clk    (pixel_clk),
        .pixel_rst_n  (pixel_rst_n),
        .t_hsync_d1   (t_hsync_d1),
        .t_vsync_d1   (t_vsync_d1),
        .t_de_d1      (t_de_d1),
        .cur_pixel    (fb_pixel),
        .w_visible    (w_visible),
        .w_rgb        (w_rgb),
        .u_visible    (u_visible),
        .u_add_sel    (u_add_sel),
        .u_rgb        (u_rgb),
        .u_alpha      (u_alpha),
        .l_visible    (l_visible),
        .l_laser_add  (l_laser_add),
        .l_laser_alpha(l_laser_alpha),
        .l_rgb        (l_rgb),
        .b_visible    (b_visible),
        .b_beam_vis   (b_beam_vis),
        .b_hair_vis   (b_hair_vis),
        .b_beam_add   (b_beam_add),
        .b_beam_alpha (b_beam_alpha),
        .b_rgb        (b_rgb),
        .f_visible    (f_visible),
        .f_add        (f_add),
        .f_alpha      (f_alpha),
        .f_rgb        (f_rgb),
        .hud_visible  (hud_visible),
        .hud_rgb      (hud_rgb),
        .hud_enable   (hud_en_sync2),
        .comp_a       (comp_a),
        .comp_r       (comp_r),
        .comp_g       (comp_g),
        .comp_b       (comp_b),
        .comp_hs      (comp_hs),
        .comp_vs      (comp_vs),
        .comp_de      (comp_de)
    );

    // =========================================================================
    // Stage 4: Optical Post-Processing (4_post_process/)
    // =========================================================================
    wire [7:0] bloom_r, bloom_g, bloom_b;
    wire       bloom_hs, bloom_vs, bloom_de;

    video_bloom_filter u_bloom_filter (
        .pixel_clk   (pixel_clk),
        .pixel_rst_n (pixel_rst_n),
        .de_in       (comp_de),
        .hsync_in    (comp_hs),
        .vsync_in    (comp_vs),
        .a_in        (comp_a),
        .r_in        (comp_r),
        .g_in        (comp_g),
        .b_in        (comp_b),
        .ctrl        (bloom_ctrl),
        .de_out      (bloom_de),
        .hsync_out   (bloom_hs),
        .vsync_out   (bloom_vs),
        .r_out       (bloom_r),
        .g_out       (bloom_g),
        .b_out       (bloom_b)
    );

    video_color_matrix u_color_matrix (
        .pixel_clk   (pixel_clk),
        .pixel_rst_n (pixel_rst_n),
        .de_in       (bloom_de),
        .hsync_in    (bloom_hs),
        .vsync_in    (bloom_vs),
        .r_in        (bloom_r),
        .g_in        (bloom_g),
        .b_in        (bloom_b),
        .ctrl        (color_matrix_ctrl),
        .de_out      (video_de),
        .hsync_out   (video_hs),
        .vsync_out   (video_vs),
        .r_out       (video_r),
        .g_out       (video_g),
        .b_out       (video_b)
    );

endmodule
