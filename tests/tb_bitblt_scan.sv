`timescale 1ns/1ps
// tb_bitblt_scan.sv -- hunt for a command that STALLS the engine.
// Board evidence: a frame took 51.3M cycles (37.8x) with a NORMAL workload
// (commands +4%, rows +6%) while the engine wait U blew up 1761x.
// So: walk the commands the firmware actually issues (plus the corners) and
// watchdog every one.  A stall dumps op/w/h/strides/offsets + live probe.
module tb_bitblt_scan;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg  [15:0] pa = 0;
    reg         ps = 0, pe = 0, pw = 0;
    reg  [31:0] pd = 0;
    wire [31:0] pr;
    wire        pre, per;
    wire [3:0]  arid, awid, wid, bid;
    wire [27:0] araddr, awaddr;
    wire [7:0]  arlen, awlen;
    wire [2:0]  arsize, awsize;
    wire [1:0]  arburst, arlock, awburst, awlock;
    wire        arvalid, arready;
    wire [127:0] rdata;
    wire [1:0]  rresp = 2'b00;
    wire        rlast, rvalid, rready;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    wire        wlast, wvalid, wready;
    wire        awvalid, awready;
    wire        bvalid, bready;
    wire [27:0] next_base, right_next_base;
    wire [7:0]  cpu_fps, fpga_fps;
    wire [6:0]  i2c_addr;
    wire        hud_dis;
`ifdef BITBLT_SCAN_MB
    localparam integer MAXB = `BITBLT_SCAN_MB;
`else
    localparam integer MAXB = 64;
