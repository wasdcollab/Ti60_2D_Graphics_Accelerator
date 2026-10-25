`timescale 1ns/1ps
// =============================================================================
// tb_write_starvation_chain
// -----------------------------------------------------------------------------
// Board symptom this reproduces (UART 115200 8N1, one line per 32 frames):
//
//   F560 C11327837 j59616 g59093 m59608 b128 s3 h5126 z134152192 n77 r1400
//        d85056 B805306368 T10027312
//
//   B = 0x3000_0000 -> APB 0x120: busy=0, done=0, bit29=1, FAULT=1, drop=0
//   T = 10,027,312  -> APB 0x12C: the job ran 2.5x past its 4,000,000-cycle
//                               watchdog and then took ~6M more to drain
//
// So nothing overflowed: the coprocessor's own drop_count is 0 and the 65535
// the player sees is bucket_build_finish()'s fail-visible marker.  The job was
// wedged on the bus.
//
// The chain has three pieces, all present in the RTL:
//
//  1. bitblt_axi_master.v presents AW as soon as the row address is known
//     (S_IDLE -> S_AW, line ~170) and only then waits in S_W for data_valid
//     from the read pipeline (line ~124).  A BitBlt write burst can therefore
//     be on the bus with its W data still owed behind a read.
//  2. Axi_Mux reserves the W channel for whichever master's AW it granted last
//     (W_Act_Cnl_List comes out of the AW2W info FIFO), and
//     video_write_guard.v admits one write at a time and holds write_pending
//     until that write's B returns (lines 39-51).  One write whose W data is
//     late therefore stops every other master behind it.
//  3. The vendor address arbiter (Axi_Mux_Addr_Ctrl, Sta_Cnl_Switch) restarts
//     its channel scan at channel 0 after every grant, so channel 2 (BitBlt)
//     and channel 3 (bucket coprocessor) are served only by luck.  A CPU that
//     asks continuously - channel 1 - takes every grant.
//
// Starve the BitBlt read and the write path stops dead: the coprocessor can
// never drain its table writes, its watchdog fires, and DROP shows 65535.
//
// The test drives S0 (scanout reads), S1 (a CPU that never stops asking),
// S2 (a BitBlt-style master: AW early, W only after its own read returns) and
// S3 (a coprocessor-style write waiting for B).  PASS requires S3's write to
// complete within WBUDGET; the released vendor arbiter needs millions.
// =============================================================================
module tb_write_starvation_chain;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    localparam integer WBUDGET = 200000;   // S3 write must finish in 2 ms

    integer tick = 0;
    always @(posedge clk) tick <= tick + 1;

    // Scanout: refill requests in bursts, and it is the hard-priority channel.
    reg [9:0] video_phase = 0;
    always @(posedge clk) video_phase <= video_phase + 10'd1;
    wire video_req = (video_phase < 10'd384);      // 75% of the time
    wire video_prio = (video_phase >= 10'd384);    // the guard's gate

    // ---------------- mux master side (towards the DDR model) ----------------
    wire [3:0]  m_awid;
    wire [31:0] m_awaddr;
    wire [7:0]  m_awlen;
    wire [2:0]  m_awsize;
    wire [1:0]  m_awburst, m_awlock;
    wire        m_awvalid, m_awready;
    wire [3:0]  m_wid;
    wire [127:0] m_wdata;
    wire [15:0] m_wstrb;
    wire        m_wlast, m_wvalid, m_wready;
    wire [3:0]  m_bid;
    wire        m_bvalid, m_bready;
    wire [3:0]  m_arid;
    wire [31:0] m_araddr;
    wire [7:0]  m_arlen;
    wire [2:0]  m_arsize;
    wire [1:0]  m_arburst, m_arlock;
    wire        m_arvalid, m_arready;
    wire [3:0]  m_rid;
    wire [127:0] m_rdata;
    wire        m_rlast, m_rvalid, m_rready;
    wire [1:0]  m_rresp;

    // The guard sits between the mux and the DDR controller, exactly as in
    // rtl/ti60_top.v:176.
    wire g_awvalid, g_awready, g_wvalid, g_wready;
    video_write_guard guard (
        .clk(clk), .rst_n(rst_n), .video_priority(video_prio),
        .s_awvalid(m_awvalid), .s_awready(m_awready),
        .m_awvalid(g_awvalid), .m_awready(g_awready),
        .s_wvalid(m_wvalid), .s_wready(m_wready),
        .m_wvalid(g_wvalid), .m_wready(g_wready),
        .bvalid(m_bvalid), .bready(m_bready));

    // ---------------- S0: scanout read --------------------------------------
    reg  s0_arvalid = 0;
    wire s0_arready;
    wire s0_rready = 1'b1;
    always @(posedge clk) begin
        if (!rst_n) s0_arvalid <= 0;
        else if (s0_arvalid && s0_arready) s0_arvalid <= 0;
        else if (video_req) s0_arvalid <= 1'b1;
    end

    // ---------------- S1: CPU read master that never stops asking ------------
    // A dcache miss on every bullet access: ARVALID stays asserted for the
    // whole run, which is what makes the vendor scan start at channel 0 and
    // stop there every time.
    wire s1_arvalid = 1'b1;
    wire s1_arready;
    wire s1_rready  = 1'b1;

    // ---------------- S2: BitBlt-style write master -------------------------
    // One iteration per drawn row: AW goes out as soon as the row address is
    // known, the read burst is requested for that row, and W is only presented
    // once the read data has come back - bitblt_axi_master.v's S_AW -> S_W
    // order.  BBR0WS rows keep this channel asking for the whole run, which is
    // what a stage full of sprites and attack effects does to the real engine.
    localparam integer BBROWS = 64;
    reg [2:0] bb_state = 0;
    reg       bb_arvalid = 0, bb_wvalid = 0, bb_awvalid = 0;
    reg       bb_data = 0;
    reg [7:0] bb_row = 0;
    wire      bb_arready, bb_awready, bb_wready;
    wire      bb_rready = 1'b1;
    wire      s2_rvalid;
    integer   bb_ar_grants = 0, bb_w_sent = 0, bb_aw_sent = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            bb_state <= 0; bb_arvalid <= 0; bb_awvalid <= 0; bb_wvalid <= 0;
            bb_data <= 0; bb_row <= 0;
        end else begin
            case (bb_state)
                0: if (bb_row < BBROWS) begin
                       bb_state   <= 1;
                       bb_arvalid <= 1'b1;
                       bb_awvalid <= 1'b1;   // address out first: the defect
                   end
                1: if (bb_arvalid && bb_arready) begin
                       bb_ar_grants <= bb_ar_grants + 1;
                       bb_arvalid   <= 1'b0;
                       bb_state     <= 2;
                   end
                2: if (bb_data) begin
                       bb_data   <= 1'b0;
                       bb_wvalid <= 1'b1;    // read data has arrived
                       bb_state  <= 3;
                   end
                3: if (bb_wvalid && bb_wready) begin
                       bb_wvalid <= 1'b0;
                       bb_w_sent <= bb_w_sent + 1;
                       bb_row    <= bb_row + 8'd1;
                       bb_state  <= 0;
                   end
            endcase
            if (bb_awvalid && bb_awready) begin
                bb_awvalid <= 1'b0;
                bb_aw_sent <= bb_aw_sent + 1;
            end
        end
    end

    // ---------------- S3: bucket-coprocessor-style write --------------------
    // One 128-bit table write, then it must see B before it can finish.
    reg       bc_awvalid = 0, bc_wvalid = 0;
    wire      bc_awready, bc_wready, bc_bvalid;
    // A stage's worth of table writes: one outstanding at a time, exactly the
    // credit the coprocessor uses (write_free requires !AW && !W && pend<8,
    // and the guard admits one write at a time anyway).
    localparam integer BCWRITES = 256;
    integer   bc_started = -1, bc_done_at = -1, bc_sent = 0;
    reg       bc_inflight = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            bc_awvalid <= 0; bc_wvalid <= 0; bc_started <= -1;
            bc_inflight <= 0; bc_sent <= 0;
        end else begin
            if (bc_started < 0) bc_started <= tick;
            if (bc_bvalid) begin
                bc_inflight <= 1'b0;
                bc_sent     <= bc_sent + 1;
                if (bc_sent + 1 == BCWRITES && bc_done_at < 0) bc_done_at <= tick;
            end
            if (!bc_inflight && bc_sent < BCWRITES && bc_started >= 0 && bc_started + 4 <= tick) begin
                bc_awvalid  <= 1'b1;
                bc_wvalid   <= 1'b1;
                bc_inflight <= 1'b1;
            end
            if (bc_awvalid && bc_awready) bc_awvalid <= 0;
            if (bc_wvalid && bc_wready)   bc_wvalid  <= 0;
        end
    end

    Axi_Mux #(.SLAVE_ID_WIDTH(4), .AXI_DATA_WIDTH(128), .ID_MODE_SEL("Normal")) mux (
        .Sys_Clk(clk), .Sys_Rst_N(rst_n),
        .O_M_AW_ID(m_awid), .O_M_AW_ADDR(m_awaddr), .O_M_AW_LEN(m_awlen),
        .O_M_AW_SIZE(m_awsize), .O_M_AW_BURST(m_awburst), .O_M_AW_LOCK(m_awlock),
        .O_M_AW_VALID(m_awvalid), .I_M_AW_READY(m_awready),
        .O_M_W_ID(m_wid), .O_M_W_DATA(m_wdata), .O_M_W_LAST(m_wlast),
        .O_M_W_STRB(m_wstrb), .O_M_W_VALID(m_wvalid), .I_M_W_READY(m_wready),
        .I_M_B_ID(m_bid), .I_M_B_VALID(m_bvalid), .O_M_B_READY(m_bready),
        .O_M_AR_ID(m_arid), .O_M_AR_ADDR(m_araddr), .O_M_AR_LEN(m_arlen),
        .O_M_AR_SIZE(m_arsize), .O_M_AR_BURST(m_arburst), .O_M_AR_LOCK(m_arlock),
        .O_M_AR_VALID(m_arvalid), .I_M_AR_READY(m_arready),
        .I_M_R_ID(m_rid), .I_M_R_DATA(m_rdata), .I_M_R_LAST(m_rlast),
        .I_M_R_RESP(m_rresp), .I_M_R_VALID(m_rvalid), .O_M_R_READY(m_rready),

        // S0: scanout (hard priority)
        .I_S0_AW_ID(4'd0), .I_S0_AW_ADDR(32'd0), .I_S0_AW_LEN(8'd0),
        .I_S0_AW_SIZE(3'd0), .I_S0_AW_BURST(2'd0), .I_S0_AW_LOCK(2'd0),
        .I_S0_AW_VALID(1'b0), .O_S0_AW_READY(),
        .I_S0_W_ID(4'd0), .I_S0_W_DATA(128'd0), .I_S0_W_LAST(1'b0),
        .I_S0_W_STRB(16'd0), .I_S0_W_VALID(1'b0), .O_S0_W_READY(),
        .O_S0_B_ID(), .O_S0_B_VALID(), .I_S0_B_READY(1'b0),
        .I_S0_AR_ID(4'd0), .I_S0_AR_ADDR(32'h0100_0000), .I_S0_AR_LEN(8'd15),
        .I_S0_AR_SIZE(3'd4), .I_S0_AR_BURST(2'd1), .I_S0_AR_LOCK(2'd0),
        .I_S0_AR_VALID(s0_arvalid), .O_S0_AR_READY(s0_arready),
        .O_S0_R_ID(), .O_S0_R_DATA(), .O_S0_R_LAST(), .O_S0_R_RESP(),
        .O_S0_R_VALID(), .I_S0_R_READY(s0_rready),

        // S1: the CPU
        .I_S1_AW_ID(4'd1), .I_S1_AW_ADDR(32'd0), .I_S1_AW_LEN(8'd0),
        .I_S1_AW_SIZE(3'd0), .I_S1_AW_BURST(2'd0), .I_S1_AW_LOCK(2'd0),
        .I_S1_AW_VALID(1'b0), .O_S1_AW_READY(),
        .I_S1_W_ID(4'd1), .I_S1_W_DATA(128'd0), .I_S1_W_LAST(1'b0),
        .I_S1_W_STRB(16'd0), .I_S1_W_VALID(1'b0), .O_S1_W_READY(),
        .O_S1_B_ID(), .O_S1_B_VALID(), .I_S1_B_READY(1'b0),
        .I_S1_AR_ID(4'd1), .I_S1_AR_ADDR(32'h0167_5400), .I_S1_AR_LEN(8'd15),
        .I_S1_AR_SIZE(3'd4), .I_S1_AR_BURST(2'd1), .I_S1_AR_LOCK(2'd0),
        .I_S1_AR_VALID(s1_arvalid), .O_S1_AR_READY(s1_arready),
        .O_S1_R_ID(), .O_S1_R_DATA(), .O_S1_R_LAST(), .O_S1_R_RESP(),
        .O_S1_R_VALID(), .I_S1_R_READY(s1_rready),

        // S2: BitBlt
        .I_S2_AW_ID(4'd2), .I_S2_AW_ADDR(32'h0080_0000), .I_S2_AW_LEN(8'd0),
        .I_S2_AW_SIZE(3'd4), .I_S2_AW_BURST(2'd1), .I_S2_AW_LOCK(2'd0),
        .I_S2_AW_VALID(bb_awvalid), .O_S2_AW_READY(bb_awready),
        .I_S2_W_ID(4'd2), .I_S2_W_DATA(128'h2222), .I_S2_W_LAST(1'b1),
        .I_S2_W_STRB(16'hFFFF), .I_S2_W_VALID(bb_wvalid), .O_S2_W_READY(bb_wready),
        .O_S2_B_ID(), .O_S2_B_VALID(), .I_S2_B_READY(1'b1),
        .I_S2_AR_ID(4'd2), .I_S2_AR_ADDR(32'h0080_4000), .I_S2_AR_LEN(8'd15),
        .I_S2_AR_SIZE(3'd4), .I_S2_AR_BURST(2'd1), .I_S2_AR_LOCK(2'd0),
        .I_S2_AR_VALID(bb_arvalid), .O_S2_AR_READY(bb_arready),
        .O_S2_R_ID(), .O_S2_R_DATA(), .O_S2_R_LAST(), .O_S2_R_RESP(),
        .O_S2_R_VALID(s2_rvalid), .I_S2_R_READY(bb_rready),

        // S3: bucket coprocessor table write
        .I_S3_AW_ID(4'd3), .I_S3_AW_ADDR(32'h0480_0000), .I_S3_AW_LEN(8'd0),
        .I_S3_AW_SIZE(3'd4), .I_S3_AW_BURST(2'd1), .I_S3_AW_LOCK(2'd0),
        .I_S3_AW_VALID(bc_awvalid), .O_S3_AW_READY(bc_awready),
        .I_S3_W_ID(4'd3), .I_S3_W_DATA(128'h3333), .I_S3_W_LAST(1'b1),
        .I_S3_W_STRB(16'hFFFF), .I_S3_W_VALID(bc_wvalid), .O_S3_W_READY(bc_wready),
        .O_S3_B_ID(), .O_S3_B_VALID(bc_bvalid), .I_S3_B_READY(1'b1),
        .I_S3_AR_ID(4'd3), .I_S3_AR_ADDR(32'h0000_0000), .I_S3_AR_LEN(8'd0),
        .I_S3_AR_SIZE(3'd4), .I_S3_AR_BURST(2'd1), .I_S3_AR_LOCK(2'd0),
        .I_S3_AR_VALID(1'b0), .O_S3_AR_READY(),
        .O_S3_R_ID(), .O_S3_R_DATA(), .O_S3_R_LAST(), .O_S3_R_RESP(),
        .O_S3_R_VALID(), .I_S3_R_READY(1'b1),

        .Cfg_Arb_Type(1'b1), .Cfg_Cnl_Mask(4'b1111),
        .O_AW_Cnl_Num(), .O_W_Cnl_Num(), .O_B_Cnl_Num(),
        .O_AR_Cnl_Num(), .O_R_Cnl_Num());

    // ---------------- DDR model ---------------------------------------------
    // One read burst at a time; writes are paired AW/W in arrival order and
    // answered with a B a few cycles after the data is in.
    reg [127:0] rd_mem [0:4095];
    reg  r_valid = 0;
    reg [7:0]  r_left = 0;
    reg [31:0] r_addr = 0;
    reg [127:0] r_data = 0;
    reg  r_last = 0;
    integer r_gap = 0;
    assign m_rdata  = r_data;
    assign m_rvalid = r_valid;
    assign m_rlast  = r_last;
    assign m_rresp  = 2'd0;
    assign m_rid    = 4'd0;
    assign m_arready = !r_valid && (r_left == 0) && (r_gap == 0);

    integer awq [0:15];
    integer aw_head = 0, aw_tail = 0;
    integer w_count = 0;
    reg  b_valid = 0;
    integer b_delay = 0;
    assign m_bvalid = b_valid;
    assign m_bid    = 4'd0;
    assign g_awready = (aw_tail - aw_head) < 15;
    assign g_wready  = 1'b1;

    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1) rd_mem[i] = 128'h0;
        for (i = 0; i < 16; i = i + 1) awq[i] = 0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            r_valid <= 0; r_left <= 0; r_gap <= 0; b_valid <= 0;
            aw_head <= 0; aw_tail <= 0; w_count <= 0; b_delay <= 0;
        end else begin
            // reads
            if (m_arvalid && m_arready) begin
                r_addr <= m_araddr;
                r_left <= m_arlen + 8'd1;
                r_gap  <= 3;
            end else if (r_gap > 0) r_gap <= r_gap - 1;
            else if (!r_valid && r_left > 0) begin
                r_data  <= rd_mem[(r_addr >> 4) & 4095];
                r_addr  <= r_addr + 16;
                r_valid <= 1;
                r_left  <= r_left - 8'd1;
                r_last  <= (r_left == 1);
            end
            if (r_valid && (m_rready === 1'b1)) begin
                r_valid <= 0;
                r_gap   <= 2;
            end
            // writes
            if (g_awvalid && g_awready) begin
                awq[aw_tail % 16] = m_awaddr;
                aw_tail = aw_tail + 1;
            end
            if (g_wvalid && g_wready) w_count = w_count + 1;
            if (w_count > 0 && (aw_tail - aw_head) > 0) begin
                w_count = w_count - 1;
                aw_head = aw_head + 1;
                if (b_delay == 0) b_delay <= 6;
            end
            if (b_delay > 0) begin
                b_delay <= b_delay - 1;
                if (b_delay == 1) b_valid <= 1;
            end
            if (b_valid && m_bready) b_valid <= 0;
        end
    end

    // The mux master W/LEN checks are not the point of this test; make sure the
    // model is not silently fed a burst it cannot pair.
    always @(posedge clk) begin
        // S2's read is what has to come back before its W may be presented.
        if (bb_state == 2 && s2_rvalid) begin
            bb_data <= 1'b1;
        end
    end

    // ---------------- run ---------------------------------------------------
    integer cycles_to_done;
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        wait (bc_done_at >= 0 || tick > 4000000);
        cycles_to_done = (bc_done_at >= 0) ? (bc_done_at - bc_started) : -1;
        if (bc_done_at < 0) begin
            $display("FAIL bucket write stream stuck: %0d of %0d writes completed in %0d cycles",
                     bc_sent, BCWRITES, tick);
            $display("     bitblt: AW accepted=%0d, read grants=%0d, W sent=%0d",
                     bb_aw_sent, bb_ar_grants, bb_w_sent);
            $fatal(1, "write path wedged behind a starved BitBlt read");
        end
        if (cycles_to_done > WBUDGET) begin
            $display("FAIL %0d bucket writes took %0d cycles (budget %0d)",
                     BCWRITES, cycles_to_done, WBUDGET);
            $display("     bitblt: AW accepted=%0d, read grants=%0d, W sent=%0d",
                     bb_aw_sent, bb_ar_grants, bb_w_sent);
            $fatal(1, "write path blocked behind a starved BitBlt read");
        end
        $display("PASS %0d bucket writes completed in %0d cycles; bitblt read grants=%0d, W sent=%0d",
                 BCWRITES, cycles_to_done, bb_ar_grants, bb_w_sent);
        $finish;
    end

endmodule
