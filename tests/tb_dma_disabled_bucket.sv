`timescale 1ns/1ps

module tb_dma_disabled_bucket;
    reg axi_clk = 0, pixel_clk = 0, rst_n = 0;
    always #5 axi_clk = ~axi_clk;
    always #6 pixel_clk = ~pixel_clk;

    reg [11:0] h_cnt = 1;
    reg [10:0] v_cnt = 0;
    reg frame_start = 0;
    wire [27:0] araddr;
    wire arvalid;

    dma_top dut (
        .axi_clk(axi_clk), .axi_rst_n(rst_n), .cal_done(1'b1),
        .m_axi_arid(), .m_axi_araddr(araddr), .m_axi_arlen(),
        .m_axi_arsize(), .m_axi_arburst(), .m_axi_arlock(),
        .m_axi_arvalid(arvalid), .m_axi_arready(1'b0),
        .m_axi_rid(4'd0), .m_axi_rdata(128'd0),
        .m_axi_rresp(2'b00), .m_axi_rlast(1'b0),
        .m_axi_rvalid(1'b0), .m_axi_rready(),
        .pixel_clk(pixel_clk), .pixel_rst_n(rst_n),
        .h_cnt(h_cnt), .v_cnt(v_cnt), .t_de(1'b0),
        .t_frame_start(frame_start), .t_frame_clear(1'b0),
        .next_frame_base_addr(28'h0800000), .active_frame_base_addr(),
        .next_right_base_addr(28'h0800000), .active_right_base_addr(),
        .vsync_flag(), .video_read_priority(), .scan_diagnostics(),
        .bucket_base(28'd0), .bucket_row(), .bucket_ready(),
        .fb_pixel()
    );

    initial begin
        repeat (4) @(negedge axi_clk);
        rst_n = 1;
        @(negedge pixel_clk); h_cnt = 0;
        @(negedge pixel_clk); h_cnt = 1;
        wait(dut.bk_pend);
        @(negedge pixel_clk); frame_start = 1;
        @(negedge pixel_clk); frame_start = 0;
        repeat (10) @(negedge axi_clk);
        if (!arvalid || araddr !== 28'h0800000)
            $fatal(1, "disabled bucket blocked framebuffer AR: valid=%b addr=%h", arvalid, araddr);
        $display("PASS tb_dma_disabled_bucket");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "timeout");
    end
endmodule
