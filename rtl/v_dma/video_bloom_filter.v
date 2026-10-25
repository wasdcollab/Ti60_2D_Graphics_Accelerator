`timescale 1ns/1ps
// =============================================================================
// video_bloom_filter -- Hardware Isotropic Bloom Engine (V3 - Round Kernels)
// -----------------------------------------------------------------------------
// Features:
// 1. True 2D 5-Line Convolution, ONE kernel shared by all three channels:
//    - Symmetrical round contours, +-2 lines deep.
//    - Style 0: Soft Halo - tight round glow (+-3 px), for dense barrages.
//    - Style 1: Wide Halo - the same shape one size up (+-6 px).
//    - No per-channel radii.  Unequal R/G/B reach is a chromatic dispersion,
//      which the eye reads as rainbow fringing - "the lens is astigmatic" -
//      rather than as light.  V2 had exactly that (R +-16, G +-12, B +-8) and
//      it was the single reason the glow looked wrong on the board.
// 2. Full 24-bit Chromatic Glow Diffusion (彩色辉光扩散):
//    - Diffuses authentic projectile colors (crimson, electric cyan, amber gold, violet).
// 3. High-Energy Overdrive Gain with Soft-Knee HDR:
//    - 1/32 normalization gain for punchy, lush, prominent bullet halos.
//    - Soft-knee shoulder compression avoids digital saturation and harsh clipping.
// 4. Pure Emissive Masking:
//    - Only non-zero Framebuffer Alpha pixels (a_in >= 32) radiate light.
//    - Background, text fonts, and UI remain 100% bloom-free with zero bleeding.
// 5. Jitter-Free Digital Sync Delay (Zero Flicker HDMI Lock):
//    - Sync signals (DE, HSYNC, VSYNC) travel along a dedicated, collision-free
//      2935-cycle digital delay line with waddr != raddr on 100% of clock cycles.
//    - Completely eliminates BRAM read-during-write collisions, jitter, and HDMI dropouts.
// =============================================================================

module video_sync_delay #(
    parameter DELAY = 2935
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] din,
    output reg  [2:0] dout
);
    reg [11:0] waddr;
    wire [11:0] raddr = (waddr == DELAY - 1) ? 12'd0 : (waddr + 12'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            waddr <= 12'd0;
        else if (waddr == DELAY - 1)
            waddr <= 12'd0;
        else
            waddr <= waddr + 12'd1;
    end

    // Simple dual-port RAM: waddr != raddr ALWAYS (raddr is always waddr + 1)
    // Absolute zero read-during-write collision!
    reg [2:0] mem [DELAY-1:0];

    always @(posedge clk) begin
        mem[waddr] <= din;
        dout       <= mem[raddr];
    end
endmodule

module video_bloom_line_ram #(
    parameter DATA_WIDTH = 48,
    parameter ADDR_WIDTH = 11 // 2048 depth
)(
    input  wire                  clk,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata,
    input  wire [ADDR_WIDTH-1:0] raddr,
    output reg  [DATA_WIDTH-1:0] rdata
);
    reg [DATA_WIDTH-1:0] mem [2047:0];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

module video_bloom_filter (
    input  wire        pixel_clk,
    input  wire        pixel_rst_n,

    // Video stream in
    input  wire        de_in,
    input  wire        hsync_in,
    input  wire        vsync_in,
    input  wire [7:0]  a_in,   // Emissive mask from Framebuffer [31:24]
    input  wire [7:0]  r_in,
    input  wire [7:0]  g_in,
    input  wire [7:0]  b_in,

    // Control register from APB 0x88
    input  wire [31:0] ctrl,

    // Video stream out
    output reg         de_out,
    output reg         hsync_out,
    output reg         vsync_out,
    output reg  [7:0]  r_out,
    output reg  [7:0]  g_out,
    output reg  [7:0]  b_out
);

    // -------------------------------------------------------------------------
    // Synchronize control word to pixel_clk
    // -------------------------------------------------------------------------
    reg [31:0] ctrl_s1, ctrl_s2;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            ctrl_s1 <= 32'd0;
            ctrl_s2 <= 32'd0;
        end else begin
            ctrl_s1 <= ctrl;
            ctrl_s2 <= ctrl_s1;
        end
    end

    wire       bloom_en    = ctrl_s2[0];
    wire       bloom_style = ctrl_s2[1]; // 0: Circular Gaussian, 1: Diamond Starburst
    wire [7:0] intensity   = (ctrl_s2[23:16] == 8'd0) ? 8'd255 : ctrl_s2[23:16];

    // -------------------------------------------------------------------------
    // Pure Emissive Mask Extraction
    // Pixels tagged with Alpha byte >= 32 emit chromatic light.
    // Text fonts, HUD gutters, and background scenery have Alpha == 0.
    // -------------------------------------------------------------------------
    wire is_emissive = (a_in >= 8'd32);
    wire [7:0] em_r  = (de_in && is_emissive) ? r_in : 8'd0;
    wire [7:0] em_g  = (de_in && is_emissive) ? g_in : 8'd0;
    wire [7:0] em_b  = (de_in && is_emissive) ? b_in : 8'd0;

    // -------------------------------------------------------------------------
    // Dedicated Jitter-Free Digital Sync Delay Line
    // Delays {de, hsync, vsync} by exactly 2 lines and 25 clocks (2937 total).
    // The delay unit provides 2936 clocks; Stage 4 output register provides +1 clock.
    // -------------------------------------------------------------------------
    wire [2:0] clean_sync_out;
    video_sync_delay #(.DELAY(2936)) u_sync_delay (
        .clk   (pixel_clk),
        .rst_n (pixel_rst_n),
        .din   ({de_in, hsync_in, vsync_in}),
        .dout  (clean_sync_out)
    );

    // -------------------------------------------------------------------------
    // Phase-locked Horizontal Counter (1456 clocks per line)
    // -------------------------------------------------------------------------
    reg        hs_prev;
    reg [10:0] line_x;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            hs_prev <= 1'b0;
            line_x  <= 11'd0;
        end else begin
            hs_prev <= hsync_in;
            if (hsync_in && !hs_prev)
                line_x <= 11'd0;
            else if (line_x == 11'd1455)
                line_x <= 11'd0;
            else
                line_x <= line_x + 11'd1;
        end
    end

    // Delay line_x registers to coordinate RAM chain
    reg [10:0] line_x_d1, line_x_d2, line_x_d3;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            line_x_d1 <= 11'd0;
            line_x_d2 <= 11'd0;
            line_x_d3 <= 11'd0;
        end else begin
            line_x_d1 <= line_x;
            line_x_d2 <= line_x_d1;
            line_x_d3 <= line_x_d2;
        end
    end

    // -------------------------------------------------------------------------
    // 4 Line Buffers for 5-Line Convolution (y-4, y-3, y-2, y-1, y)
    // Center line is y-2 (Line 2).
    // RAM 1: stores line y-1 (orig RGB + emissive RGB) -> 48 bits
    // RAM 2: stores line y-2 (orig RGB + emissive RGB) -> 48 bits (CENTER ROW)
    // RAM 3: stores line y-3 (emissive RGB)            -> 24 bits
    // RAM 4: stores line y-4 (emissive RGB)            -> 24 bits
    // -------------------------------------------------------------------------
    wire [47:0] line1_rdata;
    wire [47:0] line2_rdata;
    wire [23:0] line3_rdata;
    wire [23:0] line4_rdata;

    video_bloom_line_ram #(.DATA_WIDTH(48), .ADDR_WIDTH(11)) u_ram_line1 (
        .clk   (pixel_clk),
        .we    (1'b1),
        .waddr (line_x),
        .wdata ({r_in, g_in, b_in, em_r, em_g, em_b}),
        .raddr (line_x),
        .rdata (line1_rdata)
    );

    video_bloom_line_ram #(.DATA_WIDTH(48), .ADDR_WIDTH(11)) u_ram_line2 (
        .clk   (pixel_clk),
        .we    (1'b1),
        .waddr (line_x_d1),
        .wdata (line1_rdata),
        .raddr (line_x_d1),
        .rdata (line2_rdata)
    );

    video_bloom_line_ram #(.DATA_WIDTH(24), .ADDR_WIDTH(11)) u_ram_line3 (
        .clk   (pixel_clk),
        .we    (1'b1),
        .waddr (line_x_d2),
        .wdata (line2_rdata[23:0]),
        .raddr (line_x_d2),
        .rdata (line3_rdata)
    );

    video_bloom_line_ram #(.DATA_WIDTH(24), .ADDR_WIDTH(11)) u_ram_line4 (
        .clk   (pixel_clk),
        .we    (1'b1),
        .waddr (line_x_d3),
        .wdata (line3_rdata),
        .raddr (line_x_d3),
        .rdata (line4_rdata)
    );

    // -------------------------------------------------------------------------
    // Row Alignment to Exact Column X (At Cycle 4 relative to incoming stream)
    // -------------------------------------------------------------------------
    reg [23:0] em_in_d1, em_in_d2, em_in_d3, em_in_d4;
    reg [23:0] line1_em_d1, line1_em_d2, line1_em_d3;
    reg [23:0] line2_em_d1, line2_em_d2;
    reg [23:0] line2_rgb_d1, line2_rgb_d2;
    reg [23:0] line3_em_d1;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            em_in_d1     <= 24'd0; em_in_d2     <= 24'd0;
            em_in_d3     <= 24'd0; em_in_d4     <= 24'd0;
            line1_em_d1  <= 24'd0; line1_em_d2  <= 24'd0; line1_em_d3 <= 24'd0;
            line2_em_d1  <= 24'd0; line2_em_d2  <= 24'd0;
            line2_rgb_d1 <= 24'd0; line2_rgb_d2 <= 24'd0;
            line3_em_d1  <= 24'd0;
        end else begin
            em_in_d1     <= {em_r, em_g, em_b};
            em_in_d2     <= em_in_d1;
            em_in_d3     <= em_in_d2;
            em_in_d4     <= em_in_d3;

            line1_em_d1  <= line1_rdata[23:0];
            line1_em_d2  <= line1_em_d1;
            line1_em_d3  <= line1_em_d2;

            line2_em_d1  <= line2_rdata[23:0];
            line2_em_d2  <= line2_em_d1;

            line2_rgb_d1 <= line2_rdata[47:24];
            line2_rgb_d2 <= line2_rgb_d1;

            line3_em_d1  <= line3_rdata;
        end
    end

    // The 5 vertically aligned emissive rows at current column:
    wire [23:0] row0_rgb = line4_rdata;    // y-4 (Top)
    wire [23:0] row1_rgb = line3_em_d1;    // y-3
    wire [23:0] row2_rgb = line2_em_d2;    // y-2 (Center row)
    wire [23:0] row3_rgb = line1_em_d3;    // y-1
    wire [23:0] row4_rgb = em_in_d4;       // y   (Bottom)

    wire [23:0] center_orig_rgb = line2_rgb_d2;

    // -------------------------------------------------------------------------
    // Horizontal Shift Registers (Flat Packed Vectors for Instant Compile & Optimal SRL Mapping)
    // Tap 0 is newest input, Tap 16 is center, Tap 32 is oldest.
    // -------------------------------------------------------------------------
    reg [33*24-1:0] row2_sr;
    reg [25*24-1:0] row1_sr;
    reg [25*24-1:0] row3_sr;
    reg [21*24-1:0] row0_sr;
    reg [21*24-1:0] row4_sr;
    reg [17*24-1:0] orig_sr;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            row2_sr <= {33*24{1'b0}};
            row1_sr <= {25*24{1'b0}};
            row3_sr <= {25*24{1'b0}};
            row0_sr <= {21*24{1'b0}};
            row4_sr <= {21*24{1'b0}};
            orig_sr <= {17*24{1'b0}};
        end else begin
            row2_sr <= {row2_sr[32*24-1:0], row2_rgb};
            row1_sr <= {row1_sr[24*24-1:0], row1_rgb};
            row3_sr <= {row3_sr[24*24-1:0], row3_rgb};
            row0_sr <= {row0_sr[20*24-1:0], row0_rgb};
            row4_sr <= {row4_sr[20*24-1:0], row4_rgb};
            orig_sr <= {orig_sr[16*24-1:0], center_orig_rgb};
        end
    end

    // -------------------------------------------------------------------------
    // Tap Extraction (Tap 16 is the Center Column)
    // -------------------------------------------------------------------------
    // Row 2 taps (±16 px available)
    wire [7:0] r2_16 = row2_sr[16*24 + 16 +: 8];
    wire [7:0] g2_16 = row2_sr[16*24 + 8  +: 8];
    wire [7:0] b2_16 = row2_sr[16*24 + 0  +: 8];

    wire [7:0] r2_15 = row2_sr[15*24 + 16 +: 8];
    wire [7:0] g2_15 = row2_sr[15*24 + 8  +: 8];
    wire [7:0] b2_15 = row2_sr[15*24 + 0  +: 8];

    wire [7:0] r2_17 = row2_sr[17*24 + 16 +: 8];
    wire [7:0] g2_17 = row2_sr[17*24 + 8  +: 8];
    wire [7:0] b2_17 = row2_sr[17*24 + 0  +: 8];

    wire [7:0] r2_14 = row2_sr[14*24 + 16 +: 8];
    wire [7:0] g2_14 = row2_sr[14*24 + 8  +: 8];
    wire [7:0] b2_14 = row2_sr[14*24 + 0  +: 8];

    wire [7:0] r2_18 = row2_sr[18*24 + 16 +: 8];
    wire [7:0] g2_18 = row2_sr[18*24 + 8  +: 8];
    wire [7:0] b2_18 = row2_sr[18*24 + 0  +: 8];

    wire [7:0] r2_13 = row2_sr[13*24 + 16 +: 8];
    wire [7:0] g2_13 = row2_sr[13*24 + 8  +: 8];
    wire [7:0] b2_13 = row2_sr[13*24 + 0  +: 8];

    wire [7:0] r2_19 = row2_sr[19*24 + 16 +: 8];
    wire [7:0] g2_19 = row2_sr[19*24 + 8  +: 8];
    wire [7:0] b2_19 = row2_sr[19*24 + 0  +: 8];

    wire [7:0] r2_12 = row2_sr[12*24 + 16 +: 8];
    wire [7:0] g2_12 = row2_sr[12*24 + 8  +: 8];
    wire [7:0] b2_12 = row2_sr[12*24 + 0  +: 8];

    wire [7:0] r2_20 = row2_sr[20*24 + 16 +: 8];
    wire [7:0] g2_20 = row2_sr[20*24 + 8  +: 8];
    wire [7:0] b2_20 = row2_sr[20*24 + 0  +: 8];

    wire [7:0] r2_10 = row2_sr[10*24 + 16 +: 8];
    wire [7:0] g2_10 = row2_sr[10*24 + 8  +: 8];
    wire [7:0] b2_10 = row2_sr[10*24 + 0  +: 8];

    wire [7:0] r2_22 = row2_sr[22*24 + 16 +: 8];
    wire [7:0] g2_22 = row2_sr[22*24 + 8  +: 8];
    wire [7:0] b2_22 = row2_sr[22*24 + 0  +: 8];

    wire [7:0] r2_8  = row2_sr[8*24  + 16 +: 8];
    wire [7:0] g2_8  = row2_sr[8*24  + 8  +: 8];
    wire [7:0] b2_8  = row2_sr[8*24  + 0  +: 8];

    wire [7:0] r2_24 = row2_sr[24*24 + 16 +: 8];
    wire [7:0] g2_24 = row2_sr[24*24 + 8  +: 8];
    wire [7:0] b2_24 = row2_sr[24*24 + 0  +: 8];

    wire [7:0] r2_6  = row2_sr[6*24  + 16 +: 8];
    wire [7:0] g2_6  = row2_sr[6*24  + 8  +: 8];
    wire [7:0] b2_6  = row2_sr[6*24  + 0  +: 8];

    wire [7:0] r2_26 = row2_sr[26*24 + 16 +: 8];
    wire [7:0] g2_26 = row2_sr[26*24 + 8  +: 8];
    wire [7:0] b2_26 = row2_sr[26*24 + 0  +: 8];

    wire [7:0] r2_4  = row2_sr[4*24  + 16 +: 8];
    wire [7:0] g2_4  = row2_sr[4*24  + 8  +: 8];
    wire [7:0] b2_4  = row2_sr[4*24  + 0  +: 8];

    wire [7:0] r2_28 = row2_sr[28*24 + 16 +: 8];
    wire [7:0] g2_28 = row2_sr[28*24 + 8  +: 8];
    wire [7:0] b2_28 = row2_sr[28*24 + 0  +: 8];

    wire [7:0] r2_2  = row2_sr[2*24  + 16 +: 8];
    wire [7:0] g2_2  = row2_sr[2*24  + 8  +: 8];
    wire [7:0] b2_2  = row2_sr[2*24  + 0  +: 8];

    wire [7:0] r2_30 = row2_sr[30*24 + 16 +: 8];
    wire [7:0] g2_30 = row2_sr[30*24 + 8  +: 8];
    wire [7:0] b2_30 = row2_sr[30*24 + 0  +: 8];

    wire [7:0] r2_0  = row2_sr[0*24  + 16 +: 8];
    wire [7:0] g2_0  = row2_sr[0*24  + 8  +: 8];
    wire [7:0] b2_0  = row2_sr[0*24  + 0  +: 8];

    wire [7:0] r2_32 = row2_sr[32*24 + 16 +: 8];
    wire [7:0] g2_32 = row2_sr[32*24 + 8  +: 8];
    wire [7:0] b2_32 = row2_sr[32*24 + 0  +: 8];

    // Row 1 taps (±4 px available)
    wire [7:0] r1_16 = row1_sr[16*24 + 16 +: 8];
    wire [7:0] g1_16 = row1_sr[16*24 + 8  +: 8];
    wire [7:0] b1_16 = row1_sr[16*24 + 0  +: 8];

    wire [7:0] r1_15 = row1_sr[15*24 + 16 +: 8];
    wire [7:0] g1_15 = row1_sr[15*24 + 8  +: 8];
    wire [7:0] b1_15 = row1_sr[15*24 + 0  +: 8];

    wire [7:0] r1_17 = row1_sr[17*24 + 16 +: 8];
    wire [7:0] g1_17 = row1_sr[17*24 + 8  +: 8];
    wire [7:0] b1_17 = row1_sr[17*24 + 0  +: 8];

    wire [7:0] r1_14 = row1_sr[14*24 + 16 +: 8];
    wire [7:0] g1_14 = row1_sr[14*24 + 8  +: 8];
    wire [7:0] b1_14 = row1_sr[14*24 + 0  +: 8];

    wire [7:0] r1_18 = row1_sr[18*24 + 16 +: 8];
    wire [7:0] g1_18 = row1_sr[18*24 + 8  +: 8];
    wire [7:0] b1_18 = row1_sr[18*24 + 0  +: 8];

    wire [7:0] r1_13 = row1_sr[13*24 + 16 +: 8];
    wire [7:0] g1_13 = row1_sr[13*24 + 8  +: 8];
    wire [7:0] b1_13 = row1_sr[13*24 + 0  +: 8];

    wire [7:0] r1_19 = row1_sr[19*24 + 16 +: 8];
    wire [7:0] g1_19 = row1_sr[19*24 + 8  +: 8];
    wire [7:0] b1_19 = row1_sr[19*24 + 0  +: 8];

    wire [7:0] r1_12 = row1_sr[12*24 + 16 +: 8];
    wire [7:0] g1_12 = row1_sr[12*24 + 8  +: 8];
    wire [7:0] b1_12 = row1_sr[12*24 + 0  +: 8];

    wire [7:0] r1_20 = row1_sr[20*24 + 16 +: 8];
    wire [7:0] g1_20 = row1_sr[20*24 + 8  +: 8];
    wire [7:0] b1_20 = row1_sr[20*24 + 0  +: 8];

    // Row 3 taps (±4 px available)
    wire [7:0] r3_16 = row3_sr[16*24 + 16 +: 8];
    wire [7:0] g3_16 = row3_sr[16*24 + 8  +: 8];
    wire [7:0] b3_16 = row3_sr[16*24 + 0  +: 8];

    wire [7:0] r3_15 = row3_sr[15*24 + 16 +: 8];
    wire [7:0] g3_15 = row3_sr[15*24 + 8  +: 8];
    wire [7:0] b3_15 = row3_sr[15*24 + 0  +: 8];

    wire [7:0] r3_17 = row3_sr[17*24 + 16 +: 8];
    wire [7:0] g3_17 = row3_sr[17*24 + 8  +: 8];
    wire [7:0] b3_17 = row3_sr[17*24 + 0  +: 8];

    wire [7:0] r3_14 = row3_sr[14*24 + 16 +: 8];
    wire [7:0] g3_14 = row3_sr[14*24 + 8  +: 8];
    wire [7:0] b3_14 = row3_sr[14*24 + 0  +: 8];

    wire [7:0] r3_18 = row3_sr[18*24 + 16 +: 8];
    wire [7:0] g3_18 = row3_sr[18*24 + 8  +: 8];
    wire [7:0] b3_18 = row3_sr[18*24 + 0  +: 8];

    wire [7:0] r3_13 = row3_sr[13*24 + 16 +: 8];
    wire [7:0] g3_13 = row3_sr[13*24 + 8  +: 8];
    wire [7:0] b3_13 = row3_sr[13*24 + 0  +: 8];

    wire [7:0] r3_19 = row3_sr[19*24 + 16 +: 8];
    wire [7:0] g3_19 = row3_sr[19*24 + 8  +: 8];
    wire [7:0] b3_19 = row3_sr[19*24 + 0  +: 8];

    wire [7:0] r3_12 = row3_sr[12*24 + 16 +: 8];
    wire [7:0] g3_12 = row3_sr[12*24 + 8  +: 8];
    wire [7:0] b3_12 = row3_sr[12*24 + 0  +: 8];

    wire [7:0] r3_20 = row3_sr[20*24 + 16 +: 8];
    wire [7:0] g3_20 = row3_sr[20*24 + 8  +: 8];
    wire [7:0] b3_20 = row3_sr[20*24 + 0  +: 8];

    // Row 0 taps (±2 px available)
    wire [7:0] r0_16 = row0_sr[16*24 + 16 +: 8];
    wire [7:0] g0_16 = row0_sr[16*24 + 8  +: 8];
    wire [7:0] b0_16 = row0_sr[16*24 + 0  +: 8];

    wire [7:0] r0_15 = row0_sr[15*24 + 16 +: 8];
    wire [7:0] g0_15 = row0_sr[15*24 + 8  +: 8];
    wire [7:0] b0_15 = row0_sr[15*24 + 0  +: 8];

    wire [7:0] r0_17 = row0_sr[17*24 + 16 +: 8];
    wire [7:0] g0_17 = row0_sr[17*24 + 8  +: 8];
    wire [7:0] b0_17 = row0_sr[17*24 + 0  +: 8];

    wire [7:0] r0_14 = row0_sr[14*24 + 16 +: 8];
    wire [7:0] g0_14 = row0_sr[14*24 + 8  +: 8];
    wire [7:0] b0_14 = row0_sr[14*24 + 0  +: 8];

    wire [7:0] r0_18 = row0_sr[18*24 + 16 +: 8];
    wire [7:0] g0_18 = row0_sr[18*24 + 8  +: 8];
    wire [7:0] b0_18 = row0_sr[18*24 + 0  +: 8];

    // Row 4 taps (±2 px available)
    wire [7:0] r4_16 = row4_sr[16*24 + 16 +: 8];
    wire [7:0] g4_16 = row4_sr[16*24 + 8  +: 8];
    wire [7:0] b4_16 = row4_sr[16*24 + 0  +: 8];

    wire [7:0] r4_15 = row4_sr[15*24 + 16 +: 8];
    wire [7:0] g4_15 = row4_sr[15*24 + 8  +: 8];
    wire [7:0] b4_15 = row4_sr[15*24 + 0  +: 8];

    wire [7:0] r4_17 = row4_sr[17*24 + 16 +: 8];
    wire [7:0] g4_17 = row4_sr[17*24 + 8  +: 8];
    wire [7:0] b4_17 = row4_sr[17*24 + 0  +: 8];

    wire [7:0] r4_14 = row4_sr[14*24 + 16 +: 8];
    wire [7:0] g4_14 = row4_sr[14*24 + 8  +: 8];
    wire [7:0] b4_14 = row4_sr[14*24 + 0  +: 8];

    wire [7:0] r4_18 = row4_sr[18*24 + 16 +: 8];
    wire [7:0] g4_18 = row4_sr[18*24 + 8  +: 8];
    wire [7:0] b4_18 = row4_sr[18*24 + 0  +: 8];

    wire [23:0] orig_rgb_aligned = orig_sr[16*24 +: 24];

    // -------------------------------------------------------------------------
    // 9-bit Symmetric Pair Addition Wires (avoid overflow before shifting)
    // -------------------------------------------------------------------------
    // Red pairs
    wire [8:0] p2_1_r  = {1'b0, r2_15} + {1'b0, r2_17};
    wire [8:0] p2_2_r  = {1'b0, r2_14} + {1'b0, r2_18};
    wire [8:0] p2_3_r  = {1'b0, r2_13} + {1'b0, r2_19};
    wire [8:0] p2_4_r  = {1'b0, r2_12} + {1'b0, r2_20};
    wire [8:0] p2_6_r  = {1'b0, r2_10} + {1'b0, r2_22};
    wire [8:0] p2_8_r  = {1'b0, r2_8}  + {1'b0, r2_24};
    wire [8:0] p2_10_r = {1'b0, r2_6}  + {1'b0, r2_26};
    wire [8:0] p2_12_r = {1'b0, r2_4}  + {1'b0, r2_28};
    wire [8:0] p2_14_r = {1'b0, r2_2}  + {1'b0, r2_30};
    wire [8:0] p2_16_r = {1'b0, r2_0}  + {1'b0, r2_32};

    wire [8:0] p1_1_r  = {1'b0, r1_15} + {1'b0, r1_17};
    wire [8:0] p1_2_r  = {1'b0, r1_14} + {1'b0, r1_18};
    wire [8:0] p1_3_r  = {1'b0, r1_13} + {1'b0, r1_19};
    wire [8:0] p1_4_r  = {1'b0, r1_12} + {1'b0, r1_20};

    wire [8:0] p3_1_r  = {1'b0, r3_15} + {1'b0, r3_17};
    wire [8:0] p3_2_r  = {1'b0, r3_14} + {1'b0, r3_18};
    wire [8:0] p3_3_r  = {1'b0, r3_13} + {1'b0, r3_19};
    wire [8:0] p3_4_r  = {1'b0, r3_12} + {1'b0, r3_20};

    wire [8:0] p0_1_r  = {1'b0, r0_15} + {1'b0, r0_17};
    wire [8:0] p0_2_r  = {1'b0, r0_14} + {1'b0, r0_18};

    wire [8:0] p4_1_r  = {1'b0, r4_15} + {1'b0, r4_17};
    wire [8:0] p4_2_r  = {1'b0, r4_14} + {1'b0, r4_18};

    // Green pairs
    wire [8:0] p2_1_g  = {1'b0, g2_15} + {1'b0, g2_17};
    wire [8:0] p2_2_g  = {1'b0, g2_14} + {1'b0, g2_18};
    wire [8:0] p2_3_g  = {1'b0, g2_13} + {1'b0, g2_19};
    wire [8:0] p2_4_g  = {1'b0, g2_12} + {1'b0, g2_20};
    wire [8:0] p2_6_g  = {1'b0, g2_10} + {1'b0, g2_22};
    wire [8:0] p2_8_g  = {1'b0, g2_8}  + {1'b0, g2_24};
    wire [8:0] p2_10_g = {1'b0, g2_6}  + {1'b0, g2_26};
    wire [8:0] p2_12_g = {1'b0, g2_4}  + {1'b0, g2_28};
    wire [8:0] p2_14_g = {1'b0, g2_2}  + {1'b0, g2_30};
    wire [8:0] p2_16_g = {1'b0, g2_0}  + {1'b0, g2_32};

    wire [8:0] p1_1_g  = {1'b0, g1_15} + {1'b0, g1_17};
    wire [8:0] p1_2_g  = {1'b0, g1_14} + {1'b0, g1_18};
    wire [8:0] p1_3_g  = {1'b0, g1_13} + {1'b0, g1_19};
    wire [8:0] p1_4_g  = {1'b0, g1_12} + {1'b0, g1_20};

    wire [8:0] p3_1_g  = {1'b0, g3_15} + {1'b0, g3_17};
    wire [8:0] p3_2_g  = {1'b0, g3_14} + {1'b0, g3_18};
    wire [8:0] p3_3_g  = {1'b0, g3_13} + {1'b0, g3_19};
    wire [8:0] p3_4_g  = {1'b0, g3_12} + {1'b0, g3_20};

    wire [8:0] p0_1_g  = {1'b0, g0_15} + {1'b0, g0_17};
    wire [8:0] p0_2_g  = {1'b0, g0_14} + {1'b0, g0_18};

    wire [8:0] p4_1_g  = {1'b0, g4_15} + {1'b0, g4_17};
    wire [8:0] p4_2_g  = {1'b0, g4_14} + {1'b0, g4_18};

    // Blue pairs
    wire [8:0] p2_1_b  = {1'b0, b2_15} + {1'b0, b2_17};
    wire [8:0] p2_2_b  = {1'b0, b2_14} + {1'b0, b2_18};
    wire [8:0] p2_3_b  = {1'b0, b2_13} + {1'b0, b2_19};
    wire [8:0] p2_4_b  = {1'b0, b2_12} + {1'b0, b2_20};
    wire [8:0] p2_6_b  = {1'b0, b2_10} + {1'b0, b2_22};
    wire [8:0] p2_8_b  = {1'b0, b2_8}  + {1'b0, b2_24};
    wire [8:0] p2_10_b = {1'b0, b2_6}  + {1'b0, b2_26};
    wire [8:0] p2_12_b = {1'b0, b2_4}  + {1'b0, b2_28};
    wire [8:0] p2_14_b = {1'b0, b2_2}  + {1'b0, b2_30};
    wire [8:0] p2_16_b = {1'b0, b2_0}  + {1'b0, b2_32};

    wire [8:0] p1_1_b  = {1'b0, b1_15} + {1'b0, b1_17};
    wire [8:0] p1_2_b  = {1'b0, b1_14} + {1'b0, b1_18};
    wire [8:0] p1_3_b  = {1'b0, b1_13} + {1'b0, b1_19};
    wire [8:0] p1_4_b  = {1'b0, b1_12} + {1'b0, b1_20};

    wire [8:0] p3_1_b  = {1'b0, b3_15} + {1'b0, b3_17};
    wire [8:0] p3_2_b  = {1'b0, b3_14} + {1'b0, b3_18};
    wire [8:0] p3_3_b  = {1'b0, b3_13} + {1'b0, b3_19};
    wire [8:0] p3_4_b  = {1'b0, b3_12} + {1'b0, b3_20};

    wire [8:0] p0_1_b  = {1'b0, b0_15} + {1'b0, b0_17};
    wire [8:0] p0_2_b  = {1'b0, b0_14} + {1'b0, b0_18};

    wire [8:0] p4_1_b  = {1'b0, b4_15} + {1'b0, b4_17};
    wire [8:0] p4_2_b  = {1'b0, b4_14} + {1'b0, b4_18};

    // -------------------------------------------------------------------------
    // Pipeline Stage 1: Horizontal Weighted Convolution
    // -------------------------------------------------------------------------
    reg [13:0] hsum0_r, hsum1_r, hsum3_r, hsum4_r;
    reg [14:0] hsum2_core_r;
    reg [13:0] hsum2_wing_r;

    reg [13:0] hsum0_g, hsum1_g, hsum3_g, hsum4_g;
    reg [14:0] hsum2_core_g;
    reg [13:0] hsum2_wing_g;

    reg [13:0] hsum0_b, hsum1_b, hsum3_b, hsum4_b;
    reg [14:0] hsum2_core_b;
    reg [13:0] hsum2_wing_b;

    reg [23:0] orig_rgb_stage1;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            hsum0_r <= 14'd0; hsum1_r <= 14'd0; hsum2_core_r <= 15'd0; hsum2_wing_r <= 14'd0;
            hsum3_r <= 14'd0; hsum4_r <= 14'd0;
            hsum0_g <= 14'd0; hsum1_g <= 14'd0; hsum2_core_g <= 15'd0; hsum2_wing_g <= 14'd0;
            hsum3_g <= 14'd0; hsum4_g <= 14'd0;
            hsum0_b <= 14'd0; hsum1_b <= 14'd0; hsum2_core_b <= 15'd0; hsum2_wing_b <= 14'd0;
            hsum3_b <= 14'd0; hsum4_b <= 14'd0;
            orig_rgb_stage1 <= 24'd0;
        end else begin
            orig_rgb_stage1 <= orig_rgb_aligned;

            if (!bloom_style) begin
                // =============================================================
                // Style 0: Soft Halo -- round, tight, and CHANNEL-AGNOSTIC.
                //
                // All three channels run the SAME kernel, and that is the whole
                // point.  The kernel this replaced sent red to +-16 px, green
                // to +-12 and blue to +-8, i.e. it drew three different sizes
                // of halo in three colours - which is a lens dispersion, not a
                // glow, and the eye reads it as one: every bright pixel got a
                // rainbow fringe and the whole screen looked astigmatic.
                //
                // It is also far tighter than what it replaced, so a screen
                // carrying 192 bullets stops fusing into a single white smear.
                //
                //   dy = -2 / +2 : centre x1
                //   dy = -1 / +1 : centre x3, +-1 x2
                //   dy =  0      : centre x10, +-1 x6, +-2 x3, +-3 x1
                //
                // Total weight 46.  A solid white sprite still saturates its
                // own core (255 * 46 / 32 = 366, clamped to 255), so the glow
                // is as bright as it ever was where it matters, while the
                // falloff beyond the sprite is about three times faster.
                // =============================================================
                // Red
                hsum0_r <= {6'd0, r0_16};
                hsum4_r <= {6'd0, r4_16};

                hsum1_r <= {4'd0, r1_16, 1'b0} + {6'd0, r1_16} +
                           {5'd0, p1_1_r, 1'b0};
                hsum3_r <= {4'd0, r3_16, 1'b0} + {6'd0, r3_16} +
                           {5'd0, p3_1_r, 1'b0};

                hsum2_core_r <= {3'd0, r2_16, 3'b000} + {4'd0, r2_16, 1'b0} +
                                {4'd0, p2_1_r, 2'b00} + {5'd0, p2_1_r, 1'b0} +
                                {5'd0, p2_2_r, 1'b0}  + {6'd0, p2_2_r} +
                                {6'd0, p2_3_r};
                hsum2_wing_r <= 14'd0;

                // Green
                hsum0_g <= {6'd0, g0_16};
                hsum4_g <= {6'd0, g4_16};

                hsum1_g <= {4'd0, g1_16, 1'b0} + {6'd0, g1_16} +
                           {5'd0, p1_1_g, 1'b0};
                hsum3_g <= {4'd0, g3_16, 1'b0} + {6'd0, g3_16} +
                           {5'd0, p3_1_g, 1'b0};

                hsum2_core_g <= {3'd0, g2_16, 3'b000} + {4'd0, g2_16, 1'b0} +
                                {4'd0, p2_1_g, 2'b00} + {5'd0, p2_1_g, 1'b0} +
                                {5'd0, p2_2_g, 1'b0}  + {6'd0, p2_2_g} +
                                {6'd0, p2_3_g};
                hsum2_wing_g <= 14'd0;

                // Blue
                hsum0_b <= {6'd0, b0_16};
                hsum4_b <= {6'd0, b4_16};

                hsum1_b <= {4'd0, b1_16, 1'b0} + {6'd0, b1_16} +
                           {5'd0, p1_1_b, 1'b0};
                hsum3_b <= {4'd0, b3_16, 1'b0} + {6'd0, b3_16} +
                           {5'd0, p3_1_b, 1'b0};

                hsum2_core_b <= {3'd0, b2_16, 3'b000} + {4'd0, b2_16, 1'b0} +
                                {4'd0, p2_1_b, 2'b00} + {5'd0, p2_1_b, 1'b0} +
                                {5'd0, p2_2_b, 1'b0}  + {6'd0, p2_2_b} +
                                {6'd0, p2_3_b};
                hsum2_wing_b <= 14'd0;

            end else begin
                // =============================================================
                // Style 1: Wide Halo -- the same round kernel, one size up.
                //
                // It used to be "Ethereal Diamond Starburst (Prismatic
                // Dispersion)": a 33-pixel horizontal filament whose red, green
                // and blue arms were three different lengths.  That is a
                // chromatic aberration drawn on purpose, and on the board it
                // reads as a smeared lens rather than as energy.
                //
                // What is left is the same idea - a bigger, softer halo than
                // Style 0 - carried by ONE kernel shared by all three channels:
                //   dy = -2 / +2 : centre x1
                //   dy = -1 / +1 : centre x3, +-1 x2, +-2 x1
                //   dy =  0      : centre x12, +-1 x8, +-2 x5, +-3 x3, +-4 x2, +-6 x1
                //
                // Total weight 70, horizontal reach +-6 px against Style 0's
                // +-3, vertical reach +-2 in both.
                // =============================================================
                // Red
                hsum0_r <= {6'd0, r0_16}; // 1
                hsum4_r <= {6'd0, r4_16};

                hsum1_r <= {4'd0, r1_16, 1'b0} + {6'd0, r1_16} +
                           {5'd0, p1_1_r, 1'b0} + {6'd0, p1_2_r}; // 3, 2, 1
                hsum3_r <= {4'd0, r3_16, 1'b0} + {6'd0, r3_16} +
                           {5'd0, p3_1_r, 1'b0} + {6'd0, p3_2_r};

                hsum2_core_r <= {3'd0, r2_16, 3'b000} + {4'd0, r2_16, 2'b00} +   // 12 centre
                                {3'd0, p2_1_r, 3'b000} +                        //  8 at +-1
                                {4'd0, p2_2_r, 2'b00} + {6'd0, p2_2_r} +        //  5 at +-2
                                {5'd0, p2_3_r, 1'b0}  + {6'd0, p2_3_r} +        //  3 at +-3
                                {5'd0, p2_4_r, 1'b0}  +                         //  2 at +-4
                                {6'd0, p2_6_r};                                 //  1 at +-6
                hsum2_wing_r <= 14'd0;

                // Green
                hsum0_g <= {6'd0, g0_16}; // 1
                hsum4_g <= {6'd0, g4_16};

                hsum1_g <= {4'd0, g1_16, 1'b0} + {6'd0, g1_16} +
                           {5'd0, p1_1_g, 1'b0} + {6'd0, p1_2_g}; // 3, 2, 1
                hsum3_g <= {4'd0, g3_16, 1'b0} + {6'd0, g3_16} +
                           {5'd0, p3_1_g, 1'b0} + {6'd0, p3_2_g};

                hsum2_core_g <= {3'd0, g2_16, 3'b000} + {4'd0, g2_16, 2'b00} +
                                {3'd0, p2_1_g, 3'b000} +
                                {4'd0, p2_2_g, 2'b00} + {6'd0, p2_2_g} +
                                {5'd0, p2_3_g, 1'b0}  + {6'd0, p2_3_g} +
                                {5'd0, p2_4_g, 1'b0}  +
                                {6'd0, p2_6_g};
                hsum2_wing_g <= 14'd0;

                // Blue
                hsum0_b <= {6'd0, b0_16}; // 1
                hsum4_b <= {6'd0, b4_16};

                hsum1_b <= {4'd0, b1_16, 1'b0} + {6'd0, b1_16} +
                           {5'd0, p1_1_b, 1'b0} + {6'd0, p1_2_b}; // 3, 2, 1
                hsum3_b <= {4'd0, b3_16, 1'b0} + {6'd0, b3_16} +
                           {5'd0, p3_1_b, 1'b0} + {6'd0, p3_2_b};

                hsum2_core_b <= {3'd0, b2_16, 3'b000} + {4'd0, b2_16, 2'b00} +
                                {3'd0, p2_1_b, 3'b000} +
                                {4'd0, p2_2_b, 2'b00} + {6'd0, p2_2_b} +
                                {5'd0, p2_3_b, 1'b0}  + {6'd0, p2_3_b} +
                                {5'd0, p2_4_b, 1'b0}  +
                                {6'd0, p2_6_b};
                hsum2_wing_b <= 14'd0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 2: Vertical Accumulation (Sum 5 Rows)
    // -------------------------------------------------------------------------
    reg [15:0] total_sum_r, total_sum_g, total_sum_b;
    reg [23:0] orig_rgb_stage2;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            total_sum_r     <= 16'd0;
            total_sum_g     <= 16'd0;
            total_sum_b     <= 16'd0;
            orig_rgb_stage2 <= 24'd0;
        end else begin
            total_sum_r <= {2'd0, hsum0_r} + {2'd0, hsum1_r} + {1'b0, hsum2_core_r} +
                           {2'd0, hsum2_wing_r} + {2'd0, hsum3_r} + {2'd0, hsum4_r};
            total_sum_g <= {2'd0, hsum0_g} + {2'd0, hsum1_g} + {1'b0, hsum2_core_g} +
                           {2'd0, hsum2_wing_g} + {2'd0, hsum3_g} + {2'd0, hsum4_g};
            total_sum_b <= {2'd0, hsum0_b} + {2'd0, hsum1_b} + {1'b0, hsum2_core_b} +
                           {2'd0, hsum2_wing_b} + {2'd0, hsum3_b} + {2'd0, hsum4_b};
            orig_rgb_stage2 <= orig_rgb_stage1;
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 3: Normalization & Intensity Scaling
    // Dividing by 32 (>> 5) yields punchy, lush, prominent radiance.
    // -------------------------------------------------------------------------
    wire [7:0] raw_glow_r = (total_sum_r[15:5] > 11'd255) ? 8'd255 : total_sum_r[12:5];
    wire [7:0] raw_glow_g = (total_sum_g[15:5] > 11'd255) ? 8'd255 : total_sum_g[12:5];
    wire [7:0] raw_glow_b = (total_sum_b[15:5] > 11'd255) ? 8'd255 : total_sum_b[12:5];

    reg [15:0] mult_glow_r, mult_glow_g, mult_glow_b;
    reg [23:0] orig_rgb_stage3;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            mult_glow_r     <= 16'd0;
            mult_glow_g     <= 16'd0;
            mult_glow_b     <= 16'd0;
            orig_rgb_stage3 <= 24'd0;
        end else begin
            mult_glow_r     <= raw_glow_r * intensity;
            mult_glow_g     <= raw_glow_g * intensity;
            mult_glow_b     <= raw_glow_b * intensity;
            orig_rgb_stage3 <= orig_rgb_stage2;
        end
    end

    function [7:0] soft_knee;
        input [7:0] val;
        begin
            // Soft-knee HDR tone curve: silky smooth roll-off, never digital hard-clipped
            if (val <= 8'd140)
                soft_knee = val;
            else if (val <= 8'd220)
                soft_knee = 8'd140 + (((val - 8'd140) * 6) >> 3); // 0.75 slope
            else
                soft_knee = 8'd200 + (((val - 8'd220) * 4) >> 3); // 0.5 slope
        end
    endfunction

    // Final soft-kneed chromatic bloom values
    wire [7:0] glow_r = soft_knee(mult_glow_r[15:8]);
    wire [7:0] glow_g = soft_knee(mult_glow_g[15:8]);
    wire [7:0] glow_b = soft_knee(mult_glow_b[15:8]);

    function [7:0] sat_add8;
        input [7:0] a;
        input [7:0] b;
        reg   [8:0] s;
        begin
            s = {1'b0, a} + {1'b0, b};
            sat_add8 = s[8] ? 8'hFF : s[7:0];
        end
    endfunction

    // -------------------------------------------------------------------------
    // Pipeline Stage 4: Output Register
    // -------------------------------------------------------------------------
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            de_out    <= 1'b0;
            hsync_out <= 1'b0;
            vsync_out <= 1'b0;
            r_out     <= 8'd0;
            g_out     <= 8'd0;
            b_out     <= 8'd0;
        end else begin
            de_out    <= clean_sync_out[2];
            hsync_out <= clean_sync_out[1];
            vsync_out <= clean_sync_out[0];

            if (!clean_sync_out[2]) begin
                r_out <= 8'd0;
                g_out <= 8'd0;
                b_out <= 8'd0;
            end else if (!bloom_en) begin
                // Bypass bloom: deliver untouched original center pixel
                r_out <= orig_rgb_stage3[23:16];
                g_out <= orig_rgb_stage3[15:8];
                b_out <= orig_rgb_stage3[7:0];
            end else begin
                // True Chromatic Bloom: diffuse actual color channels
                r_out <= sat_add8(orig_rgb_stage3[23:16], glow_r);
                g_out <= sat_add8(orig_rgb_stage3[15:8],  glow_g);
                b_out <= sat_add8(orig_rgb_stage3[7:0],   glow_b);
            end
        end
    end

endmodule
