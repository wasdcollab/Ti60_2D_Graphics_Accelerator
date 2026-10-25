`timescale 1ns/1ps
// Small deterministic game soundtrack/SFX generator.  It is intentionally
// independent of DDR and the video/BitBlt paths: at 48.8 ksample/s it costs no
// memory bandwidth and events are consumed through a one-entry hardware latch.
module game_audio_synth #(
    parameter integer PCM_BGM = 1,
    parameter BGM_ROM_FILE = "assets/audio/generated/bgm_stage_a.hex"
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               enabled,
    input  wire               bgm_enabled,
    input  wire [2:0]         volume,
    input  wire               event_strobe,
    input  wire [3:0]         event_code,
    input  wire signed [15:0] stream_sample,
    output reg signed [15:0]  sample_left,
    output reg signed [15:0]  sample_right
);
    `include "sfx_rom.vh"
    localparam [3:0] EVT_NONE  = 4'd0;
    localparam [3:0] EVT_SHOT  = 4'd1;
    localparam [3:0] EVT_LASER = 4'd2;
    localparam [3:0] EVT_KILL  = 4'd3;
    localparam [3:0] EVT_BOSS  = 4'd4;
    localparam [3:0] EVT_HIT   = 4'd5;

    reg [23:0] melody_phase, bass_phase, sfx_phase;
    reg [15:0] step_timer;
    reg [3:0]  step;
    reg [3:0]  pending_event;
    reg [15:0] sfx_left;
    reg [23:0] sfx_inc;
    reg        sfx_noise_mode;
    reg        sfx_rom_mode;
    reg        sfx_rom_boost;
    reg [15:0] noise_lfsr;
    reg [12:0] sfx_rom_addr, sfx_rom_left;
    reg signed [7:0] sfx_rom_sample;
    reg [4:0] sfx_rom_div;
