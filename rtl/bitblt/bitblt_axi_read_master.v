`timescale 1ns/1ps
// =============================================================================
// bitblt_axi_read_master  (v4)
// -----------------------------------------------------------------------------
// Changes against v3 (the concurrency change):
//
//   * v3 could have exactly ONE read burst outstanding.  AR was issued from a
//     two-state machine that did not leave S_R until RLAST arrived, so the read
//     throughput was pinned to
//
//         MAX_BURST_BEATS * 16 bytes / (AR->RLAST round trip)
//
//     and the round trip through Axi_Mux and the DDR3 controller is a couple of
//     hundred core clocks.  A full-screen 1366x768 COPY is 768 rows x 342 beats,
//     i.e. ~4100 bursts, and the game redraws two surfaces that size every
//     frame - which is where the 30 FPS came from.
//
//   * v4 keeps a small queue of outstanding requests and issues AR back to
//     back, so the controller always has the next burst in hand.  The queue
//     depth is the parameter MAX_OUTSTANDING; the beat credit in
//     bitblt_stride_gen (READ_FIFO_DEPTH) is what actually limits how many can
//     be useful, so the two are sized together.
//
//   * Ordering is what makes this cheap.  Axi_Mux feeds DDR3 through a single
//     AR/R channel and returns read data in AR ISSUE ORDER (it does not decode
//     RID - see the v3 note below), so the completion that belongs to a request
//     is always the OLDEST one outstanding.  The queue therefore only has to
//     remember, per entry, which stream the burst belongs to and how long it
//     was; RLAST pops the head and reports both back to stride_gen, which
//     decrements the matching per-stream counter.
//
//   * `rd_accept` is new: a request may only be presented when the queue has
//     room.  stride_gen gates its issue on it instead of assuming every request
//     is taken.  Requests are never accepted in the same cycle a burst
//     completes, which keeps the queue pointers to a single update per cycle.
//
// Kept from v3:
//   * two read streams (source surface and, for OP_ALPHA, the live destination
//     background) are told apart by the `rd_is_dst` tag latched with the burst,
//     and each stream has its own FIFO full flag so back-pressure is per stream.
//   * RREADY is a combinational function of the head of the queue, so a beat is
//     taken every cycle the FIFO has room.
//   * FIFO back-pressure: the burst length is never allowed to overrun the FIFO.
// =============================================================================
module bitblt_axi_read_master #(
    parameter integer MAX_OUTSTANDING = 4
)(
    input  wire         clk,
    input  wire         rst_n,

    // Command interface from stride_gen
    input  wire         rd_req,
    input  wire         rd_is_dst,   // 1 = this burst reads the destination background
    input  wire [27:0]  rd_addr,
    input  wire [7:0]   rd_len,      // 0-based: 0 = 1 beat, 15 = 16 beats
    output reg          rd_done,     // single-cycle pulse when a burst completes
    output reg          rd_done_is_dst,  // ... and which stream it belonged to
    output reg  [8:0]   rd_done_len,     // ... and how many beats it delivered
    output wire         rd_accept,   // 1 = a rd_req asserted this cycle is taken
    output wire         rd_busy,

    // FIFO back-pressure, one flag per stream
    input  wire         fifo_full_src,
    input  wire         fifo_full_dst,

    // AXI4 Read Master (128-bit)
    output reg  [3:0]   m_axi_arid,
    // wire, not reg: the AR channel is driven from the request queue by
    // continuous assigns so that the address and the valid are never a cycle
    // apart.  Efinity rejects a continuous assign to a reg port (VERI-1195)
    // even though Vivado's xvlog accepts it, which is how the first version of
    // this got as far as a failed synthesis instead of a failed elaboration.
    output wire [27:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire [1:0]   m_axi_arlock,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,

    input  wire [3:0]   m_axi_rid,
    input  wire [127:0] m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,

    // To the read FIFOs
    output wire         fifo_winc_src,
    output wire         fifo_winc_dst,
    output wire [127:0] fifo_wdata,

    // ---- live engine probe (read-only, added 2026-09-24) ----------------
    // The APB 0x74 mirror reports the request-queue occupancy and whether a
    // request is staged on AR; both live in this module.  They come out as
    // PORTS rather than being read by hierarchical reference because
    // Efinity's elaborator does not resolve a reference into a submodule's
    // internal register - VERI-1172, "external reference remains
    // unresolved" - which is how the first attempt at this probe failed to
    // elaborate at all.  Nothing in the datapath reads either one.
    output wire [2:0]   probe_q_cnt,
    output wire         probe_ar_pend
);

    assign m_axi_arsize  = 3'b100;  // 16 bytes per beat (128-bit)
    assign m_axi_arburst = 2'b01;   // INCR
    assign m_axi_arlock  = 2'b00;

    localparam integer WQ  = MAX_OUTSTANDING;     // queue depth, and the pointers are sized from it
    localparam [2:0]   QMAX = WQ[2:0];
    initial begin
        if (WQ < 1 || WQ > 8) begin
            $error("MAX_OUTSTANDING=%0d is out of range", WQ);
            $error("  the queue pointers are 2 bits and the occupancy counter is 3");
            $error("  so the depth has to be 1..8");
        end
    end

    // ---- outstanding-request queue -------------------------------------
    // A ring buffer, NOT a shift register.  A shift-register FIFO only works if
    // every push shifts the whole queue, which puts the head at a position that
    // depends on how many entries are in it - a version of this file did that
    // and read the wrong entry, so the R data of a COPY went into the ALPHA
    // background FIFO and the engine's `reserved` climbed while `writes_done`
    // stayed at zero.  With head/tail pointers the oldest entry is always at
    // q_head and nothing has to move.
    reg        q_dst [0:WQ-1];      // which stream the burst feeds
    reg [8:0]  q_len [0:WQ-1];      // beats it will deliver (len + 1)
    reg [1:0]  q_head, q_tail;
    reg [2:0]  q_cnt;               // 0 .. WQ

    reg               ar_pend;      // an accepted request has not been AR'd yet
    reg [27:0]        ar_addr;
    reg [7:0]         ar_len;

    wire q_full = (q_cnt == QMAX);
    wire head_is_dst = q_dst[q_head];

    // ---- R channel: serve the head of the queue -------------------------
    wire        fifo_full   = head_is_dst ? fifo_full_dst : fifo_full_src;
    wire        r_fire      = (q_cnt != 3'd0) && m_axi_rvalid && m_axi_rready;
    wire        r_last_fire = r_fire && m_axi_rlast;

    assign m_axi_rready  = (q_cnt != 3'd0) && !fifo_full;

    assign fifo_winc_src = r_fire && !head_is_dst;
    assign fifo_winc_dst = r_fire &&  head_is_dst;
    assign fifo_wdata    = m_axi_rdata;

    // ---- request acceptance ---------------------------------------------
    // Never in the same cycle a burst retires: that would make q_cnt, q_is_dst
    // and q_len all need two updates in one cycle for no throughput gain, since
    // a retiring burst frees exactly the slot a new request would take.
    // A request may be taken whenever the staging slot will be FREE NEXT CYCLE
    // - either it is already empty, or this very cycle hands the staged one to
    // the bus.  The original required !ar_pend outright, which made the
    // back-to-back branch in the AR block below unreachable: that branch needs
    // req_fire, req_fire needs rd_accept, and rd_accept needed !ar_pend.  So
    // every AR paid an idle cycle, the queue never filled, and the version's
    // whole purpose - keeping the controller fed - did not happen.
    wire staging_free = !ar_pend || m_axi_arready;
    assign rd_accept  = staging_free && !q_full && !r_last_fire;
    assign rd_busy   = (q_cnt != 3'd0) || ar_pend;

    wire req_fire = rd_req && rd_accept;

    assign m_axi_arvalid = ar_pend;
    assign m_axi_araddr  = ar_addr;
    assign m_axi_arlen   = ar_len;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_head        <= 2'd0;
            q_tail        <= 2'd0;
            q_cnt         <= 3'd0;
            ar_pend       <= 1'b0;
            ar_addr       <= 28'd0;
            ar_len        <= 8'd0;
            rd_done       <= 1'b0;
            rd_done_is_dst<= 1'b0;
            rd_done_len   <= 9'd0;
            m_axi_arid    <= 4'd2;
        end else begin
            rd_done <= 1'b0;

            // ---- queue push -------------------------------------------------
            if (req_fire) begin
                q_dst[q_tail]  <= rd_is_dst;
                q_len[q_tail]  <= {1'b0, rd_len} + 9'd1;
                q_tail         <= q_tail + 2'd1;
                q_cnt          <= q_cnt + 3'd1;
            end

            // ---- queue pop --------------------------------------------------
            if (r_last_fire) begin
                rd_done        <= 1'b1;
                rd_done_is_dst <= head_is_dst;
                rd_done_len    <= q_len[q_head];
                q_head         <= q_head + 2'd1;
                // req_fire can never be true here - rd_accept carries !r_last_fire - so
                // this guard never fires and the subtraction always happens.  Kept
                // because a bare decrement would read as if a simultaneous push and pop
                // were impossible rather than arranged.  The arrangement is the
                // !r_last_fire inside rd_accept; that one is load-bearing.
                if (!req_fire)
                    q_cnt <= q_cnt - 3'd1;
            end

            // ---- AR channel -------------------------------------------------
            // Back-to-back: as soon as the current AR is taken, the next queued
            // request takes its place on the same cycle.  That is the whole
            // point of the change - the controller never waits for RLAST.
            if (ar_pend) begin
                if (m_axi_arready) begin
                    if (req_fire) begin
                        ar_addr <= rd_addr;
                        ar_len  <= rd_len;
                    end else begin
                        ar_pend <= 1'b0;
                    end
                end
            end else if (req_fire) begin
                ar_addr <= rd_addr;
                ar_len  <= rd_len;
                ar_pend <= 1'b1;
            end
        end
    end

    // ---- read-only probe taps (see the port list) -----------------------
    // Down here rather than beside the other continuous assigns: iverilog
    // rejects a continuous assign whose target is declared later in the
    // file, and both taps point at registers declared below the datapath.
    assign probe_q_cnt   = q_cnt;
    assign probe_ar_pend = ar_pend;

endmodule
