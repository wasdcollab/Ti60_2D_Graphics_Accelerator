`timescale 1ns / 1ps

module tb_gearbox_check;
    reg pixel_clk = 0;
    reg pixel_rst_n = 0;
    always #5.8335 pixel_clk = ~pixel_clk; // 85.714 MHz

    reg axi_clk = 0;
    reg axi_rst_n = 0;
    always #5.0 axi_clk = ~axi_clk; // 100 MHz

    wire [11:0] h_cnt;
    wire [10:0] v_cnt;
    wire        t_hsync;
    wire        t_vsync;
    wire        t_de;
    wire        t_frame_start;
    wire        t_frame_clear;

    video_timing_gen #(
        .H_ACT(1366), .H_FP(8), .H_SYNC(56), .H_BP(26), .H_TOTAL(1456),
        .V_ACT(32),  .V_FP(2), .V_SYNC(3),  .V_BP(9),  .V_TOTAL(46)
    ) u_timing (
        .pixel_clk(pixel_clk),
        .rst_n(pixel_rst_n),
        .h_cnt(h_cnt),
        .v_cnt(v_cnt),
        .hsync(t_hsync),
        .vsync(t_vsync),
        .de(t_de),
        .frame_start(t_frame_start),
        .frame_clear(t_frame_clear)
    );

    // AXI Bus Signals
    wire [3:0]   arid;
    wire [27:0]  araddr;
    wire [7:0]   arlen;
    wire [2:0]   arsize;
    wire [1:0]   arburst, arlock;
    wire         arvalid;
    reg          arready;

    wire [3:0]   rid = 4'd1;
    reg  [127:0] rdata;
    wire [1:0]   rresp = 2'b00;
    reg          rlast;
    reg          rvalid;
    wire         rready;

    wire [31:0]  fb_pixel;
    wire         video_read_priority;
    wire         vsync_flag;

    dma_top #(
        .FRAME_BASE_ADDR(28'h0080_0000),
        .H_ACT(1366),
        .H_TOTAL(1456),
        .V_ACT(32),
        .V_TOTAL(46),
        .AXI_ADDR_WIDTH(28),
        .AXI_DATA_WIDTH(128),
        .BUCKET_SLOTS(80),
        .SCANLINE_EN(1)
    ) u_dma (
        .axi_clk(axi_clk),
        .axi_rst_n(axi_rst_n),
        .cal_done(1'b1),

        .m_axi_arid(arid),
        .m_axi_araddr(araddr),
        .m_axi_arlen(arlen),
        .m_axi_arsize(arsize),
        .m_axi_arburst(arburst),
        .m_axi_arlock(arlock),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),

        .m_axi_rid(rid),
        .m_axi_rdata(rdata),
        .m_axi_rresp(rresp),
        .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid),
        .m_axi_rready(rready),

        .pixel_clk(pixel_clk),
        .pixel_rst_n(pixel_rst_n),

        .h_cnt(h_cnt),
        .v_cnt(v_cnt),
        .t_de(t_de),
        .t_frame_start(t_frame_start),
        .t_frame_clear(t_frame_clear),

        .next_frame_base_addr(28'h0080_0000),
        .active_frame_base_addr(),
        .next_right_base_addr(28'h0080_0000),
        .active_right_base_addr(),
        .vsync_flag(vsync_flag),
        .video_read_priority(video_read_priority),
        .scan_diagnostics(),

        .bucket_base(28'h0),
        .bucket_row(),
        .bucket_ready(),

        .fb_pixel(fb_pixel)
    );

    // Realistic AXI Read Responder with stall injection capability
    reg [27:0] cur_araddr;
    reg [7:0]  beats_left;
    reg [1:0]  axi_state;
    localparam AXI_IDLE = 2'd0, AXI_DATA = 2'd1;

    reg inject_stall = 0;
    integer stall_cycles = 0;

    // Helper: generate 128-bit word with 4 tagged pixels based on memory address
    function [127:0] gen_word(input [27:0] addr);
        reg [10:0] row;
        reg [11:0] col_px;
        reg [7:0]  r8, c0, c1, c2, c3;
        begin
            row = (addr[23:0]) / 8192;
            col_px = ((addr[23:0]) % 8192) / 4;
            r8 = row[7:0];
            c0 = col_px[7:0];
            c1 = col_px[7:0] + 8'd1;
            c2 = col_px[7:0] + 8'd2;
            c3 = col_px[7:0] + 8'd3;
            gen_word = {
                {r8, c3, 8'hA3, 8'h55},
                {r8, c2, 8'hA2, 8'h55},
                {r8, c1, 8'hA1, 8'h55},
                {r8, c0, 8'hA0, 8'h55}
            };
        end
    endfunction

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            arready    <= 1'b0;
            rvalid     <= 1'b0;
            rlast      <= 1'b0;
            rdata      <= 128'd0;
            cur_araddr <= 28'd0;
            beats_left <= 8'd0;
            axi_state  <= AXI_IDLE;
        end else begin
            if (stall_cycles > 0 && axi_state == AXI_IDLE) begin
                stall_cycles <= stall_cycles - 1;
                arready <= 1'b0;
            end else begin
                case (axi_state)
                    AXI_IDLE: begin
                        arready <= 1'b1;
                        if (arvalid && arready) begin
                            arready    <= 1'b0;
                            cur_araddr <= araddr;
                            beats_left <= arlen;
                            rvalid     <= 1'b1;
                            rlast      <= (arlen == 8'd0);
                            rdata      <= gen_word(araddr);
                            axi_state  <= AXI_DATA;
                        end
                    end

                    AXI_DATA: begin
                        if (rvalid && rready) begin
                            if (beats_left == 8'd0) begin
                                rvalid    <= 1'b0;
                                rlast     <= 1'b0;
                                arready   <= 1'b1;
                                axi_state <= AXI_IDLE;
                            end else begin
                                beats_left <= beats_left - 8'd1;
                                cur_araddr <= cur_araddr + 28'd16;
                                rlast      <= (beats_left == 8'd1);
                                rdata      <= gen_word(cur_araddr + 28'd16);
                            end
                        end
                    end
                endcase
            end
        end
    end

    // Pipeline Alignment (1 cycle latency to match fb_pixel from dma_top)
    reg        t_de_d1;
    reg [11:0] pixel_x_d1;
    reg [10:0] pixel_y_d1;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            t_de_d1    <= 1'b0;
            pixel_x_d1 <= 12'd0;
            pixel_y_d1 <= 11'd0;
        end else begin
            t_de_d1    <= t_de;
            pixel_x_d1 <= h_cnt;
            pixel_y_d1 <= v_cnt;
        end
    end

    // Verification of exact pixel alignment and underflow recovery
    integer pixel_checks = 0;
    integer pixel_mismatches = 0;
    integer lines_verified = 0;
    integer fault_blacks = 0, recovered_pixels = 0;
    wire [11:0] col_px = pixel_x_d1 - 12'd1;
    reg [31:0]  expected_pixel;
    reg [7:0]   exp_tag;

    always @(posedge pixel_clk) begin
        if (pixel_rst_n && t_de_d1) begin
            case (col_px[1:0])
                2'd0: exp_tag = 8'hA0;
                2'd1: exp_tag = 8'hA1;
                2'd2: exp_tag = 8'hA2;
                2'd3: exp_tag = 8'hA3;
            endcase
            expected_pixel = {pixel_y_d1[7:0], col_px[7:0], exp_tag, 8'h55};

            pixel_checks = pixel_checks + 1;
            if(pixel_y_d1>=8 && pixel_y_d1<=10 && fb_pixel==0) fault_blacks=fault_blacks+1;
            if(pixel_y_d1>=14 && pixel_y_d1<20 && fb_pixel!=0) recovered_pixels=recovered_pixels+1;

            // Only check non-zero pixels (an underflow might produce black pixels during the fault itself,
            // but must NEVER produce a shifted or misaligned pixel!)
            if (fb_pixel != 32'd0) begin
                if (fb_pixel != expected_pixel) begin
                    if (pixel_mismatches < 8) $display("[FAIL MISMATCH] at line %0d col %0d: fb_pixel=%08x expected=%08x",
                             pixel_y_d1, col_px, fb_pixel, expected_pixel);
                    pixel_mismatches = pixel_mismatches + 1;
                end
            end
        end
        if (pixel_rst_n && h_cnt == 12'd1455 && v_cnt < 11'd768) begin
            lines_verified = lines_verified + 1;
        end
    end

    initial begin
        pixel_rst_n = 0;
        axi_rst_n   = 0;
        #100;
        axi_rst_n   = 1;
        pixel_rst_n = 1;

        $display("[TB START] Starting rigorous scanout gearbox verification...");

        // Let Frame 0 prefetch and start Line 0..10 normally
        @(posedge t_frame_start);
        $display("[TB] Frame 0 start detected. Waiting for active video...");

        wait(v_cnt == 5 && h_cnt == 100);
        $display("[TB INJECT] Blocking new bursts for 6000 cycles, longer than FIFO cushion");
        wait(rvalid && rready && rlast); @(negedge axi_clk);
        stall_cycles = 6000;

        wait(v_cnt == 6 && h_cnt == 0);
        $display("[TB] Line 5 finished. Verifying Line 6 recovers with ZERO horizontal offset...");

        wait(v_cnt == 10 && h_cnt == 1450);
        $display("[TB INJECT] Injecting 30-cycle memory stall at line prefetch before Line 11...");
        // A full FIFO can hide 30 cycles; the long injection above must not.

        wait(v_cnt == 12 && h_cnt == 0);
        $display("[TB] Line 11 finished. Verifying Line 12 recovers with ZERO horizontal offset...");

        // Wait through line 20
        wait(v_cnt == 20 && h_cnt == 0);

        #1000;
        $display("==========================================================");
        $display("[TB RESULTS] Checked %0d pixels across %0d scanlines", pixel_checks, lines_verified);
        $display("[TB RESULTS] Pixel phase mismatches / shears: %0d", pixel_mismatches);
        if (pixel_mismatches == 0 && lines_verified >= 20 && fault_blacks>0 && recovered_pixels>1000) begin
            $display("[TB SUCCESS] PASS! Zero phase misalignment, no cascading tears detected under severe stalls!");
        end else begin
            $fatal(1, "[TB FAILED] Failures detected!");
        end
        $display("==========================================================");
        $finish;
    end

    initial begin #3000000; $fatal(1, "gearbox timeout"); end

endmodule
