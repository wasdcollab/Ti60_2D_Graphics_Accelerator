`timescale 1ns/1ps
// Paint the next scanline in slot order. Transparent texels never write the
// line store, so a later sprite cannot erase an earlier sprite's opaque pixel.
// 32 interleaved banks accept an entire <=26-pixel sprite row each clock.
module video_bullet_scanline #(
    parameter integer SLOTS = 1024,
    parameter integer H_TOTAL = 1456,
    parameter integer V_TOTAL = 782,
    parameter integer PLAY_LEFT = 181,
    parameter integer PLAY_RIGHT = 1185
) (
    input wire pixel_clk, pixel_rst_n,
    input wire [11:0] x,
    input wire [10:0] y,
    input wire de,
    output wire [$clog2(SLOTS)-1:0] entry_addr,
    output wire entry_group,
    input wire [31:0] entry_data,
    input wire entry_ready,
    input wire [31:0] mask_x, mask_y,
    input wire cfg_clk, cfg_rst_n,
    input wire tile_we,
    input wire [14:0] tile_waddr,
    input wire [7:0] tile_wdata,
    input wire pal_we,
    input wire [7:0] pal_waddr,
    input wire [31:0] pal_wdata,
    output wire visible, bullet_add,
    output wire [23:0] rgb,
    output wire [7:0] alpha
);
    localparam integer CLEAR_CYCLES = 64;
    wire [10:0] next_y = (y == V_TOTAL-1) ? 11'd0 : y + 11'd1;
    wire next_visible = next_y < 768;
    assign entry_group = next_y[3];
    assign entry_addr = x - CLEAR_CYCLES;
    wire issuing = next_visible && x >= CLEAR_CYCLES &&
                   x < CLEAR_CYCLES + SLOTS && entry_ready;

    function [14:0] row_addr(input [6:0] slot, input [4:0] row);
        begin
            case (slot)
                16: row_addr = 14'd13312 + {6'd0, row, 3'b0};
                17: row_addr = 14'd13520 + {5'd0, row, 4'b0};
                18: row_addr = 14'd13936 + {5'd0, row, 4'b0};
                default: row_addr = slot < 16 ? slot[3:0]*15'd832 + {5'd0,row,5'b0}
                                    : 15'd14368 + (slot-19)*15'd832 + {5'd0,row,5'b0};
            endcase
        end
    endfunction

    // Same boot contract as the coverage RAM: ascending contiguous writes
    // starting at zero. Publish partial words too, including the final word.
    reg [159:0] cfg_word;
    reg [159:0] cfg_next;
    always @* begin
        cfg_next = tile_waddr[4:0] == 0 ? 160'd0 : cfg_word;
        cfg_next[5*tile_waddr[4:0] +: 5] = tile_wdata[4:0];
    end
    always @(posedge cfg_clk) if (tile_we) cfg_word <= cfg_next;

    reg issue_d;
    wire signed [7:0] tile_row = $signed({2'b0,entry_data[16:11]})
                                - 8'sd8 + $signed({5'd0,next_y[2:0]});
    wire [14:0] tile_addr = row_addr(entry_data[23:17],tile_row[4:0]);
    wire [159:0] texels;
    simple_dual_port_ram #(.DATA_WIDTH(160), .ADDR_WIDTH(10), .OUTPUT_REG("TRUE"))
    u_tiles (
        .wclk(cfg_clk), .we(tile_we), .waddr(tile_waddr[14:5]), .wdata(cfg_next),
        .rclk(pixel_clk), .re(1'b1), .raddr(tile_addr[14:5]), .rdata(texels)
    );
    reg draw_d;
    reg [10:0] bx_d;
    reg [4:0] width_d, shift_d;
    reg [2:0] hue_d;
    reg write_half_d;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            issue_d <= 0; draw_d <= 0;
            bx_d <= 0; width_d <= 0; shift_d <= 0;
            hue_d <= 0; write_half_d <= 0;
        end else begin
            issue_d <= issuing;
            draw_d <= issue_d && entry_ready && tile_row >= 0 && tile_row < 26
                      && entry_data[23:17] < 27;
            bx_d <= entry_data[10:0];
            width_d <= entry_data[28:24];
            hue_d <= entry_data[31:29];
            shift_d <= tile_addr[4:0];
            write_half_d <= next_y[0];
        end
    end
    wire [159:0] row_pixels = texels >> (5*shift_d);
    // Rotate the texel row onto physical banks. No two pixels in a <=26-wide
    // sprite can contend for the same bank.
    wire [255:0] unrotated;
    genvar b;
    generate for (b=0;b<32;b=b+1) begin : g_texel
        wire [4:0] index = row_pixels[5*b +: 5];
        assign unrotated[8*b +: 8] = (b < width_d && index != 0)
                                      ? {hue_d,index} : 8'd0;
    end endgenerate
    wire [511:0] duplicated = {unrotated,unrotated};
    wire [255:0] rotated = duplicated >> ((32-{1'b0,bx_d[4:0]})*8);

    wire clearing = next_visible && x < CLEAR_CYCLES;
    wire [255:0] scan_pixels;
    generate for (b=0;b<32;b=b+1) begin : g_line
        wire [4:0] local_x = b - bx_d[4:0];
        wire [11:0] dest_x = {1'b0,bx_d} + {7'd0,local_x};
        wire [7:0] code = rotated[8*b +: 8];
        wire paint = draw_d && code[4:0] != 0 &&
                     dest_x >= PLAY_LEFT && dest_x < PLAY_RIGHT;
        wire [6:0] wa = clearing ? {next_y[0],x[5:0]}
                                 : {write_half_d,dest_x[10:5]};
        simple_dual_port_ram #(.DATA_WIDTH(8), .ADDR_WIDTH(7), .OUTPUT_REG("TRUE"))
        u_line (
            .wclk(pixel_clk), .we(clearing || paint), .waddr(wa),
            .wdata(clearing ? 8'd0 : code),
            .rclk(pixel_clk), .re(1'b1), .raddr({y[0],x[10:5]}),
            .rdata(scan_pixels[8*b +: 8])
        );
    end endgenerate

    reg [4:0] read_bank;
    reg [7:0] code_d;
    reg valid_line, build_ok;
    reg live1,live2,live3,live4;
    reg [31:0] color_d;
    wire in_box = mask_x[31] && x >= {1'b0,mask_x[10:0]} &&
                  x <= {1'b0,mask_x[21:11]} &&
                  y >= mask_y[10:0] && y <= mask_y[21:11];
    wire [31:0] palette_q;
    wire [7:0] scan_code = scan_pixels[8*read_bank +: 8];
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            read_bank <= 0; code_d <= 0;
            valid_line <= 0; build_ok <= 0;
            live1 <= 0; live2 <= 0; live3 <= 0; live4 <= 0; color_d <= 0;
        end else begin
            if (x == CLEAR_CYCLES) build_ok <= entry_ready;
            else if (x > CLEAR_CYCLES && x < CLEAR_CYCLES+SLOTS && !entry_ready)
                build_ok <= 0;
            if (x == H_TOTAL-1) valid_line <= next_visible && build_ok;
            read_bank <= x[4:0];
            code_d <= scan_code;
            live1 <= de && valid_line && !in_box && x >= PLAY_LEFT && x < PLAY_RIGHT;
            live2 <= live1 && scan_code[4:0] != 0;
            live3 <= live2;
            live4 <= live3;
            color_d <= palette_q;
        end
    end
    simple_dual_port_ram #(.DATA_WIDTH(32), .ADDR_WIDTH(8), .OUTPUT_REG("TRUE"))
    u_palette (
        .wclk(cfg_clk), .we(pal_we), .waddr(pal_waddr), .wdata(pal_wdata),
        .rclk(pixel_clk), .re(1'b1), .raddr(code_d), .rdata(palette_q)
    );
    assign visible = live4;
    assign rgb = color_d[23:0];
    assign alpha = color_d[31:24];
    assign bullet_add = visible && alpha == 8'hfe;
endmodule
