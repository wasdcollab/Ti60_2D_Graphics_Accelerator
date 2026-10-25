`timescale 1ns/1ps

// =============================================================================
// tb_bloom_filter -- acceptance bench for the hardware bloom engine.
// -----------------------------------------------------------------------------
// What is graded, and why it is graded on the OUTPUT pixels
// ---------------------------------------------------------
// video_bloom_filter adds a halo around emissive pixels (framebuffer alpha >= 32)
// and must leave every other pixel exactly as it arrived.  Three things are
// checked here, all of them on r_out/g_out/b_out -- the module's internal glow
// signals are not a valid stand-in, because a wrong channel mapping or a missing
// add would keep them looking perfectly healthy:
//
//   1. The halo is round and colour-blind.  The test sprite is NEUTRAL
//      (200,200,200) on purpose: grading three channels that were fed (255,30,30)
//      compares a saturated channel against two dim ones, and after the >>5
//      normalisation in stage 3 the dim channels fade out one tap sooner -- not
//      because the kernel differs (it does not) but because 30*1 >> 5 is zero
//      while 255*1 >> 5 is seven.  An earlier version of this bench did exactly
//      that and reported a 207-pixel red arm against 5-pixel green and blue
//      arms, i.e. chromatic dispersion, on a kernel that is per-channel
//      symmetric.  With a neutral sprite the three channels must agree to the
//      pixel: same lit columns, and the same value on the sprite column itself.
//
//      A neutral sprite alone is blind to the opposite failure, though: if the
//      blue channel were fed the red channel's glow, a sprite fed (200,200,200)
//      would look identical, because all three glows are equal by construction.
//      The run therefore also carries a PURE RED sprite at column 800 - there
//      the answer is unambiguous, green and blue must come out exactly zero,
//      which is what pins each channel to its own light.
//   2. Nothing else lights up.  Rows away from the sprite, the text row, and the
//      far columns of the sprite row must come back bit-identical to the input.
//   3. With bloom disabled the output is the input, untouched.
//
// Timing note -- how the previous version of this bench invented a red pixel at
// column 699, a column that never carried one:
//
// The earlier bench sent 7 rows, then waited 200 clocks, then switched style and
// sent 7 more.  Rows were not back to back, so the hsync-referenced line_x
// counter advanced 200 clocks further than the pixel stream did, and the line
// RAM was then read at addresses that no longer matched what had been written --
// stale row contents surfaced as light on a column that has no emitter.  A real
// video stream has no such gap: every row is exactly 1456 clocks.  This bench
// therefore sends rows strictly back to back and changes ctrl while background
// rows are in flight, which is the only place a style change is harmless.
// =============================================================================

module tb_bloom_filter;

    reg ok = 0;
    reg        pixel_clk = 0;
    reg        pixel_rst_n = 0;

    reg        de_in = 0;
    reg        hsync_in = 0;
    reg        vsync_in = 0;
    reg [7:0]  a_in = 0;
    reg [7:0]  r_in = 0;
    reg [7:0]  g_in = 0;
    reg [7:0]  b_in = 0;

    reg [31:0] ctrl = 0;

    wire       de_out;
    wire       hsync_out;
    wire       vsync_out;
    wire [7:0] r_out;
    wire [7:0] g_out;
    wire [7:0] b_out;

    always #5.833 pixel_clk = ~pixel_clk; // ~85.71 MHz

    video_bloom_filter dut (
        .pixel_clk   (pixel_clk),
        .pixel_rst_n (pixel_rst_n),
        .de_in       (de_in),
        .hsync_in    (hsync_in),
        .vsync_in    (vsync_in),
        .a_in        (a_in),
        .r_in        (r_in),
        .g_in        (g_in),
        .b_in        (b_in),
        .ctrl        (ctrl),
        .de_out      (de_out),
        .hsync_out   (hsync_out),
        .vsync_out   (vsync_out),
        .r_out       (r_out),
        .g_out       (g_out),
        .b_out       (b_out)
    );

    localparam integer ROWS_PER_RUN = 12;   // 4 bg, text, sprite, 6 bg (drain)
    localparam integer NRUN         = 3;    // style 0, style 1, bypass
    localparam integer MAXLINE      = 47;

    localparam integer BGR = 20, BGG = 30, BGB = 60;  // background scenery
    localparam integer PIX = 200;                     // neutral emissive sprite
    localparam integer TXT = 128;                     // alpha-0 text pixel
    localparam integer SPRITE_COL = 500;
    localparam integer RED_COL = 800;      // second sprite: pure red, no green/blue light
    localparam integer RED_R = 180;
    localparam integer TEXT_LO = 400, TEXT_HI = 450;
    localparam integer TEXT_PIXELS = TEXT_HI - TEXT_LO + 1;

    localparam integer KIND_BG = 0, KIND_TEXT = 1, KIND_HALO = 2, KIND_RED = 3;

    integer in_line = -1;
    integer in_kind  [0:MAXLINE];
    integer in_style [0:MAXLINE];
    integer in_bloom [0:MAXLINE];

    integer cur_line = -1;
    integer out_px = 0;
    reg     de_out_d = 0;

    integer de_cnt   [0:MAXLINE];
    integer err_cnt  [0:MAXLINE];
    integer err_col  [0:MAXLINE];
    integer err_gr   [0:MAXLINE], err_gg [0:MAXLINE], err_gb [0:MAXLINE];
    integer err_xr   [0:MAXLINE], err_xg [0:MAXLINE], err_xb [0:MAXLINE];
    integer hot_rmin [0:MAXLINE], hot_rmax [0:MAXLINE], hot_rcnt [0:MAXLINE];
    integer hot_gmin [0:MAXLINE], hot_gmax [0:MAXLINE], hot_gcnt [0:MAXLINE];
    integer hot_bmin [0:MAXLINE], hot_bmax [0:MAXLINE], hot_bcnt [0:MAXLINE];
    integer txt_hits [0:MAXLINE];
    integer c500_r   [0:MAXLINE], c500_g [0:MAXLINE], c500_b [0:MAXLINE];
    integer c800_r   [0:MAXLINE], c800_g [0:MAXLINE], c800_b [0:MAXLINE];

    integer e_r, e_g, e_b;
    integer i, r, l, rn, hl, rl, wid, w0, w1, fail, tb_rows;

    // The pixel this column of this row is expected to carry in, i.e. what the
    // module must hand back if it does not bloom it.
    task exp_pix(input integer kind, input integer col);
        begin
            if (kind == KIND_TEXT && col >= TEXT_LO && col <= TEXT_HI) begin
                e_r = TXT; e_g = TXT; e_b = TXT;
            end else if (kind == KIND_HALO && col == SPRITE_COL) begin
                e_r = PIX; e_g = PIX; e_b = PIX;
            end else if (kind == KIND_RED && col == RED_COL) begin
                e_r = RED_R; e_g = 0; e_b = 0;
            end else begin
                e_r = BGR; e_g = BGG; e_b = BGB;
            end
        end
    endtask

    // The sprite sits at index 5 of every run, so rows within +-2 of it may
    // legitimately be lit by the vertical part of the kernel.
    function integer near_sprite(input integer idx);
        integer k;
        begin
            near_sprite = 0;
            for (k = idx - 2; k <= idx + 2; k = k + 1) begin
                if (k >= 0 && k <= MAXLINE && (in_kind[k] == KIND_HALO || in_kind[k] == KIND_RED))
                    near_sprite = 1;
            end
        end
    endfunction

    function integer row_kind(input integer idx);
        begin
            if (idx == 4)      row_kind = KIND_TEXT;
            else if (idx == 5) row_kind = KIND_HALO;
            else if (idx == 8) row_kind = KIND_RED;
            else               row_kind = KIND_BG;
        end
    endfunction

    // One video row: 56 hsync + 26 back porch + 1366 active + 8 front porch =
    // exactly 1456 clocks, and the next row starts on the very next clock.  The
    // module's line_x counter is referenced to hsync, so a gap here would put it
    // out of phase with the pixel stream.
    task send_row(input integer kind, input integer style, input integer bloom_en);
        integer p;
        begin
            in_line = in_line + 1;
            in_kind [in_line] = kind;
            in_style[in_line] = style;
            in_bloom[in_line] = bloom_en;

            hsync_in = 1;
            vsync_in = ((in_line % ROWS_PER_RUN) == 0) ? 1'b1 : 1'b0;
            repeat (56) @(posedge pixel_clk);
            hsync_in = 0;
            repeat (26) @(posedge pixel_clk);

            for (p = 0; p < 1366; p = p + 1) begin
                de_in = 1;
                if (kind == KIND_TEXT && p >= TEXT_LO && p <= TEXT_HI) begin
                    a_in = 8'd0; r_in = TXT; g_in = TXT; b_in = TXT;
                end else if (kind == KIND_HALO && p == SPRITE_COL) begin
                    a_in = 8'hFF; r_in = PIX; g_in = PIX; b_in = PIX;
                end else if (kind == KIND_RED && p == RED_COL) begin
                    a_in = 8'hFF; r_in = RED_R; g_in = 8'd0; b_in = 8'd0;
                end else begin
                    a_in = 8'd0; r_in = BGR; g_in = BGG; b_in = BGB;
                end
                @(posedge pixel_clk);
            end
            de_in = 0; a_in = 0; r_in = 0; g_in = 0; b_in = 0;
            repeat (8) @(posedge pixel_clk);
        end
    endtask

    // de_out / r_out / g_out / b_out are read here one cycle behind the clock
    // edge, and they update together, so the trio below is self-consistent.
    always @(posedge pixel_clk) begin
        if (de_out) begin
            if (!de_out_d) begin
                cur_line = cur_line + 1;
                out_px   = 0;
            end else begin
                out_px = out_px + 1;
            end

            if (cur_line >= 0 && cur_line <= MAXLINE) begin
                de_cnt[cur_line] = de_cnt[cur_line] + 1;
                exp_pix(in_kind[cur_line], out_px);

                if (r_out > e_r) begin
                    if (out_px < hot_rmin[cur_line]) hot_rmin[cur_line] = out_px;
                    if (out_px > hot_rmax[cur_line]) hot_rmax[cur_line] = out_px;
                    hot_rcnt[cur_line] = hot_rcnt[cur_line] + 1;
                end
                if (g_out > e_g) begin
                    if (out_px < hot_gmin[cur_line]) hot_gmin[cur_line] = out_px;
                    if (out_px > hot_gmax[cur_line]) hot_gmax[cur_line] = out_px;
                    hot_gcnt[cur_line] = hot_gcnt[cur_line] + 1;
                end
                if (b_out > e_b) begin
                    if (out_px < hot_bmin[cur_line]) hot_bmin[cur_line] = out_px;
                    if (out_px > hot_bmax[cur_line]) hot_bmax[cur_line] = out_px;
                    hot_bcnt[cur_line] = hot_bcnt[cur_line] + 1;
                end

                if (out_px == SPRITE_COL) begin
                    c500_r[cur_line] = r_out;
                    c500_g[cur_line] = g_out;
                    c500_b[cur_line] = b_out;
                end
                if (out_px == RED_COL) begin
                    c800_r[cur_line] = r_out;
                    c800_g[cur_line] = g_out;
                    c800_b[cur_line] = b_out;
                end

                if (in_kind[cur_line] == KIND_TEXT && out_px >= TEXT_LO && out_px <= TEXT_HI
                    && r_out == TXT && g_out == TXT && b_out == TXT)
                    txt_hits[cur_line] = txt_hits[cur_line] + 1;

                // A pixel may differ from what came in only if it is inside the
                // sprite's neighbourhood, close to the sprite column, and only
                // ever brighter -- glow adds light, it never takes it away.
                if (r_out != e_r || g_out != e_g || b_out != e_b) begin
                    if (!(in_bloom[cur_line] != 0 && near_sprite(cur_line) != 0 &&
                          ((out_px >= SPRITE_COL - 15 && out_px <= SPRITE_COL + 15) ||
                           (out_px >= RED_COL - 15 && out_px <= RED_COL + 15)) &&
                          r_out >= e_r && g_out >= e_g && b_out >= e_b)) begin
                        if (err_cnt[cur_line] == 0) begin
                            err_col[cur_line] = out_px;
                            err_gr[cur_line]  = r_out; err_gg[cur_line] = g_out; err_gb[cur_line] = b_out;
                            err_xr[cur_line]  = e_r;   err_xg[cur_line] = e_g;   err_xb[cur_line] = e_b;
                        end
                        err_cnt[cur_line] = err_cnt[cur_line] + 1;
                    end
                end
            end
        end
        de_out_d <= de_out;
    end

    initial begin
        for (i = 0; i <= MAXLINE; i = i + 1) begin
            in_kind[i] = KIND_BG; in_style[i] = 0; in_bloom[i] = 1;
            de_cnt[i] = 0; err_cnt[i] = 0; err_col[i] = -1;
            err_gr[i] = 0; err_gg[i] = 0; err_gb[i] = 0;
            err_xr[i] = 0; err_xg[i] = 0; err_xb[i] = 0;
            hot_rmin[i] = 9999; hot_rmax[i] = -1; hot_rcnt[i] = 0;
            hot_gmin[i] = 9999; hot_gmax[i] = -1; hot_gcnt[i] = 0;
            hot_bmin[i] = 9999; hot_bmax[i] = -1; hot_bcnt[i] = 0;
            txt_hits[i] = 0; c500_r[i] = -1; c500_g[i] = -1; c500_b[i] = -1;
            c800_r[i] = -1; c800_g[i] = -1; c800_b[i] = -1;
        end

        pixel_rst_n = 0;
        ctrl = 32'd0;
        repeat (10) @(posedge pixel_clk);
        pixel_rst_n = 1;
        repeat (10) @(posedge pixel_clk);

        // Run 0: style 0 (tight halo), bloom on.
        ctrl = {8'd255, 8'd120, 14'd0, 1'b0, 1'b1};
        for (r = 0; r < ROWS_PER_RUN; r = r + 1) send_row(row_kind(r), 0, 1);

        // Run 1: style 1 (wide halo), bloom on.  The ctrl write lands while
        // background rows are in flight, four rows before the sprite, so the
        // 2-line + 25-clock pipeline has drained before it can matter.
        ctrl = {8'd255, 8'd120, 14'd0, 1'b1, 1'b1};
        for (r = 0; r < ROWS_PER_RUN; r = r + 1) send_row(row_kind(r), 1, 1);

        // Run 2: bloom off -- the module must hand the picture through untouched.
        ctrl = {8'd255, 8'd120, 14'd0, 1'b0, 1'b0};
        for (r = 0; r < ROWS_PER_RUN; r = r + 1) send_row(row_kind(r), 0, 0);

        // Let the last rows fall out of the pipeline.
        for (r = 0; r < 5; r = r + 1) send_row(KIND_BG, 0, 0);
        repeat (64) @(posedge pixel_clk);

        fail = 0;

        // ---- 1. every output row must be a whole active line ----------------
        for (l = 0; l <= MAXLINE; l = l + 1) begin
            if (de_cnt[l] != 0 && de_cnt[l] != 1366) begin
                $display("  row %0d carried %0d active pixels, expected 1366", l, de_cnt[l]);
                fail = fail + 1;
            end
        end

        // ---- 2. text rows: text pixels reproduced, and only on text rows ---
        tb_rows = 0;
        for (l = 0; l <= MAXLINE; l = l + 1) begin
            if (de_cnt[l] != 0) begin
                if (in_kind[l] == KIND_TEXT) begin
                    tb_rows = tb_rows + 1;
                    if (txt_hits[l] != TEXT_PIXELS) begin
                        $display("  text row %0d: %0d of %0d text columns came back as %0d (row/column alignment or text bleeding)",
                                 l, txt_hits[l], TEXT_PIXELS, TXT);
                        fail = fail + 1;
                    end
                end else if (txt_hits[l] != 0) begin
                    $display("  row %0d: %0d text-coloured pixels on a row that carries no text", l, txt_hits[l]);
                    fail = fail + 1;
                end
            end
        end
        if (tb_rows != NRUN) begin
            $display("  %0d text rows found, expected %0d", tb_rows, NRUN);
            fail = fail + 1;
        end

        // ---- 3. pixels that must not have changed ---------------------------
        for (l = 0; l <= MAXLINE; l = l + 1) begin
            if (err_cnt[l] != 0) begin
                $display("  row %0d (%0d px): %0d pixels wrong, first at column %0d got (%0d,%0d,%0d) expected (%0d,%0d,%0d)",
                         l, de_cnt[l], err_cnt[l], err_col[l],
                         err_gr[l], err_gg[l], err_gb[l], err_xr[l], err_xg[l], err_xb[l]);
                fail = fail + 1;
            end
        end

        // ---- 4. halo shape and channel uniformity ---------------------------
        w0 = -1; w1 = -1;
        for (rn = 0; rn < NRUN; rn = rn + 1) begin
            hl = rn * ROWS_PER_RUN + 5;
            if (in_bloom[hl] != 0) begin
                if (hot_rcnt[hl] == 0) begin
                    $display("  run %0d: sprite row %0d lit nothing", rn, hl);
                    fail = fail + 1;
                end else begin
                    if (hot_rmin[hl] != hot_gmin[hl] || hot_rmax[hl] != hot_gmax[hl] || hot_rcnt[hl] != hot_gcnt[hl] ||
                        hot_rmin[hl] != hot_bmin[hl] || hot_rmax[hl] != hot_bmax[hl] || hot_rcnt[hl] != hot_bcnt[hl]) begin
                        $display("  run %0d: lit columns R[%0d..%0d]/%0d G[%0d..%0d]/%0d B[%0d..%0d]/%0d differ -- per-channel radii",
                                 rn, hot_rmin[hl], hot_rmax[hl], hot_rcnt[hl],
                                 hot_gmin[hl], hot_gmax[hl], hot_gcnt[hl],
                                 hot_bmin[hl], hot_bmax[hl], hot_bcnt[hl]);
                        fail = fail + 1;
                    end
                    if (c500_r[hl] != c500_g[hl] || c500_r[hl] != c500_b[hl] || c500_r[hl] < PIX) begin
                        $display("  run %0d: sprite pixel came out (%0d,%0d,%0d); the three channels were fed equal values and must stay equal",
                                 rn, c500_r[hl], c500_g[hl], c500_b[hl]);
                        fail = fail + 1;
                    end
                    wid = hot_rmax[hl] - hot_rmin[hl] + 1;
                    if (rn == 0) w0 = wid;
                    if (rn == 1) w1 = wid;
                    if (rn == 0 && (wid < 5 || wid > 11)) begin
                        $display("  run 0 (tight halo): %0d lit columns, expected 5..11", wid);
                        fail = fail + 1;
                    end
                    if (rn == 1 && (wid < 9 || wid > 20)) begin
                        $display("  run 1 (wide halo): %0d lit columns, expected 9..20", wid);
                        fail = fail + 1;
                    end
                end
            end else begin
                if (hot_rcnt[hl] != 0 || hot_gcnt[hl] != 0 || hot_bcnt[hl] != 0) begin
                    $display("  run %0d: bloom disabled but row %0d still lit %0d columns", rn, hl, hot_rcnt[hl]);
                    fail = fail + 1;
                end
                if (c500_r[hl] != PIX || c500_g[hl] != PIX || c500_b[hl] != PIX) begin
                    $display("  run %0d: bloom disabled, sprite pixel came out (%0d,%0d,%0d), expected (%0d,%0d,%0d) untouched",
                             rn, c500_r[hl], c500_g[hl], c500_b[hl], PIX, PIX, PIX);
                    fail = fail + 1;
                end
            end

            // The pure-red sprite pins each channel to its own light: the
            // green and blue inputs are zero and no other emitter exists, so a
            // non-zero green or blue anywhere on this row means glow crossed
            // channels, and a blue channel fed the red glow shows up here.
            rl = rn * ROWS_PER_RUN + 8;
            if (in_bloom[rl] != 0) begin
                if (hot_rcnt[rl] == 0) begin
                    $display("  run %0d: red sprite row %0d lit nothing", rn, rl);
                    fail = fail + 1;
                end
                if (hot_gcnt[rl] != 0 || hot_bcnt[rl] != 0) begin
                    $display("  run %0d: red sprite row %0d lit %0d green and %0d blue columns -- light went into the wrong channel",
                             rn, rl, hot_gcnt[rl], hot_bcnt[rl]);
                    fail = fail + 1;
                end
                if (c800_r[rl] <= RED_R || c800_g[rl] != 0 || c800_b[rl] != 0) begin
                    $display("  run %0d: red sprite pixel came out (%0d,%0d,%0d), expected red above %0d with green and blue at 0",
                             rn, c800_r[rl], c800_g[rl], c800_b[rl], RED_R);
                    fail = fail + 1;
                end
            end else begin
                if (c800_r[rl] != RED_R || c800_g[rl] != 0 || c800_b[rl] != 0) begin
                    $display("  run %0d: bloom disabled, red sprite pixel came out (%0d,%0d,%0d), expected (%0d,0,0) untouched",
                             rn, c800_r[rl], c800_g[rl], c800_b[rl], RED_R);
                    fail = fail + 1;
                end
            end
        end
        if (w0 >= 0 && w1 >= 0 && w1 <= w0) begin
            $display("  wide halo measured %0d lit columns, tight halo %0d -- style 1 is not the larger kernel", w1, w0);
            fail = fail + 1;
        end

        if (fail == 0) begin
            ok = 1;
            $display("PASS tb_bloom_filter: round halo (tight %0d px, wide %0d px) identical across R/G/B, everything else untouched, bypass clean.", w0, w1);
        end else begin
            ok = 0;
            $display("FAIL tb_bloom_filter: %0d checks failed.", fail);
        end
        $finish(ok ? 0 : 1);
    end

    // Watchdog: the bench sends 41 rows at 1456 clocks, about 0.7 ms.
    initial begin
        #4ms;
        $display("FAIL tb_bloom_filter: watchdog expired, the pipeline never finished a frame");
        $finish(1);
    end

endmodule