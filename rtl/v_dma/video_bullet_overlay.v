`timescale 1ns/1ps
// =============================================================================
// video_bullet_overlay -- B1: the bullet curtain, composited by the scanout.
//
// WHY (the long version is 最终任务/最终帧率优化.md, section B1)
//   The curtain's state is 192 records of 8 bytes = 1,536 bytes.  Every frame the
//   firmware expands that into ~30,000 pixels, writes them into the framebuffer,
//   and the scanout then reads 4.32 MB back out of DDR to look at them.  On top
//   of that the backdrop repair puts back every tile those writes damaged: 4,478
//   + 768 rows, against the 5,400 rows the bullets themselves cost.  A
//   thousand-fold expansion, and the damage is the expensive half.
//
//   This module is the other end of it.  The firmware tells the scanout where the
//   bullets are - a per-scanline bucket table in DDR - and the scanout draws them
//   on the way past.  The framebuffer never sees a bullet, so there is nothing to
//   repair.
//
// WHAT THE FIRMWARE PUBLISHES
//   A bucket table in DDR: one bucket per scanline, SLOTS entries of 4 bytes.
//   The firmware appends one entry per (bullet, scanline it covers) pair, in
//   DRAW ORDER, so the last entry covering a pixel is the one that should win -
//   which is exactly the rule the renderer's loops already have.  Entry:
//
//       [10:0]  bx      leftmost pixel column of the bullet on this row
//       [15:11] row     which row of its tile this scanline is
//       [23:16] slot    which tile
//       [28:24] width   the tile's width in pixels
//       [31:29] hue     which colour page the tile's roles resolve against
//                       (the top three bits were free until the colour split;
//                        measured, every live entry carried 0 there)
//
//   One scanline's entries arrive here as a flat vector, already fetched by the
//   video DMA's prefetch channel.  This module has no DDR port of its own.
//
// WHAT IT DRAWS
//   Per pixel: compare x against every entry's [bx, bx+width), take the LAST live
//   entry, look its tile pixel up, and look that up in the palette.  Every step
//   is a lookup on data the firmware already computed, so the result is bit-exact
//   against what the renderer's r_blit used to put down.  That is what
//   tests/tb_bullet_overlay.sv checks, against tiles dumped out of the firmware's
//   own DDR rather than against a table somebody retyped.
//
// TILE STORAGE
//   One byte per pixel here, and that byte is a ROLE, not a palette index.
//   The role says which PART of the shape a cell is - white tip, saturated
//   body, the eleventh step of the halo, nothing here - and it carries no
//   colour at all.  The colour is resolved on the way out:
//
//       palette index = role + hue * 32
//
//   where hue is the 3-bit page number the bucket entry carries in [31:29].
//   That is what lets ONE tile serve all eight hues, and it is the whole point
//   of the change: the firmware used to build eight indexed copies of every
//   shape (128 enemy tiles + 8 player + 8 orb = 30,336 bytes).  The colour
//   split collapsed that to sixteen enemy shapes plus one player shape plus one
//   orb, and two things have taken it back up: the pressure stage's missiles
//   got a tile of their own (slot 18), and the enemy bullet doubled its edge to
//   26x26.  That is 14,192 bytes, in a 16 KB store.  Nothing is lost by any of
//   it - measured on the firmware's own DDR, the eight colourings of a shape
//   have identical opaque-cell sets, so the shape is all they ever differed BY.
//
//   The palette is 32 roles x 8 hues = 256 entries, the whole RAM depth.  28
//   roles are in use (the firmware's BROLE_*), plus role 0 - the "nothing
//   here" sentinel, which is index 0 on both sides.  The 198 DISTINCT colours
//   are exactly the 198 the old first-seen-first-numbered palette held: a role
//   that does not depend on hue (pure white) repeats across all eight pages,
//   which spends slots but not colours.  The missile's two roles (27 and 28)
//   are the first additions since, and both are hue-independent, so they cost
//   two colours and sixteen slots - 198 becomes 200, and roles 29..31 are what
//   is left.
//
//   Thirty-two is not arbitrary.  27 roles need to fit on a page, 32 is the
//   smallest power of two that holds them, and being a power of two is what
//   makes role + hue*32 a concatenation - the index arithmetic below costs no
//   adder and no multiplier.
//
// LAYER ORDER
//   HUD > beam (A3) > bullets (this module) > laser columns > weather >
//   framebuffer.  The renderer draws the player's shots first and the enemy's
//   after, so an enemy bullet covers a player bullet; the bucket is built in that
//   same order and the priority encoder takes the last entry, which reproduces it.
// =============================================================================
module video_bullet_overlay #(
    // Entries per scanline.  80 is not a round number on purpose: the worst
    // scanline measured on the pressure stage carries 75 bullets (scratch/a3/
    // bucket_depth.py), so anything the size of the historical 32 would silently
    // drop bullets and change the picture.
    parameter integer SLOTS = 80,
    // main.c's GAME_LEFT / GAME_RIGHT.  The renderer clipped every bullet to this
    // band before writing it; an overlay has no scissor, so it clips here.
    // Without it a wide orb near the edge paints over the HUD gutter.
    parameter [11:0]  PLAY_LEFT  = 12'd181,
    parameter [11:0]  PLAY_RIGHT = 12'd1185
)(
    // ---- pixel domain -------------------------------------------------------
    input  wire           pixel_clk,
    input  wire           pixel_rst_n,
    input  wire [11:0]    x,
    input  wire [10:0]    y,
    input  wire           de,

    // This scanline's entries, flattened: entry i is bits [32i+31 : 32i].
    input  wire [32*SLOTS-1:0] bucket,
    // Zero on a scanline the prefetch has not published yet, or one with no
    // bullets.  The overlay then stays out of the way entirely.
    input  wire           bucket_ready,

    // The scanout's occlusion box, the one the weather layer already takes:
    // [10:0] x0, [21:11] x1, [31] enable, and mask_y carries y0/y1 the same
    // way.  The pause card, the stage banner and the boss dialogue are painted
    // into the framebuffer, and a layer composited at scanout has no way to
    // know that - it would draw the barrage straight over them.  The firmware
    // publishes the union of those rectangles every frame (weather_box_publish
    // in main.c); the weather layer has honoured it since it was written.
    input  wire [31:0]    mask_x,
    input  wire [31:0]    mask_y,

    // ---- configuration domain (core_clk / APB) ------------------------------
    // The firmware loads the tile store and the palette once at boot.  Runtime
    // never writes either: which tile a bullet uses is decided by the firmware
    // when it appends the entry, not by the hardware.
    input  wire           cfg_clk,
    input  wire           cfg_rst_n,
    input  wire           tile_we,
    input  wire [13:0]    tile_waddr,
    input  wire [7:0]     tile_wdata,
    input  wire           pal_we,
    input  wire [7:0]     pal_waddr,
    // 32 bits, not 24: the top byte is the entry's alpha, and the scanout
    // blends the bullet against whatever is under it with that.  A 24-bit
    // palette could only ever paint an opaque bullet - the tile's own byte is
    // a palette INDEX, so there is nowhere else to carry a per-colour alpha.
    // Entries written by firmware that does not care about transparency keep
    // 0xFF and the layer behaves exactly as it did at 24 bits.
    input  wire [31:0]    pal_wdata,

    output wire           visible,
    // Which blend this pixel asks for.  1 = the scanout must ADD it
    // (min(255, base + fg)); 0 = it replaces or blends, according to `alpha`
    // below.  Carried out of this module rather than decided in the scanout for
    // the same reason the beam's and the laser's are: which blend a shape wants
    // is a property of the shape, and this is the layer that knows it.
    output wire           bullet_add,
    output wire [23:0]    rgb,
    // The winning entry's alpha, registered alongside rgb.  "Transparent" is
    // still decided by the index (see d4_op below), not by this: an entry with
    // alpha 0 is a bullet you cannot see, which is a different thing from the
    // index-0 "nothing here".  The one value that is NOT an opacity is the
    // add code - see ADD_CODE below - which is why bullet_add exists.
    output wire [7:0]     alpha
);
    // ------------------------------------------------------------------------
    // Tile run layout.  One byte per pixel, a shape ROLE.
    //
    //     slot  0 .. 15   enemy bullets   26 x 26, row stride 32 -> 832 B each
    //     slot 16         player shots     7 x 26, row stride  8 -> 208 B each
    //     slot 17         orbs            16 x 16, row stride 16 -> 256 B each
    //     slot 18         missiles        13 x 26, row stride 16 -> 416 B each
    //
    // 14,192 bytes, inside the 16 KB the depth rounds up to.  Only the enemy run
    // is addressed by a multiply - the other three are one tile each at a fixed
    // base, which is what keeps the multiply off the critical path for them.
    //
    // The enemy run DOUBLED ITS EDGE (13x13 -> 26x26) and that is the entire
    // reason this store went from 8 KB back up to 16 KB.  Its shape arithmetic
    // is the old one with every coordinate and threshold multiplied by two, and
    // 26 pixels need a 32-byte row stride because the row address is a shift -
    // a 16-byte stride for a 26-wide tile would fold rows onto each other.
    //
    // Sixteen enemy slots, one per DIRECTION - colour is no longer a dimension
    // of this store.  The sixteen are not derivable from each other either:
    // measured on the firmware's tiles, d and d+8 are not exact flips of one
    // another on an integer grid (only 1 of the 8 pairs holds) and only 4 of
    // the 16 masks are symmetric about either axis.
    //
    // slot 18 is the pressure stage's wing missiles.  They used to borrow slot
    // 16, and since a bullet's BLEND comes from its palette entry, sharing the
    // tile meant sharing the mix - which is why the one shape in the build that
    // wants two mixes (blended body, added trail) could not have them.
    //
    // Lances (8.5's 24x24 shafts) are deliberately not here.  They would fit
    // now (768 bytes); moving them is a separate change.
    // ------------------------------------------------------------------------
    localparam integer N_TILES  = 19;
    localparam [13:0]  PB_BASE  = 14'd13312;   // 16 * 832
    localparam [13:0]  ORB_BASE = 14'd13520;   // PB_BASE  + 208
    localparam [13:0]  MS_BASE  = 14'd13776;   // ORB_BASE + 256

    // Declared up here, ahead of the pipeline that reads them: iverilog rejects a
    // reference to a wire declared further down the file ("Unable to bind
    // wire/reg/memory"), even though Efinity's elaborator accepts it.
    wire [7:0]  tile_q;
    // {alpha[7:0], rgb[23:0]} - the palette entry grew an alpha byte so the
    // scanout can blend a bullet against what is behind it.
    wire [31:0] pal_q;

    // ------------------------------------------------------------------------
    // WHICH BLEND, and why it hides at the top of the alpha range.
    //
    // The entry's alpha byte is this layer's only selector, and its 256 values
    // were all spoken for: 0 is "invisible", 255 is "replace", everything
    // between is a blend factor.  The visual spec wants a third answer - its
    // "glowing things add" list is additive, and it has to be decidable per
    // PIXEL, because a missile is one shape with a blended body and an added
    // trail.
    //
    // So the top of the range is re-read: 254 means ADD.  What that costs is
    // the 254/255 blend, the one step of the ramp no eye can tell from opaque
    // (0.4% of the way).  What it buys is that the palette does not have to
    // grow a bit, and that matters HERE more than anywhere else in the design:
    // the entry is exactly 32 bits wide and every bit of it is spoken for, and
    // the last time a width on this path was got wrong - bitblt_top's bpal_data
    // port was 24 bits and threw the alpha byte away - every bullet in the
    // picture carried alpha 0 and none of them were drawn at all.
    //
    // The firmware side is one constant, BPAL_ADD in main.c's bullet_store_build.
    // ------------------------------------------------------------------------
    localparam [7:0] ADD_CODE = 8'hFE;

    // ------------------------------------------------------------------------
    // Stage 1: which entries cover this pixel?
    // ------------------------------------------------------------------------
    wire [SLOTS-1:0] hit;
    genvar gi;
    generate
        for (gi = 0; gi < SLOTS; gi = gi + 1) begin : g_hit
            wire [10:0] e_bx = bucket[32*gi +: 11];
            wire [4:0]  e_w  = bucket[32*gi + 24 +: 5];
            wire [11:0] e_x1 = {1'b0, e_bx} + {7'd0, e_w};
            assign hit[gi] = (x[10:0] >= e_bx) && ({1'b0, x[10:0]} < e_x1);
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Stage 2: the LAST live entry wins.
    //
    // "Nothing above me hit" is a prefix OR, so each win bit is one AND over a
    // tree-shaped reduction - not an 80-deep chain of found-flags, which is what
    // a naive loop writes and what would not close timing at 85.7 MHz.
    // ------------------------------------------------------------------------
    wire [SLOTS-1:0] win_oh;
    genvar gj;
    generate
        for (gj = 0; gj < SLOTS; gj = gj + 1) begin : g_win
            // The top entry has nothing above it; writing the reduction for it
            // would be a part-select that runs backwards (hit[79:80]).
            if (gj == SLOTS - 1)
                assign win_oh[gj] = hit[gj];
            else
                assign win_oh[gj] = hit[gj] && !(|hit[SLOTS-1 : gj+1]);
        end
    endgenerate

    // Fold the winner's fields out with OR trees over the one-hot mask.
    reg [10:0] w_bx;
    reg [4:0]  w_row;
    reg [7:0]  w_slot;
    reg [2:0]  w_hue;
    integer wi;
    always @(*) begin
        w_bx   = 11'd0;
        w_row  = 5'd0;
        w_slot = 8'd0;
        w_hue  = 3'd0;
        for (wi = 0; wi < SLOTS; wi = wi + 1)
            if (win_oh[wi]) begin
                w_bx   = w_bx   | bucket[32*wi +: 11];
                w_row  = w_row  | bucket[32*wi + 11 +: 5];
                w_slot = w_slot | bucket[32*wi + 16 +: 8];
                // [31:29] - which colour page this bullet's roles resolve
                // against.  The firmware puts the bullet's own colour here
                // (bucket_put), because one shape serves all eight hues and
                // the slot therefore cannot imply it.
                w_hue  = w_hue  | bucket[32*wi + 29 +: 3];
            end
    end

    // Inside the box: stay out of it.  Same comparison, same bits, as
    // video_weather.v - one rule for both scanout layers cannot drift.
    wire [11:0] box_x0 = {1'b0, mask_x[10:0]};
    wire [11:0] box_x1 = {1'b0, mask_x[21:11]};
    wire [11:0] box_y0 = {1'b0, mask_y[10:0]};
    wire [11:0] box_y1 = {1'b0, mask_y[21:11]};
    wire        in_box = mask_x[31] && (x >= box_x0) && (x <= box_x1) &&
                                    (y >= box_y0) && (y <= box_y1);

    // There used to be a `wire any = bucket_ready && (|hit) && !in_box;` here,
    // with no reader anywhere.  The flag that actually gates this layer is
    // d1_any below, which adds two conditions: the slot has to name a real tile,
    // and the pixel has to be inside the playfield.  Anything that reads a bare
    // "any" would paint from a bucket entry whose slot is past the last tile.

    // ------------------------------------------------------------------------
    // Stage 3: tile address, all shift-and-add.
    // ------------------------------------------------------------------------
    // EIGHT bits, not seven.  Truncating the slot to its low seven bits maps slot
    // 128 (the first player shot) to 0 - the whole player run then reads the
    // first enemy tile and draws nothing, because those bytes are zero where the
    // enemy tile is transparent.  It looked exactly like "the player's shots are
    // simply missing", which is why the bench sweeps every slot rather than a
    // sample.
    wire        is_pb   = (w_slot == 8'd16);     // the 8-byte row stride
    wire        is_orb  = (w_slot == 8'd17);
    wire        is_ms   = (w_slot == 8'd18);
    // The enemy run is the only one with more than one tile in it, and the run
    // is the only place a multiply would otherwise be: slot * 832 =
    // slot<<9 + slot<<8 + slot<<6.  The other three slots never read this, and a
    // slot >= N_TILES never reaches the RAM at all - d1_any refuses it below.
    wire [17:0] s832 = {1'b0, w_slot, 9'b0}
                     + {2'd0, w_slot, 8'b0}
                     + {4'd0, w_slot, 6'b0};

    wire [13:0] w_base  = is_pb  ? PB_BASE
                        : is_orb ? ORB_BASE
                        : is_ms  ? MS_BASE
                        :          s832[13:0];
    // Row stride as a shift: 32 bytes for the enemy run, 8 for the player shots,
    // 16 for the orbs and the missiles.  Three bits, not two: a 2-bit literal 4
    // truncates to 0, which would put every row of a tile on top of each other
    // at its base.
    wire [2:0]  w_shift = is_pb ? 3'd3 : (is_orb || is_ms) ? 3'd4 : 3'd5;

    wire [10:0] w_rel  = x[10:0] - w_bx;                      // 0 .. width-1
    wire [15:0] w_rowofs = {11'd0, w_row} << w_shift;
    // 14 bits: the last byte of the store is 14,191.  w_rel is wider than any
    // real pixel offset, but a pixel outside [bx, bx+width) never reaches the
    // RAM - d1_any below refuses it - so the wrap on those addresses is not
    // observable.
    wire [13:0] tile_a = w_base + w_rowofs[13:0] + {3'd0, w_rel};

    // ------------------------------------------------------------------------
    // Pipeline.  Five stages: compare, encode, tile read, palette read, output.
    // The compare and the encode are separate stages because together they are
    // the long pole - 80 range compares feeding an 80-way prefix reduction - and
    // splitting them keeps each one under half a pixel clock.
    //
    // de and the any flag ride along with the pixel, so the overlay can never
    // claim a pixel outside the active window, and can never read a tile for a
    // bullet that is not there (an out-of-range address would otherwise fetch
    // some other tile's byte and paint with it).
    // ------------------------------------------------------------------------
    //   cycle N   : x arrives, the 80 compares resolve combinationally
    //   cycle N+1 : the winner is encoded, the tile address and the two flags
    //               are registered
    //   cycle N+2 : the tile BRAM's registered output is valid; the palette is
    //               addressed from it
    //   cycle N+3 : the palette's registered output is valid
    //   cycle N+4 : rgb and visible
    //
    // Both RAMs carry OUTPUT_REG = TRUE, so each one costs a cycle.  The address
    // register has to sit BEFORE the first RAM and the capture has to sit AFTER
    // its output, or the palette ends up addressed with the index of the pixel
    // two positions ago - which still draws bullets, just the wrong ones, and
    // would be very hard to see in a screenshot.
    reg [13:0] d1_addr;
    reg        d1_any, d1_de;
    reg [2:0]  d1_hue, d2_hue;
    reg [7:0]  d2_idx;
    reg        d2_any, d2_de;
    reg        d3_any, d3_de;
    reg [23:0] d4_rgb;
    reg [7:0]  d4_alpha;
    reg        d4_add;
    reg        d4_op;
    reg        d4_any, d4_de;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            d1_addr <= 14'd0; d1_any <= 1'b0; d1_de <= 1'b0;
            d1_hue  <= 3'd0;
            d2_idx  <= 8'd0;  d2_hue <= 3'd0; d2_any <= 1'b0; d2_de <= 1'b0;
            d3_any  <= 1'b0;  d3_de  <= 1'b0;
            d4_rgb  <= 24'd0; d4_alpha <= 8'hFF; d4_add <= 1'b0; d4_op <= 1'b0; d4_any <= 1'b0; d4_de <= 1'b0;
        end else begin
            d1_addr <= tile_a;
            // The colour page rides with the pixel, beside d1_any: it belongs
            // to this bullet's entry and to nothing else on the line.
            d1_hue  <= w_hue;
            // Two things the overlay has to say no to that the engine's blit said
            // no to for it: a slot past the last tile (which would fold onto a low
            // address and paint with whatever byte lives there), and a pixel
            // outside the playfield (the blit was clipped to GAME_LEFT..GAME_RIGHT
            // and the HUD gutters are not ours to paint on).
            d1_any  <= bucket_ready && (|hit) && (w_slot < N_TILES[7:0])
                       && (x[10:0] >= PLAY_LEFT) && (x[10:0] < PLAY_RIGHT)
                       && !in_box;
            d1_de   <= de;

            // The tile RAM's registered output lands here - a shape ROLE.
            d2_idx  <= tile_q;
            d2_hue  <= d1_hue;
            d2_any  <= d1_any;
            d2_de   <= d1_de;

            // The palette is addressed from d2_idx and its own registered output
            // is a cycle behind that, so the two flags need a stage of their own
            // to travel through.  Without it they arrive one cycle ahead of the
            // pixel they belong to - which does not tear the picture, it shifts
            // the active window one pixel against it, and that is the kind of
            // thing that reads as "the edge looks slightly wrong" for weeks.
            d3_any  <= d2_any;
            d3_de   <= d2_de;

            // The palette entry is {alpha, rgb}; the two halves come out of the
            // same register so the colour and its opacity can never be a cycle
            // apart, which would blend a pixel with its neighbour's alpha.
            d4_rgb  <= pal_q[23:0];
            d4_alpha<= pal_q[31:24];
            // The one alpha value that is not an opacity.  Decoded here, in the
            // same register as the alpha it comes from, so the flag and the byte
            // can never belong to different pixels.
            d4_add  <= (pal_q[31:24] == ADD_CODE);
            // Transparent is decided by the tile's OWN byte, not by the colour
            // the palette returned and NOT by the concatenated index: role 0 on
            // hue page 3 is index 96, an ordinary entry that the palette has a
            // colour in.  Testing the index would paint every transparent cell
            // of a hue-3,4,5,6,7 bullet.  (Testing the colour was never right
            // either - a tile that legitimately held pure black would punch a
            // hole in itself - which is why this has always been a test on the
            // tile byte.)
            d4_op   <= (d2_idx != 8'd0);
            d4_any  <= d3_any;
            d4_de   <= d3_de;
        end
    end

    // ------------------------------------------------------------------------
    // Tile store and palette.  Both are true dual-port RAMs: the firmware writes
    // them in cfg_clk at boot, the pixel pipeline reads them every cycle.  A
    // single-clock array with a hand-rolled crossing would lose writes the
    // moment the firmware issued two in a row, which boot does 256 times.
    // ------------------------------------------------------------------------
    simple_dual_port_ram #(
        .DATA_WIDTH (8),
        .ADDR_WIDTH (14),
        .OUTPUT_REG ("TRUE")
    ) u_tiles (
        .wdata (tile_wdata), .waddr (tile_waddr[13:0]), .we (tile_we), .wclk (cfg_clk),
        .raddr (d1_addr), .re (1'b1), .rclk (pixel_clk),
        .rdata (tile_q)
    );

    simple_dual_port_ram #(
        .DATA_WIDTH (32),
        .ADDR_WIDTH (8),
        .OUTPUT_REG ("TRUE")
    ) u_palette (
        .wdata (pal_wdata), .waddr (pal_waddr), .we (pal_we), .wclk (cfg_clk),
        // role + hue*32, and 32 is a power of two, so this is a 3-bit/5-bit
        // concatenation: no adder, no multiplier, no extra pipeline stage.
        .raddr ({d2_hue, d2_idx[4:0]}), .re (1'b1), .rclk (pixel_clk),
        .rdata (pal_q)
    );

    // ------------------------------------------------------------------------
    // Palette index 0 means "nothing here".  The firmware never assigns it to an
    // opaque tile pixel, and an unwritten tile byte reads back as 0 - so a
    // freshly powered store draws nothing until the firmware fills it, which is
    // the safe direction to fail in.
    // ------------------------------------------------------------------------
    assign rgb     = d4_rgb;
    // 0xFF on an index whose entry carries no alpha byte, so a store loaded by
    // older firmware draws exactly as it did before this port existed.
    assign alpha   = d4_alpha;
    assign visible = d4_de && d4_any && d4_op;
    // Gated by `visible` for the same reason the beam's and the laser's are: a
    // caller that forgot the visible gate would otherwise read an add request on
    // a pixel this layer does not own.
    assign bullet_add = visible && d4_add;
endmodule
