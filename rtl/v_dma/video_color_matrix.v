`timescale 1ns/1ps
// =============================================================================
// video_color_matrix -- 3x3 hardware color matrix filter on the video stream
// -----------------------------------------------------------------------------
// Consumes 9 DSP multipliers. Inserted between video_dma / bloom and dvi_encoder.
//
// Pipeline latency: 3 clock cycles (matched across RGB and DE/HS/VS sync signals).
// Clock domain: pixel_clk (85.71 MHz).
//
// Control register (from APB 0x7C):
//   ctrl[3:0]   : Effect mode
//                 0: Normal / Bypass (Identity matrix)
//                 1: Flash White (Hit flash)
//                 2: Red Spell Card Pulse
//                 3: Grayscale / Monochrome (Slow-mo)
//                 4: Invert / Negative
//                 5: Toxic Green Tint
//                 6: Ice Blue Tint
//   ctrl[15:8]  : Effect Intensity (0..255, 0 = no effect, 255 = maximum)
//   ctrl[16]    : Force bypass (1 = hardware bypass regardless of mode)
// =============================================================================
module video_color_matrix (
    input  wire        pixel_clk,
    input  wire        pixel_rst_n,

    // Video stream in
    input  wire        de_in,
    input  wire        hsync_in,
    input  wire        vsync_in,
    input  wire [7:0]  r_in,
    input  wire [7:0]  g_in,
    input  wire [7:0]  b_in,

    // Control register from APB (synchronized to pixel_clk)
    input  wire [31:0] ctrl,

    // Video stream out (delayed by 3 clock cycles)
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

    wire [3:0] mode      = ctrl_s2[3:0];
    wire [7:0] intensity = ctrl_s2[15:8];
    wire       bypass    = ctrl_s2[16] || (mode == 4'd0) || (intensity == 8'd0 && mode != 4'd4);

    // -------------------------------------------------------------------------
    // Matrix coefficient calculation (Fixed point 1.8: 256 = 1.0)
    // -------------------------------------------------------------------------
    // Grayscale weights: R=77 (0.30), G=150 (0.59), B=29 (0.11)
    reg signed [10:0] m00, m01, m02;
    reg signed [10:0] m10, m11, m12;
    reg signed [10:0] m20, m21, m22;
    reg signed [18:0] off0, off1, off2;

    wire [9:0] int_ext = {2'd0, intensity}; // 0..255

    always @(*) begin
        // Default: Identity matrix
        m00 = 11'sd256; m01 = 11'sd0;   m02 = 11'sd0;   off0 = 19'sd0;
        m10 = 11'sd0;   m11 = 11'sd256; m12 = 11'sd0;   off1 = 19'sd0;
        m20 = 11'sd0;   m21 = 11'sd0;   m22 = 11'sd256; off2 = 19'sd0;

        if (!bypass) begin
            case (mode)
                4'd1: begin // Flash White: color * (1 - int/256) + 255 * (int/256)
                    m00 = $signed(11'd256 - int_ext);
                    m11 = $signed(11'd256 - int_ext);
                    m22 = $signed(11'd256 - int_ext);
                    off0 = $signed({int_ext, 8'd0});
                    off1 = $signed({int_ext, 8'd0});
                    off2 = $signed({int_ext, 8'd0});
                end

                4'd2: begin // Red Spell Card Pulse: amplify Red, attenuate G/B
                    m00 = 11'sd256;
                    m11 = $signed(11'd256 - ((int_ext * 10'd180) >> 8));
                    m22 = $signed(11'd256 - ((int_ext * 10'd200) >> 8));
                    off0 = $signed({int_ext, 6'd0}); // add red glow
                end

                4'd3: begin // Grayscale / Monochrome: Y = (77*R + 150*G + 29*B) >> 8
                    // Interpolate towards gray based on intensity
                    m00 = $signed(11'd256 - ((int_ext * (10'd256 - 10'd77)) >> 8));
                    m01 = $signed((int_ext * 10'd150) >> 8);
                    m02 = $signed((int_ext * 10'd29)  >> 8);

                    m10 = $signed((int_ext * 10'd77)  >> 8);
                    m11 = $signed(11'd256 - ((int_ext * (10'd256 - 10'd150)) >> 8));
                    m12 = $signed((int_ext * 10'd29)  >> 8);

                    m20 = $signed((int_ext * 10'd77)  >> 8);
                    m21 = $signed((int_ext * 10'd150) >> 8);
                    m22 = $signed(11'd256 - ((int_ext * (10'd256 - 10'd29)) >> 8));
                end

                4'd4: begin // Invert / Negative
                    m00 = -11'sd256;
                    m11 = -11'sd256;
                    m22 = -11'sd256;
                    off0 = 19'sd65280; // 255 * 256
                    off1 = 19'sd65280;
                    off2 = 19'sd65280;
                end

                4'd5: begin // Toxic Green Tint
                    m00 = $signed(11'd256 - ((int_ext * 10'd180) >> 8));
                    m11 = 11'sd256;
                    m22 = $signed(11'd256 - ((int_ext * 10'd180) >> 8));
                    off1 = $signed({int_ext, 6'd0});
                end

                4'd6: begin // Ice Blue Tint
                    m00 = $signed(11'd256 - ((int_ext * 10'd180) >> 8));
                    m11 = $signed(11'd256 - ((int_ext * 10'd90) >> 8));
                    m22 = 11'sd256;
                    off2 = $signed({int_ext, 6'd0});
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 1: 9 Multiplications (uses 9 DSP blocks)
    // -------------------------------------------------------------------------
    reg signed [19:0] prod00, prod01, prod02;
    reg signed [19:0] prod10, prod11, prod12;
    reg signed [19:0] prod20, prod21, prod22;
    reg signed [18:0] s1_off0, s1_off1, s1_off2;
    reg        [7:0]  s1_rin, s1_gin, s1_bin;
    reg               s1_de, s1_hs, s1_vs, s1_bypass;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            prod00 <= 20'sd0; prod01 <= 20'sd0; prod02 <= 20'sd0;
            prod10 <= 20'sd0; prod11 <= 20'sd0; prod12 <= 20'sd0;
            prod20 <= 20'sd0; prod21 <= 20'sd0; prod22 <= 20'sd0;
            s1_off0 <= 19'sd0; s1_off1 <= 19'sd0; s1_off2 <= 19'sd0;
            s1_rin <= 8'd0; s1_gin <= 8'd0; s1_bin <= 8'd0;
            s1_de <= 1'b0; s1_hs <= 1'b0; s1_vs <= 1'b0; s1_bypass <= 1'b1;
        end else begin
            s1_de     <= de_in;
            s1_hs     <= hsync_in;
            s1_vs     <= vsync_in;
            s1_bypass <= bypass;
            s1_rin    <= r_in;
            s1_gin    <= g_in;
            s1_bin    <= b_in;

            s1_off0   <= off0;
            s1_off1   <= off1;
            s1_off2   <= off2;

            // 9 Multipliers
            prod00 <= m00 * $signed({1'b0, r_in});
            prod01 <= m01 * $signed({1'b0, g_in});
            prod02 <= m02 * $signed({1'b0, b_in});

            prod10 <= m10 * $signed({1'b0, r_in});
            prod11 <= m11 * $signed({1'b0, g_in});
            prod12 <= m12 * $signed({1'b0, b_in});

            prod20 <= m20 * $signed({1'b0, r_in});
            prod21 <= m21 * $signed({1'b0, g_in});
            prod22 <= m22 * $signed({1'b0, b_in});
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 2: Summation and accumulation
    // -------------------------------------------------------------------------
    reg signed [21:0] sum_r, sum_g, sum_b;
    reg        [7:0]  s2_rin, s2_gin, s2_bin;
    reg               s2_de, s2_hs, s2_vs, s2_bypass;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            sum_r <= 22'sd0; sum_g <= 22'sd0; sum_b <= 22'sd0;
            s2_rin <= 8'd0; s2_gin <= 8'd0; s2_bin <= 8'd0;
            s2_de <= 1'b0; s2_hs <= 1'b0; s2_vs <= 1'b0; s2_bypass <= 1'b1;
        end else begin
            s2_de     <= s1_de;
            s2_hs     <= s1_hs;
            s2_vs     <= s1_vs;
            s2_bypass <= s1_bypass;
            s2_rin    <= s1_rin;
            s2_gin    <= s1_gin;
            s2_bin    <= s1_bin;

            sum_r <= $signed({{2{prod00[19]}}, prod00}) +
                     $signed({{2{prod01[19]}}, prod01}) +
                     $signed({{2{prod02[19]}}, prod02}) +
                     $signed({{3{s1_off0[18]}}, s1_off0});

            sum_g <= $signed({{2{prod10[19]}}, prod10}) +
                     $signed({{2{prod11[19]}}, prod11}) +
                     $signed({{2{prod12[19]}}, prod12}) +
                     $signed({{3{s1_off1[18]}}, s1_off1});

            sum_b <= $signed({{2{prod20[19]}}, prod20}) +
                     $signed({{2{prod21[19]}}, prod21}) +
                     $signed({{2{prod22[19]}}, prod22}) +
                     $signed({{3{s1_off2[18]}}, s1_off2});
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 3: Clamping [0, 255] and output registration
    // -------------------------------------------------------------------------
    function [7:0] clamp_byte;
        input signed [21:0] val;
        reg   signed [13:0] shifted;
        begin
            shifted = val >>> 8; // divide by 256
            if (shifted < 14'sd0)
                clamp_byte = 8'd0;
            else if (shifted > 14'sd255)
                clamp_byte = 8'd255;
            else
                clamp_byte = shifted[7:0];
        end
    endfunction

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            de_out    <= 1'b0;
            hsync_out <= 1'b0;
            vsync_out <= 1'b0;
            r_out     <= 8'd0;
            g_out     <= 8'd0;
            b_out     <= 8'd0;
        end else begin
            de_out    <= s2_de;
            hsync_out <= s2_hs;
            vsync_out <= s2_vs;

            if (s2_bypass || !s2_de) begin
                r_out <= s2_rin;
                g_out <= s2_gin;
                b_out <= s2_bin;
            end else begin
                r_out <= clamp_byte(sum_r);
                g_out <= clamp_byte(sum_g);
                b_out <= clamp_byte(sum_b);
            end
        end
    end

endmodule