reg [7:0] sfx_rom [0:8191];
    initial $readmemh("rtl/audio/sfx_rom.hex", sfx_rom);

    function [23:0] melody_inc;
        input [3:0] n;
        begin
            // 16-step original chiptune loop, C4..D5 at 48.828125 ksample/s.
            case (n)
                4'd0:  melody_inc = 24'd180224; // C5
                4'd1:  melody_inc = 24'd151684; // A4
                4'd2:  melody_inc = 24'd135086; // G4
                4'd3:  melody_inc = 24'd151684;
                4'd4:  melody_inc = 24'd202316; // D5
                4'd5:  melody_inc = 24'd180224;
                4'd6:  melody_inc = 24'd151684;
                4'd7:  melody_inc = 24'd135086;
                4'd8:  melody_inc = 24'd113568; // E4
                4'd9:  melody_inc = 24'd135086;
                4'd10: melody_inc = 24'd151684;
                4'd11: melody_inc = 24'd180224;
                4'd12: melody_inc = 24'd151684;
                4'd13: melody_inc = 24'd135086;
                4'd14: melody_inc = 24'd113568;
                default: melody_inc = 24'd101158; // D4
            endcase
        end
    endfunction

    function [23:0] bass_inc;
        input [3:0] n;
        begin
            case (n[3:2])
                2'd0: bass_inc = 24'd45056;  // C3
                2'd1: bass_inc = 24'd56784;  // E3
                2'd2: bass_inc = 24'd67543;  // G3
                default: bass_inc = 24'd75842; // A3
            endcase
        end
    endfunction

    wire signed [15:0] melody_wave = melody_phase[23] ? -16'sd2400 : 16'sd2400;
    wire signed [15:0] bass_wave   = bass_phase[23]   ? -16'sd1300 : 16'sd1300;
    wire signed [15:0] noise_wave  = {{3{noise_lfsr[15]}}, noise_lfsr[15:3]};
    wire signed [15:0] rom_wave    = sfx_rom_boost ?
                                      {{1{sfx_rom_sample[7]}}, sfx_rom_sample, 7'b0} :
                                      {{2{sfx_rom_sample[7]}}, sfx_rom_sample, 6'b0};
    wire signed [15:0] sfx_wave    = (sfx_left != 16'd0) ?
                                      (sfx_rom_mode ? (sfx_rom_left != 13'd0 ? rom_wave : 16'sd0) : sfx_noise_mode ? noise_wave :
                                       (sfx_phase[23] ? -16'sd7000 : 16'sd7000)) : 16'sd0;
    wire signed [15:0] pcm_bgm_wave;
    generate
        if (PCM_BGM == 1) begin : g_pcm_bgm
            bgm_pcm_rom #(.ROM_FILE(BGM_ROM_FILE)) u_bgm (
                .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
                .enabled(enabled && bgm_enabled), .sample(pcm_bgm_wave)
            );
        end else if (PCM_BGM == 2) begin : g_stream_bgm
            assign pcm_bgm_wave = stream_sample;
        end else begin : g_original_bgm
            assign pcm_bgm_wave = 16'sd0;
        end
    endgenerate
    wire signed [15:0] bgm_wave = !bgm_enabled ? 16'sd0 :
        (PCM_BGM != 0 ? pcm_bgm_wave : melody_wave + bass_wave);
    wire signed [17:0] mixed_wave = {{2{bgm_wave[15]}}, bgm_wave}
                                   + {{2{sfx_wave[15]}}, sfx_wave};
    reg signed [17:0] output_wave;
    always @* begin
        case (volume)
            3'd1: output_wave = mixed_wave >>> 3;
            3'd2: output_wave = mixed_wave >>> 2;
            3'd3: output_wave = mixed_wave >>> 1;
            3'd4: output_wave = mixed_wave;
            default: output_wave = 18'sd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            melody_phase <= 24'd0;
            bass_phase   <= 24'd0;
            sfx_phase    <= 24'd0;
            step_timer   <= 16'd0;
            step         <= 4'd0;
            pending_event <= EVT_NONE;
            sfx_left     <= 16'd0;
            sfx_inc      <= 24'd0;
            sfx_noise_mode <= 1'b0;
            sfx_rom_mode   <= 1'b0;
            sfx_rom_boost  <= 1'b0;
            noise_lfsr    <= 16'hA5C3;
            sfx_rom_addr  <= 13'd0;
            sfx_rom_left  <= 13'd0;
            sfx_rom_sample <= 8'sd0;
            sfx_rom_div   <= 5'd0;
            sample_left  <= 16'sd0;
            sample_right <= 16'sd0;
        end else begin
            // APB and sample logic share core_clk.  Latching makes a one-cycle
            // MMIO write survive until the next 48.8 kHz audio sample boundary.
            if (event_strobe && event_code != EVT_NONE)
                pending_event <= event_code;

            if (sample_tick) begin
                if (enabled) begin
                    sample_left  <= output_wave[15:0];
                    sample_right <= output_wave[15:0];
                end else begin
                    sample_left  <= 16'sd0;
                    sample_right <= 16'sd0;
                end

                melody_phase <= melody_phase + melody_inc(step);
                bass_phase   <= bass_phase + bass_inc(step);
                sfx_phase    <= sfx_phase + sfx_inc;
                noise_lfsr   <= {noise_lfsr[14:0], noise_lfsr[15] ^ noise_lfsr[13] ^ noise_lfsr[12] ^ noise_lfsr[10]};
                if (sfx_rom_mode && sfx_rom_left != 13'd0) begin
                    if (sfx_rom_div == 5'd29) begin
                        sfx_rom_div <= 5'd0;
                        sfx_rom_sample <= sfx_rom[sfx_rom_addr];
                        sfx_rom_addr <= sfx_rom_addr + 13'd1;
                        sfx_rom_left <= sfx_rom_left - 13'd1;
                    end else begin
                        sfx_rom_div <= sfx_rom_div + 5'd1;
                    end
                end
                if (step_timer == 16'd5959) begin
                    step_timer <= 16'd0;
                    step <= step + 4'd1;
                end else begin
                    step_timer <= step_timer + 16'd1;
                end

                if (sfx_left != 16'd0)
                    sfx_left <= sfx_left - 16'd1;

                if (pending_event != EVT_NONE) begin
                    case (pending_event)
                        EVT_SHOT:  begin sfx_rom_addr <= SFX_SHOT_START;  sfx_rom_left <= SFX_SHOT_LEN;  sfx_rom_div <= 0; sfx_left <= 16'hffff; sfx_rom_mode <= 1'b1; sfx_rom_boost <= 1'b0; sfx_noise_mode <= 1'b0; end
                        EVT_LASER: begin sfx_rom_addr <= SFX_LASER_START; sfx_rom_left <= SFX_LASER_LEN; sfx_rom_div <= 0; sfx_left <= 16'hffff; sfx_rom_mode <= 1'b1; sfx_rom_boost <= 1'b1; sfx_noise_mode <= 1'b0; end
                        EVT_KILL:  begin sfx_rom_addr <= SFX_KILL_START;  sfx_rom_left <= SFX_KILL_LEN;  sfx_rom_div <= 0; sfx_left <= 16'hffff; sfx_rom_mode <= 1'b1; sfx_rom_boost <= 1'b1; sfx_noise_mode <= 1'b0; end
                        EVT_BOSS:  begin sfx_rom_addr <= SFX_BOSS_START;  sfx_rom_left <= SFX_BOSS_LEN;  sfx_rom_div <= 0; sfx_left <= 16'hffff; sfx_rom_mode <= 1'b1; sfx_rom_boost <= 1'b1; sfx_noise_mode <= 1'b0; end
                        EVT_HIT:   begin sfx_rom_addr <= SFX_HIT_START;   sfx_rom_left <= SFX_HIT_LEN;   sfx_rom_div <= 0; sfx_left <= 16'hffff; sfx_rom_mode <= 1'b1; sfx_rom_boost <= 1'b1; sfx_noise_mode <= 1'b0; end
                        default:   begin sfx_inc <= 24'd0; sfx_left <= 16'd0; sfx_rom_mode <= 1'b0; sfx_rom_boost <= 1'b0; sfx_noise_mode <= 1'b0; end
                    endcase
                    sfx_phase <= 24'd0;
                    pending_event <= EVT_NONE;
                end
            end
        end
    end
endmodule

