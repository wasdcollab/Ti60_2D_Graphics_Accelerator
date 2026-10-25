`timescale 1ns/1ps
// =============================================================================
// bitblt_apb_regs  (v3)
// -----------------------------------------------------------------------------
// APB3 register file for the 2D BitBlt accelerator.
//
// Changes against v2:
//   * OP_ALPHA (2) is now a legal opcode, and the register file owns its
//     configuration: 0x68 ALPHA_CTRL (bit0 = enable) and 0x6C GLOBAL_ALPHA
//     (8'hFF = use the source pixel alpha unchanged, the reset value).
//   * the validation grew the alpha rules: OP_ALPHA with blending disabled is
//     a configuration error, and any command that blends or colour keys must
//     have both addresses on a 32-bit pixel boundary, because the per-pixel
//     strobe mask is built from whole pixels.
//
// Changes against v1 (kept):
//   * configuration validation.  v1 forwarded whatever the CPU wrote, so a
//     stride that is not a multiple of 16 bytes produced a silently corrupted
//     image, and an illegal rectangle could leave the engine spinning while the
//     driver waited for DONE forever.  START now validates the command; an
//     illegal one raises a sticky error bit, reports DONE immediately (so the
//     CPU can never hang) and never touches the bus.
//   * STATUS gains bit2 (configuration error) and bit3 (engine watchdog
//     timeout).
// =============================================================================
module bitblt_apb_regs #(parameter CLOCK_HZ = 100000000) (
    input  wire        clk,
    input  wire        rst_n,
    // APB Slave Interface
    input  wire [15:0] apb_paddr,
    input  wire        apb_psel,
    input  wire        apb_penable,
    input  wire        apb_pwrite,
    input  wire [31:0] apb_pwdata,
    output reg  [31:0] apb_prdata,
    output wire        apb_pready,
    output wire        apb_pslverr,

    // Command interface to stride_gen
    output reg         cmd_start,
    output reg  [1:0]  cmd_op_type,      // 0: OP_FILL, 1: OP_COPY, 2: OP_ALPHA
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

    // Double-buffer control
    output reg  [27:0] vdma_next_base,
    input  wire [27:0] vdma_active_base,
    input  wire [27:0] vdma_right_active_base,
    output reg  [27:0] vdma_right_next_base,
    output reg  [7:0]  cpu_fps_bcd,
    output reg  [7:0]  fpga_fps_bcd,
    input  wire [31:0] scan_diagnostics,
    input  wire        vsync_flag,

    // Gamepad & Board Keys Interface
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

    // -----------------------------------------------------------------------
    // LIVE ENGINE PROBE (read-only diagnostic, added 2026-09-23).
    //
    // These three inputs are layer-referenced up from the read master and the
    // stride generator inside bitblt_top.  They exist because the engine has an
    // intermittent failure that is invisible from the outside: the driver only
    // sees STATUS go busy and stay busy, which looks identical whether the cause
    // is a stuck write, a leaked read-burst credit, or a stranded request in the
    // read master's queue.  Exposing the counters themselves turns that into a
    // question with an answer.
    //
    // Read at 0x74, packed as
    //     [3:0]   rd_q_cnt   read master queue occupancy  (0..WQ, so 0..8)
    //     [4]     rd_ar_pend a request is staged on the AR channel
    //     [9:8]   sg_state   stride_gen state (0 idle, 2 = S_LOOP)
    //
    // [9:8], NOT [11:8]: the packing below is
    // {20'd0, diag_sg_state, 4'd0, diag_rd_ar_pend, diag_rd_q_cnt}, so the two
    // bits of state sit at 9:8 and this note used to name two bits too many.
    //
    // Healthy idle: 0x0000.  A queue count that stays non-zero while the engine
    // is idle is a stranded entry, and that alone can strand the engine forever
    // because the queue is cleared only by reset.
    input  wire [3:0]  diag_rd_q_cnt,
    input  wire        diag_rd_ar_pend,
    input  wire [1:0]  diag_sg_state,

    // Weather overlay control, forwarded to the scanout (added 2026-09-24).
    // Written at 0x78, packed as
    //     [15] enable, [14:13] stage, [12:8] scroll, [7:0] slide
    output reg  [31:0] weather_ctrl,

    // Weather occlusion box, forwarded to the scanout (Phase 2 task 04).
    // The pause card is painted into the framebuffer, i.e. UNDER the weather
    // layer, so the only way to keep snow off the menu text without emptying the
    // sky is to tell the scanline logic which rectangle to leave alone.  Written
    // at
    //     0x8C  mask_x: [10:0] x0, [21:11] x1, [31] enable (0 = no box)
    //     0xAC  mask_y: [10:0] y0, [21:11] y1
    // mask_x carries the enable so that clearing the box is a single write, and
    // so that a box is never live with a half-written y pair: firmware writes
    // y first and x (the enable) last.
    output reg  [31:0] weather_mask_x,
    output reg  [31:0] weather_mask_y,

    // Laser column centres, 2 x 12 bits each, written at
    //     0xB0  columns 0 and 1   {8'd0, x1[11:0], x0[11:0]}
    //     0xB4  columns 2 and 3   {8'd0, x3[11:0], x2[11:0]}
    // The scanout draws the columns itself (video_laser.v); what it cannot know
    // is WHERE they stand, and the cut/beam lasers move, so the firmware writes
    // the four centres whenever the set of standing columns changes.  A centre of
    // 0 parks that column off screen - the playfield starts at x = 181.
    output reg  [23:0] laser_colx_lo,
    output reg  [23:0] laser_colx_hi,

    // The player's beam and the cut/beam warning hairlines, forwarded to the
    // scanout (video_beam.v).  Written at
    //     0xB8  beam_x    [11:0] centre column
    //     0xBC  beam_ctrl [10:0] height, [11] enable
    //     0xC0 + 16k +  0  hair_x   [11:0] centre of slot k (0 = slot off)
    //     0xC0 + 16k +  4  hair_out [23:0] colour of columns hx-2 and hx+1
    //     0xC0 + 16k +  8  hair_lft [23:0] colour of column hx-1
    //     0xC0 + 16k + 12  hair_mid [23:0] colour of column hx
    // A colour of 0 draws nothing, which is how a slot that is not standing is
    // taken off the screen.  Three slots, twelve words, k = 0..2.
    output reg  [11:0] beam_x,
    output reg  [11:0] beam_len,
    output reg         beam_en,
    output reg  [35:0] hair_x,
    output reg  [71:0] hair_out,
    output reg  [71:0] hair_lft,
    output reg  [71:0] hair_mid,

    // ---- B1: the bullet bucket table and the tile store --------------------
    //     0xF0  bucket_base  [27:0] where the per-scanline bucket table lives
    //     0xF4  tile_addr    [13:0] tile store write pointer
    //     0xF8  tile_data    [7:0]  byte to write; the pointer advances by one
    //     0xFC  pal_data     [31:0] palette entry {alpha, rgb}; pointer advances
    // The two data registers auto-increment because the last four APB addresses
    // are all that is left and the store needs three of them anyway.  Boot walks
    // 14,192 bytes and then 256 palette entries through these two, once.
    // 14 address bits.  It was 15 before the colour split and 13 after it, and
    // it went back up one when the enemy bullet doubled its edge: 16 tiles at
    // 26x26 with a 32-byte row stride are 13,312 of the 14,192 bytes in use.
    output reg  [27:0] bucket_base,
    output reg  [13:0] btile_addr,
    output reg  [7:0]  btile_data,
    output reg         btile_we,
    // 32 bits since the scanout learned to alpha-blend the bullet curtain: the
    // top byte is the entry's opacity, and the tile's byte is a shape ROLE that
    // the scanout turns into an index with role + hue*32 - so this register is
    // still the one place a per-colour alpha can live.
    output reg  [31:0] bpal_data,
    output reg  [7:0]  bpal_addr,
    output reg         bpal_we,
    // Separate write pointers, because the strobe costs a cycle.  Which address
    // the store sees is NOT the same as where the firmware's pointer has got to:
    // see the 0xF8 case below.
    reg         [13:0] btile_ptr,
    reg         [7:0]  bpal_ptr,

    // Video stream 3x3 color matrix control (0x7C, Phase 1 Task 03).
    // Packed as [3:0] mode, [15:8] intensity
    output reg  [31:0] color_matrix_ctrl,

    // Video stream Bloom filter control (0x88, Phase 1 Task 05).
    // Packed as [0] enable, [15:8] threshold, [23:16] intensity
    output reg  [31:0] bloom_ctrl
);

    // Capture VSync as a sticky event so firmware cannot miss the short
    // vertical blanking pulse while polling over APB. A read of REG_VSYNC_STS
    // acknowledges the event.
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
    // Diagnostic mirror.  Registered rather than combinational because both
    // sources (the read master's queue pointers, stride_gen's state) live in
    // other clock domains of the design only in the sense of being separate
    // modules; they share clk, and registering here keeps the APB read mux from
    // reaching across module boundaries combinationally.
    reg [31:0] diag_reg;

    // ---- stall snapshot (read-only diagnostic, added 2026-09-25) ---------
    // The generator watchdog catches a command that never retires.  It does
    // NOT catch one that simply takes enormously long: the board showed a
    // frame running 51.3M cycles with a normal BitBlt workload, i.e. 27,359
    // cycles of wait per AXI round trip instead of 15.  These registers hold
    // the worst command seen so far, so the firmware can report WHICH one it
    // was and what the engine was doing - with no probe on the board.
    //
    // Purely observational: written from the command interface and the probe
    // inputs, read by nobody in the datapath.
    reg [31:0] snp_worst_cyc;
    reg [31:0] snp_op, snp_w, snp_h, snp_src, snp_dst;
    reg [31:0] snp_probe;
    reg [31:0] snp_count;
    reg [31:0] snp_cyc;
    localparam [31:0] SNAP_LIMIT = 32'd100000;   // 1 ms: pathological
    wire [31:0] snp_next = snp_cyc + 32'd1;

    // ---- asset ROM window (0x80 / 0x84) --------------------------------
    // The three stage backdrops are 12,313 bytes of RLE.  They used to be
    // .rodata -- part of the firmware image in the CPU's own 64 KiB, which had
    // 80 bytes left.  They now ride in the bitstream as this BRAM and are
    // copied to DDR once at boot, so the CPU reads them from DDR and its own
    // RAM is free for code.  Read-only, and it touches nothing else in the
    // engine: two unused addresses in a peripheral the BitBlt already owns.
    // See rtl/bitblt/bitblt_asset_rom.v for the two-access protocol.
    reg  [13:0] asset_addr;
    wire [7:0]  asset_data;

    bitblt_asset_rom u_asset_rom (
        .clk  (clk),
        .addr (asset_addr),
        .dout (asset_data)
    );

    wire left_swap = vdma_active_base != left_previous;
    wire right_swap = vdma_right_active_base != right_previous;

    // The video surface is 1366x768.  Keeping commands inside those dimensions
    // also prevents row_bytes (13 bits in stride_gen) and the row counter from
    // wrapping on malformed APB writes.  Opcodes 0/1/2 are implemented.
    // A copy whose strides are not a multiple of 16 bytes cannot be expressed
    // by 16-byte AXI beats; reject it instead of corrupting memory.
    //
    // Both Color Keying and alpha blending build a per-pixel byte-strobe mask,
    // so they additionally require the source and destination addresses to sit
    // on a 32-bit pixel boundary (otherwise a "pixel" would straddle two AXI
    // lanes).  OP_ALPHA also requires ALPHA_CTRL[0] to be set - an alpha
    // command with blending switched off is a configuration error, never a
    // silent plain copy.
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

    // Count actual newly presented half-frames
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            second_ticks <= 0;
            cpu_frames <= 0; fpga_frames <= 0;
            cpu_count <= 0; fpga_count <= 0;
            cpu_fps_bcd <= 0; fpga_fps_bcd <= 0;
            left_previous <= 28'h01000000;
            right_previous <= 28'h01000000;
        end else begin
            left_previous <= vdma_active_base;
            right_previous <= vdma_right_active_base;
            if (left_swap) cpu_frames <= cpu_frames + 1'b1;
            if (right_swap) fpga_frames <= fpga_frames + 1'b1;
            if (second_ticks == CLOCK_HZ - 1) begin
                second_ticks <= 0;
                cpu_fps_bcd <= left_swap ? increment_bcd(cpu_count) : cpu_count;
                fpga_fps_bcd <= right_swap ? increment_bcd(fpga_count) : fpga_count;
                cpu_count <= 0; fpga_count <= 0;
            end else begin
                second_ticks <= second_ticks + 1'b1;
                if (left_swap) cpu_count <= increment_bcd(cpu_count);
                if (right_swap) fpga_count <= increment_bcd(fpga_count);
            end
        end
    end

    assign apb_pready = 1'b1;
    assign apb_pslverr = 1'b0;

    wire apb_write = apb_psel & apb_penable & apb_pwrite;

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
            vdma_next_base       <= 28'h0080_0000;
            vdma_right_next_base <= 28'h0080_0000;
            vsync_seen           <= 1'b0;
            busy_d               <= 1'b0;
            done_seen            <= 1'b0;
            cfg_error_sticky     <= 1'b0;
            timeout_sticky       <= 1'b0;
            reg_i2c_cfg          <= 32'h0001_005A; // [6:0]=7'h5A (Mini-Joystick), [16]=1 (auto_poll)
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
            bucket_base          <= 28'd0;
            btile_addr           <= 14'd0;
            btile_data           <= 8'd0;
            btile_we             <= 1'b0;
            bpal_data            <= 24'd0;
            bpal_addr            <= 8'd0;
            bpal_we              <= 1'b0;
            btile_ptr            <= 14'd0;
            bpal_ptr             <= 8'd0;
            color_matrix_ctrl    <= 32'd0;
            bloom_ctrl           <= 32'd0;
            asset_addr           <= 14'd0;
        end else begin
            // One-cycle strobes, cleared every clock and set only by the write
            // that means them.  Without this the store would go on being written
            // forever after the first byte: the register would latch high and
            // the tile store would fill with copies of whatever came next.
            btile_we <= 1'b0;
            bpal_we  <= 1'b0;
            diag_reg <= {20'd0, diag_sg_state, 4'd0, diag_rd_ar_pend, diag_rd_q_cnt};
            if (cmd_start) snp_cyc <= 32'd0;
            else if (cmd_busy && !cmd_start) snp_cyc <= snp_next;

            busy_d <= cmd_busy;
            if (busy_d && !cmd_busy) begin
                done_seen <= 1'b1;
                // snapshot the command that just finished, if it was slow
                if ((snp_cyc > SNAP_LIMIT) && (snp_cyc > snp_worst_cyc)) begin
                    snp_worst_cyc <= snp_cyc;
                    snp_op        <= {30'd0, cmd_op_type};
                    snp_w        <= {21'd0, cmd_rect_w};
                    snp_h        <= {21'd0, cmd_rect_h};
                    snp_src      <= cmd_src_addr;
                    snp_dst      <= cmd_dst_addr;
                    snp_probe    <= {20'd0, diag_sg_state, 4'd0, diag_rd_ar_pend, diag_rd_q_cnt};
                    snp_count    <= snp_count + 32'd1;
                end
            end
            if (engine_timeout)
                timeout_sticky <= 1'b1;
            cmd_start <= 1'b0; // default to 0 for pulse
            if (vsync_flag)
                vsync_seen <= 1'b1;
            if (apb_psel && apb_penable && !apb_pwrite && (apb_paddr[7:0] == 8'h24))
                vsync_seen <= 1'b0;

            // Latch button press events; clear when 0x58 is read
            if (key_sw0_pulse) sw0_latched <= 1'b1;
            if (key_sw2_pulse) sw2_latched <= 1'b1;
            if (apb_psel && apb_penable && !apb_pwrite && (apb_paddr[7:0] == 8'h58)) begin
                sw0_latched <= 1'b0;
                sw2_latched <= 1'b0;
            end

            if (apb_write) begin
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
                                // Illegal or degenerate command: claim nothing
                                // was done, but report completion immediately so
                                // the driver's wait-for-idle always terminates.
                                // Starting the engine with height 0 would spin
                                // the row counter forever (the row is emitted
                                // before the "last row" test).
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
                    8'h5C: reg_i2c_cfg <= apb_pwdata;
                    8'h60: cmd_colorkey_val <= apb_pwdata;
                    8'h64: cmd_colorkey_en <= apb_pwdata[0];
                    8'h68: cmd_alpha_en <= apb_pwdata[0];
                    8'h6C: cmd_global_alpha <= apb_pwdata[7:0];
                    8'h78: weather_ctrl      <= apb_pwdata[31:0];
                    8'h7C: color_matrix_ctrl <= apb_pwdata[31:0];
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
                    8'hF4: btile_ptr         <= apb_pwdata[13:0];
                    // THE STORE SEES THE POINTER THE FIRMWARE MEANT, not the one
                    // it will have after this write.
                    //
                    // btile_we, btile_data and the increment are all registers, so
                    // they take effect together on the NEXT clock, while the data
                    // the store sees is the old one.  Incrementing here and
                    // letting the write land a cycle later therefore puts every
                    // byte one cell past where it belongs: the whole store shifts
                    // right by one byte, address 0 stays zero, every tile loses
                    // its first column to transparency and the art comes out a
                    // pixel sideways.  On the board that reads as a screenful of
                    // torn bullet tiles - and only of bullet tiles, because the
                    // beam and the laser columns do not come from this store.
                    //
                    // So the pointer is kept apart from the address the store is
                    // given: latch the pre-increment pointer into btile_addr at
                    // the same moment the strobe and the data are latched.
                    8'hF8: begin
                        btile_addr <= btile_ptr;
                        btile_data <= apb_pwdata[7:0];
                        btile_we   <= 1'b1;
                        btile_ptr  <= btile_ptr + 14'd1;
                    end
                    8'hFC: begin
                        bpal_addr <= bpal_ptr;
                        // All 32 bits, alpha byte included.  Truncating to 24
                        // would silently make every entry opaque, which is a
                        // failure that looks exactly like "the alpha feature
                        // does not work" rather than like a width bug.
                        bpal_data <= apb_pwdata[31:0];
                        bpal_we   <= 1'b1;
                        bpal_ptr  <= bpal_ptr + 8'd1;
                    end
                    8'h80: asset_addr        <= apb_pwdata[13:0];
                    8'h88: bloom_ctrl        <= apb_pwdata[31:0];
                    default: ;
                endcase
            end
        end
    end

    assign i2c_slave_addr = reg_i2c_cfg[6:0];
    assign force_hud_disable = reg_i2c_cfg[20];

    always @(*) begin
        apb_prdata = 32'd0;
        if (apb_psel && !apb_pwrite) begin
            case (apb_paddr[7:0])
                8'h00: apb_prdata = {28'd0, timeout_sticky, cfg_error_sticky,
                                     done_seen, (cmd_busy | cmd_start)};
                8'h04: apb_prdata = {4'd0, cmd_dst_addr};
                8'h08: apb_prdata = {21'd0, cmd_rect_w};
                8'h0C: apb_prdata = {21'd0, cmd_rect_h};
                8'h10: apb_prdata = cmd_color;
                8'h18: apb_prdata = {30'd0, cmd_op_type};
                8'h1C: apb_prdata = {4'd0, cmd_src_addr};
                8'h20: apb_prdata = {4'd0, vdma_next_base};
                8'h24: apb_prdata = {31'd0, vsync_seen};
                8'h28: apb_prdata = {4'd0, vdma_active_base};
                8'h2C: apb_prdata = {4'd0, vdma_right_active_base};
                8'h30: apb_prdata = {16'd0, cmd_src_stride};
                8'h34: apb_prdata = {16'd0, fpga_fps_bcd, cpu_fps_bcd};
                8'h38: apb_prdata = cpu_frames;
                8'h3C: apb_prdata = fpga_frames;
                8'h40: apb_prdata = {4'd0, vdma_right_next_base};
                8'h44: apb_prdata = scan_diagnostics;
                8'h48: apb_prdata = {16'd0, cmd_dst_stride};
                8'h50: apb_prdata = {16'd0, gamepad_joy_y, gamepad_joy_x};
                8'h54: apb_prdata = {15'd0, gamepad_online, 11'd0, gamepad_buttons};
                8'h58: apb_prdata = {22'd0, sw2_latched, sw0_latched, 6'd0, key_sw2_level, key_sw0_level};
                8'h5C: apb_prdata = reg_i2c_cfg;
                8'h60: apb_prdata = cmd_colorkey_val;
                8'h64: apb_prdata = {31'd0, cmd_colorkey_en};
                8'h68: apb_prdata = {31'd0, cmd_alpha_en};
                8'h6C: apb_prdata = {24'd0, cmd_global_alpha};
                8'h70: apb_prdata = second_ticks;
                8'h74: apb_prdata = diag_reg;   // live engine probe, see port list
                // Read the overlay control word back.  The scanout consumes it
                // in another clock domain, so "the firmware wrote it" and "the
                // scanline logic has it" are two different claims.  This makes
                // the second one observable without a probe.
                8'h78: apb_prdata = weather_ctrl;
                8'h7C: apb_prdata = color_matrix_ctrl;
                // Read the occlusion box back for the same reason as the control
                // word above: "the firmware wrote it" and "the scanline logic
                // has it" are two different claims, and only the second one
                // explains a flake sitting on the menu.
                8'h8C: apb_prdata = weather_mask_x;
                8'hAC: apb_prdata = weather_mask_y;
                8'hB0: apb_prdata = {8'd0, laser_colx_lo};
                8'hB4: apb_prdata = {8'd0, laser_colx_hi};
                // Read the beam overlay back: "the firmware wrote it" and "the
                // scanline logic has it" are two different claims, and only the
                // second one explains a beam standing on the wrong column.
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
                8'hF4: apb_prdata = {18'd0, btile_ptr};
                8'h84: apb_prdata = {24'd0, asset_data};  // asset ROM byte
                8'h88: apb_prdata = bloom_ctrl;
                8'h90: apb_prdata = snp_worst_cyc;
                8'h94: apb_prdata = snp_count;
                8'h98: apb_prdata = snp_op;
                8'h9C: apb_prdata = (snp_w << 16) | (snp_h & 16'hFFFF);
                8'hA0: apb_prdata = snp_src;
                8'hA4: apb_prdata = snp_dst;
                8'hA8: apb_prdata = snp_probe;
                default: apb_prdata = 32'd0;
            endcase
        end
    end

endmodule
