`timescale 1ns/1ps
// Entry: {hue[2:0], width[4:0], slot[6:0], row_bias[5:0], bx[10:0]}.
// row = row_bias - 8 + y[2:0]. Last NONTRANSPARENT entry wins at any depth.
//
// DMA publishes a stable bucket before x=0. During the left HUD gutter,
// one coverage word per entry is cached. All masks are ready at x=SLOTS+1,
// before PLAY_LEFT=181. Transparent rectangles never enter priority selection.
// A 512x32 coverage RAM replaces the runner-up's 16Kx5 tile RAM.
//
// Config contract: boot writes contiguous ascending tile addresses from zero,
// then starts gameplay. Every write publishes a partial 32-bit coverage word,
// including the final half block. Tiles stay immutable during scanout.
// Pixel sampled at N produces RGB/alpha/visible at N+3, as before.
module video_bullet_overlay #(
    parameter integer SLOTS = 128,
    parameter [11:0] PLAY_LEFT = 12'd181,
    parameter [11:0] PLAY_RIGHT = 12'd1185
)(
    input wire pixel_clk, pixel_rst_n,
    input wire [11:0] x,
    input wire [10:0] y,
    input wire de,
    input wire [32*SLOTS-1:0] bucket,
    input wire bucket_ready,
    input wire [31:0] mask_x, mask_y,
    input wire cfg_clk, cfg_rst_n,
    input wire tile_we,
    input wire [13:0] tile_waddr,
    input wire [7:0] tile_wdata,
    input wire pal_we,
    input wire [7:0] pal_waddr,
    input wire [31:0] pal_wdata,
    output wire visible, bullet_add,
    output wire [23:0] rgb,
    output wire [7:0] alpha
);
    function [13:0] row_addr(input [6:0] slot, input [4:0] row);
        begin
            case (slot)
                7'd16: row_addr = 14'd13312 + {6'd0, row, 3'b0};
                7'd17: row_addr = 14'd13520 + {5'd0, row, 4'b0};
                7'd18: row_addr = 14'd13936 + {5'd0, row, 4'b0};
                default: row_addr = slot >= 19 ? 15'd14368 + (slot-19)*15'd832 + {5'd0,row,5'b0}
                                  : ({11'd0, slot[3:0]} << 9)
                                  + ({10'd0, slot[3:0]} << 8)
                                  + ({10'd0, slot[3:0]} << 6)
                                  + {4'd0, row, 5'b0};
            endcase
        end
    endfunction

    reg [31:0] cfg_mask;
    reg [31:0] cfg_mask_next;
    always @(*) begin
        cfg_mask_next = (tile_waddr[4:0] == 0) ? 32'd0 : cfg_mask;
        cfg_mask_next[tile_waddr[4:0]] = |tile_wdata[4:0];
    end
    always @(posedge cfg_clk) begin
        if (tile_we) cfg_mask <= cfg_mask_next;
    end

    localparam integer INDEX_BITS = $clog2(SLOTS);
    // SLOTS is not required to be a power of two (176 is the measured ceiling
    // before the pre-read window would run past PLAY_LEFT), so the pre-read
    // index is clamped: 32*x[INDEX_BITS-1:0] would address past the end of
    // `bucket` for the tail of the window.  x < SLOTS is where prep_valid
    // already gates the write, so clamping only ever touches entries not taken.
    wire [INDEX_BITS-1:0] prep_sel = (x < SLOTS) ? x[INDEX_BITS-1:0]
                                                  : {INDEX_BITS{1'b0}};
    wire [31:0] prep_entry = bucket[32*prep_sel +: 32];
    wire [6:0] prep_slot = prep_entry[23:17];
    wire signed [7:0] prep_row = $signed({2'b0, prep_entry[16:11]})
                               - 8'sd8 + $signed({5'b0, y[2:0]});
    wire [13:0] prep_addr = row_addr(prep_slot, prep_row[4:0]);
    wire prep_valid = bucket_ready && (x < SLOTS);
    wire prep_live = (prep_slot < 19) && (prep_row >= 0) && (prep_row < 26);
    wire [31:0] coverage_q;
    simple_dual_port_ram #(
        .DATA_WIDTH(32), .ADDR_WIDTH(9), .OUTPUT_REG("TRUE")
    ) u_coverage (
        .wclk(cfg_clk), .we(tile_we), .waddr(tile_waddr[13:5]),
        .wdata(cfg_mask_next), .rclk(pixel_clk), .re(1'b1),
        .raddr(prep_addr[13:5]), .rdata(coverage_q)
    );

    reg [INDEX_BITS-1:0] prep_index_d;
    reg [4:0] prep_shift_d;
    reg prep_valid_d, prep_live_d, line_valid, masks_ready;
    reg [25:0] coverage [0:SLOTS-1];
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            prep_valid_d <= 1'b0; prep_live_d <= 1'b0;
            prep_index_d <= 0; prep_shift_d <= 0;
            line_valid <= 1'b0; masks_ready <= 1'b0;
        end else begin
            prep_valid_d <= prep_valid;
            prep_live_d <= prep_live;
            prep_index_d <= prep_sel;
            prep_shift_d <= prep_addr[4:0];
            if (x == 0) begin
                line_valid <= bucket_ready;
                masks_ready <= 1'b0;
            end else if (!bucket_ready) begin
                line_valid <= 1'b0;
                masks_ready <= 1'b0;
            end else if (x == SLOTS + 1) begin
                masks_ready <= line_valid;
            end
        end
    end
    // Unreset data is gated until every slot has been replaced this scanline.
    always @(posedge pixel_clk) begin
        if (prep_valid_d)
            coverage[prep_index_d] <= prep_live_d ? (coverage_q >> prep_shift_d) : 26'd0;
    end

    wire [SLOTS-1:0] hit, win;
    genvar g;
    generate for (g = 0; g < SLOTS; g = g + 1) begin : g_hit
        wire [10:0] bx = bucket[32*g +: 11];
        wire [4:0] width = bucket[32*g+24 +: 5];
        wire [11:0] dx = x - {1'b0, bx};
        assign hit[g] = (dx < {7'd0, width})
                      && coverage[g][dx[4:0]];
    end endgenerate

    wire [SLOTS-1:0] higher_hit;
    assign higher_hit[SLOTS-1] = 1'b0;
    generate for (g = 0; g < SLOTS-1; g = g + 1) begin : g_pfx
        assign higher_hit[g] = higher_hit[g+1] | hit[g+1];
    end endgenerate
    generate for (g = 0; g < SLOTS; g = g + 1) begin : g_win
        assign win[g] = hit[g] & ~higher_hit[g];
    end endgenerate

    // Winner selection, in groups of eight.  A priority-encoder-plus-one-read
    // version was tried first because the wide and-or reduction looks expensive;
    // PNR said otherwise - at 176 slots it cost more XLR than the reduction it
    // replaced (65,742 vs 60,800 ceiling), and dropping back to the reduction at
    // 144 still overflowed by 473.  The reduction is kept because it synthesises
    // to a shallow, low-fanout tree, while a 176:1 mux does not.
    localparam integer WIN_GROUPS = (SLOTS + 7) / 8;
    wire [31:0] grp_winner [0:WIN_GROUPS-1];
    genvar j;
    generate for (j = 0; j < WIN_GROUPS; j = j + 1) begin : g_grp
        reg [31:0] gw;
        integer m;
        always @(*) begin
            gw = 32'd0;
            for (m = 0; m < 8; m = m + 1)
                if (j*8 + m < SLOTS)
                    gw = gw | (bucket[32*(j*8+m) +: 32] & {32{win[j*8+m]}});
        end
        assign grp_winner[j] = gw;
    end endgenerate

    reg [31:0] winner;
    integer n;
    always @(*) begin
        winner = 32'd0;
        for (n = 0; n < WIN_GROUPS; n = n + 1)
            winner = winner | grp_winner[n];
    end
    wire signed [7:0] winner_row = $signed({2'b0, winner[16:11]})
                                  - 8'sd8 + $signed({5'b0, y[2:0]});
    wire [13:0] tile_addr = row_addr(winner[23:17], winner_row[4:0])
                           + {3'd0, (x[10:0] - winner[10:0])};
    wire in_box = mask_x[31] && (x >= {1'b0, mask_x[10:0]})
                  && (x <= {1'b0, mask_x[21:11]})
                  && (y >= mask_y[10:0]) && (y <= mask_y[21:11]);
    wire live = bucket_ready && masks_ready && (|win) && !in_box
                && (x >= PLAY_LEFT) && (x < PLAY_RIGHT);

    reg [13:0] d1_addr;
    reg [2:0] d1_hue, d2_hue;
    reg d1_live, d2_live, d3_live, d4_live;
    reg d1_de, d2_de, d3_de, d4_de;
    reg [31:0] d4_color;
    wire [4:0] tile_q;
    wire [31:0] pal_q;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            d1_addr <= 0; d1_hue <= 0; d2_hue <= 0;
            d1_live <= 0; d2_live <= 0; d3_live <= 0; d4_live <= 0;
            d1_de <= 0; d2_de <= 0; d3_de <= 0; d4_de <= 0;
            d4_color <= 0;
        end else begin
            d1_addr <= tile_addr;
            d1_hue <= winner[31:29];
            d1_live <= live; d1_de <= de;
            d2_hue <= d1_hue; d2_live <= d1_live; d2_de <= d1_de;
            d3_live <= d2_live && (tile_q != 0); d3_de <= d2_de;
            d4_live <= d3_live; d4_de <= d3_de; d4_color <= pal_q;
        end
    end
    simple_dual_port_ram #(
        .DATA_WIDTH(5), .ADDR_WIDTH(14), .OUTPUT_REG("TRUE")
    ) u_tiles (
        .wclk(cfg_clk), .we(tile_we), .waddr(tile_waddr), .wdata(tile_wdata[4:0]),
        .rclk(pixel_clk), .re(1'b1), .raddr(d1_addr), .rdata(tile_q)
    );
    simple_dual_port_ram #(
        .DATA_WIDTH(32), .ADDR_WIDTH(8), .OUTPUT_REG("TRUE")
    ) u_palette (
        .wclk(cfg_clk), .we(pal_we), .waddr(pal_waddr), .wdata(pal_wdata),
        .rclk(pixel_clk), .re(1'b1), .raddr({d2_hue, tile_q}), .rdata(pal_q)
    );
    assign visible = d4_live && d4_de;
    assign bullet_add = visible && (d4_color[31:24] == 8'hFE);
    assign rgb = d4_color[23:0];
    assign alpha = d4_color[31:24];
endmodule
