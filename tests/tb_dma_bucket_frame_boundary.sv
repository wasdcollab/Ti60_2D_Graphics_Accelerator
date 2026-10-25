`timescale 1ns/1ps

module tb_dma_bucket_frame_boundary;
    reg axi_clk = 0, pixel_clk = 0, rst_n = 0;
    always #5 axi_clk = ~axi_clk;
    always #6 pixel_clk = ~pixel_clk;

    reg [11:0] h_cnt = 1;
    reg [10:0] v_cnt = 0;
    reg frame_clear_axi = 0;
    reg fb_busy = 1;
    reg arready = 1, rvalid = 0, rlast = 0;
    reg [127:0] rdata = 128'd0;
    wire bk_pend, bk_act, arvalid, rready;
    wire [27:0] araddr;
    wire [7:0] arlen;

    dma_bucket_prefetch #(.BUCKET_SLOTS(80)) dut (
        .axi_clk(axi_clk), .axi_rst_n(rst_n), .cal_done(1'b1),
        .bucket_base(28'h4800000), .active_base(28'h0800000),
        .frame_clear_axi(frame_clear_axi), .discard_frame(1'b0),
        .at_line_start(1'b1), .fb_busy(fb_busy),
        .bk_pend(bk_pend), .bk_act(bk_act),
        .bk_araddr(araddr), .bk_arlen(arlen), .bk_arvalid(arvalid),
        .bk_arready(arready && bk_act), .bk_rdata(rdata),
        .bk_rlast(rlast), .bk_rvalid(rvalid && bk_act),
        .bk_rready(rready), .pixel_clk(pixel_clk), .pixel_rst_n(rst_n),
        .h_cnt(h_cnt), .v_cnt(v_cnt), .bucket_row(), .bucket_ready()
    );

    task request_row(input [10:0] row);
        begin
            @(negedge pixel_clk); v_cnt = row - 11'd2; h_cnt = 0;
            @(negedge pixel_clk); h_cnt = 1;
        end
    endtask

    task send_beat(input bit last);
        begin
            @(negedge axi_clk); rvalid = 1; rlast = last;
            @(posedge axi_clk);
            @(negedge axi_clk); rvalid = 0; rlast = 0;
        end
    endtask

    initial begin
        repeat (4) @(negedge axi_clk);
        rst_n = 1;
        request_row(11'd10);
        wait(bk_pend);
        repeat (4) @(negedge axi_clk);
        if (bk_act || arvalid)
            $fatal(1, "bucket stole an in-flight framebuffer AXI read");
        fb_busy = 0;
        wait(arvalid);
        #1;
        if (araddr !== 28'h4800000 + 28'd3200 || arlen !== 8'd15)
            $fatal(1, "first burst has wrong row/address");
        @(posedge axi_clk);
        @(negedge axi_clk);
        if (!bk_act || !rready) $fatal(1, "AR owner was lost");

        // Queue a new row while the first row's 16-beat burst is in flight.
        request_row(11'd11);
        repeat (15) send_beat(0);
        send_beat(1);
        wait(arvalid);
        #1;
        if (araddr !== 28'h4800000 + 28'd3200 + 28'd256 || arlen !== 8'd3)
            $fatal(1, "second burst switched to pending row");
        @(posedge axi_clk);
        @(negedge axi_clk);
        repeat (3) send_beat(0);
        send_beat(1);
        wait(arvalid);
        #1;
        if (araddr !== 28'h4800000 + 28'd3520 || arlen !== 8'd15)
            $fatal(1, "request arriving during a burst was lost: addr=%h len=%d pend=%b row=%d",
                   araddr, arlen, bk_pend, dut.bk_pending_row);
        @(posedge axi_clk);
        @(negedge axi_clk);

        // A frame boundary must discard pixel publication, but preserve the
        // AXI owner until the accepted read has returned its final RLAST.
        frame_clear_axi = 1;
        @(negedge axi_clk); frame_clear_axi = 0;
        if (!bk_act || !rready) $fatal(1, "frame clear stole an AXI transaction");
        repeat (15) send_beat(0);
        send_beat(1);
        wait(arvalid);
        #1;
        if (araddr !== 28'h4800000 + 28'd3520 + 28'd256)
            $fatal(1, "draining burst changed its row");
        @(posedge axi_clk);
        @(negedge axi_clk);
        repeat (3) send_beat(0);
        send_beat(1);
        @(negedge axi_clk);
        if (bk_act || bk_pend || arvalid || rready)
            $fatal(1, "old transaction was not fully drained");

        request_row(11'd12);
        wait(arvalid);
        #1;
        if (araddr !== 28'h4800000 + 28'd3840)
            $fatal(1, "new frame did not start at its own row");

        // The last two blanking lines must request rows 0 and 1 before the
        // active scan.  Previously those rows reused old bucket RAM contents.
        @(negedge axi_clk); rst_n = 0;
        repeat (3) @(negedge axi_clk);
        rst_n = 1;
        @(negedge pixel_clk); v_cnt = 11'd780; h_cnt = 0;
        @(negedge pixel_clk); h_cnt = 1;
        wait(arvalid);
        #1;
        if (araddr !== 28'h4800000)
            $fatal(1, "blanking did not prefetch bucket row 0");
        @(negedge pixel_clk); v_cnt = 11'd781; h_cnt = 0;
        @(negedge pixel_clk); h_cnt = 1;
        repeat (5) @(negedge axi_clk);
        if (!bk_pend || dut.bk_pending_row !== 11'd1)
            $fatal(1, "blanking did not queue bucket row 1");
        $display("PASS tb_dma_bucket_frame_boundary");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "timeout");
    end
endmodule
