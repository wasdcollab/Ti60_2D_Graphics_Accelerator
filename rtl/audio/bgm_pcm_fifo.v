`timescale 1ns/1ps
// CPU-fed PCM queue: one core clock, no AXI master or clock crossing.
module bgm_pcm_fifo #(
    parameter integer ADDR_WIDTH = 11,
    parameter integer START_LEVEL = 1024
)(
    input wire clk, rst_n, sample_tick,
    input wire enabled, clear,
    input wire write_strobe,
    input wire [7:0] write_data,
    output reg signed [15:0] sample,
    output wire [31:0] status,
    output reg [31:0] underflows,
    output reg [31:0] played
);
    localparam [ADDR_WIDTH:0] CAPACITY = {1'b1, {ADDR_WIDTH{1'b0}}};
    localparam [ADDR_WIDTH:0] WATERMARK = START_LEVEL;
    reg [7:0] mem [0:(1<<ADDR_WIDTH)-1];
    reg [7:0] read_data;
    reg [ADDR_WIDTH-1:0] read_ptr, write_ptr;
    reg [ADDR_WIDTH:0] count;
    reg [13:0] phase;
    reg playing, overflow, read_valid;
    wire [14:0] rate_sum = {1'b0, phase} + 15'd3072;
    wire source_tick = sample_tick && (rate_sum >= 15'd12500);
    wire pop = enabled && !clear && playing && source_tick &&
               (count != 0) && read_valid;
    wire push = !clear && write_strobe && ((count < CAPACITY) || pop);
    wire [11:0] level = count;
    assign status = {13'd0, (underflows != 0), overflow, playing, 4'd0, level};

    always @(posedge clk) begin
        if (push) mem[write_ptr] <= write_data;
        read_data <= mem[read_ptr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_ptr <= 0; write_ptr <= 0; count <= 0;
            phase <= 0; playing <= 0; overflow <= 0; read_valid <= 0;
            sample <= 0; underflows <= 0; played <= 0;
        end else if (clear) begin
            read_ptr <= 0; write_ptr <= 0; count <= 0;
            phase <= 0; playing <= 0; overflow <= 0; read_valid <= 0;
            sample <= 0; underflows <= 0; played <= 0;
        end else begin
            read_valid <= (count != 0) && !pop;
            if (push) write_ptr <= write_ptr + 1'b1;
            if (pop) read_ptr <= read_ptr + 1'b1;
            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
            if (write_strobe && !push) overflow <= 1'b1;
            if (!enabled) begin
                playing <= 0; phase <= 0; sample <= 0;
            end else if (sample_tick) begin
                if (!playing) begin
                    sample <= 0; phase <= 0;
                    if (count >= WATERMARK && read_valid) playing <= 1;
                end else begin
                    if (rate_sum >= 15'd12500) begin
                        phase <= rate_sum[13:0] - 14'd12500;
                        if (pop) begin
                            sample <= {{2{~read_data[7]}}, ~read_data[7], read_data[6:0], 6'b0};
                            played <= played + 1'b1;
                        end else begin
                            sample <= 0; playing <= 0;
                            if (underflows != 32'hffffffff)
                                underflows <= underflows + 1'b1;
                        end
                    end else phase <= rate_sum[13:0];
                end
            end
        end
    end
endmodule
