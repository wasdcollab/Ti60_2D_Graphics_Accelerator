`timescale 1ns/1ps
// =============================================================================
// video_beam -- the player's beam and the cut/beam warning hairline, drawn by
// the scanout instead of by the engine.
//
// WHY
//   These were the last two shapes in the picture that cost one DRAM row
//   activation per scanline while carrying almost no information per row:
//
//     player beam      16 x player_y   -> up to 768 rows, and its damage ledger
//                                         charged the backdrop for the same
//                                         columns again on the following frame
//     warning hairline  4 x 768, x 3   -> up to 4,608 rows across three slots,
//                                         34% of a peak pressure frame
//
//   A one-pixel column opens a DRAM row and moves four bytes.  Neither shape
//   has any per-row information in it - the beam's sheet is one column profile
//   repeated down every row and the hairline is one solid colour top to bottom -
//   so each is a handful
//   of comparators and a small lookup.  Neither of them owns a framebuffer
//   pixel either, which is the real prize: there is nothing to erase next frame
//   and no damage-ledger entry to pay for.
//
// WHAT IT DRAWS  (bit-exact with main.c's blits - tests/tb_video_beam.sv)
//
//   player beam   x in [bx-8, bx+8), y in [0, len).
//                 len is the CRAFT'S TOP EDGE, not its centre - the firmware
//                 publishes player_y - PLAYER_HALF_H, so the beam stops where
//                 the craft's artwork starts and cannot paint over the player
//                 it is fired from.  The layer order below is unchanged and
//                 still puts the beam above the framebuffer the craft is drawn
//                 into; the length is what keeps them apart, because this
//                 layer has no way to know what is under it.
//                 laser_glow_build() fills a 16-wide sheet of identical rows,
//                 so the whole 16x768 surface is a lookup on the column offset
//                 and nothing else.  Columns 0, 1, 14 and 15 are MAGENTA_KEY,
//                 which the blit skipped - transparent here too.
//                 The same lookup also answers HOW each drawn column is
//                 composited: the two centre columns add (they are the light
//                 source and the only ones allowed to saturate), the halo and
//                 the rim blend with an alpha that ramps 130 -> 190 inward, so
//                 the beam stays a light shining through the air instead of a
//                 solid white bar.  See the table below.
//
//   hairline      three slots, each a vertical line standing on x = hx[k]:
//                 column hx-2 and column hx+1 take the slot's "outer" colour,
//                 hx-1 takes "left", hx takes "centre".  A colour of 0 means
//                 "draw nothing" - the blit that produced it emitted no pixels
//                 for that column, and 0x000000 is not one of the colours any
//                 hairline has.  A slot with hx == 0 is off.
//                 main.c walks the slots 0, 1, 2 in order, so a later slot
//                 covers an earlier one; slot 2 wins here.
//
// LAYER ORDER
//   HUD > beam (this module) > laser columns (video_laser) > weather >
//   framebuffer.  The beam is drawn after the hairline, and after the laser
//   columns, in game_render(), and this module's output keeps that order: the
//   hairlines replace, the beam's core adds on top of the laser columns'
//   result, and its halo blends over the same thing.  The laser columns are
//   additive, so this module has to sit above them rather than beside them.
//
//   The player itself is NOT a layer in this chain: the craft is engine-drawn
//   framebuffer pixels, i.e. the bottom of it.  That is exactly why the beam's
//   length stops at the craft's top edge - see the beam's hit test below.
// =============================================================================
module video_beam (
    input  wire         pixel_clk,
    input  wire         pixel_rst_n,
    input  wire [11:0]  x,
    input  wire [10:0]  y,
    input  wire         de,

    // Player beam: centre column, height, enable.  Latched by the caller on the
    // same frame edge as the control word, so a beam can never appear at the
    // previous frame's x.
    input  wire [11:0]  beam_x,
    input  wire [11:0]  beam_len,
    input  wire         beam_en,

    // Three warning hairlines, packed: slot k occupies bits [12k+11 : 12k].
    input  wire [35:0]  hair_x,
    // Per slot, the colours of the four columns it can stand on.  Only three
    // are carried because the shape is symmetric: main.c fills (hx-2, width 4)
    // and then (hx-1, width 2), so columns hx-2 and hx+1 always come out the
    // same colour while the middle pair can differ.
    input  wire [71:0]  hair_out,   // hx-2 and hx+1
    input  wire [71:0]  hair_lft,   // hx-1
    input  wire [71:0]  hair_mid,   // hx
    // The same occlusion box the weather and the bullet curtain take: the pause
    // card, the stage banner and the boss dialogue are framebuffer pixels this
    // layer is composited over and cannot see.
    //     mask_x: [10:0] x0, [21:11] x1, [31] enable (zero = layer untouched)
    //     mask_y: [10:0] y0, [21:11] y1
    input  wire [31:0]  mask_x,
    input  wire [31:0]  mask_y,

    output wire         visible,
    output wire         beam_vis,   // beam pixels only
    output wire         hair_vis,   // warning-hairline pixels only
    output wire         beam_add,   // 1 = the scanout should add, not replace
    // What the scanout blends with when beam_add is 0.  Meaningless on a
    // hairline pixel, which always replaces, and 0 on a keyed column, which
    // draws nothing at all.
    output wire [7:0]   beam_alpha,
    output wire [23:0]  rgb
);
    // ---------------------------------------------------------------- beam ---
    // Hit test written so nothing underflows: bx-8 <= x  <=>  x+8 >= bx.
    //
    // y < beam_len is exclusive, and that is what puts the beam's end ON the
    // craft's top edge rather than through the middle of it: the firmware
    // publishes len = player_y - PLAYER_HALF_H, so the last row this layer
    // owns is player_y - 25 and row player_y - 24 - the craft's first row -
    // belongs to the framebuffer again.  The module has no other way to know
    // where the player is, and none is wanted: adding one would mean testing
    // every beam pixel against a 48x48 box, on the layer that exists
    // specifically because it carries no per-row state.
    wire        b_hit = beam_en && (y < beam_len) &&
                        (x + 12'd8 >= beam_x) && (x < beam_x + 12'd8);
    wire [11:0] b_rel = x + 12'd8 - beam_x;         // 0..15 while b_hit

    // The column profile, sixteen entries, indexed by the column offset.  The
    // sheet repeats every 16 rows, so this one table is the whole 16x768
    // surface laser_glow_build() builds - and tb_video_beam.sv checks the two
    // against each other column by column and row by row.
    //
    // FOUR THINGS PER COLUMN, not one:
    //
    //     rgb     the colour the sheet carries there
    //     add     1 = the scanout adds this pixel, 0 = it blends
    //     alpha   what it blends WITH, ignored when add is 1
    //
    // WHY THE COLUMNS DIFFER, AND WHY THAT NEEDED A NEW PORT
    //
    //   A beam is light, and light adds - but only its core is a light SOURCE.
    //   The old table had six of its twelve drawn columns at white or near
    //   white (5, 6, 7, 8, 9, 10) and every one of them added, so on any
    //   non-zero background the whole strip saturated: the core's over-exposure
    //   spread out until the beam read as a solid white bar rather than a light
    //   shining through the air.  Dimming the colours does not fix that - it
    //   makes a grey bar instead of a white one.  The blend has to differ by
    //   column, which is the reason video_beam grew a per-column selector at
    //   all.
    //
    //   So: the two centre columns add and are the only place allowed to
    //   saturate, and everything outside them blends against the snow.  The
    //   alpha then ramps outward-in, 130 at the rim and 190 through the halo,
    //   so the edge fades into the picture instead of stopping on a line, and
    //   the halo keeps its colour - an added cyan would bleach the snow toward
    //   white exactly where the colour is supposed to show.
    //
    //   Columns 0, 1, 14 and 15 are MAGENTA_KEY: the engine's colour key
    //   skipped them, so the backdrop stayed, and skipping them here leaves the
    //   same backdrop.  They are "not drawn" and their table row is a don't
    //   care that reads as nothing.
    reg  [23:0] b_lut_rgb;
    reg         b_lut_add;
    reg  [7:0]  b_lut_alpha;
    always @(*) begin
        case (b_rel[3:0])
            // rim: the most transparent step, fading into whatever is behind
            4'd2,  4'd13: begin b_lut_rgb = 24'h2E6C8C;
                                b_lut_add = 1'b0; b_lut_alpha = 8'd130; end
            4'd3,  4'd12: begin b_lut_rgb = 24'h4696C0;
                                b_lut_add = 1'b0; b_lut_alpha = 8'd130; end
            4'd4,  4'd11: begin b_lut_rgb = 24'h66C0E8;
                                b_lut_add = 1'b0; b_lut_alpha = 8'd130; end
            // halo: still translucent, still carrying its own colour
            4'd5,  4'd10: begin b_lut_rgb = 24'h8AD8FF;
                                b_lut_add = 1'b0; b_lut_alpha = 8'd190; end
            4'd6,  4'd9:  begin b_lut_rgb = 24'hC0EEFF;
                                b_lut_add = 1'b0; b_lut_alpha = 8'd190; end
            // core: two columns, the only ones that add, the only ones white
            4'd7,  4'd8:  begin b_lut_rgb = 24'hFFFFFF;
                                b_lut_add = 1'b1; b_lut_alpha = 8'd255; end
            default:      begin b_lut_rgb = 24'hFFFFFF;
                                b_lut_add = 1'b0; b_lut_alpha = 8'd0;   end
        endcase
    end

    wire [23:0] b_rgb = b_lut_rgb;
    // Columns 2..13 are the drawn ones; the keyed edge columns keep whatever the
    // layer underneath put there.
    wire b_op = b_hit && (b_rel >= 12'd2) && (b_rel <= 12'd13);

    // ------------------------------------------------------------ hairline ---
    wire [11:0] hx0 = hair_x[11:0];
    wire [11:0] hx1 = hair_x[23:12];
    wire [11:0] hx2 = hair_x[35:24];

    wire h0_m2 = (hx0 >= 12'd2) && (x == hx0 - 12'd2);
    wire h0_m1 = (hx0 >= 12'd1) && (x == hx0 - 12'd1);
    wire h0_p0 = (hx0 != 12'd0) && (x == hx0);
    wire h0_p1 = (hx0 != 12'd0) && (x == hx0 + 12'd1);
    wire h0_hit = h0_m2 | h0_m1 | h0_p0 | h0_p1;

    wire h1_m2 = (hx1 >= 12'd2) && (x == hx1 - 12'd2);
    wire h1_m1 = (hx1 >= 12'd1) && (x == hx1 - 12'd1);
    wire h1_p0 = (hx1 != 12'd0) && (x == hx1);
    wire h1_p1 = (hx1 != 12'd0) && (x == hx1 + 12'd1);
    wire h1_hit = h1_m2 | h1_m1 | h1_p0 | h1_p1;

    wire h2_m2 = (hx2 >= 12'd2) && (x == hx2 - 12'd2);
    wire h2_m1 = (hx2 >= 12'd1) && (x == hx2 - 12'd1);
    wire h2_p0 = (hx2 != 12'd0) && (x == hx2);
    wire h2_p1 = (hx2 != 12'd0) && (x == hx2 + 12'd1);
    wire h2_hit = h2_m2 | h2_m1 | h2_p0 | h2_p1;

    wire [23:0] c0_out = hair_out[23:0];
    wire [23:0] c0_lft = hair_lft[23:0];
    wire [23:0] c0_mid = hair_mid[23:0];
    wire [23:0] c1_out = hair_out[47:24];
    wire [23:0] c1_lft = hair_lft[47:24];
    wire [23:0] c1_mid = hair_mid[47:24];
    wire [23:0] c2_out = hair_out[71:48];
    wire [23:0] c2_lft = hair_lft[71:48];
    wire [23:0] c2_mid = hair_mid[71:48];

    wire [23:0] r0 = (h0_m2 | h0_p1) ? c0_out : h0_m1 ? c0_lft : c0_mid;
    wire [23:0] r1 = (h1_m2 | h1_p1) ? c1_out : h1_m1 ? c1_lft : c1_mid;
    wire [23:0] r2 = (h2_m2 | h2_p1) ? c2_out : h2_m1 ? c2_lft : c2_mid;

    // A later slot covers an earlier one: game_render() draws them in order.
    wire [23:0] hair_rgb = h2_hit ? r2 : h1_hit ? r1 : h0_hit ? r0 : 24'd0;

    assign rgb     = b_op ? b_rgb : hair_rgb;
    // The beam's opaque columns never carry 0, and a hairline colour of 0 was
    // never drawn at all, so "non-zero" is exactly "this module owns the pixel".
    wire [11:0] box_x0 = {1'b0, mask_x[10:0]};
    wire [11:0] box_x1 = {1'b0, mask_x[21:11]};
    wire [11:0] box_y0 = {1'b0, mask_y[10:0]};
    wire [11:0] box_y1 = {1'b0, mask_y[21:11]};
    wire        in_box = mask_x[31] && (x >= box_x0) && (x <= box_x1) &&
                                       (y >= box_y0) && (y <= box_y1);

    // ------------------------------------------------------------------------
    // Which blend, and why the three answers differ
    //
    // The visual spec's one-line boundary is "glowing things add, translucent
    // things alpha" - and the beam is both at once, which is exactly why one
    // flag per layer stopped being enough.  Its core is the light source and
    // adds; its halo and rim are translucent and blend.  So the two answers
    // come out of the column table above, one per column, and the scanout
    // picks the branch from them.
    //
    // The warning hairlines get neither.  They are HUD-ish marks that have to
    // stay legible over whatever they cross - a hairline that added to a bright
    // snow ridge would wash out exactly where the player most needs to see it -
    // so they keep replacing, which is what they have always done.  That is
    // still true after this change: the hairline path sets neither beam_add nor
    // (on the scanout side) the alpha branch.
    //
    // `visible` is kept as "beam or hairline" for the callers that only want to
    // know whether this module owns the pixel; the flags below say which of the
    // two it is and therefore how to blend it.
    // ------------------------------------------------------------------------
    assign beam_vis = de && b_op && !in_box;
    assign hair_vis = de && (hair_rgb != 24'd0) && !b_hit && !in_box;
    // Per column, straight out of the table.  A keyed column draws nothing, so
    // its row is forced to "no add, alpha 0" rather than left to the don't-care
    // default - a caller that forgot the beam_vis gate would otherwise see an
    // add request on a column this module does not own.
    assign beam_add   = b_op && b_lut_add;
    assign beam_alpha = b_op ? b_lut_alpha : 8'd0;

    assign visible = de && (b_op || (hair_rgb != 24'd0)) && !in_box;
endmodule
