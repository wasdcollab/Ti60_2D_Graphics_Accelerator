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
    parameter AXI_DATA_WIDTH  = 128,

    // B1: entries per scanline bucket.  80, because the worst scanline measured
    // on the pressure stage carries 75 bullets (scratch/a3/bucket_depth.py).
    parameter BUCKET_SLOTS    = 80
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
    // The player's beam and the three cut/beam warning hairlines, forwarded to
    // video_beam.v (APB 0xB8 .. 0xEC, core_clk domain).  All of it is latched on
    // the same frame edge the control word is, so neither the beam nor a
    // hairline can appear at the previous frame's column.
    input  wire [11:0]               beam_x,
    input  wire [11:0]               beam_len,
    input  wire                      beam_en,
    input  wire [35:0]               hair_x,
    input  wire [71:0]               hair_out,
    input  wire [71:0]               hair_lft,
    input  wire [71:0]               hair_mid,

    // ---- B1: the bullet bucket -------------------------------------------
    // Where the bucket table lives (APB, core_clk domain).  One bucket per
    // scanline: BUCKET_SLOTS four-byte entries, appended by the firmware in draw
    // order.  The scanout cannot fetch these itself - it has no DDR port - so
    // this module fetches them: one line's bucket is read ahead while the
    // previous line is on screen, and handed over as a flat vector.
    input  wire [27:0]               bucket_base,
    output wire [32*BUCKET_SLOTS-1:0] bucket_row,
    output wire                      bucket_ready,
    // The tile store and its palette are loaded once at boot through this port
    // (APB).  Runtime never writes them.
    input  wire                      btile_we,
    input  wire [13:0]               btile_addr,
    input  wire [7:0]                btile_data,
    input  wire                      bpal_we,
    input  wire [7:0]                bpal_addr,
    input  wire [31:0]               bpal_data,
    output wire [31:0] scan_diagnostics,
    output reg video_read_priority,
    output wire                      vsync_flag,

    // Video Output (to dvi_encoder / bloom_filter)
    output reg  [7:0]                alpha_out,
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

    // Declared here rather than down with the rest of the pixel-domain logic:
    // iverilog refuses a reference to a signal declared later in the file, and
    // the synchroniser below reads bk_tog_pix before that logic appears.
    reg        bk_tog_pix;
    reg [10:0] bk_row_pix;

    // ------------------------------------------------------------------------
    // B1: bullet bucket prefetch, two scanlines ahead.
    //
    // The pixel side asks for scanline N+2 while scanline N is on screen; the
    // fetch lands in buffer half (N+2)%2.  During line N's blanking the pixel
    // side lifts scanline N+1 out of half (N+1)%2.  Those are different halves at
    // every instant, so the fetch and the lift can never collide - and the line
    // being fetched has a whole scanline (17 us, against a few hundred ns of AXI)
    // to arrive, so no completion handshake is needed and a late fetch cannot
    // tear a bucket that is already on screen.
    //
    // The bursts go in at the TOP of a scanline, ahead of that line's pixel
    // bursts.  The FIFO holds two to three lines, so two extra bursts cannot
    // starve it; they are also only 320 bytes against the 5632 the line itself
    // costs.
    // ------------------------------------------------------------------------
    reg        bk_pend;          // a request is waiting to be served
    reg        bk_act;           // this transaction belongs to the bucket
    reg        bk_burst;         // 0 = the 16-beat half, 1 = the 4-beat half
    reg [3:0]  bk_beat;
    reg [10:0] bk_row_axi;
    reg  [2:0] bk_tog_sync;

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n)
            bk_tog_sync <= 3'b0;
        else
            bk_tog_sync <= {bk_tog_sync[1:0], bk_tog_pix};
    end
    wire bk_req_axi = bk_tog_sync[2] ^ bk_tog_sync[1];

    // The bucket table is double-buffered exactly like the framebuffer, and for
    // the same reason: the firmware builds the buckets for the frame it is
    // rendering while the scanout is still showing the previous one.  There are
    // two tables, and which one is live follows the framebuffer the scanout is
    // reading - bit 22 is what separates FB_LEFT_FRONT (0x0080_0000) from
    // FB_LEFT_BACK (0x00E0_0000).  A single shared table would tear: the firmware
    // would be appending to the buckets for frame N while the scanout walked the
    // buckets for frame N-1.
    wire [27:0] bk_base = bucket_base + (active_base[22] ? 28'h0003_C000 : 28'h0);

    // Everything this request feeds - bk_pend, bk_act, the burst counter - is
    // driven by the read state machine below and by nothing else.  Splitting the
    // set and the clear across two always blocks is what Efinity rejected with
    // "net is constantly driven from multiple places (VDB-1000)", and it is right
    // to: two blocks assigning one net is a race in any simulator too.

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
    // B1: the bucket fetch shares this port.  Two bursts of 320 bytes: 16 beats
    // plus 4.  Fixed, because a bucket is BUCKET_SLOTS four-byte entries and 80
    // entries is exactly 20 beats of 128 bits.
    localparam integer BUCKET_BYTES = 4 * BUCKET_SLOTS;   // 320
    wire [7:0] bk_arlen = (bk_burst == 1'b0) ? 8'd15 : 8'd3;
    assign m_axi_arlen   = bk_act ? bk_arlen
                                  : (last_burst ? (TAIL_BEATS[7:0] - 8'd1) : 8'd15);

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
    //
    // !bk_act IS THE WHOLE POINT OF THE B1 SHARING.  The bucket bursts run
    // through the same S_AR/S_R states as the pixel bursts, so without this the
    // 20 beats a bucket costs (16 + 4) are written into the PIXEL FIFO as well.
    // A scan line consumes exactly WORDS_PER_ROW = 342 words and the row's pixel
    // bursts deliver exactly 342, so every extra word is one the gearbox never
    // asked for: it stays in the FIFO, read/consume stops being equal, the FIFO
    // fills (and then drops pixel words on wfull), and the whole picture slides
    // - the "image is skewed / smeared" the board shows, with the scanout's own
    // layers (laser, beam, weather, HUD) crisp on top of it because they never
    // go near this FIFO.
    //
    // Measured by tests/tb_vdma_bucket_fifo.sv: 15,340 words a frame leaked
    // before this fix (767 bucket transactions x 20 beats), 0 after.
    assign fifo_winc = (state == S_R) && m_axi_rvalid && m_axi_rready
                       && !bk_act && !discard_frame && !frame_clear_axi;

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
            bk_pend    <= 1'b0;
            bk_act     <= 1'b0;
            bk_burst   <= 1'b0;
            bk_beat    <= 4'd0;
            bk_row_axi <= 11'd0;
        end else begin
            if (frame_start_axi)
                start_pending <= 1'b1;
            if (bk_req_axi) begin
                bk_pend    <= 1'b1;
                bk_row_axi <= bk_row_pix;
            end
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
                        end else if (!frame_clear_axi && !discard_frame && cal_done &&
                                     (bucket_base != 28'd0) &&
                                     bk_pend && !bk_act &&
                                     (burst_in_row == 5'd0) && (col_off == 13'd0)) begin
                            // B1: the bucket bursts go in at the top of a scanline,
                            // ahead of that line's pixel bursts.  row * 320 is
                            // row<<8 + row<<6.
                            m_axi_araddr  <= bk_base
                                             + {6'd0, bk_row_axi, 8'b0}
                                             + {8'd0, bk_row_axi, 6'b0};
                            m_axi_arvalid <= 1'b1;
                            bk_act        <= 1'b1;
                            bk_burst      <= 1'b0;
                            bk_beat       <= 4'd0;
                            state         <= S_AR;
                        end else if (!frame_clear_axi && !discard_frame && cal_done && (bursts_left > 15'd0) && (fifo_wusedw < 11'd960)) begin
                            // The pixel walk's next address is derived HERE, from
                            // the row/column the walk is standing on, and not left
                            // over from wherever the address register happened to
                            // be.  The bucket branch above runs out of this same
                            // state and leaves ITS address behind; without this
                            // line the first pixel burst of every line read the
                            // bucket table and the scanout painted it as pixels.
                            // Measured: 1,445 bursts a frame, see
                            // tests/tb_vdma_bucket_fifo.sv.
                            m_axi_araddr  <= ((col_off >= HALF_OFFSET) ? right_base : active_base)
                                             + row_addr + {15'd0, col_off};
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
                                if (bk_act) begin
                                    // B1: a bucket transaction.  It never touches
                                    // bursts_left, burst_in_row or col_off - the
                                    // pixel walk must not notice it happened.
                                    if (bk_burst == 1'b0) begin
                                        bk_burst      <= 1'b1;
                                        bk_beat       <= 4'd0;
                                        m_axi_araddr  <= bk_base
                                                         + {6'd0, bk_row_axi, 8'b0}
                                                         + {8'd0, bk_row_axi, 6'b0}
                                                         + 28'd256;
                                        m_axi_arvalid <= 1'b1;
                                        state         <= S_AR;
                                    end else begin
                                        bk_act  <= 1'b0;
                                        bk_pend <= 1'b0;
                                        state   <= S_IDLE;
                                    end
                                end else begin
                                // Only the walk's position advances here; the
                                // address that position implies is computed in
                                // S_IDLE.  Two writers on m_axi_araddr is what
                                // let the bucket branch's address survive into a
                                // pixel burst (see the S_IDLE note).
                                col_off  <= next_col;
                                row_addr <= next_row;
                                burst_in_row <= last_burst ? 5'd0 : burst_in_row + 5'd1;
                                if (!discard_frame && (bursts_left > 15'd0))
                                    bursts_left <= bursts_left - 15'd1;
                                state <= S_IDLE;
                                end
                            end else if (bk_act) begin
                                bk_beat <= bk_beat + 4'd1;
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

    // ------------------------------------------------------------------------
    // B1: the bucket store, and the lift from it into a flat vector.
    //
    // 128 bits wide because an AXI beat is 128 bits: one beat is four entries,
    // and a bucket is 20 beats.  Two halves of 32 words each, addressed by the
    // scanline's low bit, so a fetch and a lift are always in different halves.
    //
    // The lift happens in the blanking interval of line N and loads the bucket
    // for line N+1 - line N's pixels are already out by then, and line N+1 has
    // not started, so a single register bank is enough.  Twenty cycles against
    // ninety of blanking.
    // ------------------------------------------------------------------------
    reg [32*BUCKET_SLOTS-1:0] bucket_flat;
    reg                       bk_flat_ok;

    wire        bk_wr = (state == S_R) && bk_act && m_axi_rvalid
                        && !frame_clear_axi && !discard_frame;
    wire [4:0]  bk_widx = (bk_burst == 1'b0) ? {1'b0, bk_beat}
                                             : (5'd16 + {3'b0, bk_beat[2:0]});
    wire [5:0]  bk_waddr = {bk_row_axi[0], 5'b0} + {1'b0, bk_widx};
    wire [127:0] bk_rd;

    // The next line's bucket sits in the half the scanline's low bit does NOT
    // select: line N+1 lives in half ~N[0].
    wire [11:0] bk_off  = h_cnt - H_ACT;
    wire [4:0]  bk_lidx = bk_off[4:0];
    wire        bk_lift = (h_cnt >= H_ACT) && (h_cnt < H_ACT + 12'd32)
                          && (v_cnt < V_ACT);
    wire [5:0]  bk_raddr = {~v_cnt[0], 5'b0} + {1'b0, bk_lidx};

    simple_dual_port_ram #(
        .DATA_WIDTH (128),
        .ADDR_WIDTH (6),
        .OUTPUT_REG ("FALSE")
    ) u_bucket (
        .wdata (m_axi_rdata), .waddr (bk_waddr), .we (bk_wr), .wclk (axi_clk),
        .raddr (bk_raddr), .re (1'b1), .rclk (pixel_clk),
        .rdata (bk_rd)
    );

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            bucket_flat <= {(32*BUCKET_SLOTS){1'b0}};
            bk_flat_ok  <= 1'b0;
            bk_tog_pix  <= 1'b0;
            bk_row_pix  <= 11'd0;
        end else begin
            if (bk_lift && (bk_lidx < 5'd20)) begin
                bucket_flat[128*bk_lidx         +: 32] <= bk_rd[31:0];
                bucket_flat[128*bk_lidx +  32   +: 32] <= bk_rd[63:32];
                bucket_flat[128*bk_lidx +  64   +: 32] <= bk_rd[95:64];
                bucket_flat[128*bk_lidx +  96   +: 32] <= bk_rd[127:96];
            end
            if (h_cnt == H_ACT)
                bk_flat_ok <= 1'b0;
            else if (bk_lift && (bk_lidx == 5'd19))
                bk_flat_ok <= 1'b1;

            // Ask for the bucket two lines ahead.  Line 0 and line 1 have no
            // predecessor to have lifted, so they come up blank - which is what
            // "no bullets on screen yet" looks like anyway, and is the safe
            // direction for the first two lines of a frame to fail in.
            if ((h_cnt == 12'd0) && (v_cnt < V_ACT - 11'd2)) begin
                bk_tog_pix <= ~bk_tog_pix;
                bk_row_pix <= v_cnt[10:0] + 11'd2;
            end
        end
    end

    assign bucket_row   = bucket_flat;
    // A base of zero means "the firmware has not told us where the table is
    // yet", and the boot sequence spends a while in exactly that state.  Without
    // this the prefetch happily reads from DDR address 0 - which is the
    // framebuffer - and hands the scanout whatever bytes happen to live there as
    // if they were bucket entries.  That is a screenful of bullet tiles made of
    // backdrop pixels, for as long as it takes the firmware to reach
    // bullet_store_build().
    assign bucket_ready = bk_flat_ok && (bucket_base != 28'd0);

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
    reg [11:0] bmx_s1, bmx_s2, bmx_latched;
    reg [11:0] bml_s1, bml_s2, bml_latched;
    reg        bme_s1, bme_s2, bme_latched;
    reg [35:0] hx_s1,  hx_s2,  hx_latched;
    reg [71:0] ho_s1,  ho_s2,  ho_latched;
    reg [71:0] hl_s1,  hl_s2,  hl_latched;
    reg [71:0] hm_s1,  hm_s2,  hm_latched;
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
            bmx_s1 <= 12'd0; bmx_s2 <= 12'd0; bmx_latched <= 12'd0;
            bml_s1 <= 12'd0; bml_s2 <= 12'd0; bml_latched <= 12'd0;
            bme_s1 <= 1'b0;  bme_s2 <= 1'b0;  bme_latched <= 1'b0;
            hx_s1  <= 36'd0; hx_s2  <= 36'd0; hx_latched  <= 36'd0;
            ho_s1  <= 72'd0; ho_s2  <= 72'd0; ho_latched  <= 72'd0;
            hl_s1  <= 72'd0; hl_s2  <= 72'd0; hl_latched  <= 72'd0;
            hm_s1  <= 72'd0; hm_s2  <= 72'd0; hm_latched  <= 72'd0;
        end else begin
            wctl_s1 <= weather_ctrl;
            wctl_s2 <= wctl_s1;
            wbox_x_s1 <= weather_mask_x;
            wbox_x_s2 <= wbox_x_s1;
            wbox_y_s1 <= weather_mask_y;
            wbox_y_s2 <= wbox_y_s1;
            lcol_s1   <= laser_colx;
            lcol_s2   <= lcol_s1;
            bmx_s1 <= beam_x;   bmx_s2 <= bmx_s1;
            bml_s1 <= beam_len; bml_s2 <= bml_s1;
            bme_s1 <= beam_en;  bme_s2 <= bme_s1;
            hx_s1  <= hair_x;   hx_s2  <= hx_s1;
            ho_s1  <= hair_out; ho_s2  <= ho_s1;
            hl_s1  <= hair_lft; hl_s2  <= hl_s1;
            hm_s1  <= hair_mid; hm_s2  <= hm_s1;
            if (v_cnt == V_ACT && h_cnt == 12'd0) begin
                wctl_latched  <= wctl_s2;
                wbox_x_latched <= wbox_x_s2;
                wbox_y_latched <= wbox_y_s2;
                lcol_latched  <= lcol_s2;
                bmx_latched <= bmx_s2;
                bml_latched <= bml_s2;
                bme_latched <= bme_s2;
                hx_latched  <= hx_s2;
                ho_latched  <= ho_s2;
                hl_latched  <= hl_s2;
                hm_latched  <= hm_s2;
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
    //
    // It carries a blend selector now, the same shape video_beam's has: the two
    // centre columns add (they are the light source and the only place
    // over-exposure is wanted), and the halo and the rim blend at an alpha.  The
    // branch is taken further down, next to the beam's.
    wire        l_visible;
    wire        l_laser_add;    // ...this column adds
    wire [7:0]  l_laser_alpha;  // ...or blends at this opacity
    wire [23:0] l_rgb;
    video_laser u_laser (
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n),
        .x(pixel_x_d1), .y(pixel_y_d1), .de(t_de_d1),
        .ctrl(wctl_latched),
        .colx(lcol_latched),
        .mask_x(wbox_x_latched), .mask_y(wbox_y_latched),
        .visible(l_visible), .laser_add(l_laser_add),
        .laser_alpha(l_laser_alpha), .rgb(l_rgb)
    );

    // The player's beam and the cut/beam warning hairlines.  The hairlines are
    // opaque, so they sit above the laser columns - see video_beam.v.
    wire        b_visible;
    wire        b_beam_vis;     // beam pixels only
    wire        b_hair_vis;     // warning-hairline pixels only
    wire        b_beam_add;     // ...this beam column adds; hairlines never do
    wire [7:0]  b_beam_alpha;   // ...this beam column blends at this opacity
    wire [23:0] b_rgb;
    video_beam u_beam (
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n),
        .x(pixel_x_d1), .y(pixel_y_d1), .de(t_de_d1),
        .beam_x(bmx_latched), .beam_len(bml_latched), .beam_en(bme_latched),
        .hair_x(hx_latched),
        .hair_out(ho_latched), .hair_lft(hl_latched), .hair_mid(hm_latched),
        .mask_x(wbox_x_latched), .mask_y(wbox_y_latched),
        .visible(b_visible), .beam_vis(b_beam_vis), .hair_vis(b_hair_vis),
        .beam_add(b_beam_add), .beam_alpha(b_beam_alpha), .rgb(b_rgb)
    );

    // B1: the bullet curtain.  Opened last in game_render(), so it sits under
    // the warning hairline, under the plasma columns, and UNDER the weather -
    // the weather layer has always been a scanout overlay above the framebuffer
    // the bullets were drawn into, so a flake in front of a bullet is the
    // existing behaviour, not a new one.
    wire        u_visible;
    wire        u_add_sel;      // ...this bullet pixel adds instead of blending
    wire [23:0] u_rgb;
    wire [7:0]  u_alpha;
    video_bullet_overlay #(
        .SLOTS (BUCKET_SLOTS)
    ) u_bullets (
        .pixel_clk(pixel_clk), .pixel_rst_n(pixel_rst_n),
        .x(pixel_x_d1), .y(pixel_y_d1), .de(t_de_d1),
        .bucket(bucket_row), .bucket_ready(bucket_ready),
        // The same box the weather layer takes: the card, the banner and the
        // dialogue are framebuffer pixels this layer cannot see.
        .mask_x(wbox_x_latched), .mask_y(wbox_y_latched),
        .cfg_clk(axi_clk), .cfg_rst_n(axi_rst_n),
        .tile_we(btile_we), .tile_waddr(btile_addr), .tile_wdata(btile_data),
        .pal_we(bpal_we), .pal_waddr(bpal_addr), .pal_wdata(bpal_data),
        .visible(u_visible), .bullet_add(u_add_sel), .rgb(u_rgb), .alpha(u_alpha)
    );

    // ---- bullets: ADD, alpha blend, or replace ------------------------------
    //
    // Until the alpha byte existed the bullet curtain was an opaque overlay:
    // whatever tile byte won a pixel was written straight into the frame.  That
    // is what the picture wants for an ENEMY bullet and it is exactly what it
    // must not do for a player shot's core or a missile's body, which the visual
    // spec asks to show the snowfield through.  The tile byte is a palette
    // INDEX, so the only place an alpha can live is the palette entry - hence
    // the 32-bit palette the overlay now carries.
    //
    // alpha == 255 takes the old path bit for bit.  That is deliberate: every
    // tile that exists today was built with an opaque palette, and this whole
    // change has to leave the shipped picture alone.
    //
    // THE THIRD ANSWER.  The spec's boundary is "glowing things add, translucent
    // things alpha", and its missile (blended body, added trail) and light
    // bullet (added shell, blended core) are both at once - so the curtain needs
    // to say ADD per pixel, the way the beam and the laser columns already do.
    // That flag comes from the layer, not from here: video_bullet_overlay reads
    // the palette entry's alpha byte and reports the one value in it that is not
    // an opacity.  Nothing in this block has to know which bullet it is.
    //
    // The blend arithmetic is (fg*a + bg*(255-a) + 127) / 255, the same form the
    // BitBlt engine's OP_ALPHA uses - one blend definition in the build rather
    // than two that drift apart.
    //
    // NO DIVIDE OPERATOR.  This first went in as a literal `/ 8'd255`, which
    // simulates perfectly and is wrong on the board: a divide by a constant
    // like this either fails to close timing or is inferred as something that
    // does not produce the quotient, and the visible result is every blended
    // bullet coming out BLACK.  The engine already solved this in
    // bitblt_alpha_blend.v with the add-shift identity
    //     n / 255 == (n + 1 + (n >> 8)) >> 8      for 0 <= n <= 65152
    // which was verified exhaustively there; the numerator here is bounded by
    // the same 255*255 + 127, so the same identity applies unchanged.
    function [17:0] div255;
        input [17:0] n;
        begin
            div255 = (n + 18'd1 + (n >> 8)) >> 8;
        end
    endfunction

    function [7:0] blend8;
        input [7:0] fg;
        input [7:0] bg;
        input [7:0] a;
        reg [17:0] base;
        reg signed [8:0]  diff;
        reg signed [17:0] prod;
        reg [17:0] n;
        begin
            // 255*bg + 127 is the "all background" end, and a*(fg-bg) walks it
            // toward the foreground as a grows.  bg and fg are 8-bit, so their
            // difference needs the sign bit - as an unsigned term it wraps and
            // produces 255 where it should produce 190.
            base = ({10'd0, bg} * 18'd255) + 18'd127;
            diff = $signed({1'b0, fg}) - $signed({1'b0, bg});
            prod = diff * $signed({1'b0, a});
            // base >= 127 and the true sum is never negative, so the two's
            // complement wrap of an unsigned add lands on the right value; the
            // identity holds for 0 <= n <= 65152, which covers this range.
            n = base + prod[17:0];
            blend8 = div255(n);
        end
    endfunction

    // The layer the bullet is composited OVER: snow if the weather owns this
    // pixel, the framebuffer otherwise.  Note this is NOT the value the laser
    // columns add to - those sit ABOVE the curtain, so they want the composite.
    wire [7:0] u_under_r = w_visible ? w_rgb[23:16] : cur_pixel[23:16];
    wire [7:0] u_under_g = w_visible ? w_rgb[15:8]  : cur_pixel[15:8];
    wire [7:0] u_under_b = w_visible ? w_rgb[7:0]   : cur_pixel[7:0];

    wire       u_opaque = (u_alpha == 8'hFF);
    wire       u_add    = u_visible && u_add_sel;

    // The additive path: min(255, base + fg) per channel, the same sum the
    // laser columns and the beam take, over the same "what is under this layer"
    // value the blend uses.  Which entries ask for it is the palette's business
    // - video_bullet_overlay decodes the one alpha value that is not an opacity
    // - so one tile can carry an added trail and a blended body at once, which
    // is exactly what the spec's missile and light bullet need.
    wire [8:0] u_sum_r = {1'b0, u_under_r} + {1'b0, u_rgb[23:16]};
    wire [8:0] u_sum_g = {1'b0, u_under_g} + {1'b0, u_rgb[15:8]};
    wire [8:0] u_sum_b = {1'b0, u_under_b} + {1'b0, u_rgb[7:0]};

    wire [7:0] u_add_r = u_sum_r[8] ? 8'd255 : u_sum_r[7:0];
    wire [7:0] u_add_g = u_sum_g[8] ? 8'd255 : u_sum_g[7:0];
    wire [7:0] u_add_b = u_sum_b[8] ? 8'd255 : u_sum_b[7:0];

    // THREE ANSWERS NOW, and the widths are not optional - see the note further
    // down about the one-bit wires that made a whole layer come out black.
    wire [7:0] u_out_r  = u_add    ? u_add_r
                        : u_opaque ? u_rgb[23:16]
                        : blend8(u_rgb[23:16], u_under_r, u_alpha);
    wire [7:0] u_out_g  = u_add    ? u_add_g
                        : u_opaque ? u_rgb[15:8]
                        : blend8(u_rgb[15:8],  u_under_g, u_alpha);
    wire [7:0] u_out_b  = u_add    ? u_add_b
                        : u_opaque ? u_rgb[7:0]
                        : blend8(u_rgb[7:0],   u_under_b, u_alpha);

    // The composite as the layer ABOVE sees it: the blended bullet where the
    // curtain drew, and the layer underneath everywhere else.  The laser columns
    // add to this, which is what keeps a column crossing a bullet from being
    // dimmed by it.
    wire [7:0] u_comp_r = u_visible ? u_out_r : u_under_r;
    wire [7:0] u_comp_g = u_visible ? u_out_g : u_under_g;
    wire [7:0] u_comp_b = u_visible ? u_out_b : u_under_b;

    // ---- the boss's laser columns: add at the core, blend outside it -------
    //
    // These used to add on every one of their sixteen columns, and six of those
    // were white or near white, so on any non-zero background the whole column
    // saturated and the light source's over-exposure became the column's.  Which
    // columns add is now decided in video_laser's profile (l_laser_add) and the
    // rest blend with l_laser_alpha, so the snow reads through the halo and the
    // rim.  This block runs both answers and lets the flag choose.
    //
    // The blend base has to include the bullets: the columns were blended
    // against a framebuffer that had the curtain in it, so blending them
    // against the backdrop alone would change every column that crosses a
    // bullet.
    wire [7:0] l_bg_r = u_comp_r;
    wire [7:0] l_bg_g = u_comp_g;
    wire [7:0] l_bg_b = u_comp_b;

    wire [8:0] l_sum_r = {1'b0, l_bg_r} + {1'b0, l_rgb[23:16]};
    wire [8:0] l_sum_g = {1'b0, l_bg_g} + {1'b0, l_rgb[15:8]};
    wire [8:0] l_sum_b = {1'b0, l_bg_b} + {1'b0, l_rgb[7:0]};

    wire [7:0] l_add_r = l_sum_r[8] ? 8'd255 : l_sum_r[7:0];
    wire [7:0] l_add_g = l_sum_g[8] ? 8'd255 : l_sum_g[7:0];
    wire [7:0] l_add_b = l_sum_b[8] ? 8'd255 : l_sum_b[7:0];

    // The same blend8() the curtain and the beam use, so this file still has one
    // blend definition rather than three that drift apart.
    wire [7:0] l_mix_r = blend8(l_rgb[23:16], l_bg_r, l_laser_alpha);
    wire [7:0] l_mix_g = blend8(l_rgb[15:8],  l_bg_g, l_laser_alpha);
    wire [7:0] l_mix_b = blend8(l_rgb[7:0],   l_bg_b, l_laser_alpha);

    // The laser layer's own result, over the bullets.  The beam is composited
    // against THIS rather than against l_add_*, so a beam pixel landing on a
    // blended laser column sees the laser the picture actually has.
    wire [7:0] l_out_r = l_visible && l_laser_add ? l_add_r
                       : l_visible                 ? l_mix_r : u_comp_r;
    wire [7:0] l_out_g = l_visible && l_laser_add ? l_add_g
                       : l_visible                 ? l_mix_g : u_comp_g;
    wire [7:0] l_out_b = l_visible && l_laser_add ? l_add_b
                       : l_visible                 ? l_mix_b : u_comp_b;

    // ---- the craft's beam: add at the core, blend at the halo --------------
    //
    // The beam sits ABOVE the boss's laser columns, so it composites against
    // the columns' result rather than beside it - l_out, which is the columns
    // blended where they blend and added where they add.  So this chain is
    // framebuffer -> bullets(add OR alpha) -> laser(add OR alpha) -> beam(add OR
    // alpha).  Both of the beam's answers take the same input, l_out: the layer
    // it is drawn over.
    //
    // WHICH OF THE TWO IS NOT DECIDED HERE.  video_beam's column table carries
    // the answer (beam_add and beam_alpha), because it is a property of the
    // beam's profile - which column is the light source and which is the halo -
    // and this chain could not invent it.  What is left here is to run both
    // branches and let the flag choose, which is the same shape the bullet
    // curtain above already had.
    //
    // The additive branch is unchanged: min(255, base + beam) per channel,
    // exactly like the columns' additive branch.  The beam's own profile runs
    // from a translucent rim to white in the core, so the ramp comes from the
    // table and this only sums it - a core of white saturates anything it lands
    // on, which is the over-exposure the spec calls correct rather than a
    // defect.
    //
    // The alpha branch is the same blend8() the bullet curtain uses, so this
    // file still has one blend definition rather than two that drift apart.  It
    // is what keeps the halo's own colour: an added cyan would bleach the snow
    // toward white, and the colour is the thing the halo is for.
    wire [8:0] b_sum_r = {1'b0, l_out_r} + {1'b0, b_rgb[23:16]};
    wire [8:0] b_sum_g = {1'b0, l_out_g} + {1'b0, b_rgb[15:8]};
    wire [8:0] b_sum_b = {1'b0, l_out_b} + {1'b0, b_rgb[7:0]};

    wire [7:0] b_add_r = b_sum_r[8] ? 8'd255 : b_sum_r[7:0];
    wire [7:0] b_add_g = b_sum_g[8] ? 8'd255 : b_sum_g[7:0];
    wire [7:0] b_add_b = b_sum_b[8] ? 8'd255 : b_sum_b[7:0];

    wire [7:0] b_mix_r = blend8(b_rgb[23:16], l_out_r, b_beam_alpha);
    wire [7:0] b_mix_g = blend8(b_rgb[15:8],  l_out_g, b_beam_alpha);
    wire [7:0] b_mix_b = blend8(b_rgb[7:0],   l_out_b, b_beam_alpha);

    // The warning hairlines replace; the beam either adds or blends, per column.
    // The flag comes from the layer rather than from here, so "which blend" is a
    // property of the shape instead of a fact this block has to remember.
    wire b_add = b_visible && b_beam_vis &&  b_beam_add;
    wire b_mix = b_visible && b_beam_vis && !b_beam_add;

    // b_add and b_mix are both false on a hairline pixel, which is the whole
    // point: the two flags divide the beam, and the hairline falls through to
    // the plain replace branch below, opaque, as it has always been.
    //
    // THE WIDTHS ARE NOT OPTIONAL.  These three were first written without a
    // range, and "wire b_out_r = <8-bit expression>" declares a ONE-BIT wire:
    // every beam pixel kept only the low bit of its own colour, so the whole
    // strip came out black with a bit of noise in it, and no bench noticed -
    // the module compiled, Verilator's width warning is switched off here, and
    // the picture is the only place the difference shows.  The three lines that
    // feed them carry [7:0] for the same reason.
    wire [7:0] b_out_r = b_add ? b_add_r : b_mix ? b_mix_r : b_rgb[23:16];
    wire [7:0] b_out_g = b_add ? b_add_g : b_mix ? b_mix_g : b_rgb[15:8];
    wire [7:0] b_out_b = b_add ? b_add_b : b_mix ? b_mix_b : b_rgb[7:0];
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
            // has no meaning at 1366x768.  It is DISABLED, and the comment above used
            // to claim that while the line below it sat outside any condition: the
            // counter ran once per pixel clock, so scan_diagnostics[31:16] was a free-
            // running 16-bit garbage value and the word looked like 0x5f9f0000 instead
            // of the underflow count it is supposed to carry.  Measured on the board's
            // own counter model: 24479 at the moment of a read.
            // Re-enable only together with a redefined test pattern:
            //     background_errors<=background_errors+1'b1;
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
            alpha_out  <= 8'd0;
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
                // Layer order: HUD > beam (ADD at the core, ALPHA at the halo)
                // and hairlines (opaque) > laser columns (ADD at the core,
                // ALPHA outside it) > weather > bullets (add|alpha) > framebuffer.
                //
                // The blend choices are the visual spec's boundary made literal:
                // the ADD layers are the light, the ALPHA layers are the
                // translucent things, and the chain reads
                //     framebuffer -> bullets(add|alpha) -> laser(add|alpha) -> beam(add|alpha)
                // so light accumulates on top of what it shines through.
                //
                // The beam is the one layer that is both, and it is the layer
                // that decides which - b_out_* comes out of video_beam's column
                // table, already resolved between "add", "blend with our alpha"
                // and "plain replace" (a hairline pixel, which never blends).
                // Nothing above this line has to know which column it is.  The
                // laser columns resolve the same way, one branch earlier, in
                // l_out_*.
                //
                // Written as a flat chain rather than nested ternaries: one more
                // level of nesting here is exactly where the parentheses stopped
                // lining up.  b_visible is tested first because it may be a
                // hairline rather than a beam column.
                //
                // alpha_out is the bloom mask, not an opacity: a pixel radiates
                // when this byte is >= 32.  Every beam column radiates whichever
                // way it blends - the core adds and the halo blends, but both are
                // light - and so did the hairline before this change.
                alpha_out <= (hud_visible && hud_en_sync2) ? 8'd0
                           : b_visible ? 8'hFF
                           : l_visible ? 8'hFF
                           : w_visible ? 8'd0
                           : u_visible ? 8'hFF
                           : cur_pixel[31:24];

                red_out   <= (hud_visible && hud_en_sync2) ? hud_rgb[23:16]
                           : b_visible ? b_out_r
                           : l_visible ? l_out_r
                           : w_visible ? w_rgb[23:16]
                           : u_visible ? u_out_r
                           : cur_pixel[23:16];

                green_out <= (hud_visible && hud_en_sync2) ? hud_rgb[15:8]
                           : b_visible ? b_out_g
                           : l_visible ? l_out_g
                           : w_visible ? w_rgb[15:8]
                           : u_visible ? u_out_g
                           : cur_pixel[15:8];

                blue_out  <= (hud_visible && hud_en_sync2) ? hud_rgb[7:0]
                           : b_visible ? b_out_b
                           : l_visible ? l_out_b
                           : w_visible ? w_rgb[7:0]
                           : u_visible ? u_out_b
                           : cur_pixel[7:0];
            end else begin
                alpha_out <= 8'd0;
                red_out   <= 8'd0;
                green_out <= 8'd0;
                blue_out  <= 8'd0;
            end
        end
    end

endmodule
