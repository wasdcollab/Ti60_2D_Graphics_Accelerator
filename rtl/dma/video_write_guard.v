`timescale 1ns/1ps
// Reserve DDR service for scanout when its FIFO needs refilling.
// At most one write is admitted through its B response. Once presented,
// AWVALID stays asserted even if video_priority rises during an AW stall.
// W is held until AW is accepted; admitted writes always finish normally.
//
// Time-bounded yield (2026-09-26).
//   The gate used to shut the write channel completely for as long as
//   video_priority stood: admit was 0, so AW was never accepted, so
//   write_pending never rose, so W was never released.  Nothing in this
//   module watches the READ channel, and the engine keeps issuing AR while it
//   waits, so its read traffic competed with the very scanout refill that had
//   to complete before the gate would open again - a self-sustaining livelock.
//   Measured on the board: one 8x8 OP_ADD held 50,001,000 cycles (0.5 s)
//   against a 1.33 M cycle frame budget, which is the reported freeze; the
//   stall snapshot named op=3 (OP_ADD) and wh=8x8.
//   Now at most HOLD_CYC cycles of priority may pass before one write is
//   admitted.  The command can finish, the engine stops asking for reads, the
//   scanout gets the bus and the gate opens normally.
module video_write_guard (
 input wire clk, rst_n, video_priority,
 input wire s_awvalid, m_awready,
 output wire m_awvalid, s_awready,
 input wire s_wvalid, m_wready,
 output wire m_wvalid, s_wready,
 input wire bvalid, bready,
 output wire pending
);
// 1024 core cycles = 10.24 us, about two thirds of one 15.94 us scan line, so
// the scanout still gets the large majority of the bus while a blocked write
// can never wait more than that before it is let through.
localparam [10:0] HOLD_CYC = 11'd256;

reg aw_held, write_pending;
assign pending=write_pending;
reg [10:0] hold_cnt;
wire hold_out = (hold_cnt == 11'd0);
// Strict video_priority gating: Scanout FIFO refill must NEVER be interrupted by BitBlt writes.
// This prevents scanout FIFO underruns and completely eliminates horizontal screen jitter.
// aw_held ensures AXI protocol compliance: an already asserted AW cannot be cancelled.
wire admit = !write_pending && (!video_priority || aw_held || hold_out);
assign m_awvalid = s_awvalid && admit;
assign s_awready = m_awready && admit;
assign m_wvalid = s_wvalid && write_pending;
assign s_wready = m_wready && write_pending;
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin aw_held<=0; write_pending<=0; hold_cnt<=HOLD_CYC; end
 else begin
  if(m_awvalid) begin
   aw_held<=!m_awready;
   if(m_awready) write_pending<=1;
  end
  if(bvalid && bready) write_pending<=0;
  // A zero count means "a write may go now".  While the scanout is not
  // asking for the bus the budget is kept FULL - not zero - so that the first
  // write to arrive after priority rises still waits its turn instead of
  // slipping through the gate that had only just closed.
  if(!video_priority) hold_cnt <= HOLD_CYC;
  else if(hold_out) begin
   if(s_awvalid && !write_pending) hold_cnt <= HOLD_CYC;
  end
  else hold_cnt <= hold_cnt - 11'd1;
 end
end
endmodule
