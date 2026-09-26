`timescale 1ns/1ps
// =============================================================================
// bitblt_align_shifter
// -----------------------------------------------------------------------------
// Byte-granular realignment stage between the BitBlt read FIFO and the AXI4
// write master.
//
// WHY IT IS NEEDED
//   AXI4 bursts must be 16-byte aligned, so the read engine fetches from
//   sa = src_addr & ~15 while the write engine writes to da = dst_addr & ~15.
//   The bytes the destination actually needs start at sigma = src_addr - dst_addr
//   inside the read stream, i.e. they straddle two consecutive read beats.
//   Without this stage the copy silently shifts by (dst_off - src_off) bytes
//   whenever the two addresses have different low nibbles.
//
// HOW IT WORKS
//   win : 3 x 128-bit shift register holding the last three read beats,
//         {D(k+1), D(k), D(k-1)} with the newest beat in the MSB lane.
//   Output beat k = win[8*(16+sigma) +: 128]                   (16+sigma = 1..31)
//   The window is advanced (one beat popped out of the FIFO) while there is
//   room for the next output beat:
//         pops < wr_done + rows_done + 2  (+1 when a beat is consumed now)
//   where
//     +2          : pipeline pre-fill - two read beats must be present before
//                   the very first output beat can be assembled (the missing
//                   D(-1) lane is zero and is always strobe-masked);
//     +rows_done  : every copied row issues exactly one extra read beat
//                   (the look-ahead beat), which has no matching write beat.
//
// The shift amount is constant for a whole command, so the 32-byte funnel is
// a fixed 4-stage byte rotator (1/2/4/8 bytes).
// =============================================================================
module bitblt_align_shifter #(
    parameter integer DATA_BYTES = 16,
    // How many read beats the window is allowed to run ahead of the
    // write pointer.  2 is the minimum that lets the funnel assemble a
    // beat at all (the missing D(-1) lane is zero and strobe-masked).
    // Larger values let bitblt_stride_gen keep more read bursts in
    // flight, which is the whole point of the concurrent read master -
    // at the default of 2 the FIFO refuses the extra beats and the
    // master's queue stays empty.  Made a parameter so the effect can
    // be measured before anything is committed to it.
    parameter integer PREFETCH_BEATS = 2
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     clr,           // command boundary
    input  wire [4:0]               shift_bytes,   // 16 + sigma, range 1..31

    // read FIFO side (first-word fall-through, combinational read data)
    input  wire [DATA_BYTES*8-1:0]  fifo_rdata,
    input  wire                     fifo_empty,
    output wire                     fifo_rinc,

    // write side (to the AXI4 write master)
    output wire [DATA_BYTES*8-1:0]  beat_data,
    input  wire                     beat_ack,      // write master consumed one beat
    output wire                     beat_valid,    // next output beat is fully assembled
    input  wire [9:0]               rows_done      // completed rows (from stride_gen)
);

    localparam integer W = DATA_BYTES*8;

    reg  [3*W-1:0] win;
    reg  [18:0]    pops;
    reg  [18:0]    wr_done;

    // Number of read beats that must have been popped for the *next* output beat
    // to be complete.
    wire [18:0] need = {9'd0, rows_done} + wr_done + {13'd0, PREFETCH_BEATS[5:0]};

    assign beat_valid = (pops >= need);

    // Pop policy: always keep two beats of look-ahead over the write pointer.
    wire [18:0] limit  = need + (beat_ack ? 19'd1 : 19'd0);
    assign      fifo_rinc = !fifo_empty && (pops < limit);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win     <= {(3*W){1'b0}};
            pops    <= 19'd0;
            wr_done <= 19'd0;
        end else if (clr) begin
            win     <= {(3*W){1'b0}};
            pops    <= 19'd0;
            wr_done <= 19'd0;
        end else begin
            if (fifo_rinc)
                win <= {fifo_rdata, win[3*W-1:W]};
            if (fifo_rinc)
                pops <= pops + 19'd1;
            if (beat_ack)
                wr_done <= wr_done + 19'd1;
        end
    end

    // ---------------------------------------------------------------------
    // Funnel: select DATA_BYTES bytes starting at byte offset `off`.
    //
    //   shift = 16+sigma >= 16  (sigma >= 0) : use the pair {D(k), D(k+1)},
    //                                          offset = sigma          = shift[3:0]
    //   shift = 16+sigma <  16  (sigma <  0) : use the pair {D(k-1), D(k)},
    //                                          offset = 16+sigma       = shift[3:0]
    // In both cases offset == shift_bytes[3:0], only the pair source changes.
    // ---------------------------------------------------------------------
    wire        use_lower_pair = ~shift_bytes[4];
    wire [3:0]  off            = shift_bytes[3:0];

    wire [2*W-1:0] pair = use_lower_pair ? win[2*W-1:0] : win[3*W-1:W];

    reg  [2*W-1:0] st1, st2, st3, st4;
    always @* begin
        st1 = off[0] ? {8'd0,      pair[2*W-1:8]}   : pair;
        st2 = off[1] ? {16'd0,     st1[2*W-1:16]}   : st1;
        st3 = off[2] ? {32'd0,     st2[2*W-1:32]}   : st2;
        st4 = off[3] ? {64'd0,     st3[2*W-1:64]}   : st3;
    end

    assign beat_data = st4[W-1:0];

endmodule
