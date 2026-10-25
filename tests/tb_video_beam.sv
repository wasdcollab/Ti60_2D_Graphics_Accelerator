`timescale 1ns/1ps
// =============================================================================
// tb_video_beam -- the scanout's beam / hairline overlay against the pixels the
// engine used to write.
//
// THE REFERENCE IS NOT A SECOND COPY OF THE RTL'S TABLE.  It is the sheet the
// FIRMWARE builds at boot: laser_glow_build() in sw/app/main.c fills
// MM_LASER_GLOW with a 16 x 768 surface whose rows repeat every 16, and
// tools/dump_beam_ref.py dumps exactly those bytes out of the emulated DDR.
// Before A3 the engine blitted that sheet into the framebuffer with the magenta
// colour key skipping columns 0, 1, 14 and 15.  The RTL has to put the same
// pixels on the same columns and skip the same four, and this is where that
// claim is tested - against the firmware's own bytes, not against a table
// somebody retyped.
//
// Run:  tools\sim_video_beam.ps1
// =============================================================================
module tb_video_beam;
    localparam integer TEX_ROWS = 768;
    localparam integer TEX_COLS = 16;
    localparam [31:0]  MAGENTA_KEY = 32'h00FF00FF;

    // The DUT is combinational; the clock is only here so the simulator has
    // something to advance on between one stimulus and the next.
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [11:0] X = 12'd0;
    reg [10:0] Y = 11'd0;
    reg        DE = 1'b1;

    reg [11:0] beam_x   = 12'd0;
    reg [11:0] beam_len = 12'd0;
    reg        beam_en  = 1'b0;

    reg [35:0] hair_x   = 36'd0;
    reg [71:0] hair_out = 72'd0;
    reg [71:0] hair_lft = 72'd0;
    reg [71:0] hair_mid = 72'd0;

    // The occlusion box the firmware publishes every frame (weather_box_publish
    // in main.c): [10:0] x0, [21:11] x1, [31] enable, and mask_y carries y0/y1
    // the same way.  The pause card, the stage banner and the boss dialogue are
    // framebuffer pixels this layer is composited over and cannot see, so the
    // box is the only thing stopping the beam from being drawn across them.
    reg [31:0] mask_x = 32'd0;
    reg [31:0] mask_y = 32'd0;

    wire        vis;
    wire [23:0] rgb;
    // Which blend the layer is asking for on this pixel.  A switch in the
    // beam's own column table, not a constant any more: the core adds and the
    // halo blends, and the scanout picks its branch from these two.
    wire        vis_add;
    wire [7:0]  vis_alpha;

    video_beam dut (
        .pixel_clk(clk), .pixel_rst_n(1'b1),
        .x(X), .y(Y), .de(DE),
        .beam_x(beam_x), .beam_len(beam_len), .beam_en(beam_en),
        .hair_x(hair_x), .hair_out(hair_out),
        .hair_lft(hair_lft), .hair_mid(hair_mid),
        .mask_x(mask_x), .mask_y(mask_y),
        .visible(vis), .beam_add(vis_add), .beam_alpha(vis_alpha), .rgb(rgb)
    );

    reg [31:0] tex [0:TEX_ROWS*TEX_COLS-1];

    integer checks = 0;
    integer fails  = 0;
    integer i, y, dx, k, bx, sbx;
    reg [31:0] want;
    reg        want_op;
    reg        exp_add;
    reg [7:0]  exp_alpha;

    task set_hair(input integer slot, input [11:0] cx,
                  input [23:0] c_out, input [23:0] c_lft, input [23:0] c_mid);
        begin
            case (slot)
                0: begin hair_x[11:0]  = cx; hair_out[23:0]  = c_out;
                         hair_lft[23:0]  = c_lft; hair_mid[23:0]  = c_mid; end
                1: begin hair_x[23:12] = cx; hair_out[47:24] = c_out;
                         hair_lft[47:24] = c_lft; hair_mid[47:24] = c_mid; end
                default: begin hair_x[35:24] = cx; hair_out[71:48] = c_out;
                         hair_lft[71:48] = c_lft; hair_mid[71:48] = c_mid; end
            endcase
        end
    endtask

    task chk(input ok, input [1023:0] what);
        begin
            checks = checks + 1;
            if (!ok) begin
                fails = fails + 1;
                if (fails <= 12) $display("  FAIL %0s", what);
            end
        end
    endtask

    initial begin
        $readmemh("laser_glow.hex", tex);

        // ------------------------------------------------------------------
        // 1. the craft's beam: the whole 16 x 768 surface the engine used to
        //    copy, against the firmware's sheet, at three different centres.
        // ------------------------------------------------------------------
        for (k = 0; k < 3; k = k + 1) begin
            bx = (k == 0) ? 189 : (k == 1) ? 600 : 1177;
            beam_x   = bx[11:0];
            beam_len = 12'd768;
            beam_en  = 1'b1;
            for (y = 0; y < TEX_ROWS; y = y + 1) begin
                for (dx = 0; dx < TEX_COLS; dx = dx + 1) begin
                    X = (bx - 8 + dx);
                    Y = y[10:0];
                    @(negedge clk);
                    want    = tex[y*TEX_COLS + dx];
                    want_op = (want != MAGENTA_KEY);
                    checks  = checks + 1;
                    if (want_op ? ((vis !== 1'b1) || (rgb !== want[23:0]))
                                : (vis !== 1'b0)) begin
                        fails = fails + 1;
                        if (fails <= 12)
                            $display("  FAIL beam centre %0d y=%0d dx=%0d: want %06x/%b got %06x/%b",
                                     bx, y, dx, want[23:0], want_op, rgb, vis);
                    end
                end
            end
        end
        $display("  beam: swept 3 centres x %0d rows x %0d columns", TEX_ROWS, TEX_COLS);

        // ------------------------------------------------------------------
        // 1b. WHICH BLEND each column asks for.
        //
        //    The sheet compared above is a 24-bit surface: it can say what
        //    colour a column is and nothing else - an opacity does not fit in
        //    it and "add" is not a colour at all.  That answer lives in the
        //    column table inside video_beam, and this is the only place it is
        //    checked against the rule the picture needs:
        //
        //      columns 7, 8            add, and are the only ones that do -
        //                              they are the light source
        //      columns 5, 6, 9, 10     blend at 190 (the halo)
        //      columns 2..4, 11..13    blend at 130 (the rim, the most
        //                              transparent step, so the edge fades)
        //      columns 0, 1, 14, 15    drawn by nobody and blended by nobody
        //
        //    Before this change every drawn column added.  Six of the twelve
        //    were white or near white, so on any non-zero background the whole
        //    strip saturated and the beam read as a solid white bar - which is
        //    why the selector exists at all, and why a bench that only swept
        //    colours would have called that picture correct.
        // ------------------------------------------------------------------
        beam_x = 12'd600; beam_len = 12'd768; beam_en = 1'b1;
        for (dx = 0; dx < TEX_COLS; dx = dx + 1) begin
            X = 12'd592 + dx[11:0];
            Y = 11'd300;
            @(negedge clk);
            exp_add   = (dx == 7) || (dx == 8);
            exp_alpha = (dx <= 1 || dx >= 14) ? 8'd0
                      : (dx <= 4 || dx >= 11) ? 8'd130
                      : (dx <= 6 || dx >= 9)  ? 8'd190
                      : 8'd255;
            checks = checks + 1;
            if (vis   !== ((dx >= 2) && (dx <= 13)) ||
                vis_add   !== exp_add ||
                vis_alpha !== exp_alpha) begin
                fails = fails + 1;
                if (fails <= 12)
                    $display("  FAIL beam column dx=%0d: want drawn=%b add=%b alpha=%0d, got drawn=%b add=%b alpha=%0d",
                             dx, (dx >= 2) && (dx <= 13), exp_add, exp_alpha,
                             vis, vis_add, vis_alpha);
            end
        end
        $display("  beam: the blend selector swept across all %0d columns", TEX_COLS);
        beam_en = 1'b0; beam_len = 12'd0;

        // ------------------------------------------------------------------
        // 2. the beam's edges: nothing outside the strip, nothing past the
        //    height, nothing at all with the enable down.
        // ------------------------------------------------------------------
        beam_x = 12'd600; beam_len = 12'd100; beam_en = 1'b1;
        X = 12'd591; Y = 11'd50; @(negedge clk);
        chk(vis === 1'b0, "one column left of the strip must be empty");
        X = 12'd608; Y = 11'd50; @(negedge clk);
        chk(vis === 1'b0, "one column right of the strip must be empty");
        // Columns 592, 593, 606 and 607 are the sheet's magenta-keyed ones, so
        // they draw nothing here either - which is what the blit's colour key
        // did with them.
        X = 12'd592; Y = 11'd50; @(negedge clk);
        chk(vis === 1'b0, "the strip's first keyed column must be empty");
        X = 12'd593; Y = 11'd50; @(negedge clk);
        chk(vis === 1'b0, "the strip's second keyed column must be empty");
        X = 12'd594; Y = 11'd50; @(negedge clk);
        chk(vis === 1'b1, "the strip's leftmost opaque column must be drawn");
        X = 12'd605; Y = 11'd50; @(negedge clk);
        chk(vis === 1'b1, "the strip's rightmost opaque column must be drawn");
        X = 12'd606; Y = 11'd50; @(negedge clk);
        chk(vis === 1'b0, "the strip's third keyed column must be empty");
        X = 12'd607; Y = 11'd50; @(negedge clk);
        chk(vis === 1'b0, "the strip's last keyed column must be empty");
        X = 12'd600; Y = 11'd99; @(negedge clk);
        chk(vis === 1'b1, "the last row inside the beam must be drawn");
        Y = 11'd100; @(negedge clk);
        chk(vis === 1'b0, "the first row past the beam must be empty");
        Y = 11'd767; @(negedge clk);
        chk(vis === 1'b0, "y = 767 with a 100-row beam must be empty");
        Y = 11'd50; beam_en = 1'b0; @(negedge clk);
        chk(vis === 1'b0, "a disabled beam must draw nothing");
        beam_en = 1'b1; DE = 1'b0; @(negedge clk);
        chk(vis === 1'b0, "de low must draw nothing");
        DE = 1'b1; beam_en = 1'b0; beam_len = 12'd0;

        // ------------------------------------------------------------------
        // 3. the warning hairline: four columns, three colours, and the two
        //    forms main.c actually writes (the 4-wide sheath pair and the
        //    2-wide white pair), plus the shimmer line's split pair.
        // ------------------------------------------------------------------
        set_hair(0, 12'd400, 24'hFF3050, 24'hFFFFFF, 24'hFF1030);
        set_hair(1, 12'd0,   24'h000000, 24'h000000, 24'h000000);
        set_hair(2, 12'd0,   24'h000000, 24'h000000, 24'h000000);
        X = 12'd398; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hFF3050, "hairline hx-2 takes the outer colour");
        X = 12'd399; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hFFFFFF, "hairline hx-1 takes the left colour");
        X = 12'd400; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hFF1030, "hairline hx takes the centre colour");
        X = 12'd401; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hFF3050, "hairline hx+1 takes the outer colour");
        // A hairline asks for NEITHER blend.  It replaces, which is what keeps
        // it legible over a bright snow ridge - an additive hairline would wash
        // out exactly where the player most needs to read it.  That was true
        // before the beam grew a per-column selector and it has to stay true
        // after: the selector belongs to the beam, not to this module's output.
        X = 12'd400; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hFF1030 && !vis_add && vis_alpha === 8'd0,
            "a hairline replaces: it never asks to add and never asks to blend");
        X = 12'd397; @(negedge clk);
        chk(vis === 1'b0, "hairline hx-3 must be empty");
        X = 12'd402; @(negedge clk);
        chk(vis === 1'b0, "hairline hx+2 must be empty");
        Y = 11'd0; X = 12'd400; @(negedge clk);
        chk(vis === 1'b1, "a hairline runs the full height (top row)");
        Y = 11'd767; @(negedge clk);
        chk(vis === 1'b1, "a hairline runs the full height (bottom row)");

        // the 2-wide white form: outer and left cleared, centre white
        set_hair(0, 12'd400, 24'h000000, 24'hFFFFFF, 24'hFFFFFF);
        X = 12'd398; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b0, "the 2-wide form draws nothing at hx-2");
        X = 12'd399; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hFFFFFF, "the 2-wide form is white at hx-1");
        X = 12'd400; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hFFFFFF, "the 2-wide form is white at hx");
        X = 12'd401; @(negedge clk);
        chk(vis === 1'b0, "the 2-wide form draws nothing at hx+1");

        // the shimmer form: a different colour in each of the middle pair
        set_hair(0, 12'd400, 24'h000000, 24'hFF9AA8, 24'h783840);
        X = 12'd399; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hFF9AA8, "the shimmer form's hx-1 colour");
        X = 12'd400; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h783840, "the shimmer form's hx colour");

        // a slot with x = 0 is off, whatever its colours say
        set_hair(0, 12'd0, 24'hFF3050, 24'hFFFFFF, 24'hFF1030);
        X = 12'd0; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b0, "a slot parked at x = 0 must draw nothing");

        // ------------------------------------------------------------------
        // 4. three slots at once, and the order they cover each other in.
        //    game_render() walks k = 0, 1, 2, so slot 2 is on top.
        // ------------------------------------------------------------------
        set_hair(0, 12'd500, 24'h000000, 24'h111111, 24'h111111);
        set_hair(1, 12'd500, 24'h000000, 24'h222222, 24'h222222);
        set_hair(2, 12'd500, 24'h000000, 24'h333333, 24'h333333);
        X = 12'd500; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h333333, "slot 2 covers slot 1 and slot 0");
        set_hair(2, 12'd0, 24'h000000, 24'h000000, 24'h000000);
        X = 12'd500; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h222222, "slot 1 covers slot 0 once slot 2 is off");
        set_hair(1, 12'd0, 24'h000000, 24'h000000, 24'h000000);
        X = 12'd500; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h111111, "slot 0 survives on its own");
        set_hair(0, 12'd0, 24'h000000, 24'h000000, 24'h000000);
        X = 12'd500; @(negedge clk);
        chk(vis === 1'b0, "three clear slots draw nothing");

        // ...and the beam is drawn after all of them: it wins an overlap.
        set_hair(0, 12'd600, 24'hFF3050, 24'hFFFFFF, 24'hFF1030);
        set_hair(1, 12'd600, 24'hFF3050, 24'hFFFFFF, 24'hFF1030);
        set_hair(2, 12'd600, 24'hFF3050, 24'hFFFFFF, 24'hFF1030);
        beam_x = 12'd600; beam_len = 12'd768; beam_en = 1'b1;
        X = 12'd600; Y = 11'd300; @(negedge clk);
        want = tex[300*TEX_COLS + 8];
        chk(vis === 1'b1 && rgb === want[23:0],
            "the beam covers a hairline standing on the same column");
        // ...but a keyed beam column does not: the hairline shows through it.
        set_hair(2, 12'd0, 24'h000000, 24'h000000, 24'h000000);
        set_hair(1, 12'd0, 24'h000000, 24'h000000, 24'h000000);
        // x = 607 is the beam's dx = 15, i.e. one of the four columns the
        // engine's colour key skipped.  The hairline standing there has to
        // survive, exactly as it did when the blit stepped over the pixel.
        set_hair(0, 12'd607, 24'h000000, 24'h7A7A7A, 24'h7A7A7A);
        beam_x = 12'd600;
        X = 12'd607; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h7A7A7A,
            "a hairline under the beam's keyed edge column still shows");
        // The other way round: a hairline standing where the beam is opaque
        // is covered by it, because game_render() draws the beam last.
        set_hair(0, 12'd604, 24'h000000, 24'h7A7A7A, 24'h7A7A7A);
        X = 12'd604; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h4696C0,
            "an opaque beam column covers a hairline standing under it");

        // ------------------------------------------------------------------
        // 5. the occlusion box.  The pause card, the stage banner and the boss
        //    dialogue are painted into the framebuffer; a layer composited at
        //    scanout has no way to know that, so the firmware publishes the
        //    union of their rectangles and this module has to drop whatever it
        //    was about to draw inside them.
        //
        //    This section did not exist until now, and neither did the two
        //    instantiation ports it drives: mask_x / mask_y were simply left out
        //    of the dut instantiation, so mask_x[31] - the enable - was a
        //    constant 0 and "the box is off" was the only case this bench ever
        //    simulated.  Everything above it was grading a layer whose occlusion
        //    was switched off.
        //
        //    The mask word is {enable, 9 bits spare, x1[10:0], x0[10:0]}, so the
        //    enable belongs at bit 31 and nowhere else.  Writing it as
        //    {1'b1, 11'd608, 11'd600} produces a 23-bit value that is zero
        //    extended into a 32-bit read - enable 0, box off.  All four mask
        //    writes below are built with the 9-bit pad spelled out.
        // ------------------------------------------------------------------
        beam_x = 12'd600; beam_len = 12'd768; beam_en = 1'b1;
        set_hair(0, 12'd400, 24'h7A7A7A, 24'h7A7A7A, 24'h7A7A7A);
        set_hair(1, 12'd0, 24'h000000, 24'h000000, 24'h000000);
        set_hair(2, 12'd0, 24'h000000, 24'h000000, 24'h000000);

        // box off: both shapes are really there, so the checks below are not
        // comparing against an empty picture.  x = 604 is the beam's dx = 12
        // (colour 0088FF), x = 599 is dx = 7 (white).
        mask_x = 32'd0; mask_y = 32'd0;
        X = 12'd604; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h4696C0, "box off: the beam column is drawn");
        X = 12'd399; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h7A7A7A, "box off: the hairline is drawn");

        // box over x 600..604, y 290..310.  The RTL compares with >= and <=, so
        // x0, x1, y0 and y1 themselves are inside the rectangle.
        mask_x = {1'b1, 9'd0, 11'd604, 11'd600};
        mask_y = {10'd0, 11'd310, 11'd290};
        X = 12'd604; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b0, "inside the box the beam is not drawn");
        X = 12'd600; @(negedge clk);
        chk(vis === 1'b0, "the box x0 column is inside the box");
        X = 12'd602; @(negedge clk);
        chk(vis === 1'b0, "the middle of the box is inside the box");
        X = 12'd599; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hFFFFFF, "one column left of the box is still drawn");
        X = 12'd605; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h2E6C8C, "one column right of the box is still drawn");
        X = 12'd604; Y = 11'd289; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h4696C0, "one row above the box is still drawn");
        Y = 11'd290; @(negedge clk);
        chk(vis === 1'b0, "the box y0 row is inside the box");
        Y = 11'd310; @(negedge clk);
        chk(vis === 1'b0, "the box y1 row is inside the box");
        Y = 11'd311; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h4696C0, "one row below the box is still drawn");

        // the same rectangle covers the hairline too: one box for the whole
        // layer, not one per shape.  x = 604 is outside it, so the hairline at
        // 399 is still there to be tested.
        X = 12'd399; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h7A7A7A, "the hairline is outside a box that only covers the beam");
        mask_x = {1'b1, 9'd0, 11'd400, 11'd399};
        X = 12'd399; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b0, "the hairline is dropped inside the box");
        X = 12'd398; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h7A7A7A, "the hairline one column outside the box survives");
        X = 12'd401; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h7A7A7A, "the hairline on the far side of the box survives");

        // released: the picture comes back, nothing was latched away
        mask_x = 32'd0;
        X = 12'd604; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h4696C0, "the beam comes back when the box is released");
        X = 12'd399; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'h7A7A7A, "the hairline comes back when the box is released");

        // a box over a single column is still a box, and the enable bit is what
        // turns it on: x0 == x1 == 0 with [31] set covers column 0 and nothing else
        set_hair(0, 12'd2, 24'hAABBCC, 24'hAABBCC, 24'hAABBCC);
        X = 12'd0; Y = 11'd300; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hAABBCC, "column 0 carries the hairline outer colour");
        mask_x = {1'b1, 9'd0, 11'd0, 11'd0};
        X = 12'd0; @(negedge clk);
        chk(vis === 1'b0, "a box over column 0 drops column 0");
        X = 12'd1; @(negedge clk);
        chk(vis === 1'b1 && rgb === 24'hAABBCC, "the column beside it still carries the hairline");
        mask_x = 32'd0;
        mask_x = 32'd0;

        $display("");
        $display("CHECKED %0d  FAILED %0d", checks, fails);
        if (fails == 0) $display("PASS tb_video_beam RTL: the scanout reproduces the firmware's beam sheet and hairlines pixel for pixel");
        else            $display("FAIL tb_video_beam RTL: %0d pixels differ", fails);
        $finish(fails ? 1 : 0);
    end
endmodule
