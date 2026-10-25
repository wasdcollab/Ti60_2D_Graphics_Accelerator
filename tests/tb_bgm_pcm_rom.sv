`timescale 1ns/1ps
module tb_bgm_pcm_rom;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, tick = 0, enabled = 0;
    wire signed [15:0] sample;
    integer phase = 0, address = 0, advances = 0, i, expected;
    bgm_pcm_rom #(.ROM_FILE("work_sim/bgm_test.hex")) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .enabled(enabled), .sample(sample)
    );
    function integer value_at;
        input integer n;
        begin
            case (n % 4)
                0: value_at = -8192;
                1: value_at = -64;
                2: value_at = 0;
                default: value_at = 8128;
            endcase
        end
    endfunction
    task frame;
        begin
            @(negedge clk); tick = 1;
            @(posedge clk); #1;
            expected = value_at(address);
            if (sample !== expected[15:0])
                $fatal(1, "PCM frame %0d address %0d got %0d want %0d", i, address, sample, expected);
            phase = phase + 3072;
            if (phase >= 12500) begin
                phase = phase - 12500;
                address = (address + 1) % 2048;
                advances = advances + 1;
            end
            @(negedge clk); tick = 0;
            repeat (3) @(negedge clk);
        end
    endtask
    initial begin
        repeat (3) @(negedge clk);
        if (sample !== 16'sd0) $fatal(1, "reset must mute");
        rst_n = 1;
        repeat (3) @(negedge clk);
        enabled = 1;
        for (i = 0; i < 12500; i = i + 1) frame;
        if (advances != 3072 || phase != 0 || address != 1024)
            $fatal(1, "12 kHz ratio or ROM wrap mismatch");
        enabled = 0;
        repeat (3) @(negedge clk);
        if (sample !== 16'sd0) $fatal(1, "disable must mute");
        enabled = 1; address = 0; phase = 0;
        for (i = 0; i < 20; i = i + 1) frame;
        rst_n = 0;
        #1;
        if (sample !== 16'sd0) $fatal(1, "mid-stream reset must mute");
        $display("TB_PASS: PCM signed endpoints, exact 12 kHz rate, full wrap, disable/restart, reset");
        $finish;
    end
    initial begin #2000000; $fatal(1, "timeout"); end
endmodule
