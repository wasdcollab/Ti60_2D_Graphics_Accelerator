`timescale 1ns/1ps

module tb_i2s_tx;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg signed [15:0] left = 16'hA55A;
    reg signed [15:0] right = 16'h3CC3;
    wire tick, bclk, lrclk, din;
    integer ticks = 0;

    i2s_tx #(.BCLK_HALF_DIV(2)) dut (
        .clk(clk), .rst_n(rst_n), .sample_left(left), .sample_right(right),
        .sample_tick(tick), .i2s_bclk(bclk), .i2s_lrclk(lrclk), .i2s_din(din)
    );

    always #5 clk = ~clk;
    always @(posedge clk) if (tick) ticks = ticks + 1;

    task expect_word;
        input expected_lrclk;
        input [15:0] expected_word;
        integer i;
        reg [15:0] got;
        begin
            // First rising edge after LRCLK changes is the I2S padding bit.
            @(posedge bclk);
            if (din !== 1'b0) begin
                $display("FAIL: missing I2S padding bit");
                $fatal;
            end
            for (i = 15; i >= 0; i = i - 1) begin
                @(posedge bclk);
                if (lrclk !== expected_lrclk) begin
                    $display("FAIL: LRCLK changed while reading word");
                    $fatal;
                end
                got[i] = din;
            end
            if (got !== expected_word) begin
                $display("FAIL: lr=%0d got=%h want=%h", expected_lrclk, got, expected_word);
                $fatal;
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        // Wait for a fresh left-channel boundary after the first samples
        // have been latched at the end of the reset-silence frame.
        @(negedge lrclk);
        expect_word(1'b0, 16'hA55A);
        @(posedge lrclk);
        expect_word(1'b1, 16'h3CC3);
        if (ticks < 1) begin
            $display("FAIL: sample tick absent");
            $fatal;
        end
        $display("PASS: I2S standard framing and samples verified");
        $finish;
    end
endmodule
