`timescale 1ns/1ps
module bgm_flash_spi (
    input wire clk, rst_n, start, cs_n,
    input wire [7:0] tx_data,
    input wire miso,
    output reg sclk, mosi, busy,
    output reg [7:0] rx_data
);
    reg [2:0] divider, bit_count;
    reg [7:0] tx_shift, rx_shift;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk <= 0; mosi <= 0; busy <= 0; rx_data <= 0;
            divider <= 0; bit_count <= 0; tx_shift <= 0; rx_shift <= 0;
        end else if (cs_n) begin
            sclk <= 0; busy <= 0; divider <= 0;
        end else if (!busy) begin
            if (start) begin
                busy <= 1; divider <= 0; bit_count <= 0;
                tx_shift <= tx_data; mosi <= tx_data[7]; rx_shift <= 0;
            end
        end else begin
            divider <= divider + 1'b1;
            if (divider == 3'd7) begin
                sclk <= ~sclk;
                if (!sclk) begin
                    rx_shift <= {rx_shift[6:0], miso};
                end else if (bit_count == 3'd7) begin
                    busy <= 0; rx_data <= rx_shift;
                end else begin
                    bit_count <= bit_count + 1'b1;
                    tx_shift <= {tx_shift[6:0], 1'b0};
                    mosi <= tx_shift[6];
                end
            end
        end
    end
endmodule
