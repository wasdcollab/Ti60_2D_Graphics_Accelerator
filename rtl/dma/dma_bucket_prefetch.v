`timescale 1ns / 1ps
// =============================================================================
// dma_bucket_prefetch.v
// -----------------------------------------------------------------------------
// B1 Architecture Bullet Bucket Table AXI4 Prefetch Controller & RAM Store.
// Stripped from video_dma_read.v as part of the Triad Architecture refactoring.
//
// Responsibilities:
// - Monitors pixel scanline timing and triggers bucket prefetch 2 lines ahead.
// - Two bursts, supporting 80 (16+4 beats) or 128 (16+16 beats) slots.
// - Stores fetched bucket entries into double-buffered on-chip Block RAM.
// - Lifts pre-fetched bucket entries during horizontal blanking into a parameterized
//   flat row vector (bucket_row) and asserts bucket_ready for the overlay layer.
// =============================================================================

module dma_bucket_prefetch #(
    parameter BUCKET_SLOTS        = 128,
    parameter BUCKET_GROUP_ROWS   = 8,
    parameter BUCKET_GROUP_SHIFT  = 3,
    parameter H_ACT               = 1366,
    parameter V_ACT               = 768,
    parameter V_TOTAL             = 782,
    parameter AXI_ADDR_WIDTH      = 28,
    parameter AXI_DATA_WIDTH      = 128
)(
    input  wire                       axi_clk,
    input  wire                       axi_rst_n,
    input  wire                       cal_done,

    // Bucket table configuration & base address
    input  wire [AXI_ADDR_WIDTH-1:0]  bucket_base,
    input  wire [AXI_ADDR_WIDTH-1:0]  active_base,

    // Synchronization from frame logic
    input  wire                       frame_clear_axi,
    input  wire                       discard_frame,
    input  wire                       at_line_start,
    input  wire                       fb_busy,

    // Coordination with Framebuffer Reader
    output reg                        bk_pend,
    output reg                        bk_act,

    // AXI4 Read Master Channel (to DMA top arbiter)
    output reg  [AXI_ADDR_WIDTH-1:0]  bk_araddr,
    output wire [7:0]                 bk_arlen,
    output reg                        bk_arvalid,
    input  wire                       bk_arready,

    input  wire [AXI_DATA_WIDTH-1:0]  bk_rdata,
    input  wire                       bk_rlast,
    input  wire                       bk_rvalid,
    output reg                        bk_rready,

    // Pixel Clock Domain Interface
    input  wire                       pixel_clk,
    input  wire                       pixel_rst_n,
    input  wire [11:0]                h_cnt,
    input  wire [10:0]                v_cnt,

    output wire [32*BUCKET_SLOTS-1:0] bucket_row,
    output wire                       bucket_ready
);

    // -------------------------------------------------------------------------
    // Pixel side: request the NEXT GROUP while this one is on screen.
    //
    // This used to request scanline N+2 while scanline N was showing.  With the
    // bucket's row unit being a group of BUCKET_GROUP_ROWS scanlines the request
    // moves to the first scanline of each group and asks for the group after it,
    // which leaves eight scanlines of headroom instead of two - more margin, not
    // less, for the AXI round trip and for the framebuffer reader holding the
    // mux.
    //
    // The last group of the frame asks for group 0.  That is what puts the next
    // frame's first bucket in the RAM before its first line starts, and it is
    // the group-granular replacement for the old V_TOTAL-2 / V_TOTAL-1 special
    // cases that fetched rows 0 and 1.
    //
    // WHY THE READ HALF IS THE CURRENT GROUP'S PARITY.  The RAM is two buckets
    // deep and the two halves hold "the group being scanned" and "the group being
    // fetched".  The fetch target is always the group AFTER the current one, so
    // its parity is always the opposite of the current group's - the writer and
    // the reader can never be in the same half.  Keying the read off ~v_cnt[0]
    // the way the per-scanline version did would break that here: eight
    // consecutive scanlines share one group, so four of them would read the half
    // the AXI writer owns and the curtain would tear into horizontal stripes.
    // -------------------------------------------------------------------------
    localparam integer GROUPS = V_ACT / BUCKET_GROUP_ROWS;

    // The bucket the LIFT presents.  The lift runs in scanline v_cnt's blanking
    // interval and its result is consumed by scanline v_cnt+1, so it has to be
    // the bucket of (v_cnt+1)'s group - NOT of v_cnt's.
    //
    // This is the one place the grouping can go wrong silently.  Taking v_cnt's
    // own group is right for seven scanlines out of every eight and wrong on the
    // eighth: there the next scanline is handed the PREVIOUS group's bucket, its
    // tile row reconstructs eight rows too high, and that scanline repeats what
    // the scanline eight above it already showed.  On the board that reads as
    // bands of the curtain sliding downwards - each group's last scanline
    // wearing the tile rows from eight rows up.
    // The frame's LAST blanking line (v_cnt == V_TOTAL-1) is the second arm of
    // bk_lift's condition, and the scanline it feeds is the NEXT FRAME's first
    // one - group 0.  Without the special case (781+1)>>3 is 97, past the last
    // group, and the first scanline of every frame is handed whatever happened
    // to be in that half.
    wire [10:0] disp_group  = (v_cnt == V_TOTAL - 1)
                              ? 11'd0
                              : ((v_cnt + 11'd1) >> BUCKET_GROUP_SHIFT);
    // The bucket to FETCH: one group past the one being scanned, requested on
    // each group's first scanline.  That leaves the AXI round trip eight
    // scanlines of slack, and it means group g+1 is already in the RAM by the
    // time disp_group first names it (on the last scanline of group g).  The
    // last group of the frame asks for group 0, which is what puts the next
    // frame's first bucket in the RAM in time.
    wire [10:0] fetch_group = ((v_cnt >> BUCKET_GROUP_SHIFT) + 11'd1 >= GROUPS)
                              ? 11'd0
                              : (v_cnt >> BUCKET_GROUP_SHIFT) + 11'd1;
    wire        at_group_start = (v_cnt < V_ACT) &&
                                 ((v_cnt & (BUCKET_GROUP_ROWS - 1)) == 11'd0);

    reg        bk_tog_pix;
    reg [10:0] bk_row_pix;              // the GROUP this request names

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            bk_tog_pix <= 1'b0;
            bk_row_pix <= 11'd0;
        end else if ((h_cnt == 12'd0) && at_group_start) begin
            bk_tog_pix <= ~bk_tog_pix;
            bk_row_pix <= fetch_group;
        end
    end

    // -------------------------------------------------------------------------
    // Cross request toggle from pixel_clk to axi_clk domain
    // -------------------------------------------------------------------------
    reg [2:0]  bk_tog_sync;
    reg [10:0] bk_pending_row;
    reg [10:0] bk_active_row;
    reg [27:0] bk_active_base;

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n)
            bk_tog_sync <= 3'b0;
        else
            bk_tog_sync <= {bk_tog_sync[1:0], bk_tog_pix};
    end
    wire bk_req_axi = bk_tog_sync[2] ^ bk_tog_sync[1];

    // 128-bit bus: four entries per beat, at most 32 beats per bucket.
    localparam integer ROW_BYTES = BUCKET_SLOTS * 4;
    localparam integer ROW_BEATS = BUCKET_SLOTS / 4;
    localparam [7:0] SECOND_ARLEN = ROW_BEATS - 17;
    // One table holds one bucket per GROUP, not per scanline.
    localparam [27:0] TABLE_BYTES = ROW_BYTES * (V_ACT / BUCKET_GROUP_ROWS);

    // Double-buffered bucket table address offset
    wire [27:0] bk_base = bucket_base + (active_base[22] ? TABLE_BYTES : 28'h0);

    // -------------------------------------------------------------------------
    // AXI Read State Machine for Bucket Prefetch
    // -------------------------------------------------------------------------
    localparam S_IDLE = 2'd0;
    localparam S_AR   = 2'd1;
    localparam S_R    = 2'd2;

    reg [1:0] state;
    reg       bk_burst; // first / second burst
    reg [3:0] bk_beat;
    reg       bk_drop;  // drain an old-frame transaction without publishing it

    assign bk_arlen = (bk_burst == 1'b0) ? 8'd15 : SECOND_ARLEN;

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            state      <= S_IDLE;
            bk_pend    <= 1'b0;
            bk_act     <= 1'b0;
            bk_burst   <= 1'b0;
            bk_beat    <= 4'd0;
            bk_pending_row <= 11'd0;
            bk_active_row  <= 11'd0;
            bk_active_base <= 28'd0;
            bk_drop    <= 1'b0;
            bk_araddr  <= 28'd0;
            bk_arvalid <= 1'b0;
            bk_rready  <= 1'b0;
        end else begin
            if (bk_req_axi) begin
                bk_pend    <= 1'b1;
                bk_pending_row <= bk_row_pix;
            end

            case (state)
                S_IDLE: begin
                    if (!frame_clear_axi && !discard_frame && cal_done &&
                        (bucket_base != 28'd0) && bk_pend && !bk_act &&
                        at_line_start && !fb_busy) begin
                        // Constant stride; 128 slots becomes a shift by nine.
                        bk_araddr  <= bk_base
                                      + bk_pending_row * ROW_BYTES;
                        bk_arvalid <= 1'b1;
                        bk_act     <= 1'b1;
                        // A new line request can arrive on this exact clock.
                        // The transaction consumes the old pending row; retain
                        // the new request for the following transaction.
                        bk_pend    <= bk_req_axi;
                        bk_active_row <= bk_pending_row;
                        bk_active_base <= bk_base;
                        bk_drop    <= 1'b0;
                        bk_burst   <= 1'b0;
                        bk_beat    <= 4'd0;
                        state      <= S_AR;
                    end
                end

                S_AR: begin
                    if (bk_arready) begin
                        bk_arvalid <= 1'b0;
                        bk_rready  <= 1'b1;
                        state      <= S_R;
                    end
                end

                S_R: begin
                    if (bk_rvalid) begin
                        if (bk_rlast) begin
                            bk_rready <= 1'b0;
                            if (bk_burst == 1'b0) begin
                                bk_burst   <= 1'b1;
                                bk_beat    <= 4'd0;
                                bk_araddr  <= bk_active_base
                                              + bk_active_row * ROW_BYTES
                                              + 28'd256;
                                bk_arvalid <= 1'b1;
                                state      <= S_AR;
                            end else begin
                                bk_act  <= 1'b0;
                                state   <= S_IDLE;
                            end
                        end else begin
                            bk_beat <= bk_beat + 4'd1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase

            if (frame_clear_axi) begin
                // AXI VALID cannot be withdrawn after it is presented, and an
                // accepted AR must keep its RREADY owner through RLAST.  Drain
                // the old bucket transaction before giving the mux to FB DMA.
                bk_pend    <= 1'b0;
                bk_drop    <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // B1: On-Chip Dual-Port RAM Store and Pixel-Domain Vector Lift
    // -------------------------------------------------------------------------
    wire        bk_wr = (state == S_R) && bk_act && bk_rvalid
                        && !frame_clear_axi && !bk_drop && !discard_frame;
    wire [4:0]  bk_widx = (bk_burst == 1'b0) ? {1'b0, bk_beat}
                                             : {1'b1, bk_beat};
    wire [5:0]  bk_waddr = {bk_active_row[0], 5'b0} + {1'b0, bk_widx};
    wire [127:0] bk_rd;

    wire [11:0] bk_off  = h_cnt - H_ACT;
    wire [4:0]  bk_lidx = bk_off[4:0];
    wire        bk_lift = (h_cnt >= H_ACT) && (h_cnt < H_ACT + 12'd32) &&
                          ((v_cnt < V_ACT) || (v_cnt == V_TOTAL - 1));
    // The half holding the group this lift is presenting - (v_cnt+1)'s group,
    // not v_cnt's; see disp_group above.  And not the parity of the scanline
    // either: eight consecutive scanlines share one bucket, so keying this off
    // v_cnt[0] would put the reader in the writer's half on half the lines of
    // every group.
    wire [5:0]  bk_raddr = {disp_group[0], 5'b0} + {1'b0, bk_lidx};

    // OUTPUT_REG must stay "TRUE".  With "FALSE" the read is asynchronous,
    // which no BRAM can do, so the synthesiser builds this 64 x 128-bit store
    // out of 8,192 flip-flops instead - and with them this block became the
    // single largest consumer of logic cells in the design (measured: 12,374
    // FFs and 6,017 LUTs, and physical placement failed with "Not enough
    // physical locations for Logic blocks: capacity=60800").  A synchronous
    // read costs one pixel clock, which the lift below absorbs by carrying its
    // address and enable alongside the data.  There is room for it: the lift
    // runs in the horizontal blanking interval (h_cnt 1366..1398 of 1456), not
    // while pixels are being scanned.
    simple_dual_port_ram #(
        .DATA_WIDTH (128),
        .ADDR_WIDTH (6),
        .OUTPUT_REG ("TRUE")
    ) u_bucket (
        .wclk  (axi_clk),
        .we    (bk_wr),
        .waddr (bk_waddr),
        .wdata (bk_rdata),
        .rclk  (pixel_clk),
        .re    (1'b1),
        .raddr (bk_raddr),
        .rdata (bk_rd)
    );

    reg [32*BUCKET_SLOTS-1:0] bucket_flat;
    reg                       bk_flat_ok;
    // The RAM's read is registered now, so its data lands one clock after the
    // address above.  These two carry the address and the enable along with it;
    // without them every slot would be filled with the previous slot's beat and
    // the curtain would come out shifted by one 128-bit word.
    reg [4:0]  bk_lidx_d;
    reg        bk_lift_d;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            bucket_flat <= {(32*BUCKET_SLOTS){1'b0}};
            bk_flat_ok  <= 1'b0;
            bk_lidx_d   <= 5'd0;
            bk_lift_d   <= 1'b0;
        end else begin
            bk_lidx_d <= bk_lidx;
            bk_lift_d <= bk_lift;
            if (bk_lift_d && (bk_lidx_d < ROW_BEATS)) begin
                bucket_flat[128*bk_lidx_d       +: 32] <= bk_rd[31:0];
                bucket_flat[128*bk_lidx_d + 32  +: 32] <= bk_rd[63:32];
                bucket_flat[128*bk_lidx_d + 64  +: 32] <= bk_rd[95:64];
                bucket_flat[128*bk_lidx_d + 96  +: 32] <= bk_rd[127:96];
            end
            if (h_cnt == H_ACT)
                bk_flat_ok <= 1'b0;
            else if (bk_lift_d && (bk_lidx_d == ROW_BEATS - 1))
                bk_flat_ok <= 1'b1;
        end
    end

    assign bucket_row   = bucket_flat;
    assign bucket_ready = bk_flat_ok && (bucket_base != 28'd0);

endmodule
