`timescale 1ns/1ps
// =============================================================================
// tb_bullet_overlay -- B1's scanout compositor against the pixels the engine
// used to blit.
//
// THE REFERENCE IS THE FIRMWARE'S OWN TILES.  tools/gen_bullet_tiles.py lifts
// ebullet_dirtile_build / pbullet_tile_build / orb_tile_build /
// missile_tile_build straight out of the emulated DDR - the tile bytes are
// shape ROLES now - reads the palette the firmware built for those roles (256
// slots, 200 distinct colours), and packs both into the run layout
// video_bullet_overlay.v reads.  This bench then walks every opaque and every
// transparent cell of every tile and checks that the compositor puts the same
// pixel where the r_blit put it - 14,352 BYTES of tile data across 19 slots
// (16 x 26x26 + 1 x 7x26 + 1 x 16x26 + 1 x 13x26), at three different bx so the
// range compare is not tested at one lucky column.  The orb run is 26 rows tall
// in the store because the firmware pads it with transparent ones; this bench
// only feeds it the 16 rows of picture the dumper has, which is why its sweep
// stops at k_h[2].
//
// It also grades the COLOUR PAGE, which the old bench could not: a tile holds
// no colour any more, the index is role + hue*32, and hue rides in the bucket
// entry's [31:29].  Section 1b feeds one slot eight times with eight different
// hues and insists each resolves to its own palette entry.
//
// ...AND THE BUCKET'S ROW UNIT IS A GROUP.  An entry carries the tile row of the
// bucket's first scanline, biased +8; the RTL adds the scanline's offset inside
// the group (y[2:0]) back on.  entry()/entry_hue() below therefore take a real
// tile row and subtract the current Y's offset, so every check in this file
// keeps the meaning it had when the table was one bucket per scanline.  Where Y
// changes between the bucket write and the check, the bucket has to be written
// again at the new Y - see section 6.
//
// Run:  tools\sim_bullet_overlay.ps1
// =============================================================================
module tb_bullet_overlay;
    localparam integer SLOTS       = 128;
    localparam integer STORE_BYTES = 16384;
    localparam integer NKINDS      = 4;

    reg clk = 1'b0;
    reg pixel_rst_n = 1'b0;
    always #5 clk = ~clk;
    reg cfg_clk = 1'b0;
    always #7 cfg_clk = ~cfg_clk;

    reg  [11:0]          X;
    reg  [10:0]          Y;
    reg                  DE;
    reg  [32*SLOTS-1:0]  bucket;
    reg                  bucket_ready;
    reg                  tile_we;
    reg  [13:0]          tile_waddr;
    reg  [7:0]           tile_wdata;
    reg                  pal_we;
    reg  [7:0]           pal_waddr;
    reg  [31:0]          pal_wdata;
    wire                 visible;
    wire                 bullet_add;
    wire [23:0]          rgb;
    // The winning entry's alpha, and the one value of it that is not an
    // opacity: 254 asks for ADD, and that is the whole of what "the missile's
    // body blends and its trail adds" means on this side of the wire.
    wire [7:0]           alpha;

    // The occlusion box (weather_box_publish in main.c): [10:0] x0, [21:11] x1,
    // [31] enable, mask_y the same.  These two were left out of the
    // instantiation entirely until now, which fixed mask_x[31] - the enable - at
    // 0 and meant this bench only ever graded a layer whose occlusion was off.
    reg [31:0]          mask_x = 32'd0;
    reg [31:0]          mask_y = 32'd0;

    video_bullet_overlay #(.SLOTS(SLOTS)) dut (
        .pixel_clk(clk), .pixel_rst_n(pixel_rst_n),
        .x(X), .y(Y), .de(DE),
        .bucket(bucket), .bucket_ready(bucket_ready),
        .cfg_clk(cfg_clk), .cfg_rst_n(1'b1),
        .tile_we(tile_we), .tile_waddr(tile_waddr), .tile_wdata(tile_wdata),
        .pal_we(pal_we), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
        .mask_x(mask_x), .mask_y(mask_y),
        .visible(visible), .bullet_add(bullet_add), .rgb(rgb), .alpha(alpha)
    );

    reg [7:0]  tiles [0:STORE_BYTES-1];
    // 32 bits, not 24: the top byte is the entry's alpha and the missile is the
    // first thing in the build that sets it to anything but 0xFF.
    reg [31:0] pal   [0:255];

    integer checks = 0;
    integer fails  = 0;
    integer i, s, t, row, col, off, exp_idx;
    integer hue, found, hit_row, hit_col, hit_role, hit_w;
    // Section 1d: the halo tier sweep and the one halo cell it feeds to the DUT.
    integer hr, hs_role, hs_row, hs_col;
    // Section 4b: the transparent-winner probe.
    integer ov_row, ov_col, ov_p;
    // Section 4c/4d: three stacked entries, and how deep the fallback goes.
    integer ow_row, ow_col, ow_p, ow_p2;
    integer bx;
    reg [23:0] exp_rgb;
    localparam integer STREAM_COUNT = 64 * 8 * 52;
    reg [218:0] stream_vectors [0:STREAM_COUNT-1];
    reg [33:0] stream_expected [0:3];
    reg [33:0] stream_result;
    integer stream_i;

    // {slot0, count, w, h, rowstride} -- mirrors tools/gen_bullet_tiles.py
    integer k_slot0 [0:NKINDS-1];
    integer k_count [0:NKINDS-1];
    integer k_w     [0:NKINDS-1];
    integer k_h     [0:NKINDS-1];
    integer k_rs    [0:NKINDS-1];

    // Mirrors video_bullet_overlay.v's PB_BASE/ORB_BASE/MS_BASE: slots 0..15
    // are the enemy run at an 832-byte pitch, and the last three are one tile
    // each at a fixed base.
    function integer tile_off(input integer slot);
        begin
            if (slot < 16)       tile_off = slot * 832;
            else if (slot == 16) tile_off = 13312;
            else if (slot == 17) tile_off = 13520;
            else                 tile_off = 13936 + (slot - 18) * 416;
        end
    endfunction

    // The bucket entry, thirty-two bits with every one of them spoken for:
    //
    //     [10:0]  bx          leftmost column
    //     [16:11] trow_base   tile row of the bucket's first scanline, +8 bias
    //     [23:17] slot        which tile - seven bits, not eight
    //     [28:24] width       the tile's width in pixels
    //     [31:29] hue         which colour page
    //
    // The bias and the current scanline's offset inside the group cancel, so
    // what these take is a REAL tile row and what the RTL reconstructs is the
    // same real tile row - whatever Y happens to be.  That is what keeps every
    // check in this file comparable with the per-scanline version.
    function [31:0] entry(input integer e_bx, input integer e_row,
                           input integer e_slot, input integer e_w);
        integer tb;
        begin
            tb = e_row + 8 - Y[2:0];
            entry = {3'd0, e_w[4:0], e_slot[6:0], tb[5:0], e_bx[10:0]};
        end
    endfunction

    // ...and the same entry with a colour page in [31:29], which is where the
    // firmware puts the bullet's own colour (bucket_put in main.c).
    function [31:0] entry_hue(input integer e_bx, input integer e_row,
                              input integer e_slot, input integer e_w,
                              input integer e_hue);
        integer tb;
        begin
            tb = e_row + 8 - Y[2:0];
            entry_hue = {e_hue[2:0], e_w[4:0], e_slot[6:0], tb[5:0],
                         e_bx[10:0]};
        end
    endfunction

    task chk(input ok, input [511:0] what);
        begin
            checks = checks + 1;
            if (!ok) begin
                fails = fails + 1;
                if (fails <= 12) $display("  FAIL %0s", what);
            end
        end
    endtask

    task put_bucket(input integer e_bx, input integer e_row,
                    input integer e_slot, input integer e_w);
        begin
            bucket = {32*SLOTS{1'b0}};
            bucket[31:0] = entry(e_bx, e_row, e_slot, e_w);
            bucket_ready = 1'b1;
        end
    endtask

    task put_bucket_hue(input integer e_bx, input integer e_row,
                        input integer e_slot, input integer e_w,
                        input integer e_hue);
        begin
            bucket = {32*SLOTS{1'b0}};
            bucket[31:0] = entry_hue(e_bx, e_row, e_slot, e_w, e_hue);
            bucket_ready = 1'b1;
        end
    endtask

    initial begin
        k_slot0[0] =  0; k_count[0] = 16; k_w[0] = 26; k_h[0] = 26; k_rs[0] = 32;
        k_slot0[1] = 16; k_count[1] =  1; k_w[1] =  7; k_h[1] = 26; k_rs[1] =  8;
        k_slot0[2] = 17; k_count[2] =  1; k_w[2] = 16; k_h[2] = 16; k_rs[2] = 16;
        k_slot0[3] = 18; k_count[3] =  1; k_w[3] = 13; k_h[3] = 26; k_rs[3] = 16;

        X = 12'd0; Y = 11'd0; DE = 1'b1;
        bucket = {32*SLOTS{1'b0}}; bucket_ready = 1'b0;
        tile_we = 1'b0; tile_waddr = 14'd0; tile_wdata = 8'd0;
        pal_we = 1'b0; pal_waddr = 8'd0; pal_wdata = 24'd0;

        $readmemh("bullet_tiles.hex", tiles);
        $readmemh("bullet_palette.hex", pal);

        repeat (4) @(posedge clk);
        @(negedge clk); pixel_rst_n = 1'b1;

        // ---- load the store and the palette through the config port --------
        @(negedge cfg_clk);
        tile_we = 1'b1;
        // Exactly the boot writer's length, including a partial final block.
        for (i = 0; i < 14352; i = i + 1) begin
            tile_waddr = i[13:0];
            tile_wdata = tiles[i];
            @(negedge cfg_clk);
        end
        tile_we = 1'b0;
        pal_we = 1'b1;
        for (i = 0; i < 256; i = i + 1) begin
            pal_waddr = i[7:0];
            pal_wdata = pal[i];
            @(negedge cfg_clk);
        end
        pal_we = 1'b0;
        repeat (4) @(posedge clk);

        // ---- 1. every cell of every tile, at three different bx ------------
        for (t = 0; t < 3; t = t + 1) begin
            bx = (t == 0) ? 300 : (t == 1) ? 700 : 1100;
            for (s = 0; s < k_count[0] + k_count[1] + k_count[2] + k_count[3];
                 s = s + 1) begin
                // find which kind this slot belongs to
                for (i = 0; i < NKINDS; i = i + 1) begin
                    if (s >= k_slot0[i] && s < k_slot0[i] + k_count[i]) begin
                        off  = tile_off(s);
                        for (row = 0; row < k_h[i]; row = row + 1) begin
                            for (col = 0; col < k_w[i]; col = col + 1) begin
                                put_bucket(bx, row, s, k_w[i]);
                                X = bx + col; Y = 11'd0; DE = 1'b1;
                                repeat (8) @(posedge clk);
                                exp_idx = tiles[off + row * k_rs[i] + col];
                                exp_rgb = pal[exp_idx][23:0];
                                checks = checks + 1;
                                if (exp_idx == 0) begin
                                    if (visible !== 1'b0) begin
                                        fails = fails + 1;
                                        if (fails <= 12)
                                            $display("  FAIL slot %0d row %0d col %0d: transparent cell drawn (%06x)",
                                                     s, row, col, rgb);
                                    end
                                end else if (visible !== 1'b1 || rgb !== exp_rgb) begin
                                    fails = fails + 1;
                                    if (fails <= 12)
                                        $display("  FAIL slot %0d row %0d col %0d bx %0d: want %06x got %06x vis=%b",
                                                 s, row, col, bx, exp_rgb, rgb, visible);
                                end
                            end
                        end
                    end
                end
            end
        end
        $display("  tiles: %0d slots x 3 bx positions swept", 19);

        // ---- 1b. the colour page -------------------------------------------
        // A tile byte is a shape ROLE; the palette index is role + hue*32 and
        // hue comes from the bucket entry's [31:29].  A bench that never sets
        // those bits only ever grades page 0 - which is exactly what this one
        // did until this section existed, and the failure it would have missed
        // is a transparent cell painted opaque on any page but 0.
        //
        // One opaque cell of each slot, fed eight times with eight hues: each
        // must land on pal[role + hue*32].
        for (s = 0; s < 19; s = s + 1) begin
            found = 0;
            for (i = 0; i < NKINDS; i = i + 1) begin
                if (!found && s >= k_slot0[i] && s < k_slot0[i] + k_count[i]) begin
                    off = tile_off(s);
                    for (row = 0; row < k_h[i] && !found; row = row + 1)
                        for (col = 0; col < k_w[i] && !found; col = col + 1)
                            if (tiles[off + row * k_rs[i] + col] != 0) begin
                                found    = 1;
                                hit_row  = row;
                                hit_col  = col;
                                hit_role = tiles[off + row * k_rs[i] + col];
                                hit_w    = k_w[i];
                            end
                end
            end
            if (found && hit_role < 29) begin
                for (hue = 0; hue < 8; hue = hue + 1) begin
                    put_bucket_hue(500, hit_row, s, hit_w, hue);
                    X = 12'd500 + hit_col; Y = 11'd0; DE = 1'b1;
                    repeat (8) @(posedge clk);
                    exp_rgb = pal[hit_role + hue*32][23:0];
                    checks = checks + 1;
                    if (visible !== 1'b1 || rgb !== exp_rgb) begin
                        fails = fails + 1;
                        if (fails <= 12)
                            $display("  FAIL slot %0d hue %0d role %0d: want %06x got %06x vis=%b",
                                     s, hue, hit_role, exp_rgb, rgb, visible);
                    end
                end
            end
        end
        $display("  colour pages: every slot swept over all 8 hues");

        // ---- 1c. the missile: ONE shape, TWO mixes --------------------------
        // slot 18 is the only bullet in the build whose palette entries are not
        // all opaque.  Row 5 of its tile is BODY (role 27, alpha 190 -> blend)
        // and row 15 is TRAIL (role 28, alpha 254 -> BPAL_ADD).  The scanout
        // decides the mix per pixel from the entry's alpha byte, so this is the
        // place where "half of it shows the snowfield through and half of it
        // adds" becomes something the bench can fail on rather than a comment.
        for (hue = 0; hue < 8; hue = hue + 1) begin
            chk(pal[27 + hue*32][31:24] === 8'd190,
                "every hue page: the missile body's entry blends at 190");
            chk(pal[28 + hue*32][31:24] === 8'd254,
                "every hue page: the missile trail's entry asks for ADD");
        end
        // ...and the DUT has to say so, on its own wires, for the pixel it
        // picks.  hue 5 is the colour spawn_pbullet_lockon sets.
        put_bucket_hue(600, 5, 18, 13, 5);       // row 5 of the missile: body
        X = 12'd606; Y = 11'd0; DE = 1'b1;
        repeat (8) @(posedge clk);
        chk(visible === 1'b1 && bullet_add === 1'b0 && alpha === 8'd190,
            "slot 18 row 5 must come out BLENDED at 190");
        put_bucket_hue(600, 15, 18, 13, 5);      // row 15: trail
        X = 12'd606; @(posedge clk); repeat (8) @(posedge clk);
        chk(visible === 1'b1 && bullet_add === 1'b1 && alpha === 8'd254,
            "slot 18 row 15 must come out ADDED");
        $display("  missile: body blended at 190, trail added, on all 8 pages");

        // ---- 1d. the enemy halo tiers ask for ADD, on every hue page -------
        // The 18 halo tiers (role 9..26) are the enemy barrage's only claim to
        // being see-through, and until now that claim was a lie the picture
        // paid for.  brole_color() pre-multiplies their colour by eb_halo_a[],
        // which is only the right colour when the backdrop is BLACK, and the
        // alpha byte said 255 - so the scanout hard-replaced whatever was
        // really there with it.  A player shot under a halo came out greyed
        // over instead of lit, and two halos overlapping ate a wedge out of
        // each other.  Both were reported off the board.
        //
        // The fix is NOT to stop pre-multiplying - an ADD wants that weight,
        // and feeding it the bare hue would flatten the 18-step ramp into one
        // bright ring - it is to stop calling the result opaque.  Nothing else
        // in this bench reads a halo entry, so without these checks the barrel
        // of alpha values in bullet_store_build() can go back to 255 and every
        // other test in the file still passes.  That is exactly how the bug
        // survived: this bench graded the missile's two mixes and stopped.
        for (hr = 9; hr <= 26; hr = hr + 1)
            for (hue = 0; hue < 8; hue = hue + 1) begin
                chk(pal[hr + hue*32][31:24] === 8'd254,
                    "every enemy halo tier, on every hue page, must ask for ADD");
                // ...and the colour is still the pre-multiplied one: each
                // channel at or below the neon body of the same hue, which is
                // the body the tier was mixed down from.
                chk(pal[hr + hue*32][23:16] <= pal[2 + hue*32][23:16] &&
                    pal[hr + hue*32][15:8]  <= pal[2 + hue*32][15:8]  &&
                    pal[hr + hue*32][7:0]   <= pal[2 + hue*32][7:0],
                    "every enemy halo tier stays pre-multiplied, never the bare hue");
            end

        // ...and the DUT has to say so on its own wires, for a real halo pixel.
        // Tile 0 flies along +x, so a row through the middle of it runs from
        // the neon body outward through the tiers.  Find one, feed it to the
        // scanout and read bullet_add back - "the picture stopped lying" has
        // to be something this bench can fail on, not a comment.
        hs_role = -1;
        for (row = 0; row < 26 && hs_role < 0; row = row + 1)
            for (col = 0; col < 26 && hs_role < 0; col = col + 1)
                if (tiles[tile_off(0) + row*32 + col] >= 9 &&
                    tiles[tile_off(0) + row*32 + col] <= 26) begin
                    hs_role = tiles[tile_off(0) + row*32 + col];
                    hs_row  = row;
                    hs_col  = col;
                end
        chk(hs_role >= 9, "sanity: the enemy tile holds at least one halo cell");
        put_bucket_hue(800, hs_row, 0, 26, 3);
        X = 12'd800 + hs_col; Y = 11'd0; DE = 1'b1;
        repeat (8) @(posedge clk);
        chk(visible === 1'b1 && bullet_add === 1'b1 && alpha === 8'd254,
            "an enemy halo pixel must come out ADDED, not replaced");
        $display("  enemy halo: role %0d at row %0d col %0d comes out ADDED",
                 hs_role, hs_row, hs_col);

        // ---- 1e. enemy wings are role 31 at alpha 210; roles 1 and 2 stay
        // opaque.  The wing used to be role 2, which player shots and orbs
        // share, so a body alpha written there would have washed those out.
        for (hue = 0; hue < 8; hue = hue + 1) begin
            chk(pal[1 + hue*32][31:24] === 8'd255,
                "role 1 stays opaque on every hue page");
            chk(pal[2 + hue*32][31:24] === 8'd255,
                "role 2 stays opaque on every hue page");
            chk(pal[3 + hue*32][31:24] === 8'd255,
                "the electric spine stays opaque on every hue page");
            chk(pal[31 + hue*32][31:24] === 8'd210,
                "role 31 blends at 210 on every hue page");
            chk(pal[31 + hue*32][23:0] === pal[2 + hue*32][23:0],
                "role 31 carries the same neon colour as role 2");
        end
        hs_role = -1;
        for (row = 0; row < 26 && hs_role < 0; row = row + 1)
            for (col = 0; col < 26 && hs_role < 0; col = col + 1)
                if (tiles[tile_off(0) + row*32 + col] == 31) begin
                    hs_role = 31;
                    hs_row  = row;
                    hs_col  = col;
                end
        chk(hs_role == 31, "sanity: the enemy tile holds a wing cell");
        Y = 11'd0;
        put_bucket_hue(820, hs_row, 0, 26, 4);
        X = 12'd820 + hs_col; DE = 1'b1;
        repeat (8) @(posedge clk);
        chk(visible === 1'b1 && bullet_add === 1'b0 && alpha === 8'd210,
            "an enemy wing pixel must blend at 210, not add or replace");
        $display("  enemy wing: role 31 at row %0d col %0d blends at 210",
                 hs_row, hs_col);

        // ---- 2. the range compare: one column each side must stay empty ---
        // Row 12, not row 0: tile 0 is a 26x26 enemy shape flying along +x, so
        // its middle row is the one that is actually full of pixels.  Row 0 of
        // that shape is far off the flight axis and entirely transparent, which
        // would have made this section pass without testing anything.
        put_bucket(700, 12, 0, 26);
        X = 12'd699; @(posedge clk); repeat (8) @(posedge clk);
        chk(visible === 1'b0, "one column left of bx must be empty");
        X = 12'd726; @(posedge clk); repeat (8) @(posedge clk);
        chk(visible === 1'b0, "bx+width is the first column NOT covered");
        X = 12'd725; @(posedge clk); repeat (8) @(posedge clk);
        // This used to be `chk(visible === 1'b1 || tiles[tile_off(0) + 12] == 0)`,
        // which cannot fail: cell 12 of tile 0 is 0 (transparent), so the right
        // side was always true while the left side was always false.
        exp_idx = tiles[tile_off(0) + 12*32 + 25];
        chk(visible === (exp_idx != 0) && (exp_idx == 0 || rgb === pal[exp_idx][23:0]),
            "the last column inside the tile must match its own cell");

        // ---- 3. bucket_ready low means nothing is drawn --------------------
        put_bucket(700, 12, 0, 26);
        bucket_ready = 1'b0;
        X = 12'd713; @(posedge clk); repeat (8) @(posedge clk);
        chk(visible === 1'b0, "an unpublished bucket draws nothing");
        bucket_ready = 1'b1;

        // ---- 4. the LAST entry wins, which is what draw order means --------
        //     Player shots are slot 16 and enemy bullets 0..15; the renderer
        //     draws the player's first, so an enemy bullet sitting on the same
        //     pixel has to cover it.  Put the LOWER slot first in the bucket and
        //     the HIGHER slot second: the higher one must win.
        bucket = {32*SLOTS{1'b0}};
        //     The two entries have to OVERLAP for this to mean anything, and
        //     at 26x26 they only did so once both were moved: x = 705 is column
        //     1 of the player shot (bx 704) and column 15 of the enemy bullet
        //     (bx 690), and both of those cells are opaque on row 12.
        bucket[31:0]        = entry(704, 12, 16, 7);  // player shot, drawn first
        bucket[32*(SLOTS-1) +: 32] = entry(690, 12, 3, 26);  // enemy bullet, drawn last
        bucket_ready = 1'b1;
        X = 12'd705; @(posedge clk); repeat (8) @(posedge clk);
        exp_idx = tiles[tile_off(3) + 12*32 + 15];
        chk(visible === (exp_idx != 0) && rgb === pal[exp_idx][23:0],
            "the later entry in the bucket covers the earlier one");

        // ...and swapping which slot sits higher in the bucket swaps the winner
        bucket = {32*SLOTS{1'b0}};
        bucket[31:0]        = entry(690, 12, 3, 26);  // enemy bullet first
        bucket[32*(SLOTS-1) +: 32] = entry(704, 12, 16, 7);  // player shot last
        X = 12'd705; @(posedge clk); repeat (8) @(posedge clk);
        exp_idx = tiles[tile_off(16) + 12*8 + 1];
        chk(visible === (exp_idx != 0) && rgb === pal[exp_idx][23:0],
            "swapping the bucket order swaps the winner");

        // ---- 4b. a TRANSPARENT winner must not erase the entry beneath it --
        //
        // This is the other half of "the later entry wins", and nothing here
        // graded it until now.  The rule as written is a per-PIXEL pick: the
        // winning entry's tile decides the pixel, and if that tile cell is
        // role 0 the layer draws NOTHING there - it does not fall back to the
        // entry it just beat.  The bucket is a priority list, not a stack.
        //
        // That is invisible while every layer is a framebuffer blit, because
        // "draw nothing" correctly reveals the framebuffer underneath.  B1
        // moved the player's shots OFF the framebuffer and INTO this bucket
        // (main.c:6514), so there is no longer anything underneath them to
        // reveal: an enemy entry that merely OVERLAPS a player shot - the
        // enemy tile is 26x26 and mostly transparent - takes the pixel, finds
        // role 0 in its own tile, paints nothing, and the player's shot is
        // gone.  On the board that reads as an invisible dark rectangle that
        // eats the player's shots as they pass under it.
        //
        // Both entries cover x here and only the player's tile paints, so the
        // pixel has exactly one honest answer.
        ov_row = -1; ov_col = -1;
        for (row = 0; row < 26 && ov_row < 0; row = row + 1)
            for (col = 0; col < 7 && ov_row < 0; col = col + 1)
                if (tiles[tile_off(16) + row*8 + col] != 0 &&
                    tiles[tile_off(0)  + row*32 + (14 + col)] == 0) begin
                    ov_row = row;
                    ov_col = col;
                end
        chk(ov_row >= 0,
            "sanity: these two tiles share a column only the player shot paints");
        bucket = {32*SLOTS{1'b0}};
        bucket[31:0]        = entry(704, ov_row, 16, 7);   // player shot, drawn first
        bucket[32*(SLOTS-1) +: 32] = entry(690, ov_row,  0, 26);  // enemy bullet, drawn last
        bucket_ready = 1'b1;
        X = 12'd704 + ov_col; Y = 11'd0; DE = 1'b1;
        repeat (8) @(posedge clk);
        ov_p = tiles[tile_off(16) + ov_row*8 + ov_col];
        $display("  overlap probe: row %0d col %0d x %0d - player paints role %0d (#%06x), enemy cell is transparent",
                 ov_row, ov_col, 704 + ov_col, ov_p, pal[ov_p][23:0]);
        chk(visible === 1'b1 && rgb === pal[ov_p][23:0],
            "a player shot under a TRANSPARENT enemy cell must still be drawn");

        // ---- 4c. the fallback is exactly ONE level, and it is the RIGHT one --
        //
        // Three entries on the same column, so all three tiles are indexed by the
        // same cell number: bucket[2] outranks bucket[1] outranks bucket[0].  The
        // runner-up has to be the SECOND-highest hit specifically - an encoder
        // that grabbed "some other hit" would still pass 4b, where there are only
        // two entries to choose from, and would paint the wrong bullet here.
        //
        // Same bx for all three on purpose: the cell is then the same column in
        // every tile and the arithmetic in this section cannot silently drift.
        ow_row = -1; ow_col = -1;
        for (row = 0; row < 26 && ow_row < 0; row = row + 1)
            for (col = 0; col < 26 && ow_row < 0; col = col + 1)
                if (tiles[tile_off(11) + row*32 + col] == 0 &&
                    tiles[tile_off(8)  + row*32 + col] != 0 &&
                    tiles[tile_off(0)  + row*32 + col] != 0) begin
                    ow_row = row;
                    ow_col = col;
                end
        chk(ow_row >= 0,
            "sanity: the three tiles share a cell where only the top one is transparent");
        if (ow_row >= 0) begin
            bucket = {32*SLOTS{1'b0}};
            bucket[31:0]         = entry(700, ow_row, 0, 26);   // lowest priority
            bucket[32*1 +: 32]   = entry(700, ow_row, 8, 26);   // the runner-up
            bucket[32*2 +: 32]   = entry(700, ow_row, 11, 26);  // wins, but transparent here
            bucket_ready = 1'b1;
            X = 12'd700 + ow_col; Y = 11'd0; DE = 1'b1;
            repeat (8) @(posedge clk);
            ow_p  = tiles[tile_off(8) + ow_row*32 + ow_col];
            ow_p2 = tiles[tile_off(0) + ow_row*32 + ow_col];
            $display("  stack probe: row %0d col %0d - slot 11 transparent, slot 8 role %0d, slot 0 role %0d",
                     ow_row, ow_col, ow_p, ow_p2);
            chk(visible === 1'b1 && rgb === pal[ow_p][23:0],
                "the second-highest entry must paint, not the third");
        end

        // ---- 4d. and the fallback stops there: the documented LIMIT -----------
        //
        // Three entries on the column, the top two transparent at this cell, the
        // bottom one live.  With ONE level of fallback the layer paints nothing:
        // it retreats from bucket[2] to bucket[1], finds role 0 again and stops.
        // The same tile is stacked twice because it only has to be transparent
        // here - an entry may legally repeat.
        //
        // This asserts the LIMIT, not a fix.  Going deeper costs a read port per
        // level and level two is where the reported artefacts end, so the boundary
        // is written down as a check: if someone ever deepens the fallback, THIS is
        // the line that tells them they changed it.
        if (ow_row >= 0) begin
            bucket = {32*SLOTS{1'b0}};
            bucket[31:0]       = entry(700, ow_row, 0, 26);   // live, one level too deep
            bucket[32*1 +: 32] = entry(700, ow_row, 11, 26);  // transparent
            bucket[32*2 +: 32] = entry(700, ow_row, 11, 26);  // transparent, wins
            bucket_ready = 1'b1;
            X = 12'd700 + ow_col; Y = 11'd0; DE = 1'b1;
            repeat (8) @(posedge clk);
            chk(tiles[tile_off(0) + ow_row*32 + ow_col] != 0,
                "sanity: the bottom entry really is opaque at this cell");
            chk(visible === 1'b0,
                "one level only: a live entry two levels down stays hidden");
            $display("  stack probe: fallback depth is one level, by design");
        end

        // ---- 5. an entry that misses must not block one that hits ----------
        bucket = {32*SLOTS{1'b0}};
        bucket[31:0]        = entry(100, 12, 5, 26);  // far away
        bucket[32*(SLOTS-1) +: 32] = entry(700, 12, 7, 26);  // covers x = 712
        X = 12'd712; @(posedge clk); repeat (8) @(posedge clk);
        exp_idx = tiles[tile_off(7) + 12*32 + 12];
        chk(visible === (exp_idx != 0) && rgb === pal[exp_idx][23:0],
            "a miss above must not shadow a hit below");

        // ---- 6. the occlusion box ------------------------------------------
        //     The pause card, the stage banner and the boss dialogue are
        //     framebuffer pixels, and a layer composited at scanout cannot see
        //     them; the firmware publishes their union and this layer has to
        //     stay out of it.  The rectangle is compared with >= and <=, so x0,
        //     x1, y0 and y1 are themselves inside the box.
        //
        //     Row 0 of tile 0 is entirely transparent, so the checks below use
        //     row 12, whose columns 9..17 are opaque: "the cell is not drawn"
        //     has to mean the box and not an empty cell.  (At 13x13 this was
        //     row 6, columns 3..10 - the shape flew along +x then too, but the
        //     row through its middle was 6.)
        put_bucket(700, 12, 0, 26);
        mask_x = 32'd0; mask_y = 32'd0;
        exp_idx = tiles[tile_off(0) + 12*32 + 13];
        chk(exp_idx != 0, "sanity: the cell this section uses is opaque");
        X = 12'd713; Y = 11'd0; @(posedge clk); repeat (8) @(posedge clk);
        chk(visible === 1'b1 && rgb === pal[exp_idx][23:0],
            "box off: the cell at x = 713 is drawn");

        mask_x = {1'b1, 9'd0, 11'd714, 11'd713};
        mask_y = {10'd0, 11'd5, 11'd0};
        X = 12'd713; Y = 11'd0; @(posedge clk); repeat (8) @(posedge clk);
        chk(visible === 1'b0, "inside the box the opaque cell is not drawn");
        X = 12'd714; @(posedge clk); repeat (8) @(posedge clk);
        chk(visible === 1'b0, "the box x1 column is inside the box");
        X = 12'd712; @(posedge clk); repeat (8) @(posedge clk);
        exp_idx = tiles[tile_off(0) + 12*32 + 12];
        chk(exp_idx != 0 && visible === 1'b1 && rgb === pal[exp_idx][23:0],
            "one column left of the box is still drawn");
        X = 12'd715; @(posedge clk); repeat (8) @(posedge clk);
        exp_idx = tiles[tile_off(0) + 12*32 + 15];
        chk(exp_idx != 0 && visible === 1'b1 && rgb === pal[exp_idx][23:0],
            "one column right of the box is still drawn");
        X = 12'd713; @(posedge clk); repeat (8) @(posedge clk);
        chk(visible === 1'b0, "still inside the box at the same column");
        // The bucket is rewritten at each new Y.  An entry's trow_base is
        // relative to the scanline it was written for, so carrying the old one
        // into a different row would slide the tile instead of testing the box.
        Y = 11'd5; put_bucket(700, 12, 0, 26);
        @(posedge clk); repeat (8) @(posedge clk);
        chk(visible === 1'b0, "the box y1 row is inside the box");
        Y = 11'd6; put_bucket(700, 12, 0, 26);
        @(posedge clk); repeat (8) @(posedge clk);
        chk(visible === 1'b1, "one row below the box is still drawn");

        // released: the cell comes back, nothing was latched away
        mask_x = 32'd0; mask_y = 32'd0;
        Y = 11'd0; put_bucket(700, 12, 0, 26);
        X = 12'd713; @(posedge clk); repeat (8) @(posedge clk);
        if (visible !== 1'b1)
            $display("  DEBUG released: visible=%b rgb=%06x X=%0d Y=%0d entry=%08x in_box=%b mask_x=%08x",
                     visible, rgb, X, Y, bucket[31:0], dut.in_box, mask_x);
        chk(visible === 1'b1, "the cell comes back when the box is released");

        // ---- 7. continuous pixels checked against the Python model oracle --
        // Addresses are sampled at edge N; rgb/alpha/visible emerge at N+3.
        // Unlike the static probes, this detects colour/hue/DE misalignment.
        $readmemh("bullet_stream.hex", stream_vectors);
        for (stream_i = 0; stream_i < STREAM_COUNT + 3; stream_i = stream_i + 1) begin
            @(negedge clk);
            bucket = {32*SLOTS{1'b0}};
            if (stream_i < STREAM_COUNT) begin
                {stream_result, mask_y, mask_x, bucket_ready, DE, Y, X,
                 bucket[32*(SLOTS-1) +: 32], bucket[32*(SLOTS-2) +: 32],
                 bucket[31:0]} = stream_vectors[stream_i];
            end else begin
                DE = 1'b0;
                stream_result = 34'd0;
            end
            stream_expected[stream_i % 4] = stream_result;
            @(posedge clk); #1;
            if (stream_i >= 3) begin
                stream_result = stream_expected[(stream_i - 3) % 4];
                chk(visible === stream_result[33] && bullet_add === stream_result[32],
                    "continuous pixel: visible/add aligned with input N-3");
                if (stream_result[33])
                    chk({alpha, rgb} === stream_result[31:0],
                        "continuous pixel: role, hue, alpha and RGB from same candidate");
            end
        end
        $display("  stream: %0d consecutive pixels, including metadata transitions", STREAM_COUNT);

        // Losing readiness must fail closed for the remainder of this line.
        Y = 0; put_bucket(700, 12, 0, 26); X = 713; DE = 1;
        prepare_line();
        repeat (8) @(posedge clk); #1;
        chk(visible === 1'b1, "ready before loss");
        @(negedge clk); bucket_ready = 0;
        repeat (8) @(posedge clk); #1;
        chk(visible === 1'b0, "unpublished bucket never paints");
        @(negedge clk); bucket_ready = 1;
        repeat (8) @(posedge clk); #1;
        chk(visible === 1'b0, "late ready cannot reuse stale coverage");
        prepare_line();
        repeat (8) @(posedge clk); #1;
        chk(visible === 1'b1, "next complete scanline recovers");
        @(negedge clk); pixel_rst_n = 0;
        repeat (4) @(posedge clk);
        @(negedge clk); pixel_rst_n = 1;
        repeat (8) @(posedge clk); #1;
        chk(visible === 1'b0, "reset invalidates coverage before next line");
        prepare_line();
        repeat (8) @(posedge clk); #1;
        chk(visible === 1'b1, "coverage rebuilt after reset without reloading tiles");

        $display("");
        $display("CHECKED %0d  FAILED %0d", checks, fails);
        if (fails == 0)
            $display("PASS tb_bullet_overlay RTL: the scanout reproduces the firmware's bullet tiles cell for cell");
        else
            $display("FAIL tb_bullet_overlay RTL: %0d cells differ", fails);
        if (fails != 0) $fatal(1, "bullet overlay checks failed");
        $finish;
    end
endmodule

