`timescale 1ns/1ps
// =============================================================================
// bitblt_stride_gen  (v3 - pipelined tri-iterator 2D address generator)
// -----------------------------------------------------------------------------
// Fixes against v1
//   * v1 hard-coded every AXI burst to 16 beats (bitblt_stride_gen.v:74), which
//     is why the read channel could only ever fetch 256 B per round trip.
//     Burst length is now the parameter MAX_BURST_BEATS (default 64) and the
//     tail chunk is split in halves instead of leaving a 1-beat runt.
//   * v1 ran "read burst -> wait -> write burst -> wait" strictly in sequence.
//     v2 keeps independent read / write iterators with credit counters, so the
//     read of chunk N+1 overlaps the write of chunk N.
//   * v1 masked the write strobes for the destination alignment but fed the
//     write master with source-aligned data, so src/dst with different low
//     nibbles produced a shifted image.  v2 sizes the read stream as
//     N_read = N_write + 1 beats and hands both streams to
//     bitblt_align_shifter, which realigns the data (see that file).
//   * v1 had no configuration validation and could hang the CPU forever.
//     v2 validates strides, reports a sticky error bit and has a watchdog.
//
// v3 adds OP_ALPHA (2).  Real alpha blending has to read the LIVE destination
// background back before it can be blended, so the generator now drives THREE
// iterators: source read, destination-background read, and the write.  Both
// read streams share the single AXI read master (the Axi_Mux feeds DDR3 through
// one AR/R channel and returns read data in AR issue order, so a second read
// master would buy no extra concurrency) and are told apart by the `rd_is_dst`
// tag latched with the request.
//
// ROW GEOMETRY (all addresses 16-byte aligned, strides must be multiples of 16)
//   row_bytes = dst_off + 4*width                (dst_off = dst_addr[3:0])
//   N_write   = ceil(row_bytes / 16)
//   N_read    = N_write + 1                      (+1 look-ahead beat)
//   N_dst_rd  = N_write                          (background read lanes == write lanes)
// =============================================================================
module bitblt_stride_gen #(
    parameter integer MAX_BURST_BEATS = 64,
    parameter integer FIFO_DEPTH      = 192,
    parameter integer DST_FIFO_DEPTH  = 192,
    parameter integer WATCHDOG_CYCLES = 10000000,
    // How many read bursts may be outstanding at once.  Must not exceed the
    // queue depth of bitblt_axi_read_master.  The beat credit below is what
    // really caps it: a 64-beat burst plus the "+4" in rd_room_ok has to fit in
    // FIFO_DEPTH, so 192/64 leaves room for three and the fourth request is
    // refused by the credit check rather than by this number.
    parameter integer RD_MAX_OUT      = 4
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- command interface (from bitblt_apb_regs) ----
    input  wire        cmd_start,
    input  wire [1:0]  cmd_op_type,      // 0 = OP_FILL, 1 = OP_COPY, 2 = OP_ALPHA
    input  wire [27:0] cmd_dst_addr,
    input  wire [27:0] cmd_src_addr,
    input  wire [10:0] cmd_rect_w,
    input  wire [10:0] cmd_rect_h,
    input  wire [31:0] cmd_color,
    input  wire [15:0] cmd_src_stride,
    input  wire [15:0] cmd_dst_stride,
    output wire        busy,
    output reg         cmd_done,
    output reg         engine_abort,

    // ---- AXI4 read master (shared by both read streams) ----
    // Level, not pulse: the request is held until the master accepts it, exactly
    // like AXI VALID.  A one-cycle pulse cannot be handshaken against a
    // combinational ready - the pulse is registered, the ready is not, so the
    // two are a cycle apart and a request that arrives just as the master's
    // queue retires a burst is silently dropped.  That is precisely how this
    // started out, and the bench caught it as "reserved=65 writes_done=0".
    output wire        rd_req,
    output wire        rd_is_dst,        // 1 = the burst being requested reads the
                                         //     destination background (OP_ALPHA)
    output wire [27:0] rd_addr,
    output wire [7:0]  rd_len,           // 0-based beat count
    input  wire        rd_done,
    input  wire        rd_done_is_dst,   // which stream the retired burst fed
    input  wire [8:0]  rd_done_len,      // beats it delivered (len + 1)
    input  wire        rd_accept,        // master has room for the request
    output reg         fifo_clr,

    // ---- AXI4 write master ----
    output wire        data_from_fifo,
    output reg         burst_req,
    output reg  [27:0] burst_addr,
    output reg  [7:0]  burst_len,
    output reg  [127:0] burst_data,
    output reg  [15:0] burst_wstrb_first,
    output reg  [15:0] burst_wstrb_last,
    input  wire        burst_done,

    // ---- alignment shifter ----
    output reg  [4:0]  align_shift,      // 16 + sigma, range 1..31
    output reg  [9:0]  rows_done,        // completed rows (look-ahead credit)
    input  wire        beat_valid,       // shifter has the next output beat ready

    // ---- status ----
    output reg         err_timeout,

    // ---- live engine probe (read-only, added 2026-09-24) ----------------
    // The stride generator's state is what tells "the engine is wedged" from
    // "the engine is busy" - APB 0x74 publishes it.  A port, not a
    // hierarchical reference: Efinity will not resolve a reference into a
    // submodule's internal register (VERI-1172).  Nothing reads it back.
    output wire [1:0]  probe_state
);

    localparam S_IDLE     = 2'd0;
    localparam S_ROW_INIT = 2'd1;
    localparam S_LOOP     = 2'd2;
    localparam S_ROW_NEXT = 2'd3;

    localparam [1:0] OP_FILL  = 2'd0;
    localparam [1:0] OP_COPY  = 2'd1;
    localparam [1:0] OP_ALPHA = 2'd2;
    localparam [1:0] OP_ADD   = 2'd3;

    reg [1:0]  state;

    // ---------------- latched command ----------------
    reg [1:0]  r_op;
    reg [10:0] r_w, r_h;
    reg [15:0] r_dstride, r_sstride;
    reg [3:0]  r_doff;
    reg [12:0] row_bytes;        // r_doff + 4*width  (<= 15 + 4096)
    reg [10:0] row_idx;

    // ---------------- row / burst iterators ----------------
    reg [27:0] row_dst_base, row_src_base;
    reg [27:0] cur_wr_addr, cur_rd_addr;
    reg [27:0] cur_dst_rd_addr;  // OP_ALPHA background read cursor (== write cursor)
    reg [8:0]  wr_left, rd_left, dst_rd_left;
    reg        wr_inflight;
    reg [8:0]  wr_len_inflight;
    // v3 tracked ONE read burst with a bit plus a tag.  v4 lets several be in
    // flight, so the engine keeps a count per stream instead: the completion
    // that comes back is always the oldest request's, and the master reports
    // which stream that was.  Credit is still global (rd_reserved vs the FIFO
    // depth); these counters only gate how many requests may be live at once
    // and tell row_done when the row has actually been drained.
    reg [2:0]  rd_out_src, rd_out_dst;

    // ---- staged read request (valid/ready against the read master) -------
    // At most one is in flight between the engine and the request queue, which
    // is what keeps the slot accounting below honest: rd_out_* is bumped when
    // the request is STAGED, and the staging register is cleared only by the
    // handshake, so the engine can never have more requests in flight than it
    // counted.
    reg        rd_tx_pend;
    reg        rd_tx_is_dst;
    reg [27:0] rd_tx_addr;
    reg [7:0]  rd_tx_len;

    assign rd_req    = rd_tx_pend;
    assign rd_is_dst = rd_tx_is_dst;
    assign rd_addr   = rd_tx_addr;
    assign rd_len    = rd_tx_len;

    wire rd_tx_take = rd_tx_pend && rd_accept;
    // Room for one more staged request: either nothing is staged, or this cycle
    // hands the staged one over.
    wire rd_stage_ok = (rd_out_src + {1'b0, rd_out_dst}) < RD_MAX_OUT[3:0];
    wire rd_can_stage = (!rd_tx_pend || rd_tx_take) && rd_stage_ok;

    // ---------------- global credit counters ----------------
    // 19 bits, not 18: a full-screen 1366x768 copy is 768 x 342 = 262656 write
    // beats and 263424 read beats, and the 18-bit ceiling is 262143.  At 1024x600
    // (153600) and 1280x720 (230400) the old width was enough.
    reg [18:0] rd_reserved;      // source read beats issued
    // rd_arrived counts beats that have actually been delivered, and NOTHING
    // reads it: flow control uses rd_reserved (issued) minus what has been
    // written out, which is deliberately pessimistic.  Kept because it is the
    // only place the true occupancy exists, should a credit scheme ever want it -
    // but it is not the number the credit check uses today.
    reg [18:0] rd_arrived;       // delivered into the FIFO (no reader)
    reg [18:0] dst_rd_reserved;  // background read beats issued
    reg [18:0] wr_done_cnt;      // write beats completed

    // ---------------- watchdog ----------------
    reg [25:0] wd_cnt;

    // Final-row drain flag: S_ROW_NEXT parks on the last row until every
    // outstanding read retires, so late beats cannot land in the FIFO after the
    // next command's clr.  Rows before the last one do NOT wait.
    reg        last_row_wait;

    wire [8:0] wr_beats_row = (row_bytes + 13'd15) >> 4;
    wire [8:0] rd_beats_row = wr_beats_row + 9'd1;

    assign busy            = (state != S_IDLE);
    assign data_from_fifo  = (r_op != 2'd0);

    // ---------------------------------------------------------------------
    // Chunk sizing: never exceed MAX_BURST_BEATS, never cross a 4 KiB page,
    // and split the tail into two halves instead of leaving a runt burst.
    // ---------------------------------------------------------------------
    wire [8:0] bmax     = MAX_BURST_BEATS[8:0];
    wire [8:0] two_bmax = {bmax[7:0], 1'b0};
    wire [8:0] wr_page  = 9'd256 - {1'b0, cur_wr_addr[11:4]};
    wire [8:0] rd_page  = 9'd256 - {1'b0, cur_rd_addr[11:4]};
    wire [8:0] dr_page  = 9'd256 - {1'b0, cur_dst_rd_addr[11:4]};

    function [8:0] chunk_len;
        input [8:0] rem;
        input [8:0] page;
        input [8:0] lim;
        input [8:0] two_lim;
        reg   [8:0] base;
        begin
            if (rem <= lim)          base = rem;
            else if (rem <= two_lim) base = (rem + 9'd1) >> 1;
            else                     base = lim;
            chunk_len = (base > page) ? page : base;
        end
    endfunction

    wire [8:0] wr_chunk = chunk_len(wr_left, wr_page, bmax, two_bmax);
    wire [8:0] rd_chunk = chunk_len(rd_left, rd_page, bmax, two_bmax);
    wire [8:0] dr_chunk = chunk_len(dst_rd_left, dr_page, bmax, two_bmax);

    // Credit accounting.  A beat counts as "in the FIFO" from the moment its
    // burst is issued until the write of the corresponding beat completes, so
    // both streams stay inside their FIFO depth even though the read master
    // serves them one burst at a time.  The "+4" covers the beats that are in
    // flight inside the read master and the alignment shifter.
    // Each completed COPY/ALPHA row consumes one source look-ahead beat
    // without a matching write beat (see align_shifter rows_done). Charging
    // it forever falsely fills the FIFO on tall surfaces; the stall row
    // depends on burst sizing and the write-side prefetch requirement.
    wire [18:0] rd_pending  = rd_reserved - wr_done_cnt - {9'd0, rows_done};
    wire        rd_room_ok  = (rd_pending + {10'd0, rd_chunk} + 19'd4) <= FIFO_DEPTH[18:0];

    // The background stream is consumed exactly once per write beat, so the
    // same write counter is its consumption pointer.  Keeping
    // DST_FIFO_DEPTH > 2*MAX_BURST_BEATS makes the check safe: a burst that has
    // already been charged can never be starved by its own accounting.
    wire [18:0] dr_pending  = dst_rd_reserved - wr_done_cnt;
    wire        dr_room_ok  = (dr_pending + {10'd0, dr_chunk} + 19'd4) <= DST_FIFO_DEPTH[18:0];

    // Both read iterators share the one AXI read master, so they share one
    // outstanding-burst budget.  The credit check still runs on top: rd_room_ok
    // is what keeps the FIFO from being over-committed, rd_can_stage is what
    // keeps the request queue from filling.
    wire issue_wr  = (state == S_LOOP) && !wr_inflight && (wr_left != 9'd0) &&
                     ((r_op == OP_FILL) || beat_valid);
    wire issue_rd  = (state == S_LOOP) && (r_op != OP_FILL) && rd_can_stage &&
                     (rd_left != 9'd0) && rd_room_ok;
    wire issue_drd = (state == S_LOOP) && ((r_op == OP_ALPHA) || (r_op == OP_ADD)) && rd_can_stage &&
                     (dst_rd_left != 9'd0) && dr_room_ok;

    // Exact cycle qualification for burst dispatch vs completion
    wire rd_take_src   = (state == S_LOOP) && !issue_wr && !issue_drd && issue_rd;
    wire rd_take_dst   = (state == S_LOOP) && !issue_wr && issue_drd;
    wire rd_retire_src = rd_done && !rd_done_is_dst;
    wire rd_retire_dst = rd_done && rd_done_is_dst;

    // A row is done the moment every beat of it has been ISSUED, not when the
    // reads have drained: the old condition also required rd_out_src/dst to be
    // zero, which flushed the read pipeline at every row boundary and made each
    // row pay the full DDR read latency again ("per-row = read latency + 31.9").
    // The FIFO credit (rd_room_ok) and the shifter's pop accounting already
    // gate correctness; only the FINAL row of a command still drains, in
    // S_ROW_NEXT below, so late beats cannot leak into the next command's FIFO.
    wire row_done = (state == S_LOOP) && !wr_inflight &&
                    (wr_left == 9'd0) && (rd_left == 9'd0) && (dst_rd_left == 9'd0);

    // tail-of-row detection for the write strobes
    wire wr_chunk_is_first = (wr_left == wr_beats_row);
    wire wr_chunk_is_last  = (wr_chunk == wr_left);
    wire [3:0] end_bytes   = row_bytes[3:0];

    // ---------------------------------------------------------------------
    // Fill pattern.  AXI beats are 16 bytes, so a destination that does not
    // start on a 16-byte boundary needs the replicated colour rotated: byte
    // lane L of the beat must carry colour byte ((L - dst_off) mod 4).
    // ---------------------------------------------------------------------
    wire [127:0] fill_rep = {4{cmd_color}};
    wire [1:0]   fill_rot = cmd_dst_addr[1:0];
    wire [127:0] fill_data =
        (fill_rot == 2'd0) ? fill_rep :
        (fill_rot == 2'd1) ? {fill_rep[119:0],  fill_rep[127:120]} :
        (fill_rot == 2'd2) ? {fill_rep[111:0],  fill_rep[127:112]} :
                             {fill_rep[103:0],  fill_rep[127:104]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= S_IDLE;
            engine_abort         <= 1'b0;
            // rd_req / rd_is_dst / rd_addr / rd_len are driven by the staging
            // register through continuous assigns now, so they are not reset
            // here - rd_tx_pend is, further down.
            fifo_clr             <= 1'b0;
            burst_req            <= 1'b0;
            burst_addr           <= 28'd0;
            burst_len            <= 8'd0;
            burst_data           <= 128'd0;
            burst_wstrb_first    <= 16'hFFFF;
            burst_wstrb_last     <= 16'hFFFF;
            cmd_done             <= 1'b0;
            err_timeout          <= 1'b0;
            r_op                 <= 2'd0;
            r_w                  <= 11'd0;
            r_h                  <= 11'd0;
            r_dstride            <= 16'd4096;
            r_sstride            <= 16'd4096;
            r_doff               <= 4'd0;
            row_bytes            <= 13'd0;
            row_idx              <= 11'd0;
            row_dst_base         <= 28'd0;
            row_src_base         <= 28'd0;
            cur_wr_addr          <= 28'd0;
            cur_rd_addr          <= 28'd0;
            cur_dst_rd_addr      <= 28'd0;
            wr_left              <= 9'd0;
            rd_left              <= 9'd0;
            dst_rd_left          <= 9'd0;
            wr_inflight          <= 1'b0;
            wr_len_inflight      <= 9'd0;
            rd_out_src           <= 3'd0;
            rd_out_dst           <= 3'd0;
            rd_tx_pend           <= 1'b0;
            rd_tx_is_dst         <= 1'b0;
            rd_tx_addr           <= 28'd0;
            rd_tx_len            <= 8'd0;
            rd_reserved          <= 19'd0;
            rd_arrived           <= 19'd0;
            dst_rd_reserved      <= 19'd0;
            wr_done_cnt          <= 19'd0;
            align_shift          <= 5'd16;
            rows_done            <= 10'd0;
            wd_cnt               <= 26'd0;
        end else begin
            // Hand the staged request over before anything else gets a look at
            // the slot, so issue_rd below can refill it on the same cycle.
            if (rd_tx_take)
                rd_tx_pend <= 1'b0;

            burst_req <= 1'b0;
            fifo_clr  <= 1'b0;
            cmd_done  <= 1'b0;
            // ---- read completion accounting ----
            // Bursts retire in issue order, so the tag and length the master
            // reports belong to the oldest outstanding request of whichever
            // stream asked for it.
            if (rd_done && !rd_done_is_dst) begin
                rd_arrived <= rd_arrived + {10'd0, rd_done_len};
            end

            // Atomic outstanding read counter update:
            // Handles simultaneous burst dispatch and retirement in the exact same clock cycle.
            case ({rd_take_src, rd_retire_src})
                2'b10:   rd_out_src <= rd_out_src + 3'd1;
                2'b01:   rd_out_src <= rd_out_src - 3'd1;
                default: ; // 2'b11: net zero change; 2'b00: no change
            endcase

            case ({rd_take_dst, rd_retire_dst})
                2'b10:   rd_out_dst <= rd_out_dst + 3'd1;
                2'b01:   rd_out_dst <= rd_out_dst - 3'd1;
                default: ; // 2'b11: net zero change; 2'b00: no change
            endcase
            // ---- write completion accounting ----
            if (burst_done) begin
                wr_inflight <= 1'b0;
                wr_done_cnt <= wr_done_cnt + {9'd0, wr_len_inflight};
            end

            case (state)
            // -------------------------------------------------------------
            S_IDLE: begin
                if (cmd_start) begin
                    engine_abort <= 1'b0;
                    r_op       <= cmd_op_type;
                    r_w        <= cmd_rect_w;
                    r_h        <= cmd_rect_h;
                    r_dstride  <= (cmd_dst_stride == 16'd0) ? 16'd4096 : cmd_dst_stride;
                    r_sstride  <= (cmd_src_stride == 16'd0) ? 16'd4096 : cmd_src_stride;
                    r_doff     <= cmd_dst_addr[3:0];
                    row_bytes  <= {2'b0, cmd_dst_addr[3:0]} + ({5'd0, cmd_rect_w} << 2);
                    burst_data <= fill_data;
                    align_shift<= 5'd16 + {1'b0, cmd_src_addr[3:0]} - {1'b0, cmd_dst_addr[3:0]};
                    row_dst_base <= {cmd_dst_addr[27:4], 4'b0000};
                    row_src_base <= {cmd_src_addr[27:4], 4'b0000};
                    row_idx    <= 11'd0;
                    wr_left    <= 9'd0;
                    rd_left    <= 9'd0;
                    dst_rd_left<= 9'd0;
                    wr_inflight<= 1'b0;
                    rd_out_src <= 3'd0;
                    rd_out_dst <= 3'd0;
                    rd_tx_pend <= 1'b0;
                    rd_reserved<= 19'd0;
                    rd_arrived <= 19'd0;
                    dst_rd_reserved <= 19'd0;
                    wr_done_cnt<= 19'd0;
                    rows_done  <= 10'd0;
                    err_timeout<= 1'b0;
                    wd_cnt     <= 26'd0;
                    last_row_wait <= 1'b0;
                    fifo_clr   <= 1'b1;

                    // bitblt_apb_regs only asserts cmd_start for a legal,
                    // non-degenerate rectangle; the guard below is the
                    // defensive second line of defence (a height of 0 would
                    // otherwise cycle the row counter forever).
                    if (cmd_rect_w != 11'd0 && cmd_rect_h != 11'd0)
                        state <= S_ROW_INIT;
                end
            end
            // -------------------------------------------------------------
            S_ROW_INIT: begin
                cur_wr_addr     <= row_dst_base;
                cur_rd_addr     <= row_src_base;
                cur_dst_rd_addr <= row_dst_base;
                wr_left         <= wr_beats_row;
                rd_left         <= (r_op == OP_FILL) ? 9'd0 : rd_beats_row;
                dst_rd_left     <= ((r_op == OP_ALPHA) || (r_op == OP_ADD)) ? wr_beats_row : 9'd0;
                state           <= S_LOOP;
            end
            // -------------------------------------------------------------
            S_LOOP: begin
                // watchdog: never leave the CPU polling a dead engine
                if (wd_cnt == WATCHDOG_CYCLES[25:0]) begin
                    engine_abort <= 1'b1;
                    rd_tx_pend <= 1'b0;
                    wr_inflight <= 1'b0;
                    rd_out_src <= 3'd0;
                    rd_out_dst <= 3'd0;
                    err_timeout <= 1'b1;
                    state       <= S_IDLE;
                    cmd_done    <= 1'b1;
                end else begin
                    wd_cnt <= wd_cnt + 26'd1;

                    if (issue_wr) begin
                        wr_inflight     <= 1'b1;
                        wr_len_inflight <= wr_chunk;
                        wr_left         <= wr_left - wr_chunk;
                        cur_wr_addr     <= cur_wr_addr + {13'd0, wr_chunk, 4'd0};
                        burst_req       <= 1'b1;
                        burst_addr      <= cur_wr_addr;
                        burst_len       <= wr_chunk[7:0] - 8'd1;
                        // byte-granular row head / tail masking; a single-beat
                        // burst gets (first & last) from the write master.
                        burst_wstrb_first <= wr_chunk_is_first
                                             ? (16'hFFFF << r_doff) : 16'hFFFF;
                        burst_wstrb_last  <= (wr_chunk_is_last && (end_bytes != 4'd0))
                                             ? (16'hFFFF >> (5'd16 - {1'b0, end_bytes}))
                                             : 16'hFFFF;
                    end else if (issue_drd) begin
                        rd_tx_pend          <= 1'b1;
                        rd_tx_is_dst        <= 1'b1;
                        rd_tx_addr          <= cur_dst_rd_addr;
                        rd_tx_len           <= dr_chunk[7:0] - 8'd1;
                        dst_rd_left         <= dst_rd_left - dr_chunk;
                        dst_rd_reserved     <= dst_rd_reserved + {9'd0, dr_chunk};
                        cur_dst_rd_addr     <= cur_dst_rd_addr + {13'd0, dr_chunk, 4'd0};
                    end else if (issue_rd) begin
                        rd_tx_pend          <= 1'b1;
                        rd_tx_is_dst        <= 1'b0;
                        rd_tx_addr          <= cur_rd_addr;
                        rd_tx_len           <= rd_chunk[7:0] - 8'd1;
                        rd_left             <= rd_left - rd_chunk;
                        rd_reserved         <= rd_reserved + {9'd0, rd_chunk};
                        cur_rd_addr         <= cur_rd_addr + {13'd0, rd_chunk, 4'd0};
                    end else if (row_done) begin
                        state <= S_ROW_NEXT;
                    end
                end
            end
            // -------------------------------------------------------------
            S_ROW_NEXT: begin
                if (last_row_wait) begin
                    // Parked on the final row: retire only once every read has
                    // come back, then hand the FIFO over clean.  rd_done
                    // accounting runs unconditionally, so it drains here.  The
                    // watchdog stays armed: a DDR response that never returns
                    // must still trip err_timeout instead of hanging forever.
                    if (wd_cnt == WATCHDOG_CYCLES[25:0]) begin
                        engine_abort <= 1'b1;
                        rd_tx_pend <= 1'b0;
                        wr_inflight <= 1'b0;
                        rd_out_src <= 3'd0;
                        rd_out_dst <= 3'd0;
                        err_timeout  <= 1'b1;
                        last_row_wait <= 1'b0;
                        state         <= S_IDLE;
                        cmd_done      <= 1'b1;
                    end else begin
                        wd_cnt <= wd_cnt + 26'd1;
                        if ((rd_out_src == 3'd0) && (rd_out_dst == 3'd0)) begin
                            last_row_wait <= 1'b0;
                            state         <= S_IDLE;
                            cmd_done      <= 1'b1;
                        end
                    end
                end else if (row_idx + 11'd1 == r_h) begin
                    rows_done     <= rows_done + 10'd1;
                    last_row_wait <= 1'b1;
                end else begin
                    rows_done     <= rows_done + 10'd1;
                    row_idx       <= row_idx + 11'd1;
                    row_dst_base  <= row_dst_base + {12'd0, r_dstride};
                    row_src_base  <= row_src_base + {12'd0, r_sstride};
                    wd_cnt        <= 26'd0;
                    state         <= S_ROW_INIT;
                end
            end
            default: state <= S_IDLE;
            endcase
        end
    end

    // Read-only probe tap (see the port list).  Only the APB 0x74 mirror
    // reads this; the datapath does not see it.
    assign probe_state = state;

endmodule