`endif
    localparam [3:0] RID = 4'd2;
    localparam [27:0] SRC_BASE = 28'h0160_0000;
    localparam [27:0] DST_BASE = 28'h0080_0000;

    bitblt_top #(
        .MAX_BURST_BEATS (MAXB), .READ_FIFO_DEPTH (448), .READ_FIFO_AW (9),
        .DST_FIFO_DEPTH (448), .DST_FIFO_AW (9)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .apb_paddr(pa), .apb_psel(ps), .apb_penable(pe), .apb_pwrite(pw),
        .apb_pwdata(pd), .apb_prdata(pr), .apb_pready(pre), .apb_pslverr(per),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(RID), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wid(wid), .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .vdma_next_base(next_base), .vdma_active_base(28'h0100_0000),
        .vdma_right_next_base(right_next_base),
        .vdma_right_active_base(28'h0100_0000),
        .cpu_fps_bcd(cpu_fps), .fpga_fps_bcd(fpga_fps),
        .scan_diagnostics(32'd0), .vsync_flag(1'b0),
        .gamepad_joy_x(8'd128), .gamepad_joy_y(8'd128), .gamepad_buttons(5'd0),
        .gamepad_online(1'b0), .key_sw0_level(1'b0), .key_sw2_level(1'b0),
        .key_sw0_pulse(1'b0), .key_sw2_pulse(1'b0),
        .i2c_slave_addr(i2c_addr), .force_hud_disable(hud_dis),
        .weather_ctrl(), .color_matrix_ctrl(), .bloom_ctrl()
    );

    integer LAT = 60;
    localparam integer RDQ = 4;
    reg arready_r = 0, awready_r = 0, wready_r = 0, rvalid_r = 0, bvalid_r = 0;
    reg [127:0] rdata_r = 0;
    reg [8:0]  rd_left = 0;
    reg [27:0] rd_cur = 0;
    reg        rd_streaming = 0;
    reg [27:0] rq_addr [0:RDQ-1];
    reg [8:0]  rq_left [0:RDQ-1];
    integer    rq_wait [0:RDQ-1];
    integer    rq_head = 0, rq_tail = 0, rq_cnt = 0;
    integer    ii, b_delay = 0;
    reg        wr_active = 0;
    integer    n_rd = 0, n_wr = 0, n_ar = 0, n_aw = 0;
    longint    cyc = 0;

    assign arready = arready_r;
    assign awready = awready_r;
    assign wready  = wready_r;
    assign bvalid  = bvalid_r;
    assign rvalid  = rvalid_r;
    assign rlast   = rvalid_r && (rd_left == 9'd1);
    assign rdata   = rdata_r;
    wire ar_hs = arvalid && arready;
    wire w_hs  = wvalid && wready;
    wire aw_hs = awvalid && awready;

    always @(negedge clk) arready_r <= (rq_cnt < RDQ);

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (rst_n) begin
            if (ar_hs) begin
                n_ar = n_ar + 1;
                rq_addr[rq_tail] = araddr;
                rq_left[rq_tail] = {1'b0, arlen} + 9'd1;
                rq_wait[rq_tail] = LAT;
                rq_tail = (rq_tail + 1) % RDQ;
                rq_cnt  = rq_cnt + 1;
            end
            for (ii = 0; ii < RDQ; ii = ii + 1)
                if ((ii < rq_cnt) && (rq_wait[(rq_head + ii) % RDQ] > 0))
                    rq_wait[(rq_head + ii) % RDQ] = rq_wait[(rq_head + ii) % RDQ] - 1;
            if ((rq_cnt > 0) && !rd_streaming && (rq_wait[rq_head] == 0)) begin
                rd_streaming = 1'b1;
                rd_cur  = rq_addr[rq_head];
                rd_left = rq_left[rq_head];
            end
            if (rd_streaming && !rvalid_r) begin
                rvalid_r <= 1'b1;
                rdata_r  <= {96'h0, rd_cur[27:0]};
                rd_cur   <= rd_cur + 28'd16;
            end
            if (rvalid_r && rready) begin
                n_rd = n_rd + 1;
                rvalid_r <= 1'b0;
                rd_left  = rd_left - 9'd1;
                if (rd_left == 9'd0) begin
                    rd_streaming = 1'b0;
                    rq_head = (rq_head + 1) % RDQ;
                    rq_cnt  = rq_cnt - 1;
                end
            end
            awready_r <= (bvalid_r === 1'b0) && (b_delay == 0);
            wready_r  <= wr_active;
            if (aw_hs) begin
                n_aw = n_aw + 1;
                wr_active <= 1'b1;
            end
            if (w_hs) begin
                n_wr = n_wr + 1;
                if (wlast) begin
                    wr_active <= 1'b0;
                    b_delay <= 6;
                end
            end
            if (b_delay > 0) begin
                b_delay <= b_delay - 1;
                if (b_delay == 1) bvalid_r <= 1'b1;
            end
            if (bvalid_r && bready) bvalid_r <= 1'b0;
        end
    end

    task apb_write(input [15:0] a, input [31:0] d);
        begin
            @(negedge clk); pa = a; pd = d; ps = 1'b1; pe = 1'b0; pw = 1'b1;
            @(negedge clk); pe = 1'b1;
            @(negedge clk); ps = 1'b0; pe = 1'b0; pw = 1'b0;
        end
    endtask

    task apb_read(input [15:0] a, output [31:0] d);
        begin
            @(negedge clk); pa = a; ps = 1'b1; pe = 1'b0; pw = 1'b0;
            @(negedge clk); pe = 1'b1;
            d = pr;
            @(negedge clk); ps = 1'b0; pe = 1'b0;
        end
    endtask

    reg [31:0] status;
    reg [31:0] probe;
    integer guard;
    integer n_timeout = 0;
    integer n_ok = 0, n_stall = 0, n_cfg = 0;
    longint t_start, worst = 0;
    localparam integer LIMIT = 1000000;

    task run_cmd(input [1:0] op, input [27:0] src, input [27:0] dst,
                 input [10:0] w, input [10:0] h,
                 input [15:0] ss, input [15:0] ds);
        begin
            apb_write(16'h18, {30'd0, op});
            apb_write(16'h68, 32'd1);
            apb_write(16'h1C, src);
            apb_write(16'h04, dst);
            apb_write(16'h08, {21'd0, w});
            apb_write(16'h0C, {21'd0, h});
            apb_write(16'h30, {16'd0, ss});
            apb_write(16'h48, {16'd0, ds});
            t_start = cyc;
            apb_write(16'h14, 32'd1);
            guard = 0;
            apb_read(16'h00, status);
            while ((status[1] == 1'b0) && (guard < LIMIT)) begin
                apb_read(16'h00, status);
                guard = guard + 1;
            end
            if (status[1] == 1'b0) begin
                n_stall = n_stall + 1;
                apb_read(16'h74, probe);
                $display("STALL op=%0d w=%0d h=%0d ss=%0d ds=%0d dst=%h off=%0d sg=%0d q=%0d arp=%b rd=%0d wr=%0d ar=%0d aw=%0d LAT=%0d",
                    op, w, h, ss, ds, dst, dst[3:0], dut.u_stride_gen.state,
                    dut.u_read_master.q_cnt, dut.u_read_master.ar_pend,
                    n_rd, n_wr, n_ar, n_aw, LAT);
                $fatal(1, "engine stalled");
            end
            // bit2 is cfg_error_sticky and bit3 is timeout_sticky; they shared one
            // counter, so an engine timeout was counted as a CONFIG ERROR, was neither
            // an ok nor a failure, and the bench still ended with SCAN PASS - the one
            // outcome this bench exists to catch.
            if (status[3])      n_timeout = n_timeout + 1;
            else if (status[2]) n_cfg     = n_cfg + 1;
            else begin
                n_ok = n_ok + 1;
                if ((cyc - t_start) > worst) worst = cyc - t_start;
            end
            repeat (2) @(negedge clk);
        end
    endtask

    // ---- the exact command shapes the firmware issues --------------------
    task sweep_latency;
        begin
            $display("---- A: firmware shapes, LAT=%0d ----", LAT);
            // particles_render 8x8 ss=32
            run_cmd(2'd3, 28'h033F7000, DST_BASE, 11'd8,  11'd8,  16'd32,  16'd8192);
            run_cmd(2'd1, 28'h033F7000, DST_BASE, 11'd8,  11'd8,  16'd32,  16'd8192);
            // orb 16x16 ss=64
            run_cmd(2'd3, 28'h033F5000, DST_BASE, 11'd16, 11'd16, 16'd64,  16'd8192);
            // laser glow 16xN ss=64  (N = player_y up to 768)
            run_cmd(2'd3, 28'h01660000, DST_BASE, 11'd16, 11'd512, 16'd64, 16'd8192);
            run_cmd(2'd3, 28'h01660000, DST_BASE, 11'd16, 11'd768, 16'd64, 16'd8192);
            // burst frame 112x112 ss=448
            run_cmd(2'd1, 28'h03290000, DST_BASE, 11'd112, 11'd112, 16'd448, 16'd8192);
            // pbullet 7x26 ss=32 / ebullet dirtile 9x9 ss=48
            run_cmd(2'd1, 28'h01633000, DST_BASE, 11'd7,  11'd26, 16'd32,  16'd8192);
            run_cmd(2'd1, 28'h01635000, DST_BASE, 11'd9,  11'd9,  16'd48,  16'd8192);
            // HUD glyph copy 18x24 ss=1536
            run_cmd(2'd1, 28'h01645200, DST_BASE, 11'd18, 11'd24, 16'd1536, 16'd8192);
            // HUD gutter clears 177x88 ss=8192 (SAME stride both sides)
            run_cmd(2'd1, 28'h03A00000, DST_BASE, 11'd177, 11'd88, 16'd8192, 16'd8192);
            run_cmd(2'd1, 28'h03A00000, DST_BASE, 11'd177, 11'd768, 16'd8192, 16'd8192);
            // damage restore bands
            run_cmd(2'd1, 28'h01D00000, DST_BASE, 11'd64,  11'd16, 16'd8192, 16'd8192);
            run_cmd(2'd1, 28'h01D00000, DST_BASE, 11'd1005, 11'd8, 16'd8192, 16'd8192);
            run_cmd(2'd1, 28'h01D00000, DST_BASE, 11'd448, 11'd72, 16'd8192, 16'd8192);
            // stage banner 420x64 / border 4x768
            run_cmd(2'd0, SRC_BASE, DST_BASE, 11'd420, 11'd64, 16'd8192, 16'd8192);
            run_cmd(2'd0, SRC_BASE, DST_BASE, 11'd4,   11'd768, 16'd8192, 16'd8192);
            $display("---- A done ok=%0d cfg=%0d worst=%0d ----", n_ok, n_cfg, worst);
        end
    endtask

    integer i;
    initial begin
        repeat (10) @(negedge clk);
        rst_n = 1;
        repeat (10) @(negedge clk);

        sweep_latency;
        LAT = 200;  sweep_latency;
        LAT = 600;  sweep_latency;
        LAT = 2000; sweep_latency;

        $display("---- B: 4KiB-boundary and odd-offset walk ----");
        for (i = 0; i < 8; i = i + 1) begin
            run_cmd(2'd3, SRC_BASE + i*4, DST_BASE + i*12, 11'd16, 11'd512, 16'd64, 16'd8192);
            run_cmd(2'd3, 28'h01660000, 28'h00800000 + i*4096, 11'd16, 11'd511, 16'd64, 16'd8192);
            run_cmd(2'd1, 28'h01D00000, 28'h00800000 + i*4096, 11'd64, 11'd16, 16'd8192, 16'd8192);
        end
        $display("---- B done ok=%0d cfg=%0d worst=%0d ----", n_ok, n_cfg, worst);

        $display("SCAN ok=%0d cfg=%0d timeout=%0d stalled=%0d worst=%0d",
                 n_ok, n_cfg, n_timeout, n_stall, worst);
        if (n_timeout != 0 || n_cfg != 0 || n_stall != 0) begin
            $display("SCAN FAIL: timeout=%0d cfg=%0d stalled=%0d",
                     n_timeout, n_cfg, n_stall);
            $finish(1);
        end
        $display("SCAN PASS ok=%0d worst=%0d cycles", n_ok, worst);
        $finish;
    end

    initial begin
        #600000000;
        $fatal(1, "global timeout");
    end

endmodule