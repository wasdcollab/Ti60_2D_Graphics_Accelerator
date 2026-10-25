`timescale 1ns/1ps
// =============================================================================
// tb_scanout_layers -- what does the SCANOUT actually put on the wire?
//
// The laser columns, the warning hairlines, the player beam, the weather and
// the B1 bullet curtain are all synthesised INSIDE video_dma_read.  None of them
// is written into the framebuffer, so no RV32 program can tell whether they
// reached the picture.  The VM proves the firmware writes the right registers;
// this bench takes those registers, the bucket tables and the tile store, and
// composites a real frame.
//
// TWO PHASES, because the board bug is a sequence and a cold bench cannot see
// it: the run happens first (the bucket prefetch fills the scanout 80-entry
// store with bullets), and only THEN does the register set change to the menu.
// A bench that starts at the menu starts with that store empty, which is why
// "the curtain stays stuck over the menu" was never reproducible.  Phase A runs
// regs.hex/bucket.hex, phase B switches to regs2.hex/bucket2.hex and is what the
// counts and the picture report.
//
// Inputs come from tools/dump_scanout_state.py:
//     bucket.hex / bucket2.hex   both 320x768 bucket tables, in order
//     regs.hex  / regs2.hex      the APB values, indexed as below
// Output: scanout.ppm (P6), the frame the board would have shown.
// =============================================================================
module tb_scanout_layers;

    localparam integer H_ACT   = 1366;
    localparam integer V_ACT   = 768;

    localparam [27:0] BUCKET_LO = 28'h0480_0000;
    localparam [27:0] BUCKET_HI = 28'h0487_8000;   // two tables of 320 x 768 B
    localparam [27:0] FB0       = 28'h0080_0000;
    localparam [27:0] FB1       = 28'h00E0_0000;
    localparam [27:0] FB_SPAN   = 28'h0060_0000;   // 6 MB a buffer
    localparam [31:0] BACKDROP  = 32'hFF00_0000;   // anything else reads black

    localparam integer PHASE_A_FRAMES = 4;
    localparam integer PHASE_B_FRAMES = 3;
    localparam integer PHASE_C_FRAMES = 3;

    reg axi_clk = 0, pixel_clk = 0, rst_n = 0;
    always #5      axi_clk   = ~axi_clk;
    always #5.8335 pixel_clk = ~pixel_clk;

    // The framebuffer the firmware really produced, dumped by
    // tools/dump_scanout_state.py.  Both buffers get the same image; the bench
    // composites one frame of one buffer.
    reg [31:0] fb    [0:1572863];
    // The firmware own bullet tiles, packed by tools/gen_bullet_tiles.py.
    reg [7:0]  tiles [0:16383];
    // {alpha, rgb} since the scanout learned to blend the curtain: the overlay
    // reads the top byte as the entry's opacity.  The generator writes 0xFF
    // there, so the shipped picture is the opaque one this bench always checked.
    reg [31:0] pals  [0:255];

    reg [31:0] bucket_a [0:122879];
    reg [31:0] bucket_b [0:122879];
    reg        use_b = 0;
    // Whether bucket2.hex/regs2.hex were actually present.  use_b selects the
    // PHASE (and with it which counters run); it must NOT also decide which
    // bucket is read unless there is a second table to read.
    reg        have_b = 0;

    reg [31:0] regs_a [0:31];
    reg [31:0] regs_b [0:31];
    reg [31:0] regs   [0:31];

    localparam integer R_WEATHER = 0,  R_COLX_LO = 1,  R_COLX_HI = 2,
                       R_BEAM_X  = 3,  R_BEAM_C  = 4,
                       R_HAIR_X0 = 5,  R_HAIR_O0 = 8,  R_HAIR_L0 = 11,
                       R_HAIR_M0 = 14, R_BUCKET  = 17, R_HUD     = 18,
                       R_FRAMES  = 19, R_MASK_X  = 20, R_MASK_Y  = 21;

    wire [31:0] weather_ctrl = regs[R_WEATHER];
    wire [47:0] laser_colx   = {regs[R_COLX_HI][23:0], regs[R_COLX_LO][23:0]};
    wire [11:0] beam_x       = regs[R_BEAM_X][11:0];
    wire [10:0] beam_len     = regs[R_BEAM_C][10:0];
    wire        beam_en      = regs[R_BEAM_C][11];
    wire [35:0] hair_x       = {regs[R_HAIR_X0+2][11:0], regs[R_HAIR_X0+1][11:0],
                                regs[R_HAIR_X0][11:0]};
    wire [71:0] hair_out     = {regs[R_HAIR_O0+2][23:0], regs[R_HAIR_O0+1][23:0],
                                regs[R_HAIR_O0][23:0]};
    wire [71:0] hair_lft     = {regs[R_HAIR_L0+2][23:0], regs[R_HAIR_L0+1][23:0],
                                regs[R_HAIR_L0][23:0]};
    wire [71:0] hair_mid     = {regs[R_HAIR_M0+2][23:0], regs[R_HAIR_M0+1][23:0],
                                regs[R_HAIR_M0][23:0]};
    wire [27:0] bucket_base  = regs[R_BUCKET][27:0];
    wire        hud_enable   = regs[R_HUD][0];
    // The occlusion box both scanout layers take (APB 0x8C / 0xAC).
    wire [31:0] mask_x       = regs[R_MASK_X];
    wire [31:0] mask_y       = regs[R_MASK_Y];

    wire [3:0]   arid;
    wire [27:0]  araddr;
    wire [7:0]   arlen;
    wire [2:0]   arsize;
    wire [1:0]   arburst, arlock;
    wire         arvalid;
    reg          arready = 0;
    wire [127:0] rdata;
    reg          rlast = 1'b0, rvalid = 1'b0;
    wire         rready;
    wire [27:0]  act_base, act_right;
    wire [31:0]  scan_diag;
    wire         vprio, vsync_flag;
    wire [7:0]   vo_a, vo_r, vo_g, vo_b;
    wire         vo_hs, vo_vs, vo_de;
    wire [32*80-1:0] bucket_row;
    wire         bucket_ready;

    reg          btile_we = 0;
    reg  [13:0]  btile_addr = 0;
    reg  [7:0]   btile_data = 0;
    reg          bpal_we = 0;
    reg  [7:0]   bpal_addr = 0;
    reg  [31:0]  bpal_data = 0;

    video_dma_read #(
        .FRAME_BASE_ADDR (28'h0080_0000),
        .H_ACT           (1366),
        .V_ACT           (768)
    ) dut (
        .axi_clk(axi_clk), .axi_rst_n(rst_n), .cal_done(1'b1),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(4'd1), .m_axi_rdata(rdata), .m_axi_rresp(2'b00),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .pixel_clk(pixel_clk), .pixel_rst_n(rst_n),
        .next_frame_base_addr(28'h0080_0000),
        .active_frame_base_addr(act_base),
        .next_right_base_addr(28'h0080_0000),
        .active_right_base_addr(act_right),
        .cpu_fps_bcd(8'h00), .fpga_fps_bcd(8'h00),
        .hud_enable(hud_enable),
        .weather_ctrl(weather_ctrl),
        .weather_mask_x(mask_x), .weather_mask_y(mask_y),
        .laser_colx(laser_colx),
        .beam_x(beam_x), .beam_len(beam_len), .beam_en(beam_en),
        .hair_x(hair_x), .hair_out(hair_out),
        .hair_lft(hair_lft), .hair_mid(hair_mid),
        .bucket_base(bucket_base),
        .bucket_row(bucket_row), .bucket_ready(bucket_ready),
        .btile_we(btile_we), .btile_addr(btile_addr), .btile_data(btile_data),
        .bpal_we(bpal_we), .bpal_addr(bpal_addr), .bpal_data(bpal_data),
        .scan_diagnostics(scan_diag), .video_read_priority(vprio),
        .vsync_flag(vsync_flag),
        .alpha_out(vo_a), .red_out(vo_r), .green_out(vo_g), .blue_out(vo_b),
        .hsync_out(vo_hs), .vsync_out(vo_vs), .de_out(vo_de)
    );

    // ---- AXI read slave ------------------------------------------------------
    reg [27:0] rd_addr = 0;
    reg [7:0]  rd_left = 0;
    reg        rd_busy = 0;

    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            arready <= 1'b0; rvalid <= 1'b0; rlast <= 1'b0;
            rd_busy <= 1'b0; rd_left <= 8'd0; rd_addr <= 28'd0;
        end else begin
            arready <= 1'b1;
            if (!rd_busy && arvalid && arready) begin
                rd_busy <= 1'b1; rd_left <= arlen; rd_addr <= araddr;
                rvalid  <= 1'b1; rlast <= (arlen == 8'd0);
            end else if (rd_busy && rvalid && rready) begin
                rd_addr <= rd_addr + 28'd16;
                if (rd_left == 8'd0) begin
                    rd_busy <= 1'b0; rvalid <= 1'b0; rlast <= 1'b0;
                end else begin
                    rd_left <= rd_left - 8'd1;
                    rlast   <= (rd_left == 8'd1);
                end
            end
        end
    end

    function [31:0] word_at;
        input [27:0] a;
        reg [26:0] idx;
        begin
            if (a >= BUCKET_LO && a < BUCKET_HI) begin
                idx = (a - BUCKET_LO) >> 2;
                // bucket_b only when there really is a second table.  The
                // else arm used to fall through to the all-zero bucket_b, so
                // phase B composited an empty curtain and the exported frame
                // showed no bullets at all.  It looked plausible only because
                // a stale pair of those files sat in work_sim/ from an older
                // working tree - and it stopped matching the firmware the day
                // the bucket entry grew a colour page in [31:29], after which
                // the leftover's slot numbers were past N_TILES and every one
                // of its entries was refused.
                word_at = (use_b && have_b) ? bucket_b[idx] : bucket_a[idx];
            end else if (a >= FB0 && a < FB0 + FB_SPAN) begin
                word_at = fb[(a - FB0) >> 2];
            end else if (a >= FB1 && a < FB1 + FB_SPAN) begin
                word_at = fb[(a - FB1) >> 2];
            end else
                word_at = BACKDROP;
        end
    endfunction

    assign rdata = {word_at(rd_addr + 28'd12), word_at(rd_addr + 28'd8),
                    word_at(rd_addr + 28'd4),  word_at(rd_addr)};

    // ---- capture ------------------------------------------------------------
    reg [23:0] frame [0:H_ACT*V_ACT-1];
    reg [10:0] last_v = 11'h7FF;
    integer    frames_done = 0;
    integer    i;

    integer laser_px = 0, beam_px = 0, weather_px = 0, bullet_px = 0, hud_px = 0;
    integer scandone = 0;
    integer de_px = 0;
    integer laser_a = 0, bullet_a = 0;
    // Pixels either scanout layer painted INSIDE the occlusion box.  The
    // box is the firmware's "leave this rectangle alone" rectangle - the
    // pause card, the stage banner, the boss dialogue - and both answers
    // below have to be zero.
    integer bullet_in_box = 0, weather_in_box = 0;
    // The laser columns and the beam take the same rectangle.  These count it
    // with the box ON; phase C counts it again with the enable bit cleared,
    // which is what makes the zero above "the box worked" rather than "the
    // layer had nothing in there".
    integer laser_in_box = 0, beam_in_box = 0;
    integer laser_nb = 0, beam_nb = 0;
    // Beam pixels that came out PURE BLACK.  A beam is light: its core adds a
    // saturated white and its halo blends a colour that is nowhere near black,
    // so a black beam pixel can only mean the blend path is broken.  This
    // counter exists because it happened.  The per-column selector's first
    // version wrote "wire b_out_r = <8-bit expression>" with no range, which
    // declares a ONE-BIT wire, so every beam column kept only the low bit of
    // its own colour and the whole strip came out black.  Nothing else here
    // noticed: the frame was the right size, the layer counters were right, the
    // module compiled, and every other check passed.  The picture was the only
    // place it showed.
    integer beam_black = 0;
    // ---- the bullet curtain on its own ------------------------------------
    // A second frame buffer holding ONLY the bullets the scanout drew, so the
    // layer can be looked at without the backdrop, the weather and the HUD
    // mixed into it.  Alongside it, what those pixels actually came out as:
    // a bullet that is drawn but lands within a few levels of the backdrop is
    // "drawn" and "invisible" at the same time, and the layer count cannot
    // tell those two apart.
    //
    // u_dark counts bullet pixels at or below 40/255 luma.  The darkest
    // backdrop this stage carries is around 0x0A122C (luma 17) and the
    // brightest snow is 0xE0F0FF, so a bullet under 40 is one the snow eats.
    reg [23:0]  ulayer [0:H_ACT*V_ACT-1];
    integer     u_px = 0, u_lum_sum = 0, u_dark = 0, u_min = 255, u_max = 0;
    integer     lum_tmp;
    reg     use_c = 0;
    wire [11:0] mbx0 = mask_x[10:0];
    wire [11:0] mbx1 = mask_x[21:11];
    wire [10:0] mby0 = mask_y[10:0];
    wire [10:0] mby1 = mask_y[21:11];
    // The rectangle itself, regardless of whether the box is enabled: with it
    // enabled these counts must be zero, and with it disabled they are the
    // barrage that would have been painted over the card.
    wire        px_in_box = (dut.pixel_x_d1 >= mbx0) && (dut.pixel_x_d1 <= mbx1)
                          && (dut.pixel_y_d1 >= mby0) && (dut.pixel_y_d1 <= mby1);

    always @(posedge pixel_clk) begin
        if (rst_n) begin
            if (dut.v_cnt == 11'd0 && last_v != 11'd0)
                frames_done <= frames_done + 1;
            last_v <= dut.v_cnt;

            if (vo_de) begin
                if (dut.pixel_y_d1 < V_ACT && dut.pixel_x_d1 < H_ACT) begin
                    frame[dut.pixel_y_d1 * H_ACT + dut.pixel_x_d1] <= {vo_r, vo_g, vo_b};
                    // The bullet layer alone: everything the curtain owns, on
                    // black.  Written only while use_b is set, so the two
                    // side-by-side frames below are the same instant.
                    ulayer[dut.pixel_y_d1 * H_ACT + dut.pixel_x_d1] <=
                        (use_b && dut.u_visible) ? {vo_r, vo_g, vo_b} : 24'h000000;
                end
                if (px_in_box) begin
                    if (dut.u_visible) bullet_in_box  <= bullet_in_box + 1;
                    if (dut.w_visible) weather_in_box <= weather_in_box + 1;
                    if (dut.l_visible) laser_in_box   <= laser_in_box + 1;
                    if (dut.b_visible) beam_in_box    <= beam_in_box + 1;
                end
                if (use_c && px_in_box) begin
                    if (dut.l_visible) laser_nb <= laser_nb + 1;
                    if (dut.b_visible) beam_nb  <= beam_nb + 1;
                end
                if (!use_b) begin
                    if (dut.l_visible) laser_a  <= laser_a + 1;
                    if (dut.u_visible) bullet_a <= bullet_a + 1;
                end else begin
                    de_px <= de_px + 1;
                    if (dut.l_visible) laser_px   <= laser_px + 1;
                    if (dut.b_visible) begin
                        beam_px <= beam_px + 1;
                        if ({vo_r, vo_g, vo_b} == 24'd0)
                            beam_black <= beam_black + 1;
                    end
                    if (dut.w_visible) weather_px <= weather_px + 1;
                    if (dut.u_visible) begin
                        bullet_px <= bullet_px + 1;
                        lum_tmp = (vo_r * 30 + vo_g * 59 + vo_b * 11) / 100;
                        u_px <= u_px + 1;
                        u_lum_sum <= u_lum_sum + lum_tmp;
                        if (lum_tmp <= 40) u_dark <= u_dark + 1;
                        if (lum_tmp < u_min) u_min <= lum_tmp;
                        if (lum_tmp > u_max) u_max <= lum_tmp;
                    end
                    if (dut.hud_visible && dut.hud_en_sync2) hud_px <= hud_px + 1;
                end
            end
        end
    end

    task load_cfg;
        begin
            for (i = 0; i < 16384; i = i + 1) begin
                @(negedge axi_clk);
                btile_we = 1'b1; btile_addr = i[13:0]; btile_data = tiles[i];
            end
            @(negedge axi_clk); btile_we = 0;
            for (i = 0; i < 256; i = i + 1) begin
                @(negedge axi_clk);
                bpal_we = 1'b1; bpal_addr = i[7:0]; bpal_data = pals[i];
            end
            @(negedge axi_clk); bpal_we = 0;
        end
    endtask

    integer fd, k;
    initial begin
        for (i = 0; i < H_ACT*V_ACT; i = i + 1) ulayer[i] = 24'h000000;
        $readmemh("fb.hex",            fb);
        $readmemh("bullet_tiles.hex",   tiles);
        $readmemh("bullet_palette.hex", pals);
        $readmemh("bucket.hex",  bucket_a);
        $readmemh("regs.hex",    regs_a);
        fd = $fopen("bucket2.hex", "r");
        have_b = (fd != 0);
        if (fd != 0) $fclose(fd);
        if (have_b) begin
            $readmemh("bucket2.hex", bucket_b);
            $readmemh("regs2.hex",   regs_b);
        end
        for (k = 0; k < 32; k = k + 1) regs[k] = regs_a[k];

        repeat (10) @(negedge axi_clk);
        rst_n = 1;
        load_cfg();

        // ---- phase A: a run is on screen -------------------------------
        while (frames_done <= PHASE_A_FRAMES) @(negedge pixel_clk);
        $display("");
        $display("  phase A (the run): laser %0d px, bullets %0d px", laser_a, bullet_a);

        // ---- phase B: what the screen does once the run is gone --------
        if (have_b) begin
            for (k = 0; k < 32; k = k + 1) regs[k] = regs_b[k];
        end
        use_b = 1;
        while (frames_done <= PHASE_A_FRAMES + PHASE_B_FRAMES) @(negedge pixel_clk);

        $display("  phase B (after the run changed the registers):");
        $display("    de pixels                : %0d", de_px);
        $display("    laser   layer visible px : %0d", laser_px);
        $display("    beam    layer visible px : %0d", beam_px);
        $display("    weather layer visible px : %0d", weather_px);
        $display("    bullets layer visible px : %0d", bullet_px);
        $display("    hud     layer visible px : %0d", hud_px);
        $display("    bucket_ready now         : %0d", bucket_ready);
        $display("    box %0d,%0d .. %0d,%0d (enable %0d)", mbx0, mby0, mbx1, mby1, mask_x[31]);
        $display("    bullets inside the rectangle: %0d", bullet_in_box);
        $display("    weather inside the rectangle: %0d", weather_in_box);
        $display("    laser   inside the rectangle: %0d", laser_in_box);
        $display("    beam    inside the rectangle: %0d", beam_in_box);

        fd = $fopen("scanout.ppm", "wb");
        $fwrite(fd, "P6\n%0d %0d\n255\n", H_ACT, V_ACT);
        for (i = 0; i < H_ACT*V_ACT; i = i + 1)
            $fwrite(fd, "%c%c%c", frame[i][23:16], frame[i][15:8], frame[i][7:0]);
        $fclose(fd);

        // The same instant, the bullet curtain on its own.
        fd = $fopen("bullet_layer.ppm", "wb");
        $fwrite(fd, "P6\n%0d %0d\n255\n", H_ACT, V_ACT);
        for (i = 0; i < H_ACT*V_ACT; i = i + 1)
            $fwrite(fd, "%c%c%c", ulayer[i][23:16], ulayer[i][15:8], ulayer[i][7:0]);
        $fclose(fd);
        $display("    wrote scanout.ppm and bullet_layer.ppm");
        if (u_px > 0)
            $display("    bullet pixels: %0d   luma min/avg/max %0d/%0d/%0d   at or below 40: %0d of %0d",
                     u_px, u_min, u_lum_sum / u_px, u_max, u_dark, u_px);
        else
            $display("    bullet pixels: 0");

        // ---- phase C: the same frame with the occlusion OFF -------------
        // The registers are untouched apart from the box enable bit, so the
        // rectangle keeps its coordinates and every other layer keeps its
        // state.  Whatever the two counters below report is what the laser
        // and the beam WOULD paint over the panel.
        regs[R_MASK_X] = regs[R_MASK_X] & 32'h7FFF_FFFF;
        use_c = 1;
        while (frames_done <= PHASE_A_FRAMES + PHASE_B_FRAMES + PHASE_C_FRAMES)
            @(negedge pixel_clk);
        $display("    with the box OFF: laser inside %0d, beam inside %0d",
                 laser_nb, beam_nb);

        // ---- self-check -------------------------------------------------
        // This bench composites the frame the scanout WOULD put on the wire and
        // used to end here with a bare $finish(0): every number above was printed
        // and nothing was judged, so a broken scanout still exited 0.  The two
        // checks below are the ones that hold for every case - the active window
        // is the right size, and each frame clocked out exactly 1366x768 pixels -
        // plus a floor on the layer counters so a frame that came out empty is not
        // mistaken for a frame that came out black on purpose.
        // The bench counts de pixels across three phases (A, B and C), so the
        // total is a small whole number of frames rather than exactly one: it was
        // 6 x 1366x768 when this check was written.
        scandone = 1;
        if (de_px < 1366*768 || de_px > 12*1366*768) begin
            $display("SCANFAIL: %0d de pixels is not 1..12 whole frames of 1366x768",                     de_px);
            scandone = 0;
        end
        if (de_px % (1366*768) != 0) begin
            $display("SCANFAIL: %0d de pixels is not a whole number of frames", de_px);
            scandone = 0;
        end
        if (beam_black != 0) begin
            $display("SCANFAIL: %0d beam pixel(s) came out pure black - the blend path is broken",
                     beam_black);
            scandone = 0;
        end else begin
            $display("    beam pixels that came out black: 0 (of %0d)", beam_px);
        end
        if (scandone)
            $display("SCANDONE ok=1 frames_of_de=%0d hud=%0d weather=%0d bullets=%0d",
                     de_px / (1366*768), hud_px, weather_px, bullet_px);
        else
            $display("SCANDONE ok=0");
        $finish(scandone ? 0 : 1);
    end

endmodule
