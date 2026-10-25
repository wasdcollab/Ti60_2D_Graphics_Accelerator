`timescale 1ns/1ps
module tb_bgm_pcm_fifo;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, tick = 0, enabled = 0, clear = 0, wr = 0;
    reg [7:0] data = 0;
    wire signed [15:0] sample;
    wire [31:0] status, underflows, played;
    bgm_pcm_fifo #(.ADDR_WIDTH(4), .START_LEVEL(8)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick), .enabled(enabled),
        .clear(clear), .write_strobe(wr), .write_data(data),
        .sample(sample), .status(status), .underflows(underflows), .played(played)
    );
    integer i, head = 0, tail = 0, count = 0, checked = 0, expected, keep;
    reg [7:0] queue [0:15];
    reg do_pop, do_push;
    task cycle;
        input put;
        input [7:0] value;
        input sample_en;
        begin
            @(negedge clk); wr = put; data = value; tick = sample_en;
            #1;
            do_pop = dut.pop; do_push = put && ((count < 16) || do_pop);
            if (do_pop) begin
                expected = (integer'(queue[head]) - 128) * 64;
                head = (head + 1) % 16; count = count - 1;
            end
            if (do_push) begin
                queue[tail] = value; tail = (tail + 1) % 16; count = count + 1;
            end
            @(posedge clk); #1;
            if (status[11:0] !== count) $fatal(1, "FIFO count mismatch");
            if (do_pop) begin
                if (sample !== expected[15:0]) $fatal(1, "PCM order/sign mismatch");
                checked = checked + 1;
            end
        end
    endtask
    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        for (i = 0; i < 16; i = i + 1) cycle(1, i * 17, 0);
        cycle(1, 8'hfe, 0);
        if (!status[17] || status[11:0] != 16) $fatal(1, "full queue must reject write");
        enabled = 1;
        for (i = 0; i < 80; i = i + 1) cycle(0, 0, i % 4 == 0);
        keep = checked;
        // Steady input, repeated full/empty boundaries and simultaneous push/pop.
        for (i = 0; i < 3000; i = i + 1) cycle(i % 7 == 0, i[7:0], i % 4 == 0);
        if (checked < keep + 150) $fatal(1, "stream did not advance");
        for (i = 0; i < 600; i = i + 1) cycle(0, 0, i % 4 == 0);
        if (underflows != 1 || sample !== 16'sd0 || status[16])
            $fatal(1, "underflow must mute and count once");
        for (i = 0; i < 7; i = i + 1) cycle(1, i[7:0], 0);
        repeat (24) cycle(0, 0, 1);
        if (status[16]) $fatal(1, "must wait for safe watermark");
        cycle(1, 8'hff, 0);
        repeat (24) cycle(0, 0, 1);
        if (!status[16]) $fatal(1, "must resume at watermark");
        enabled = 0;
        cycle(0, 0, 0);
        if (sample !== 16'sd0 || status[16]) $fatal(1, "disable must mute");
        @(negedge clk); clear = 1;
        @(posedge clk); #1;
        if (status !== 0 || underflows !== 0 || played !== 0) $fatal(1, "clear must reset telemetry");
        $display("TB_PASS: PCM FIFO ordering, wrap, full rejection, simultaneous IO, watermark and underflow recovery");
        $finish;
    end
    initial begin #200000; $fatal(1, "timeout"); end
endmodule
