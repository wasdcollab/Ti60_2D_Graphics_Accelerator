`timescale 1ns/1ps
// =============================================================================
// video_laser -- the boss opener's laser columns, synthesised at scanout.
//
// WHY
//   Four columns of 16x768 is 3,072 rows a frame.  The engine pays a DRAM row
//   activation per row, and the boss frame already spends ~14 ms waiting on the
//   engine out of a 13.3 ms budget - this was the largest single item in it.
//
//   The shape is free to synthesise because it has almost no information in it:
//   the bar is ONE 16-pixel column pattern repeated down its whole height, at a
//   fixed x, in one of three brightness bands.  A 16-entry colour function and
//   four comparators replace 3,072 rows of blitting per frame, plus the erase
//   pass the columns used to need when they expired (and the cross-buffer
//   damage ledger that came with it) - a scanout overlay owns no pixels, so it
//   has nothing to erase.
//
// WHAT IT DRAWS (bit-exact with main.c's old blit, checked by tests/tb_laser.v)
//   per column: haze across all 16 pixels, then a 6-wide beam at offset 5 and a
//   2-wide white core at offset 7.  Columns sit at
//       GAME_LEFT + (GAME_RIGHT - GAME_LEFT) * (2k+1) / 8
//   and each is drawn from x = centre - 8.
//
// CONTROL (carried in the weather control word, so no new bus is needed)
//   ctrl[18]    enable
//   ctrl[20:19] band  0 = boss_laser > 60, 1 = > 30, 2 = otherwise
// =============================================================================
module video_laser #(
    // main.c's GAME_LEFT / GAME_RIGHT.  tools/check_hud_layout.py derives the
    // same band from those definitions.
    parameter [11:0] PLAY_LEFT  = 12'd181,
    parameter [11:0] PLAY_RIGHT = 12'd1185
)(
    input  wire         pixel_clk,
    input  wire         pixel_rst_n,
    input  wire [11:0]  x,
    input  wire [10:0]  y,
    input  wire         de,
    input  wire [31:0]  ctrl,
    output wire         visible,
    output wire [23:0]  rgb
);
    localparam integer PW = PLAY_RIGHT - PLAY_LEFT;
    localparam [11:0] C0 = PLAY_LEFT + (PW * 1) / 8;
    localparam [11:0] C1 = PLAY_LEFT + (PW * 3) / 8;
    localparam [11:0] C2 = PLAY_LEFT + (PW * 5) / 8;
    localparam [11:0] C3 = PLAY_LEFT + (PW * 7) / 8;

    wire h0 = (x >= C0 - 12'd8) && (x < C0 + 12'd8);
    wire h1 = (x >= C1 - 12'd8) && (x < C1 + 12'd8);
    wire h2 = (x >= C2 - 12'd8) && (x < C2 + 12'd8);
    wire h3 = (x >= C3 - 12'd8) && (x < C3 + 12'd8);
    wire any = h0 | h1 | h2 | h3;

    wire [11:0] rel = h0 ? (x - (C0 - 12'd8)) :
                      h1 ? (x - (C1 - 12'd8)) :
                      h2 ? (x - (C2 - 12'd8)) : (x - (C3 - 12'd8));

    // 3 FILLs a column in the old code: haze 0..15, then beam 5..10, then the
    // white core 7..8 on top.  One table now.
    wire [1:0]  band = ctrl[20:19];
    wire [23:0] haze = (band == 2'd0) ? 24'h501424 :
                       (band == 2'd1) ? 24'h602838 : 24'h504A58;
    wire [23:0] beam = (band == 2'd0) ? 24'hE03050 :
                       (band == 2'd1) ? 24'hFF6080 : 24'hFFC0D0;
    wire core = (rel == 12'd7) || (rel == 12'd8);
    wire lit  = (rel >= 12'd5) && (rel <= 12'd10);

    assign rgb     = core ? 24'hFFFFFF : (lit ? beam : haze);
    assign visible = ctrl[18] && de && any;
endmodule

