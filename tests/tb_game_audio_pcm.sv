`timescale 1ns/1ps
module tb_game_audio_pcm;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, tick = 0, enabled = 1, bgm_enabled = 1;
    reg [2:0] volume = 4;
    reg event_strobe = 0;
    reg [3:0] event_code = 0;
    wire signed [15:0] left, right;
    integer i, v, expected, bgm, sfx, heard_sfx = 0;
    game_audio_synth #(.BGM_ROM_FILE("work_sim/bgm_test.hex")) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .enabled(enabled), .bgm_enabled(bgm_enabled), .volume(volume),
        .event_strobe(event_strobe), .event_code(event_code),
        .stream_sample(16'sd0),
        .sample_left(left), .sample_right(right)
    );
    task frame;
        begin
            @(negedge clk);
            bgm = bgm_enabled ? $signed(dut.pcm_bgm_wave) : 0;
            sfx = $signed(dut.sfx_wave);
            if (sfx != 0) heard_sfx = heard_sfx + 1;
            expected = bgm + sfx;
            case (volume)
                1: expected = expected >>> 3;
                2: expected = expected >>> 2;
                3: expected = expected >>> 1;
                4: expected = expected;
                default: expected = 0;
            endcase
            if (!enabled) expected = 0;
            tick = 1;
            @(posedge clk); #1;
            if (left !== expected[15:0] || right !== expected[15:0])
                $fatal(1, "mix/volume mismatch got %0d/%0d want %0d", left, right, expected);
            @(negedge clk); tick = 0;
            repeat (3) @(negedge clk);
        end
    endtask
    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        for (v = 0; v < 8; v = v + 1) begin
            volume = v;
            for (i = 0; i < 32; i = i + 1) frame;
        end
        volume = 4;
        // Existing SFX must still contribute alongside PCM BGM.
        event_code = 1; event_strobe = 1;
        @(negedge clk); event_strobe = 0;
        for (i = 0; i < 5000; i = i + 1) frame;
        if (heard_sfx == 0) $fatal(1, "shot SFX never contributed");
        bgm_enabled = 0;
        for (i = 0; i < 40; i = i + 1) frame;
        enabled = 0;
        for (i = 0; i < 20; i = i + 1) frame;
        $display("TB_PASS: PCM selected, stereo mix, all volumes, SFX coexistence, enable gates");
        $finish;
    end
    initial begin #1000000; $fatal(1, "timeout"); end
endmodule
