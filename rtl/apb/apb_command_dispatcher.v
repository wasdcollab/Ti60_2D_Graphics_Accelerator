`timescale 1ns/1ps
// =============================================================================
// apb_command_dispatcher.v
// -----------------------------------------------------------------------------
// Central command and configuration dispatcher for Sapphire RISC-V SoC APB3 bus.
//
// Triad Architecture Role: "Central Military Command" (rtl/apb/)
// - Address 0x00 ~ 0x6C: Decodes pure 2D BitBlt commands (bitblt_cmd_* bus)
//   and double-buffering / gamepad / status registers.
// - Address 0x70 ~ 0xFC: Decodes pure display / effect commands (display_cfg_* bus)
//   such as weather, occlusion box, laser, beam, hairlines, bullet buckets,
//   color matrix, and bloom filter.
// - Hardware validation of command dimensions, strides, and pixel alignments.
// - Status and diagnostic telemetry readback.
// =============================================================================

module apb_command_dispatcher #(
    parameter CLOCK_HZ = 100_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cal_done,

    // APB3 Slave Interface (from Sapphire SoC io_apbSlave_0)
    input  wire [15:0] apb_paddr,
    input  wire        apb_psel,
    input  wire        apb_penable,
    input  wire        apb_pwrite,
    input  wire [31:0] apb_pwdata,
    output reg  [31:0] apb_prdata,
    output wire        apb_pready,
    output wire        apb_pslverr,

    // -------------------------------------------------------------------------
    // Pure 2D BitBlt Command Bus (bitblt_cmd_* -> rtl/bitblt/)
    // -------------------------------------------------------------------------
    output reg         cmd_start,
    output reg  [1:0]  cmd_op_type,      // 0: OP_FILL, 1: OP_COPY, 2: OP_ALPHA, 3: OP_ADD
    output reg  [27:0] cmd_dst_addr,
    output reg  [27:0] cmd_src_addr,
    output reg  [10:0] cmd_rect_w,
    output reg  [10:0] cmd_rect_h,
    output reg  [31:0] cmd_color,
    output reg  [15:0] cmd_src_stride,
    output reg  [15:0] cmd_dst_stride,
    output reg         cmd_colorkey_en,
    output reg  [31:0] cmd_colorkey_val,
    output reg         cmd_alpha_en,
    output reg  [7:0]  cmd_global_alpha,
    input  wire        cmd_busy,
    input  wire        engine_timeout,

    // BitBlt Live Engine Diagnostic Probe
    input  wire [3:0]  diag_rd_q_cnt,
    input  wire        diag_rd_ar_pend,
    input  wire [1:0]  diag_sg_state,

    // -------------------------------------------------------------------------
    // Double-Buffer Control & Frame Telemetry (rtl/dma/ & rtl/display_engine/)
    // -------------------------------------------------------------------------
    output reg  [27:0] vdma_next_base,
    output reg  [27:0] vdma_right_next_base,
    input  wire [27:0] vdma_active_base,
    input  wire [27:0] vdma_right_active_base,
    output reg  [7:0]  cpu_fps_bcd,
    output reg  [7:0]  fpga_fps_bcd,
    input  wire [31:0] scan_diagnostics,
    input  wire        vsync_flag,

    // -------------------------------------------------------------------------
    // Gamepad & Board Keys Interface (u_i2c_gamepad)
    // -------------------------------------------------------------------------
    input  wire [7:0]  gamepad_joy_x,
    input  wire [7:0]  gamepad_joy_y,
    input  wire [4:0]  gamepad_buttons,
    input  wire        gamepad_online,
    input  wire        key_sw0_level,
    input  wire        key_sw2_level,
    input  wire        key_sw0_pulse,
    input  wire        key_sw2_pulse,
    output wire [6:0]  i2c_slave_addr,
    output wire        force_hud_disable,

    // -------------------------------------------------------------------------
    // Pure Display / Effect Configuration Bus (display_cfg_* -> rtl/display_engine/ & rtl/dma/)
    // -------------------------------------------------------------------------
    output reg  [31:0] weather_ctrl,
    output reg  [31:0] weather_mask_x,
    output reg  [31:0] weather_mask_y,
    output reg  [23:0] laser_colx_lo,
    output reg  [23:0] laser_colx_hi,
    output wire [47:0] laser_colx,
    output reg  [11:0] beam_x,
    output reg  [11:0] beam_len,
    output reg         beam_en,
    output reg  [35:0] hair_x,
    output reg  [71:0] hair_out,
    output reg  [71:0] hair_lft,
    output reg  [71:0] hair_mid,

    // Procedural impact rings, bank 2 (0x200..0x22F).  Four slots, three words
    // each; see rtl/display_engine/2_layer_generators/video_fx_ring.v for the
    // field packing and sw/driver/gpu2d.h for the byte offsets.
    output wire [127:0] fx_a,
    output wire [127:0] fx_b,
    output wire [127:0] fx_c,

    // Bullet Bucket Table & Tile Store Write Port
    output reg  [27:0] bucket_base,
    output reg  [14:0] btile_addr,
    output reg  [7:0]  btile_data,
    output reg         btile_we,
    output reg  [31:0] bpal_data,
    output reg  [7:0]  bpal_addr,
    output reg         bpal_we,

    // Video Post-Processing Controls
    output reg  [31:0] color_matrix_ctrl,
    output reg  [31:0] bloom_ctrl,

    // APB 0x4C: bits [3:0] issue a one-shot event, bit 8 enables output,
    // bit 9 enables the procedural BGM.
    output reg  [31:0] audio_ctrl,
    output reg         audio_event_strobe,
    output reg         pcm_enabled,
    output reg         pcm_clear,
    output reg         pcm_write,
    output reg [7:0]   pcm_data,
    input wire [31:0]  pcm_status,
    input wire [31:0]  pcm_underflows,
    input wire [31:0]  pcm_played,
    output reg flash_start, flash_cs_n,
    output reg [7:0] flash_tx,
    input wire flash_busy,
    input wire [7:0] flash_rx,
    output reg bucket_start, bucket_clear_req, bucket_motion_en, bucket_buffer_sel,
    output reg [9:0] bucket_pb_count,
    output reg [14:0] bucket_eb_count,
    output reg [31:0] bucket_player_xy,
    input wire bucket_busy, bucket_done, bucket_fault,
    input wire [15:0] bucket_drop_count, bucket_eb_live, bucket_eb_cand,
    input wire [31:0] bucket_cycles,
    input wire [31:0] bucket_debug,
    input wire [11:0] bucket_pool_drop,
    output reg hb_we,
    output reg [7:0] hb_val
);

    // -------------------------------------------------------------------------
    // Impact ring slots (bank 2).  One flat register per word, gathered into
    // the three 128-bit buses the scanout takes: slot 0 in bits [31:0].
    // -------------------------------------------------------------------------
    reg [31:0] fx_a0, fx_a1, fx_a2, fx_a3;
    reg [31:0] fx_b0, fx_b1, fx_b2, fx_b3;
    reg [31:0] fx_c0, fx_c1, fx_c2, fx_c3;
    assign fx_a = {fx_a3, fx_a2, fx_a1, fx_a0};
    assign fx_b = {fx_b3, fx_b2, fx_b1, fx_b0};
    assign fx_c = {fx_c3, fx_c2, fx_c1, fx_c0};

    assign laser_colx = {laser_colx_hi, laser_colx_lo};
    wire [16:0] bucket_drop_sum={1'b0,bucket_drop_count}+{5'd0,bucket_pool_drop};
    wire [15:0] bucket_drop_word=bucket_drop_sum[16] ? 16'hffff : bucket_drop_sum[15:0];

    // VSync event latch for software polling
    reg vsync_seen;
    reg busy_d;
    reg done_seen;
    reg [31:0] reg_i2c_cfg;
    reg sw0_latched, sw2_latched;
    reg [31:0] second_ticks, cpu_frames, fpga_frames;
    reg [7:0] cpu_count, fpga_count;
    reg [27:0] left_previous, right_previous;
    reg cfg_error_sticky;
    reg timeout_sticky;
    reg [31:0] diag_reg;

    // Stall snapshot registers (diagnostics)
    reg [31:0] snp_worst_cyc;
    reg [31:0] snp_op, snp_w, snp_h, snp_src, snp_dst;
    reg [31:0] snp_probe;
    reg [31:0] snp_count;
    reg [31:0] snp_cyc;
    localparam [31:0] SNAP_LIMIT = 32'd100000;   // 1 ms: pathological
    wire [31:0] snp_next = snp_cyc + 32'd1;

    // Asset ROM window (0x80 / 0x84)
    reg  [13:0] asset_addr;
    wire [7:0]  asset_data;

    bitblt_asset_rom u_asset_rom (
        .clk  (clk),
        .addr (asset_addr),
        .dout (asset_data)
    );

    wire left_swap  = (vdma_active_base != left_previous);
    wire right_swap = (vdma_right_active_base != right_previous);

    // Command validation
    wire pixel_aligned = (cmd_src_addr[1:0] == 2'd0) && (cmd_dst_addr[1:0] == 2'd0);
    wire needs_pixel_align = (cmd_op_type == 2'd2) || (cmd_op_type == 2'd3) ||
                             (cmd_colorkey_en && (cmd_op_type == 2'd1));

    wire cfg_bad = (cmd_rect_w != 11'd0) && (cmd_rect_h != 11'd0) &&
                   ((cmd_rect_w > 11'd1366) ||
                    (cmd_rect_h > 11'd768) ||
                    (cmd_dst_stride[3:0] != 4'd0) ||
                    ((cmd_op_type != 2'd0) && (cmd_src_stride[3:0] != 4'd0)) ||
                    ((cmd_op_type == 2'd2) && !cmd_alpha_en) ||
                    (needs_pixel_align && !pixel_aligned));

    function [7:0] increment_bcd;
        input [7:0] value;
        begin
            if (value == 8'h99) increment_bcd = value;
            else if (value[3:0] == 9) increment_bcd = {value[7:4] + 4'd1, 4'd0};
            else increment_bcd = value + 8'd1;
        end
    endfunction

    // Count presented half-frames & compute BCD FPS
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            second_ticks   <= 32'd0;
            cpu_frames     <= 32'd0;
            fpga_frames    <= 32'd0;
            cpu_count      <= 8'd0;
            fpga_count     <= 8'd0;
            cpu_fps_bcd    <= 8'd0;
            fpga_fps_bcd   <= 8'd0;
            left_previous  <= 28'h1000000;
            right_previous <= 28'h1000000;
        end else begin
            left_previous  <= vdma_active_base;
            right_previous <= vdma_right_active_base;
            if (left_swap)  cpu_frames  <= cpu_frames + 1'b1;
            if (right_swap) fpga_frames <= fpga_frames + 1'b1;
            if (second_ticks == CLOCK_HZ - 1) begin
                second_ticks <= 32'd0;
                cpu_fps_bcd  <= left_swap ? increment_bcd(cpu_count) : cpu_count;
                fpga_fps_bcd <= right_swap ? increment_bcd(fpga_count) : fpga_count;
                cpu_count    <= 8'd0;
                fpga_count   <= 8'd0;
            end else begin
                second_ticks <= second_ticks + 1'b1;
                if (left_swap)  cpu_count  <= increment_bcd(cpu_count);
                if (right_swap) fpga_count <= increment_bcd(fpga_count);
            end
        end
    end

    assign apb_pready  = 1'b1;
    assign apb_pslverr = 1'b0;

    wire apb_write = apb_psel & apb_penable & apb_pwrite;

    reg [14:0] btile_ptr;
    reg [7:0]  bpal_ptr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_start            <= 1'b0;
            cmd_op_type          <= 2'd0;
            cmd_dst_addr         <= 28'd0;
            cmd_src_addr         <= 28'd0;
            cmd_rect_w           <= 11'd0;
            cmd_rect_h           <= 11'd0;
            cmd_color            <= 32'd0;
            cmd_src_stride       <= 16'd4096;
            cmd_dst_stride       <= 16'd4096;
            cmd_colorkey_en      <= 1'b0;
            cmd_colorkey_val     <= 32'h00FF00FF;
            cmd_alpha_en         <= 1'b0;
            cmd_global_alpha     <= 8'hFF;
            vdma_next_base       <= 28'h080_0000;
            vdma_right_next_base <= 28'h080_0000;
            vsync_seen           <= 1'b0;
            busy_d               <= 1'b0;
            done_seen            <= 1'b0;
            cfg_error_sticky     <= 1'b0;
            timeout_sticky       <= 1'b0;
            reg_i2c_cfg          <= 32'h0001_005A; // [6:0]=7'h5A, [16]=1 (auto_poll)
            sw0_latched          <= 1'b0;
            sw2_latched          <= 1'b0;
            diag_reg             <= 32'd0;
            snp_worst_cyc        <= 32'd0;
            snp_op               <= 32'd0;
            snp_w                <= 32'd0;
            snp_h                <= 32'd0;
            snp_src              <= 32'd0;
            snp_dst              <= 32'd0;
            snp_probe            <= 32'd0;
            snp_count            <= 32'd0;
            snp_cyc              <= 32'd0;
            weather_ctrl         <= 32'd0;
            weather_mask_x       <= 32'd0;
            weather_mask_y       <= 32'd0;
            laser_colx_lo        <= 24'd0;
            laser_colx_hi        <= 24'd0;
            beam_x               <= 12'd0;
            beam_len             <= 12'd0;
            beam_en              <= 1'b0;
            hair_x               <= 36'd0;
            hair_out             <= 72'd0;
            hair_lft             <= 72'd0;
            hair_mid             <= 72'd0;
            fx_a0 <= 32'd0; fx_a1 <= 32'd0; fx_a2 <= 32'd0; fx_a3 <= 32'd0;
            fx_b0 <= 32'd0; fx_b1 <= 32'd0; fx_b2 <= 32'd0; fx_b3 <= 32'd0;
            fx_c0 <= 32'd0; fx_c1 <= 32'd0; fx_c2 <= 32'd0; fx_c3 <= 32'd0;
            bucket_base          <= 28'd0;
            btile_addr           <= 15'd0;
            btile_data           <= 8'd0;
            btile_we             <= 1'b0;
            bpal_data            <= 32'd0;
            bpal_addr            <= 8'd0;
            bpal_we              <= 1'b0;
            btile_ptr            <= 15'd0;
            bpal_ptr             <= 8'd0;
            asset_addr           <= 14'd0;
            color_matrix_ctrl    <= 32'd0;
            bloom_ctrl           <= 32'd0;
            audio_ctrl           <= 32'h0000_3300;
            audio_event_strobe   <= 1'b0;
            pcm_enabled <= 1'b0;
            pcm_clear <= 1'b0;
            pcm_write <= 1'b0;
            pcm_data <= 8'd0;
            flash_start <= 1'b0;
            flash_cs_n <= 1'b1;
            flash_tx <= 8'd0;
            bucket_start         <= 1'b0;
            bucket_clear_req     <= 1'b0;
            bucket_motion_en     <= 1'b0;
            bucket_buffer_sel    <= 1'b0;
            bucket_pb_count      <= 10'd0;
            bucket_eb_count      <= 15'd0;
            bucket_player_xy     <= 32'h0200_02AB;
            hb_we                <= 1'b0;
            hb_val               <= 8'd0;
        end else begin
            btile_we <= 1'b0;
            bpal_we  <= 1'b0;
            audio_event_strobe <= 1'b0;
            pcm_clear <= 1'b0;
            pcm_write <= 1'b0;
            bucket_start <= 1'b0;
            flash_start <= 1'b0;
            if (apb_write && apb_paddr == 16'h013C && !flash_busy && !flash_start) begin
                flash_start <= 1'b1;
                flash_tx <= apb_pwdata[7:0];
            end
            if (apb_write && apb_paddr == 16'h0140) flash_cs_n <= apb_pwdata[0];
            bucket_clear_req <= 1'b0;
            hb_we <= 1'b0;
            if (apb_write && apb_paddr == 16'h0100) begin
                pcm_enabled <= apb_pwdata[0];
                pcm_clear <= apb_pwdata[1];
            end
            if (apb_write && apb_paddr == 16'h0104) begin
                pcm_write <= 1'b1;
                pcm_data <= apb_pwdata[7:0];
            end
            if (apb_write && apb_paddr == 16'h0120) begin
                bucket_start      <= apb_pwdata[31];
                bucket_clear_req  <= apb_pwdata[30];
                bucket_motion_en  <= apb_pwdata[29];
                bucket_buffer_sel <= apb_pwdata[0];
                bucket_pb_count   <= apb_pwdata[13:4];
                // count[14:13] lives in [15:14]; count[12:0] lives in [28:16].
                // Bit 29 stays motion and [13:4] stays the player-bullet count.
                bucket_eb_count   <= {apb_pwdata[15:14],apb_pwdata[28:16]};
            end
            if (apb_write && apb_paddr == 16'h0124) begin
                bucket_player_xy  <= apb_pwdata;
            end
            // One APB transaction publishes a full frame. Independent 0x20/0x40
            // writes remain available for the split-screen renderer benchmark.
            if (apb_write && apb_paddr == 16'h0134) begin
                vdma_next_base       <= apb_pwdata[27:0];
                vdma_right_next_base <= apb_pwdata[27:0];
            end
            // CPU heartbeat: one write per main-loop pass, low byte = stage.
            // See rtl/common/diag_uart_hb.v - when these stop arriving the
            // fabric takes the UART TX pin over and reports for itself.
            if (apb_write && apb_paddr == 16'h0130) begin
                hb_we  <= 1'b1;
                hb_val <= apb_pwdata[7:0];
            end
            diag_reg <= {20'd0, diag_sg_state, 4'd0, diag_rd_ar_pend, diag_rd_q_cnt};
            if (cmd_start) snp_cyc <= 32'd0;
            else if (cmd_busy && !cmd_start) snp_cyc <= snp_next;

            busy_d <= cmd_busy;
            if (busy_d && !cmd_busy) begin
                done_seen <= 1'b1;
                if ((snp_cyc > SNAP_LIMIT) && (snp_cyc > snp_worst_cyc)) begin
                    snp_worst_cyc <= snp_cyc;
                    snp_op        <= {30'd0, cmd_op_type};
                    snp_w         <= {21'd0, cmd_rect_w};
                    snp_h         <= {21'd0, cmd_rect_h};
                    snp_src       <= cmd_src_addr;
                    snp_dst       <= cmd_dst_addr;
                    snp_probe     <= {20'd0, diag_sg_state, 4'd0, diag_rd_ar_pend, diag_rd_q_cnt};
                    snp_count     <= snp_count + 32'd1;
                end
            end
            if (engine_timeout)
                timeout_sticky <= 1'b1;
            cmd_start <= 1'b0;
            if (apb_psel && apb_penable && !apb_pwrite && (apb_paddr == 16'h0024))
                vsync_seen <= vsync_flag;
            else if (vsync_flag)
                vsync_seen <= 1'b1;

            if (key_sw0_pulse) sw0_latched <= 1'b1;
            if (key_sw2_pulse) sw2_latched <= 1'b1;
            if (apb_psel && apb_penable && !apb_pwrite && (apb_paddr == 16'h0058)) begin
                sw0_latched <= 1'b0;
                sw2_latched <= 1'b0;
            end

            // Bank 2: procedural impact ring slots (0x200..0x23F).  Four slots
            // at a 16-byte stride: +0 word A, +4 word B, +8 word C.
            if (apb_write && apb_paddr[15:8] == 8'd2) begin
                case (apb_paddr[7:0])
                    8'h00: fx_a0 <= apb_pwdata;
                    8'h04: fx_b0 <= apb_pwdata;
                    8'h08: fx_c0 <= apb_pwdata;
                    8'h10: fx_a1 <= apb_pwdata;
                    8'h14: fx_b1 <= apb_pwdata;
                    8'h18: fx_c1 <= apb_pwdata;
                    8'h20: fx_a2 <= apb_pwdata;
                    8'h24: fx_b2 <= apb_pwdata;
                    8'h28: fx_c2 <= apb_pwdata;
                    8'h30: fx_a3 <= apb_pwdata;
                    8'h34: fx_b3 <= apb_pwdata;
                    8'h38: fx_c3 <= apb_pwdata;
                    default: ;
                endcase
            end

            if (apb_write && apb_paddr[15:8] == 8'd0) begin
                case (apb_paddr[7:0])
                    8'h04: cmd_dst_addr <= apb_pwdata[27:0];
                    8'h08: cmd_rect_w <= apb_pwdata[10:0];
                    8'h0C: cmd_rect_h <= apb_pwdata[10:0];
                    8'h10: cmd_color <= apb_pwdata;
                    8'h14: begin
                        if (apb_pwdata[0] && !cmd_busy && !cmd_start) begin
                            cfg_error_sticky <= cfg_bad;
                            timeout_sticky   <= 1'b0;
                            if (cfg_bad || cmd_rect_w == 11'd0 || cmd_rect_h == 11'd0) begin
                                done_seen <= 1'b1;
                            end else begin
                                cmd_start <= 1'b1;
                                done_seen <= 1'b0;
                            end
                        end
                    end
                    8'h18: cmd_op_type <= apb_pwdata[1:0];
                    8'h1C: cmd_src_addr <= apb_pwdata[27:0];
                    8'h20: vdma_next_base <= apb_pwdata[27:0];
                    8'h30: cmd_src_stride <= apb_pwdata[15:0];
                    8'h40: vdma_right_next_base <= apb_pwdata[27:0];
                    8'h48: cmd_dst_stride <= apb_pwdata[15:0];
                    8'h4C: begin
                        audio_ctrl <= apb_pwdata;
                        audio_event_strobe <= (apb_pwdata[3:0] != 4'd0);
                    end
                    8'h5C: reg_i2c_cfg <= apb_pwdata;
                    8'h60: cmd_colorkey_val <= apb_pwdata;
                    8'h64: cmd_colorkey_en <= apb_pwdata[0];
                    8'h68: cmd_alpha_en <= apb_pwdata[0];
                    8'h6C: cmd_global_alpha <= apb_pwdata[7:0];
                    8'h78: weather_ctrl      <= apb_pwdata[31:0];
                    8'h7C: color_matrix_ctrl <= apb_pwdata[31:0];
                    8'h80: asset_addr        <= apb_pwdata[13:0];
                    8'h88: bloom_ctrl        <= apb_pwdata[31:0];
                    8'h8C: weather_mask_x    <= apb_pwdata[31:0];
                    8'hAC: weather_mask_y    <= apb_pwdata[31:0];
                    8'hB0: laser_colx_lo     <= apb_pwdata[23:0];
                    8'hB4: laser_colx_hi     <= apb_pwdata[23:0];
                    8'hB8: beam_x            <= apb_pwdata[11:0];
                    8'hBC: begin
                        beam_len <= apb_pwdata[10:0];
                        beam_en  <= apb_pwdata[11];
                    end
                    8'hC0: hair_x[11:0]      <= apb_pwdata[11:0];
                    8'hC4: hair_out[23:0]    <= apb_pwdata[23:0];
                    8'hC8: hair_lft[23:0]    <= apb_pwdata[23:0];
                    8'hCC: hair_mid[23:0]    <= apb_pwdata[23:0];
                    8'hD0: hair_x[23:12]     <= apb_pwdata[11:0];
                    8'hD4: hair_out[47:24]   <= apb_pwdata[23:0];
                    8'hD8: hair_lft[47:24]   <= apb_pwdata[23:0];
                    8'hDC: hair_mid[47:24]   <= apb_pwdata[23:0];
                    8'hE0: hair_x[35:24]     <= apb_pwdata[11:0];
                    8'hE4: hair_out[71:48]   <= apb_pwdata[23:0];
                    8'hE8: hair_lft[71:48]   <= apb_pwdata[23:0];
                    8'hEC: hair_mid[71:48]   <= apb_pwdata[23:0];
                    8'hF0: bucket_base       <= apb_pwdata[27:0];
                    8'hF4: btile_ptr         <= apb_pwdata[14:0];
                    8'hF8: begin
                        btile_addr <= btile_ptr;
                        btile_data <= apb_pwdata[7:0];
                        btile_we   <= 1'b1;
                        btile_ptr  <= btile_ptr + 15'd1;
                    end
                    8'hFC: begin
                        bpal_addr <= bpal_ptr;
                        bpal_data <= apb_pwdata[31:0];
                        bpal_we   <= 1'b1;
                        bpal_ptr  <= bpal_ptr + 8'd1;
                    end
                    default: ;
                endcase
            end
        end
    end

    assign i2c_slave_addr = reg_i2c_cfg[6:0];
    assign force_hud_disable = reg_i2c_cfg[20];

    always @(*) begin
        apb_prdata = 32'd0;
        if (apb_psel && !apb_pwrite && apb_paddr[15:8] == 8'd0) begin
            case (apb_paddr[7:0])
                8'h00: apb_prdata = {27'd0, cal_done, timeout_sticky, cfg_error_sticky,
                                     done_seen, (cmd_busy | cmd_start)};
                8'h04: apb_prdata = {4'd0, cmd_dst_addr};
                8'h08: apb_prdata = {21'd0, cmd_rect_w};
                8'h0C: apb_prdata = {21'd0, cmd_rect_h};
                8'h10: apb_prdata = cmd_color;
                8'h18: apb_prdata = {30'd0, cmd_op_type};
                8'h1C: apb_prdata = {4'd0, cmd_src_addr};
                8'h20: apb_prdata = {4'd0, vdma_next_base};
                8'h24: apb_prdata = {31'd0, (vsync_seen | vsync_flag)};
                8'h28: apb_prdata = {4'd0, vdma_active_base};
                8'h2C: apb_prdata = {4'd0, vdma_right_active_base};
                8'h30: apb_prdata = {16'd0, cmd_src_stride};
                8'h34: apb_prdata = {16'd0, fpga_fps_bcd, cpu_fps_bcd};
                8'h38: apb_prdata = cpu_frames;
                8'h3C: apb_prdata = fpga_frames;
                8'h40: apb_prdata = {4'd0, vdma_right_next_base};
                8'h44: apb_prdata = scan_diagnostics;
                8'h48: apb_prdata = {16'd0, cmd_dst_stride};
                8'h4C: apb_prdata = audio_ctrl;
                8'h50: apb_prdata = {16'd0, gamepad_joy_y, gamepad_joy_x};
                8'h54: apb_prdata = {15'd0, gamepad_online, 11'd0, gamepad_buttons};
                8'h58: apb_prdata = {22'd0, sw2_latched, sw0_latched, 6'd0, key_sw2_level, key_sw0_level};
                8'h5C: apb_prdata = reg_i2c_cfg;
                8'h60: apb_prdata = cmd_colorkey_val;
                8'h64: apb_prdata = {31'd0, cmd_colorkey_en};
                8'h68: apb_prdata = {31'd0, cmd_alpha_en};
                8'h6C: apb_prdata = {24'd0, cmd_global_alpha};
                8'h70: apb_prdata = second_ticks;
                8'h74: apb_prdata = diag_reg;
                8'h78: apb_prdata = weather_ctrl;
                8'h7C: apb_prdata = color_matrix_ctrl;
                8'h80: apb_prdata = {18'd0, asset_addr};
                8'h84: apb_prdata = {24'd0, asset_data};
                8'h88: apb_prdata = bloom_ctrl;
                8'h8C: apb_prdata = weather_mask_x;
                8'hAC: apb_prdata = weather_mask_y;
                8'h90: apb_prdata = snp_worst_cyc;
                8'h94: apb_prdata = snp_count;
                8'h98: apb_prdata = snp_op;
                8'h9C: apb_prdata = (snp_w << 16) | (snp_h & 16'hFFFF);
                8'hA0: apb_prdata = snp_src;
                8'hA4: apb_prdata = snp_dst;
                8'hA8: apb_prdata = snp_probe;
                8'hB0: apb_prdata = {8'd0, laser_colx_lo};
                8'hB4: apb_prdata = {8'd0, laser_colx_hi};
                8'hB8: apb_prdata = {20'd0, beam_x};
                8'hBC: apb_prdata = {20'd0, beam_en, beam_len[10:0]};
                8'hC0: apb_prdata = {20'd0, hair_x[11:0]};
                8'hC4: apb_prdata = hair_out[23:0];
                8'hC8: apb_prdata = hair_lft[23:0];
                8'hCC: apb_prdata = hair_mid[23:0];
                8'hD0: apb_prdata = {20'd0, hair_x[23:12]};
                8'hD4: apb_prdata = hair_out[47:24];
                8'hD8: apb_prdata = hair_lft[47:24];
                8'hDC: apb_prdata = hair_mid[47:24];
                8'hE0: apb_prdata = {20'd0, hair_x[35:24]};
                8'hE4: apb_prdata = hair_out[71:48];
                8'hE8: apb_prdata = hair_lft[71:48];
                8'hEC: apb_prdata = hair_mid[71:48];
                8'hF0: apb_prdata = {4'd0, bucket_base};
                8'hF4: apb_prdata = {17'd0, btile_ptr};
                default: apb_prdata = 32'd0;
            endcase
        end
        if (apb_psel && !apb_pwrite && apb_paddr[15:8] == 8'd2) begin
            case (apb_paddr[7:0])
                8'h00: apb_prdata = fx_a0;
                8'h04: apb_prdata = fx_b0;
                8'h08: apb_prdata = fx_c0;
                8'h10: apb_prdata = fx_a1;
                8'h14: apb_prdata = fx_b1;
                8'h18: apb_prdata = fx_c1;
                8'h20: apb_prdata = fx_a2;
                8'h24: apb_prdata = fx_b2;
                8'h28: apb_prdata = fx_c2;
                8'h30: apb_prdata = fx_a3;
                8'h34: apb_prdata = fx_b3;
                8'h38: apb_prdata = fx_c3;
                default: apb_prdata = 32'd0;
            endcase
        end
        if (apb_psel && !apb_pwrite && apb_paddr[15:8] == 8'd1) begin
            case (apb_paddr[7:0])
                8'h00: apb_prdata = {31'd0, pcm_enabled};
                8'h08: apb_prdata = pcm_status;
                8'h0C: apb_prdata = pcm_underflows;
                8'h10: apb_prdata = pcm_played;
                8'h20: apb_prdata = {(bucket_busy | bucket_start), bucket_done, 1'b1, bucket_fault, 12'd0, bucket_drop_word};
                8'h24: apb_prdata = bucket_player_xy;
                8'h28: apb_prdata = {bucket_eb_cand,bucket_eb_live};
                8'h2C: apb_prdata = bucket_cycles;
                8'h38: apb_prdata = bucket_debug;
                8'h3C: apb_prdata = {23'd0, (flash_busy | flash_start), flash_rx};
                8'h40: apb_prdata = {31'd0, flash_cs_n};
                default: apb_prdata = 32'd0;
            endcase
        end
    end

endmodule
