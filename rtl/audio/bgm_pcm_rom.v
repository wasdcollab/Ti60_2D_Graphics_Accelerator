`timescale 1ns/1ps
// Stage A: unsigned 8-bit / 12 kHz PCM, entirely in the 100 MHz core domain.
// sample_tick is the existing 100 MHz / 2048 I2S frame enable, not BCLK.
module bgm_pcm_rom #(
    parameter ROM_FILE = "assets/audio/generated/bgm_stage_a.hex",
    parameter integer ADDR_WIDTH = 11,
    parameter integer SAMPLE_COUNT = 2048
)(
    input wire clk,
    input wire rst_n,
    input wire sample_tick,
    input wire enabled,
    output reg signed [15:0] sample
);
    reg [7:0] pcm [0:SAMPLE_COUNT-1];
    reg [7:0] pcm_read;
    reg [ADDR_WIDTH-1:0] address;
    reg [13:0] rate_phase;
    wire [14:0] rate_sum = {1'b0, rate_phase} + 15'd3072;
    localparam [ADDR_WIDTH-1:0] LAST_ADDRESS = SAMPLE_COUNT - 1;

    // Efinity supports initialized, synchronous ROMs, as for the SFX ROM.
    // Keep the read register out of the reset block for block-RAM inference.
    initial $readmemh(ROM_FILE, pcm);
    always @(posedge clk)
        pcm_read <= pcm[address];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            address <= {ADDR_WIDTH{1'b0}};
            rate_phase <= 14'd0;
            sample <= 16'sd0;
        end else if (!enabled) begin
            address <= {ADDR_WIDTH{1'b0}};
            rate_phase <= 14'd0;
            sample <= 16'sd0;
        end else if (sample_tick) begin
            // Offset-binary to signed, then gain 64: -8192 .. +8128.
            sample <= { {2{~pcm_read[7]}}, ~pcm_read[7], pcm_read[6:0], 6'b0 };
            // 3072/12500 * 48828.125 = exactly 12000 source samples/s.
            if (rate_sum >= 15'd12500) begin
                rate_phase <= rate_sum[13:0] - 14'd12500;
                if (address == LAST_ADDRESS)
                    address <= {ADDR_WIDTH{1'b0}};
                else
                    address <= address + 1'b1;
            end else begin
                rate_phase <= rate_sum[13:0];
            end
        end
    end
endmodule
