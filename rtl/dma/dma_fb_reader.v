module dma_fb_reader #(
    parameter FRAME_BASE_ADDR = 28'h0080_0000,
    parameter H_ACT           = 1366,
    parameter V_ACT           = 768,
    parameter AXI_ADDR_WIDTH  = 28,
    parameter AXI_DATA_WIDTH  = 128
)(
    input  wire                      axi_clk,
    input  wire                      axi_rst_n,
    input  wire                      cal_done,

    // Active frame base addresses from atomic VSync latch
    input  wire [AXI_ADDR_WIDTH-1:0] active_base,
    input  wire [AXI_ADDR_WIDTH-1:0] right_base,

    // Frame synchronization from pixel clock domain
    input  wire                      frame_start_axi,
    input  wire                      frame_clear_axi,

    // FIFO Watermark and Data Push
    input  wire [10:0]               fifo_wusedw,
    output wire                      fifo_winc,
    output wire [AXI_DATA_WIDTH-1:0] fifo_wdata,
    output reg                       video_read_priority,

    // Coordination with Bullet Bucket Prefetch
    input  wire                      bk_pend,
    input  wire                      bk_act,
    output wire                      at_line_start,
    output reg  [4:0]                burst_in_row,
    output reg  [12:0]               col_off,
    output reg                       discard_frame,

    // AXI4 Read Master Channel (to DMA top arbiter)
    output reg  [AXI_ADDR_WIDTH-1:0] fb_araddr,
    output reg  [7:0]                fb_arlen,
    output reg                       fb_arvalid,
    input  wire                      fb_arready,

    input  wire [AXI_DATA_WIDTH-1:0] fb_rdata,
    input  wire                      fb_rlast,
    input  wire                      fb_rvalid,
    output reg                       fb_rready
);

    // 2026-10-21: the scanout reader issues ONE burst at a time, so the DDR3
    // read latency L is paid once per burst and cannot be overlapped.  A row
    // therefore costs N*(1+L+BEATS), against a 1,699-cycle budget.
    //
    // Measured on the board with the underflow counter at APB 0x44 (low 16
    // bits, per frame):
    //   16-beat bursts: saturated at 0xFFFF  (>=25% of fetch points empty)
    //   32-beat bursts: 0xC328..0xC975       (~19%)
    // 32 beats halved the exposures but the row is still right at the edge -
    // 11*(33+L) + bucket share ~= 1,697 of 1,699 - so any DDR hiccup tears.
    //
    // 64 beats takes the row to 348 + 6L: with L=100 that is ~950 cycles,
    // leaving ~30% headroom.  This needs HALF_OFFSET to be a multiple of the
    // burst size (1024 B) or the left/right base switch lands mid-burst, so
    // the split moves 2560 -> 2048 B (640 -> 512 px) in step with
    // SCAN_HALF_PIXELS in sw/app/main.c.
    localparam [13:0] ROW_STRIDE     = 14'd8192;            // framebuffer row pitch (bytes)
    localparam [12:0] HALF_OFFSET    = 13'd2736;            // 684 px = 171 beats = 2736 B (50/50 split)
    localparam [8:0]  WORDS_PER_ROW  = (H_ACT + 3) / 4;                    // 1366 -> 342

    localparam S_IDLE = 2'd0;
    localparam S_AR   = 2'd1;
    localparam S_R    = 2'd2;

    reg [1:0]  state;
    reg [14:0] bursts_left;
    reg        start_pending;
    reg [27:0] row_addr;

    // Distinguish between unified full-screen mode (Menu, Game, Stress) where
    // active_base == right_base, and 50/50 split-screen mode (SCREEN_BITBLT) where
    // active_base != right_base.
    // Unified mode uses 6 bursts (5x64 + 1x22) to retain 30% DDR headroom, eliminating
    // scanout FIFO underflow / menu flicker under BitBlt contention.
    wire        is_split       = (active_base != right_base);
    wire [4:0]  bursts_per_row = is_split ? 5'd7 : 5'd6;
    wire [14:0] total_bursts   = is_split ? (15'd7 * V_ACT[14:0]) : (15'd6 * V_ACT[14:0]);
    wire        last_burst     = (burst_in_row == bursts_per_row - 5'd1);

    // Burst table for 1366x768 row (342 beats = 5472 B):
    // Unified 6-burst mode: 64, 64, 64, 64, 64, 22
    // Split 7-burst mode:
    //   Left  (active_base): 64, 64, 43 (=171 beats = 2736 B = 684 px)
    //   Right (right_base):  64, 21, 64, 22 (=171 beats = 2736 B = 684 px, bounded at 4KB)
    reg [7:0]  cur_arlen;
    reg [12:0] next_col_comb;
    always @(*) begin
        if (!is_split) begin
            case (burst_in_row)
                5'd0: begin cur_arlen = 8'd63; next_col_comb = 13'd1024; end
                5'd1: begin cur_arlen = 8'd63; next_col_comb = 13'd2048; end
                5'd2: begin cur_arlen = 8'd63; next_col_comb = 13'd3072; end
                5'd3: begin cur_arlen = 8'd63; next_col_comb = 13'd4096; end
                5'd4: begin cur_arlen = 8'd63; next_col_comb = 13'd5120; end
                5'd5: begin cur_arlen = 8'd21; next_col_comb = 13'd0;    end
                default: begin cur_arlen = 8'd63; next_col_comb = 13'd0; end
            endcase
        end else begin
            case (burst_in_row)
                5'd0: begin cur_arlen = 8'd63; next_col_comb = 13'd1024; end
                5'd1: begin cur_arlen = 8'd63; next_col_comb = 13'd2048; end
                5'd2: begin cur_arlen = 8'd42; next_col_comb = 13'd2736; end // ends at 2736 B
                5'd3: begin cur_arlen = 8'd63; next_col_comb = 13'd3760; end // 64 beats
                5'd4: begin cur_arlen = 8'd20; next_col_comb = 13'd4096; end // 21 beats -> 4KB boundary
                5'd5: begin cur_arlen = 8'd63; next_col_comb = 13'd5120; end // 64 beats
                5'd6: begin cur_arlen = 8'd21; next_col_comb = 13'd0;    end // 22 beats
                default: begin cur_arlen = 8'd63; next_col_comb = 13'd0; end
            endcase
        end
    end

    wire [12:0] next_col      = next_col_comb;
    wire [27:0] next_row      = last_burst ? (row_addr + ROW_STRIDE) : row_addr;

    assign at_line_start = (burst_in_row == 5'd0) && (col_off == 13'd0);

    // Scanout FIFO low watermark priority: refill FIFO before allowing BitBlt writes
    reg       want_prio;
    reg [8:0] prio_run;
    reg       prio_gap;
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            want_prio <= 1'b0; prio_run <= 9'd0; prio_gap <= 1'b0;
        end else if (frame_clear_axi || discard_frame || bursts_left == 15'd0) begin
            want_prio <= 1'b0; prio_run <= 9'd0; prio_gap <= 1'b0;
        end else begin
            if (fifo_wusedw < 11'd864)
                want_prio <= 1'b1;            // ~2.5 rows cushion
            else if (fifo_wusedw >= 11'd960)
                want_prio <= 1'b0;            // ~2.8 rows full

            // Fairness window.  The mux gives the scanout HARD priority, and
            // this reader asks for the bus every cycle while its FIFO is
            // below the watermark.  If the rest of the system ever makes the
            // FIFO slow to refill (heavy BitBlt/bucket traffic), that is a
            // continuous grant: the BitBlt's AR/AW are starved, its watchdog
            // aborts mid-command, and the engine is left out of sync - the
            // board freeze.  After 256 cycles of asking, hand the bus back
            // for 16 cycles.  The FIFO holds ~2.9 rows (5.4 KB each), so 16
            // cycles cost at most 256 bytes of one row; in exchange every
            // other master gets a guaranteed opening.
            if (prio_gap) begin
                if (prio_run == 9'd0) prio_gap <= 1'b0;
                else                  prio_run <= prio_run - 9'd1;
            end else if (want_prio) begin
                if (prio_run == 9'd255) begin
                    prio_gap <= 1'b1;
                    prio_run <= 9'd15;
                end else begin
                    prio_run <= prio_run + 9'd1;
                end
            end else begin
                prio_run <= 9'd0;
            end
        end
    end
    always @(*) video_read_priority = want_prio && !prio_gap;

    assign fifo_winc  = (state == S_R) && fb_rvalid && fb_rready && !discard_frame && !frame_clear_axi;
    assign fifo_wdata = fb_rdata;

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            state           <= S_IDLE;
            fb_araddr       <= FRAME_BASE_ADDR;
            fb_arlen        <= 8'd63;
            fb_arvalid      <= 1'b0;
            fb_rready       <= 1'b0;
            bursts_left     <= 15'd0;
            discard_frame   <= 1'b1;
            start_pending   <= 1'b0;
            row_addr        <= 28'd0;
            col_off         <= 13'd0;
            burst_in_row    <= 5'd0;
        end else begin
            if (frame_start_axi)
                start_pending <= 1'b1;

            case (state)
                S_IDLE: begin
                    if (!frame_clear_axi && (start_pending || frame_start_axi)) begin
                        row_addr        <= 28'd0;
                        col_off         <= 13'd0;
                        burst_in_row    <= 5'd0;
                        fb_araddr       <= active_base;
                        bursts_left     <= total_bursts;
                        discard_frame   <= 1'b0;
                        start_pending   <= 1'b0;
                    end else if (!frame_clear_axi && !discard_frame && cal_done &&
                                 (bursts_left > 15'd0) && (fifo_wusedw < 11'd960) &&
                                 !bk_act && !(bk_pend && at_line_start)) begin
                        fb_araddr  <= ((col_off >= HALF_OFFSET) ? right_base : active_base)
                                      + row_addr + {15'd0, col_off};
                        fb_arlen   <= cur_arlen;
                        fb_arvalid <= 1'b1;
                        state      <= S_AR;
                    end
                end

                S_AR: begin
                    if (fb_arready) begin
                        fb_arvalid <= 1'b0;
                        fb_rready  <= 1'b1;
                        state      <= S_R;
                    end
                end

                S_R: begin
                    if (fb_rvalid) begin
                        if (fb_rlast) begin
                            fb_rready    <= 1'b0;
                            col_off      <= next_col;
                            row_addr     <= next_row;
                            burst_in_row <= last_burst ? 5'd0 : (burst_in_row + 5'd1);
                            if (!discard_frame && (bursts_left > 15'd0))
                                bursts_left <= bursts_left - 15'd1;
                            state        <= S_IDLE;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase

            if (frame_clear_axi) begin
                discard_frame <= 1'b1;
                bursts_left   <= 15'd0;
                burst_in_row  <= 5'd0;
            end
        end
    end

endmodule
