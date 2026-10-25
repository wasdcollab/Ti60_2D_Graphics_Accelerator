`timescale 1ns/1ps
// I2S master transmitter for MAX98357A. 100 MHz / (2 * 16) gives a
// 3.125 MHz BCLK and 48.828125 kHz stereo frame rate (64 BCLK/frame).
// DIN changes only on BCLK falling edges; the amplifier samples it on rising.
module i2s_tx #(
    parameter integer BCLK_HALF_DIV = 16
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [15:0] sample_left,
    input  wire signed [15:0] sample_right,
    output reg                sample_tick,
    output reg                i2s_bclk,
    output wire               i2s_lrclk,
    output reg                i2s_din
);
    reg [5:0] div_count;
    reg [5:0] slot;
    reg signed [15:0] left_hold, right_hold;

    // I2S changes LRCLK on a falling BCLK edge.  The following rising edge
    // is the mandatory one-bit delay; therefore load the MSB at slot 0/32
    // on the next falling edge, ready for the second rising edge.
    assign i2s_lrclk = (slot >= 6'd32);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_count  <= 6'd0;
            slot       <= 6'd0;
            left_hold  <= 16'sd0;
            right_hold <= 16'sd0;
            sample_tick <= 1'b0;
            i2s_bclk   <= 1'b0;
            i2s_din    <= 1'b0;
        end else begin
            sample_tick <= 1'b0;
            if (div_count == BCLK_HALF_DIV - 1) begin
                div_count <= 6'd0;
                if (i2s_bclk) begin
                    // Falling edge: LRCLK/data are stable before the next
                    // rising edge, which is the MAX98357A sampling edge.
                    i2s_bclk <= 1'b0;
                    if (slot <= 6'd15) begin
                        i2s_din <= left_hold[15 - slot];
                    end else if ((slot >= 6'd32) && (slot <= 6'd47)) begin
                        i2s_din <= right_hold[47 - slot];
                    end else begin
                        i2s_din <= 1'b0;
                    end
                    if (slot == 6'd63) begin
                        slot        <= 6'd0;
                        left_hold   <= sample_left;
                        right_hold  <= sample_right;
                        sample_tick <= 1'b1;
                    end else begin
                        slot <= slot + 6'd1;
                    end
                end else begin
                    i2s_bclk <= 1'b1;
                end
            end else begin
                div_count <= div_count + 6'd1;
            end
        end
    end
endmodule
