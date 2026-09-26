// video_dma_read.v
// Framebuffer Video DMA Reader with AXI4 Master Interface + Async FIFO + Timing Generator
// Step 3: Dynamic frame base address + VSync flag output for double buffering
`timescale 1ns / 1ps

module video_dma_read #(
    parameter FRAME_BASE_ADDR = 28'h0080_0000,
    // 1366x768 at 75.28 Hz with the 85.7118 MHz pixel clock constrained in
    // sdc/ti60_top.sdc.  The frame loop publishes one completed buffer per
    // scanout swap; shortening blanking raises that ceiling to about 75 FPS.
    parameter H_ACT           = 1366,
    parameter H_FP            = 8,
    parameter H_SYNC          = 56,
    parameter H_BP            = 26,
    parameter H_TOTAL         = 1456,

    parameter V_ACT           = 768,
    parameter V_FP            = 2,
    parameter V_SYNC          = 3,
    parameter V_BP            = 9,
    parameter V_TOTAL         = 782,
    parameter AXI_ADDR_WIDTH  = 28,
    parameter AXI_DATA_WIDTH  = 128
)(
    // AXI Clock & Reset
    input  wire                      axi_clk,
    input  wire                      axi_rst_n,
    input  wire                      cal_done,

    // AXI4 Read Master Interface (to Axi_Mux Slave 0)
    output wire [3:0]                m_axi_arid,
    output reg  [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0]                m_axi_arlen,
    output wire [2:0]                m_axi_arsize,
    output wire [1:0]                m_axi_arburst,
    output wire [1:0]                m_axi_arlock,
    output reg                       m_axi_arvalid,
    input  wire                      m_axi_arready,

    input  wire [3:0]                m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0]                m_axi_rresp,
    input  wire                      m_axi_rlast,
    input  wire                      m_axi_rvalid,
    output reg                       m_axi_rready,

    // Pixel Clock & Reset
    input  wire                      pixel_clk,
    input  wire                      pixel_rst_n,

    // Double-buffer control (axi_clk domain)
    input  wire [AXI_ADDR_WIDTH-1:0] next_frame_base_addr,
    output wire [AXI_ADDR_WIDTH-1:0] active_frame_base_addr,
    input  wire [AXI_ADDR_WIDTH-1:0] next_right_base_addr,
    output wire [AXI_ADDR_WIDTH-1:0] active_right_base_addr,
    input  wire [7:0] cpu_fps_bcd, fpga_fps_bcd,
    input  wire                      hud_enable,
    input  wire [31:0]               weather_ctrl,
    // Pause-card occlusion box for the weather layer (core_clk domain, see
    // bitblt_apb_regs 0x8C / 0xAC).  Zero = no box, layer as it always was.
    input  wire [31:0]               weather_mask_x,
    input  wire [31:0]               weather_mask_y,
    // Where the four laser columns stand, 4 x 12 bits (APB 0xB0 / 0xB4,
    // core_clk domain).  Centre 0 parks a column off screen.
    input  wire [47:0]               laser_colx,
    output wire [31:0] scan_diagnostics,
    output reg video_read_priority,
    output wire                      vsync_flag,

    // Video Output (to dvi_encoder)
    output reg  [7:0]                red_out,
    output reg  [7:0]                green_out,
    output reg  [7:0]                blue_out,
    output reg                       hsync_out,
    output reg                       vsync_out,
    output reg                       de_out
);

    assign m_axi_arid    = 4'd1;
    // m_axi_arlen is driven further down, next to last_burst - it depends on the
    // per-row burst index, which is declared together with the read state machine.
    assign m_axi_arsize  = 3'b100;    // 16 bytes per beat (128-bit)
    assign m_axi_arburst = 2'b01;     // INCR
    assign m_axi_arlock  = 2'b00;

    // A scan line is 1366 px = 5464 B, which is NOT a multiple of 256, and the
    // framebuffer row pitch is 8192 B (a power of two, so the firmware's
    // y * SCREEN_STRIDE stays a shift) because BitBlt rejects any stride
    // that is not a multiple of 16.  So the address model counts bursts inside a
    // row and advances a row offset by ROW_STRIDE, instead of walking one flat
    // byte offset - a flat walk silently assumes stride == H_ACT*4.
    //
    // A row is 22 bursts: 21 x 256 B = 5376 B of real pixels (a scan line is
    // 5464 B) plus one 6-beat tail burst that runs 168 B past the end of the
    // row.  Those bytes are read and dropped; the framebuffer has to tolerate
    // the read at the very last line, which the DDR layout accounts for.
    localparam [4:0]  BURSTS_PER_ROW = (H_ACT + 63) / 64;   // ceil: 1366 -> 22
    // 14 BITS, NOT 13.  The pitch is 8192 B = 2^13, and a 13-bit literal is
    // silently truncated to 0: row_addr then never advances, every scan line
    // re-reads row 0, and all 768 lines of the screen show the same 5632
    // bytes.  The 1024x600 pitch (4096) and the 1280x720 pitch (5120) both
    // fitted in 13 bits - which is exactly why this only appeared at 1366x768.
    // INVARIANT: ROW_STRIDE >= H_ACT*4 and ROW_STRIDE is a multiple of 16.
    localparam [13:0] ROW_STRIDE     = 14'd8192;            // framebuffer row pitch (bytes)
    localparam [12:0] HALF_OFFSET    = 13'd2560;            // 640 px = 10 bursts
    localparam [14:0] TOTAL_BURSTS   = 15'd16896;           // 22 * 768
    // Word budget of ONE scan line, and what the tail burst must deliver.
    // 1366 px = 5464 B = 341.5 x 128-bit words, so a line needs 342 words,
    // while the first 21 full bursts only supply 336 - hence a 6-beat tail.
    // 1024 -> 256 and 1280 -> 320 are exact multiples of 16, so for those the
    // tail evaluates to a full 16-beat burst and nothing changes.
    // INVARIANT: WORDS_PER_ROW must equal the pops word_fetch performs per
    // line (see the pop threshold below), and the tail must be 1..16 beats.
    localparam [8:0]  WORDS_PER_ROW  = (H_ACT + 3) / 4;                    // 1366 -> 342
    localparam [8:0]  TAIL_BEATS     = WORDS_PER_ROW -
                                       (BURSTS_PER_ROW - 5'd1) * 9'd16;    // 1366 -> 6
    // TOTAL_BURSTS AND bursts_left ARE 15-BIT ON PURPOSE.  A 14-bit counter wraps
    // at 16383, and 16896 (= 22 bursts x 768 rows) silently truncated to 512 when
    // they were 14 bits - VDMA then read 32 scan lines a frame and the rest of the
    // screen showed DDR residue.  Re-check the width whenever the frame grows.
    // INVARIANT: TOTAL_BURSTS == V_ACT * BURSTS_PER_ROW, and HALF_OFFSET must be
    // a multiple of 256 or one burst would straddle the two scanout bases.
    // Re-check both by hand whenever H_ACT, V_ACT or the framebuffer pitch changes.

    // Video Timing Generator
    wire [11:0] h_cnt;
    wire [10:0] v_cnt;
    wire        t_hsync;
    wire        t_vsync;
    wire        t_de;
    wire        t_frame_start;

    video_timing_gen #(
        .H_ACT(H_ACT),
        .H_FP(H_FP),
        .H_SYNC(H_SYNC),
        .H_BP(H_BP),
        .H_TOTAL(H_TOTAL),
        .V_ACT(V_ACT),
        .V_FP(V_FP),
        .V_SYNC(V_SYNC),
        .V_BP(V_BP),
        .V_TOTAL(V_TOTAL)
    ) u_timing (
        .pixel_clk   (pixel_clk),
        .rst_n       (pixel_rst_n),
        .h_cnt       (h_cnt),
        .v_cnt       (v_cnt),
        .hsync       (t_hsync),
        .vsync       (t_vsync),
        .de          (t_de),
        .frame_start (t_frame_start)
    );

    // Synchronize frame_start from pixel_clk to axi_clk
    reg frame_toggle_p;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)
            frame_toggle_p <= 1'b0;
        else if (t_frame_start)
            frame_toggle_p <= ~frame_toggle_p;
    end

    reg [2:0] frame_toggle_sync;
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n)
            frame_toggle_sync <= 3'b0;
        else
            frame_toggle_sync <= {frame_toggle_sync[1:0], frame_toggle_p};
    end
    wire frame_start_axi = frame_toggle_sync[2] ^ frame_toggle_sync[1];

    // Frame clear pulse during vertical blanking (at v_cnt == V_ACT, right after active video ends)
    wire frame_clear_p = (v_cnt == V_ACT) && (h_cnt < 12'd16);

    reg [2:0] frame_clear_sync;
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n)
            frame_clear_sync <= 3'b0;
        else
            frame_clear_sync <= {frame_clear_sync[1:0], frame_clear_p};
    end
    wire frame_clear_axi = frame_clear_sync[1];

    // ==========================================================
    // Step 3: Dynamic frame base address with VSync atomic latch
    // ==========================================================
    reg [AXI_ADDR_WIDTH-1:0] active_base;
    reg [AXI_ADDR_WIDTH-1:0] right_base;

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            active_base <= FRAME_BASE_ADDR;
            right_base <= FRAME_BASE_ADDR;
        end else if (frame_clear_sync[1] && !frame_clear_sync[2]) begin
            active_base <= next_frame_base_addr;
            right_base <= next_right_base_addr;
        end
    end

    // VSync flag output: directly expose frame_clear_axi to SoC (core_clk domain)
    // Since axi_clk IS core_clk (both 100MHz), no CDC needed
    assign vsync_flag = frame_clear_axi;
    assign active_frame_base_addr = active_base;
    assign active_right_base_addr = right_base;

    // Async FIFO
    wire         fifo_wfull;
    wire [10:0]  fifo_wusedw;
    wire         fifo_winc;
    wire [127:0] fifo_rdata;
    wire         fifo_rempty;
    wire         fifo_rinc;

    async_fifo #(
        .DATA_WIDTH(128),
        .ADDR_WIDTH(10)   // 1024 depth
    ) u_fifo (
        .wclk   (axi_clk),
        .wrst_n (axi_rst_n),
        .wclr   (frame_clear_axi),
        .winc   (fifo_winc),
        .wdata  (m_axi_rdata),
        .wfull  (fifo_wfull),
        .wusedw (fifo_wusedw),

        .rclk   (pixel_clk),
        .rrst_n (pixel_rst_n),
        .rclr   (frame_clear_p),
        .rinc   (fifo_rinc),
        .rdata  (fifo_rdata),
        .rempty (fifo_rempty)
    );

    // AXI Read State Machine
    localparam S_IDLE = 2'd0;
    localparam S_AR   = 2'd1;
    localparam S_R    = 2'd2;

    reg [1:0]  state;
    reg [14:0] bursts_left;
    reg discard_frame;
    reg [4:0] burst_in_row;
    reg start_pending;
    reg [27:0] row_addr;                    // byte offset of the current row
    reg [12:0] col_off;                     // byte offset inside that row
    wire [4:0] last_burst = (burst_in_row == BURSTS_PER_ROW - 5'd1);
    wire [12:0] next_col   = last_burst ? 13'd0 : (col_off + 13'd256);
    wire [27:0] next_row   = last_burst ? (row_addr + ROW_STRIDE) : row_addr;

    // The tail burst of a row is TRIMMED to the beats the line really needs.
    // Reading all 22 bursts full would deliver 352 words for a line that pops
    // 342: the 10 extra words are never consumed by the pixel gearbox, so they
    // stay in the FIFO and push every following row 10 words (40 px) sideways -
    // an error that accumulates down the screen as diagonal garbage.  Reading
    // exactly WORDS_PER_ROW keeps READ == CONSUME, and that equality is what
    // makes row N of the framebuffer land on row N of the screen.
    assign m_axi_arlen   = last_burst ? (TAIL_BEATS[7:0] - 8'd1) : 8'd15;

    // Two-line low watermark, refill to three lines before allowing
    // more CPU/BitBlt writes. A previously admitted write is never cancelled.
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) video_read_priority <= 1'b0;
        else if (frame_clear_axi || discard_frame || bursts_left == 0)
            video_read_priority <= 1'b0;
        else if (fifo_wusedw < 11'd704) video_read_priority <= 1'b1;  // 2 rows (352 words/row)
        else if (fifo_wusedw >= 11'd960) video_read_priority <= 1'b0; // ~2.7 rows
    end

    // Combinational handshake: write to FIFO in the exact cycle AXI read data is valid
    assign fifo_winc = (state == S_R) && m_axi_rvalid && m_axi_rready && !discard_frame && !frame_clear_axi;

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            state         <= S_IDLE;
            m_axi_araddr  <= FRAME_BASE_ADDR;
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b0;
            bursts_left   <= 15'd0;
            discard_frame <= 1'b1;
            start_pending <= 1'b0;
            row_addr <= 28'd0;
            col_off  <= 13'd0;
            burst_in_row  <= 5'd0;
        end else begin
            if (frame_start_axi)
                start_pending <= 1'b1;
            // Never cancel an asserted AR or strand an accepted read at VBlank.
            // Drain its response, discard old pixels, then begin the new frame.
                case (state)
                    S_IDLE: begin
                        if (!frame_clear_axi && (start_pending || frame_start_axi)) begin
                            row_addr <= 28'd0;
                            col_off  <= 13'd0;
                            m_axi_araddr <= active_base;
                            bursts_left <= TOTAL_BURSTS;
                            discard_frame <= 1'b0;
                            start_pending <= 1'b0;
                        end else if (!frame_clear_axi && !discard_frame && cal_done && (bursts_left > 15'd0) && (fifo_wusedw < 11'd960)) begin
                            m_axi_arvalid <= 1'b1;
                            state         <= S_AR;
                        end
                    end

                    S_AR: begin
                        if (m_axi_arready) begin
                            m_axi_arvalid <= 1'b0;
                            m_axi_rready  <= 1'b1;
                            state         <= S_R;
                        end
                    end

                    S_R: begin
                        if (m_axi_rvalid) begin
                            if (m_axi_rlast) begin
                                m_axi_rready <= 1'b0;
                                col_off  <= next_col;
                                row_addr <= next_row;
                                m_axi_araddr <= ((next_col >= HALF_OFFSET)
                                                 ? right_base : active_base)
                                                + next_row + {15'd0, next_col};
                                burst_in_row <= last_burst ? 5'd0 : burst_in_row + 5'd1;
                                if (!discard_frame && (bursts_left > 15'd0))
                                    bursts_left <= bursts_left - 15'd1;
                                state <= S_IDLE;
                            end
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            if (frame_clear_axi) begin
                discard_frame <= 1'b1;
                bursts_left <= 15'd0;
                burst_in_row <= 5'd0;
            end
        end
    end

    // Pixel Domain Gearbox (128-bit -> 32-bit pixel)
    reg [1:0]   sub_pix_cnt;
    reg [127:0] cur_word;
    reg [31:0]  cur_pixel;

    // Prefetch Word 0 at the end of the previous scan line.  Line 0 prefetches
    // at the end of line V_TOTAL-1; lines 1..V_ACT-1 at the end of the line
    // before them.
    wire prefetch_line = (v_cnt == V_TOTAL - 1) || (v_cnt < V_ACT - 1);
    wire line_prefetch = (h_cnt == H_TOTAL - 2) && prefetch_line && !fifo_rempty;

    // The pop threshold decides how many words a scan line CONSUMES, and it has
    // to equal the words that row read DELIVERS (WORDS_PER_ROW).  A line of
    // H_ACT pixels spans ceil(H_ACT/4) words: 1024 -> 256 and 1280 -> 320 are
    // whole numbers, but 1366 needs 342 while stopping at H_ACT-4 pops only 341.
    // One short word per line is invisible on its own - but it accumulates into
    // a per-row skew, which is exactly what the 1366 screen showed.
    wire word_fetch    = (sub_pix_cnt == 2'd2) && (h_cnt < H_ACT - 2) && t_de && !fifo_rempty;
    // An underrun must FREEZE the pixel phase, not let it run on.  word_fetch
    // already refuses to pop when the FIFO is empty, but sub_pix_cnt kept
    // counting, so at sub==3 cur_word latched the STALE head and from that pixel
    // on the whole scan line was displaced by one word (4 px).  A displacement
    // that small is invisible on the menu's large glyphs and destroys the
    // backdrop's fine striping - "the menu is fine, the sides are garbage".
    wire word_stall    = (sub_pix_cnt == 2'd2) && (h_cnt < H_ACT - 2) && t_de && fifo_rempty;
    assign fifo_rinc   = line_prefetch || word_fetch;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            sub_pix_cnt <= 2'd0;
            cur_word    <= 128'd0;
            cur_pixel   <= 32'd0;
        end else begin
            if ((h_cnt == H_TOTAL - 1) && prefetch_line) begin
                cur_word    <= fifo_rempty ? 128'd0 : fifo_rdata;
                sub_pix_cnt <= 2'd0;
                cur_pixel   <= 32'd0;
            end else if (t_de) begin
                // Hold the phase while the FIFO cannot feed the next word: the
                // current word's remaining lanes are still valid, so repeating a
                // pixel for a cycle or two is recoverable, whereas advancing the
                // phase is not (it shifts every remaining pixel of the line).
                if (!word_stall) begin
                    sub_pix_cnt <= sub_pix_cnt + 2'd1;

                    case (sub_pix_cnt)
                        2'd0: cur_pixel <= cur_word[31:0];
                        2'd1: cur_pixel <= cur_word[63:32];
                        2'd2: cur_pixel <= cur_word[95:64];
                        2'd3: begin
                            cur_pixel <= cur_word[127:96];
                            cur_word  <= fifo_rempty ? 128'd0 : fifo_rdata;
                        end
                    endcase
                end
            end else begin
                sub_pix_cnt <= 2'd0;
                cur_pixel   <= 32'd0;
            end
        end
    end

    // Pipeline Alignment (1 cycle latency to match cur_pixel)
    reg t_hsync_d1, t_vsync_d1, t_de_d1;
    reg [11:0] pixel_x_d1;
    reg [10:0] pixel_y_d1;
    reg [15:0] fps_sync1, fps_sync2, fps_stable, fps_display;
    reg hud_en_sync1, hud_en_sync2;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            fps_sync1<=0; fps_sync2<=0; fps_stable<=0; fps_display<=0;
            hud_en_sync1<=1'b1; hud_en_sync2<=1'b1;
        end else begin
            fps_sync1<={fpga_fps_bcd,cpu_fps_bcd};
            fps_sync2<=fps_sync1;
            fps_stable<=fps_sync2;
            hud_en_sync1<=hud_enable;
            hud_en_sync2<=hud_en_sync1;
            // Only adopt a settled snapshot during blank; digits stay fixed for a frame.
            if (v_cnt == V_ACT && h_cnt == 12'd32 && fps_stable == fps_sync2)
                fps_display<=fps_stable;
        end
    end
    wire hud_visible;
    wire [23:0] hud_rgb;

    // Weather overlay and laser: control word crosses from core_clk, two flops like the
    // HUD enable does, plus a VSync-synchronous shadow register to prevent mid-frame
    // scanline tearing and column gaps.  The pause-card occlusion box rides the same
    // path and is latched on the same frame edge, so the box and the layer it masks
    // can never disagree about which frame they belong to.
    reg [31:0] wctl_s1, wctl_s2;
    reg [31:0] wctl_latched;
    reg [31:0] wbox_x_s1, wbox_x_s2, wbox_x_latched;
    reg [31:0] wbox_y_s1, wbox_y_s2, wbox_y_latched;
    reg [47:0] lcol_s1, lcol_s2, lcol_latched;
    wire w_visible;
    wire [23:0] w_rgb;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            wctl_s1      <= 32'd0;
            wctl_s2      <= 32'd0;
            wctl_latched <= 32'd0;
            wbox_x_s1    <= 32'd0;
            wbox_x_s2    <= 32'd0;
            wbox_x_latched <= 32'd0;
            wbox_y_s1    <= 32'd0;
            wbox_y_s2    <= 32'd0;
            wbox_y_latched <= 32'd0;
            lcol_s1      <= 48'd0;
            lcol_s2      <= 48'd0;
            lcol_latched <= 48'd0;
        end else begin
            wctl_s1 <= weather_ctrl;
            wctl_s2 <= wctl_s1;
            wbox_x_s1 <= weather_mask_x;
            wbox_x_s2 <= wbox_x_s1;
            wbox_y_s1 <= weather_mask_y;
            wbox_y_s2 <= wbox_y_s1;
            lcol_s1   <= laser_colx;
            lcol_s2   <= lcol_s1;
            if (v_cnt == V_ACT && h_cnt == 12'd0) begin
                wctl_latched  <= wctl_s2;
                wbox_x_latched <= wbox_x_s2;
                wbox_y_latched <= wbox_y_s2;
                lcol_latched  <= lcol_s2;
            end
        end
    end
    video_weather u_weather (
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n),
        .x(pixel_x_d1), .y(pixel_y_d1), .de(t_de_d1),
        .ctrl(wctl_latched),
        .mask_x(wbox_x_latched), .mask_y(wbox_y_latched),
        .visible(w_visible), .rgb(w_rgb)
    );

    // The boss's laser columns.  Same scan position and the same control word as
    // the weather overlay; it owns no framebuffer pixels, which is the whole
    // point - see video_laser.v for why 3,072 rows a frame moved here.
    wire        l_visible;
    wire [23:0] l_rgb;
    video_laser u_laser (
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n),
        .x(pixel_x_d1), .y(pixel_y_d1), .de(t_de_d1),
        .ctrl(wctl_latched),
        .colx(lcol_latched),
        .visible(l_visible), .rgb(l_rgb)
    );

    // Laser saturated additive blending over weather/framebuffer:
    // Core white (24'hFFFFFF) clamps to 255 to trigger scanout bloom filter;
    // Sheath & beam add saturated energy over live background.
    wire [7:0] l_bg_r = w_visible ? w_rgb[23:16] : cur_pixel[23:16];
    wire [7:0] l_bg_g = w_visible ? w_rgb[15:8]  : cur_pixel[15:8];
    wire [7:0] l_bg_b = w_visible ? w_rgb[7:0]   : cur_pixel[7:0];

    wire [8:0] l_sum_r = {1'b0, l_bg_r} + {1'b0, l_rgb[23:16]};
    wire [8:0] l_sum_g = {1'b0, l_bg_g} + {1'b0, l_rgb[15:8]};
    wire [8:0] l_sum_b = {1'b0, l_bg_b} + {1'b0, l_rgb[7:0]};

    wire [7:0] l_add_r = l_sum_r[8] ? 8'd255 : l_sum_r[7:0];
    wire [7:0] l_add_g = l_sum_g[8] ? 8'd255 : l_sum_g[7:0];
    wire [7:0] l_add_b = l_sum_b[8] ? 8'd255 : l_sum_b[7:0];
    reg [15:0] underflow_count, background_errors;
    reg [31:0] scan_snapshot, scan_sync1, scan_sync2;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            underflow_count<=0; background_errors<=0; scan_snapshot<=0;
        end else if (v_cnt == V_ACT && h_cnt == 12'd32) begin
            scan_snapshot<={background_errors,underflow_count};
            underflow_count<=0; background_errors<=0;
        end else begin
            if (((h_cnt == H_TOTAL - 12'd2 && prefetch_line) ||
                 (sub_pix_cnt == 2'd2 && h_cnt < H_ACT - 12'd2 && t_de)) &&
                fifo_rempty && underflow_count != 16'hffff)
                underflow_count<=underflow_count+1'b1;
            // The top-row "left half black / right half blue" self-check was written
            // against the 1024x600 test pattern; its window (x 16..1000, split at 512)
            // has no meaning at 1280x720.  Left disabled rather than re-derived, because
            // it would otherwise count every active pixel of every frame as an error and
            // pin scan_diagnostics[31:16] at 0xFFFF, hiding real underflow counts.
            // Re-enable only together with a redefined test pattern.
                background_errors<=background_errors+1'b1;
        end
    end
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin scan_sync1<=0; scan_sync2<=0; end
        else begin scan_sync1<=scan_snapshot; scan_sync2<=scan_sync1; end
    end
    assign scan_diagnostics=scan_sync2;
    video_dual_hud u_hud (
        .x(pixel_x_d1), .y(pixel_y_d1),
        .cpu_fps_bcd(fps_display[7:0]), .fpga_fps_bcd(fps_display[15:8]),
        .visible(hud_visible), .rgb(hud_rgb)
    );
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            t_hsync_d1 <= 1'b0;
            t_vsync_d1 <= 1'b0;
            t_de_d1    <= 1'b0;
            pixel_x_d1 <= 0;
            pixel_y_d1 <= 0;
            hsync_out  <= 1'b0;
            vsync_out  <= 1'b0;
            de_out     <= 1'b0;
            red_out    <= 8'd0;
            green_out  <= 8'd0;
            blue_out   <= 8'd0;
        end else begin
            t_hsync_d1 <= t_hsync;
            t_vsync_d1 <= t_vsync;
            t_de_d1    <= t_de;
            pixel_x_d1 <= h_cnt;
            pixel_y_d1 <= v_cnt;

            hsync_out  <= t_hsync_d1;
            vsync_out  <= t_vsync_d1;
            de_out     <= t_de_d1;

            if (t_de_d1) begin
                // Layer order: HUD > laser (saturated add on background) > weather > framebuffer.
                // Saturated addition produces blinding white core (min >= 240) which activates
                // downstream u_bloom_filter, plus glowing semi-transparent plasma walls.
                red_out   <= (hud_visible && hud_en_sync2) ? hud_rgb[23:16]
                           : (l_visible                  ? l_add_r
                           : (w_visible                  ? w_rgb[23:16]
                                                         : cur_pixel[23:16]));
                green_out <= (hud_visible && hud_en_sync2) ? hud_rgb[15:8]
                           : (l_visible                  ? l_add_g
                           : (w_visible                  ? w_rgb[15:8]
                                                         : cur_pixel[15:8]));
                blue_out  <= (hud_visible && hud_en_sync2) ? hud_rgb[7:0]
                           : (l_visible                  ? l_add_b
                           : (w_visible                  ? w_rgb[7:0]
                                                         : cur_pixel[7:0]));
            end else begin
                red_out   <= 8'd0;
                green_out <= 8'd0;
                blue_out  <= 8'd0;
            end
        end
    end

endmodule
