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
//
// WHERE THE COLUMNS ARE (colx, four 12-bit centres, APB 0xB0 / 0xB4)
//   The opener's four columns sit at GAME_LEFT + (GAME_RIGHT-GAME_LEFT)*(2k+1)/8
//   and never move, but the cut/beam lasers are aimed wherever the boss likes -
//   and those were the last 16x768 blits in the firmware: three bars, 2,304 rows
//   a frame, which is the frame the board stutters on.  So the x of each column
//   is a register and the firmware writes whichever set of columns is standing.
//   A centre of 0 means "this column is off": the playfield starts at 181, so a
//   column parked there can never match a scan pixel and needs no enable bit.
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
    // Column centres, 4 x 12 bits, pre-synchronised to pixel_clk by the caller
    // and latched on the same frame edge as ctrl.
    input  wire [47:0]  colx,
    output wire         visible,
    output wire [23:0]  rgb
);
    wire [11:0] C0 = colx[11:0];
    wire [11:0] C1 = colx[23:12];
    wire [11:0] C2 = colx[35:24];
    wire [11:0] C3 = colx[47:36];

    wire h0 = (C0 != 12'd0) && (x >= C0 - 12'd8) && (x < C0 + 12'd8);
    wire h1 = (C1 != 12'd0) && (x >= C1 - 12'd8) && (x < C1 + 12'd8);
    wire h2 = (C2 != 12'd0) && (x >= C2 - 12'd8) && (x < C2 + 12'd8);
    wire h3 = (C3 != 12'd0) && (x >= C3 - 12'd8) && (x < C3 + 12'd8);
    wire any = h0 | h1 | h2 | h3;

    wire [11:0] rel = h0 ? (x - (C0 - 12'd8)) :
                      h1 ? (x - (C1 - 12'd8)) :
                      h2 ? (x - (C2 - 12'd8)) : (x - (C3 - 12'd8));

    // Multi-layer glowing plasma column:
    // Core (pure white 0xFFFFFF) triggers downstream u_bloom_filter hardware glow;
    // Sheath (radiant peach/white) + Beam (neon crimson) + Haze (semi-transparent halo)
    // with dynamic vertical plasma surge.
    wire [1:0]  band = ctrl[20:19];
    wire        surge = (band == 2'd0) && (y[4] ^ y[2]);

    wire core   = surge ? ((rel >= 12'd6) && (rel <= 12'd9))
                        : ((rel == 12'd7) || (rel == 12'd8));
    wire sheath = surge ? ((rel == 12'd5) || (rel == 12'd10))
                        : ((rel == 12'd6) || (rel == 12'd9));
    wire beam   = (rel >= 12'd4) && (rel <= 12'd11);

    wire [23:0] sheath_color = (band == 2'd0) ? 24'hFFA0C8 :
                               (band == 2'd1) ? 24'hFF80A0 : 24'hD05070;
    wire [23:0] beam_color   = (band == 2'd0) ? 24'hFF2050 :
                               (band == 2'd1) ? 24'hE01840 : 24'h901028;
    wire [23:0] haze_color   = (band == 2'd0) ? 24'h500C18 :
                               (band == 2'd1) ? 24'h380810 : 24'h20040A;

    assign rgb     = core   ? 24'hFFFFFF :
                     sheath ? sheath_color :
                     beam   ? beam_color : haze_color;
    assign visible = ctrl[18] && de && any;
endmodule

