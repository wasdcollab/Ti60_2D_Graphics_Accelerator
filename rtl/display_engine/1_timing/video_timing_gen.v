// video_timing_gen.v
// 1366x768 @ 59.94Hz Timing Generator for Pixel Clock = 85.714 MHz
`timescale 1ns / 1ps

module video_timing_gen #(
    parameter H_ACT   = 1366,
    parameter H_FP    = 70,
    parameter H_SYNC  = 143,
    parameter H_BP    = 213,
    parameter H_TOTAL = 1792,

    parameter V_ACT   = 768,
    parameter V_FP    = 3,
    parameter V_SYNC  = 3,
    parameter V_BP    = 24,
    parameter V_TOTAL = 798
)(
    input  wire        pixel_clk,
    input  wire        rst_n,

    output reg  [11:0] h_cnt,
    output reg  [10:0] v_cnt,
    output reg         hsync,
    output reg         vsync,
    output reg         de,
    output reg         frame_start,
    output reg         frame_clear
);

    wire [11:0] h_cnt_next = (h_cnt == H_TOTAL - 1) ? 12'd0 : (h_cnt + 12'd1);
    wire        h_end      = (h_cnt == H_TOTAL - 1);
    wire [10:0] v_cnt_next = h_end ? ((v_cnt == V_TOTAL - 1) ? 11'd0 : (v_cnt + 11'd1)) : v_cnt;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt       <= 0;
            v_cnt       <= 0;
            hsync       <= 0;
            vsync       <= 0;
            de          <= 0;
            frame_start <= 0;
            frame_clear <= 0;
        end else begin
            h_cnt <= h_cnt_next;
            v_cnt <= v_cnt_next;

            // Horizontal sync (active high or active low; typically active high for DVI/HDMI encoders)
            hsync <= (h_cnt >= (H_ACT + H_FP)) && (h_cnt < (H_ACT + H_FP + H_SYNC));

            // Vertical sync
            vsync <= (v_cnt >= (V_ACT + V_FP)) && (v_cnt < (V_ACT + V_FP + V_SYNC));

            // Data enable (active display region)
            de <= (h_cnt < H_ACT) && (v_cnt < V_ACT);

            // Prefill the larger video FIFO during vertical blanking before active scan resumes.
            frame_start <= (v_cnt == V_TOTAL - 8) && (h_cnt == 0);

            // Frame clear pulse during vertical blanking (at v_cnt == V_ACT, right after active video ends)
            frame_clear <= (v_cnt == V_ACT) && (h_cnt < 12'd16);
        end
    end

endmodule
