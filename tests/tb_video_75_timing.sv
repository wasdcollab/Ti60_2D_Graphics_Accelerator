`timescale 1ns/1ps

module tb_video_75_timing;
    reg pixel_clk = 0;
    reg axi_clk = 0;
    reg rst_n = 0;
    always #5.8335 pixel_clk = ~pixel_clk;
    always #5 axi_clk = ~axi_clk;

    video_dma_read dut (
        .axi_clk(axi_clk), .axi_rst_n(rst_n), .cal_done(1'b1),
        .pixel_clk(pixel_clk), .pixel_rst_n(rst_n),
        .next_frame_base_addr(28'h0800000),
        .next_right_base_addr(28'h0e00000),
        .cpu_fps_bcd(8'h00), .fpga_fps_bcd(8'h00),
        .weather_mask_x(32'd0), .weather_mask_y(32'd0),
        .m_axi_arready(1'b0), .m_axi_rid(4'd0),
        .m_axi_rdata(128'd0), .m_axi_rresp(2'd0),
        .m_axi_rlast(1'b0), .m_axi_rvalid(1'b0)
    );

    integer clocks = 0;
    integer blank_edges = 0;
    always @(posedge pixel_clk) begin
        if (rst_n) begin
            clocks = clocks + 1;
            if (dut.h_cnt == 0 && dut.v_cnt == 768)
                blank_edges = blank_edges + 1;
        end
    end

    initial begin
        if (dut.H_TOTAL != 1456 || dut.V_TOTAL != 782 ||
            dut.H_ACT != 1366 || dut.V_ACT != 768)
            $fatal(1, "scan timing is not 1366x768 at 75.28 Hz");
        repeat (4) @(negedge pixel_clk);
        rst_n = 1;
        repeat (1456*782) @(negedge pixel_clk);
        if (dut.h_cnt != 0 || dut.v_cnt != 0 || blank_edges != 1)
            $fatal(1, "frame period/blank edge mismatch: h=%0d v=%0d edges=%0d",
                   dut.h_cnt, dut.v_cnt, blank_edges);
        $display("PASS video timing: 1456 x 782 pixels, one blank edge per frame (75.28 Hz @ 85.712 MHz)");
        $finish;
    end
endmodule
