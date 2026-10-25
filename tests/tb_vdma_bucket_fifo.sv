`timescale 1ns/1ps
// =============================================================================
// tb_vdma_bucket_fifo -- do the B1 bucket bursts leak into the PIXEL fifo?
//
// video_dma_read drives one AXI read master from two very different streams:
//
//   * the scanline's pixel bursts, which end in the sync FIFO (u_fifo) that the
//     pixel gearbox pops exactly WORDS_PER_ROW = 342 times per line, and
//   * the B1 bullet-bucket bursts, which end in their own 80-entry store
//     (u_bucket) and are read from there by video_bullet_overlay.
//
// Those two destinations are what makes the sharing safe, and only if the
// bucket beats reach u_bucket and NOTHING ELSE.  The pixel FIFO's write enable
// is `state == S_R && rvalid && rready`; the bucket transaction runs through the
// same S_R states, so unless it is excluded there, its 20 beats (16 + 4) are
// pushed into the pixel FIFO as well.
//
// The scan line pops a fixed 342 words and the row reads deliver 342, so any
// word that arrives on top of that is a word the gearbox did not ask for: it
// stays in the FIFO and shifts every later pixel of the frame sideways by 4
// pixels.  Read/consume stops being equal, the FIFO fills, and the picture
// slides - which is what "the image is skewed / the picture is smeared" looks
// like on the board.
//
// This bench counts beats written into the pixel FIFO while a bucket
// transaction owns the master.  Zero is the only correct answer.
//
//   PASS  leaked == 0
//   FAIL  leaked > 0, and the count is printed per frame
// =============================================================================
module tb_vdma_bucket_fifo;

    reg axi_clk = 0, pixel_clk = 0;
    reg rst_n = 0;
    always #5      axi_clk   = ~axi_clk;      // 100 MHz
    always #5.8335 pixel_clk = ~pixel_clk;    // 85.71 MHz

    // ---- DUT ---------------------------------------------------------------
    wire [3:0]  arid;
    wire [27:0] araddr;
    wire [7:0]  arlen;
    wire [2:0]  arsize;
    wire [1:0]  arburst, arlock;
    wire        arvalid;
    reg         arready = 0;

    wire [127:0] rdata;
    reg          rlast  = 1'b0;
    reg          rvalid = 1'b0;
    wire         rready;

    wire [27:0] act_base, act_right;
    wire [31:0] scan_diag;
    wire        vprio, vsync_flag;
    wire [7:0]  vo_a, vo_r, vo_g, vo_b;
    wire        vo_hs, vo_vs, vo_de;
    wire [32*80-1:0] bucket_row;
    wire        bucket_ready;

    // Non-zero base so the bucket prefetch is enabled at all.
    localparam [27:0] BUCKET_BASE = 28'h0480_0000;

    video_dma_read dut (
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
        .hud_enable(1'b0),
        .weather_ctrl(32'h0004_0000),
        .weather_mask_x(32'd0), .weather_mask_y(32'd0),
        .laser_colx({12'd1059, 12'd808, 12'd557, 12'd306}),
        .beam_x(12'd0), .beam_len(12'd0), .beam_en(1'b0),
        .hair_x(36'd0), .hair_out(72'd0), .hair_lft(72'd0), .hair_mid(72'd0),

        .bucket_base(BUCKET_BASE),
        .bucket_row(bucket_row), .bucket_ready(bucket_ready),
        .btile_we(1'b0), .btile_addr(14'd0), .btile_data(8'd0),
        .bpal_we(1'b0), .bpal_addr(8'd0), .bpal_data(24'd0),

        .scan_diagnostics(scan_diag), .video_read_priority(vprio),
        .vsync_flag(vsync_flag),
        .alpha_out(vo_a), .red_out(vo_r), .green_out(vo_g), .blue_out(vo_b),
        .hsync_out(vo_hs), .vsync_out(vo_vs), .de_out(vo_de)
    );

    // ---- AXI read slave: accepts immediately, streams the beats back --------
    reg [7:0] rd_left = 8'd0;
    reg       rd_busy = 0;

    always @(posedge axi_clk or negedge rst_n) begin
        if (!rst_n) begin
            arready <= 1'b0;
            rvalid  <= 1'b0;
            rlast   <= 1'b0;
            rd_busy <= 1'b0;
            rd_left <= 8'd0;
        end else begin
            arready <= 1'b1;
            if (!rd_busy && arvalid && arready) begin
                rd_busy <= 1'b1;
                rd_left <= arlen;
                rvalid  <= 1'b1;
                rlast   <= (arlen == 8'd0);
            end else if (rd_busy && rvalid && rready) begin
                if (rd_left == 8'd0) begin
                    rd_busy <= 1'b0;
                    rvalid  <= 1'b0;
                    rlast   <= 1'b0;
                end else begin
                    rd_left <= rd_left - 8'd1;
                    rlast   <= (rd_left == 8'd1);
                end
            end
        end
    end

    assign rdata = {4{32'h11223344}};

    // ---- the measurement ---------------------------------------------------
    integer leaked      = 0;   // beats into the pixel FIFO during a bucket burst
    integer pixel_beats = 0;   // beats into the pixel FIFO otherwise
    integer bucket_beats = 0;  // beats the bucket store took
    integer bad_addr    = 0;   // pixel bursts that did NOT address the framebuffer
    integer laser_px    = 0;   // output pixels the laser columns lit
    integer pixel_bursts = 0;

    localparam [27:0] FB_LO = 28'h0080_0000;
    localparam [27:0] FB_HI = 28'h00E0_0000;

    always @(posedge axi_clk) begin
        if (rst_n) begin
            if (dut.fifo_winc && dut.bk_act) leaked <= leaked + 1;
            else if (dut.fifo_winc)          pixel_beats <= pixel_beats + 1;
            if (dut.bk_wr)                   bucket_beats <= bucket_beats + 1;

            // The laser is the scanout's own layer: alpha 0xFF at the columns, the
            // framebuffer's own alpha (0x11 here) everywhere else.
            if (vo_de && vo_a == 8'hFF)      laser_px <= laser_px + 1;

            // A pixel burst is one the bucket does not own.  Its address has to
            // be inside the framebuffer it is scanning; anything else means the
            // address register still held the bucket's last request.
            if (arvalid && arready && !dut.bk_act) begin
                pixel_bursts <= pixel_bursts + 1;
                if (araddr < FB_LO || araddr >= FB_HI) begin
                    bad_addr <= bad_addr + 1;
                    if (bad_addr < 4)
                        $display("  !! pixel burst to %0h (outside the framebuffer) at t=%0t",
                                 araddr, $time);
                end
            end
        end
    end

    // One full frame is 782 lines; run two so the first (discarded) is behind us.
    localparam integer FRAME_PIXELS = 782 * 1366;
    integer frames = 0;
    integer last_v = -1;

    always @(posedge pixel_clk) begin
        if (rst_n && dut.v_cnt == 0 && last_v != 0) begin
            frames <= frames + 1;
            $display("  frame %0d: leaked=%0d pixel=%0d bucket=%0d",
                     frames, leaked, pixel_beats, bucket_beats);
        end
        last_v <= dut.v_cnt;
    end

    initial begin
        repeat (10) @(negedge axi_clk);
        rst_n = 1;
        // Two full frames plus a little.
        repeat (3 * 782 * 1456) @(negedge pixel_clk);

        $display("");
        $display("  ============================================================");
        $display("  beats into the PIXEL fifo while a bucket burst owned the master : %0d", leaked);
        $display("  beats into the PIXEL fifo from the pixel bursts               : %0d", pixel_beats);
        $display("  beats the bucket store took                                   : %0d", bucket_beats);
        $display("  pixel bursts issued                                           : %0d", pixel_bursts);
        $display("  of those, addressed OUTSIDE the framebuffer                   : %0d", bad_addr);
        $display("  output pixels lit by the laser columns                        : %0d", laser_px);
        $display("  ============================================================");
        if (leaked != 0) begin
            $display("FAIL vdma bucket beats leak into the pixel FIFO: %0d words", leaked);
            $display("     every leaked word pushes the rest of the frame 4 px sideways");
        end
        if (bad_addr != 0) begin
            $display("FAIL %0d pixel bursts read the wrong address (bucket's request left behind)",
                     bad_addr);
        end
        // 4 columns x 16 px x 768 lines x 3 frames is 147,456; the first frame
        // is partly blanked, so anything in the tens of thousands is healthy.
        if (laser_px < 100000) begin
            $display("FAIL the laser columns never lit the output (%0d pixels)", laser_px);
            $finish(1);
        end
        if (leaked != 0 || bad_addr != 0) $finish(1);
        $display("PASS vdma bucket prefetch stays out of the pixel FIFO,");
        $display("     every pixel burst addresses the framebuffer,");
        $display("     and the laser columns reach the output");
        $finish(0);
    end

endmodule