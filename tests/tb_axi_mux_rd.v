`timescale 1ns/1ps
//=============================================================================
// tb_axi_mux_rd -- does the REAL Axi_Mux survive several read bursts in flight
//                 from ONE slave?
//
// The engine's read master (the "v4" build) issued up to four ARs back to back
// and deadlocked on the board.  The testbench that cleared it used a behavioural
// AXI slave, which accepts any number of ARs back to back and therefore cannot
// reproduce whatever the real interconnect does.
//
// This bench puts the real rtl/common/Axi_Mux.v in front of a DDR-like
// responder and asks the narrow question first, with nothing else attached:
//
//     can ONE slave keep MAXOUT read bursts outstanding through Axi_Mux?
//
// S0 is held idle, so any failure is attributable to the mux alone.  Sweep
// MAXOUT with -DMAXOUT=n (1 / 2 / 4 / 8) and compare.
//
// Watched, via hierarchical reference into the mux:
//   fifo_depth  AR2R_Number  - how many ARs are outstanding inside the mux
//   fifo_full   AR2R_Full    - the signal that was supposed to throttle AR
//   fifo_err    AR2R_Error   - FIFO overflow, dropped on the board side
//=============================================================================
module tb_axi_mux_rd;

`ifndef TB_MAXOUT
  `define TB_MAXOUT 4
`endif
`ifndef TB_TOTAL
  `define TB_TOTAL 32
`endif
`ifndef TB_AR_LEN
  `define TB_AR_LEN 3            // 0-based: 3 => 4 beats, like a 9x9 tile row
`endif

  localparam integer MAXOUT = `TB_MAXOUT;
  localparam integer TOTAL  = `TB_TOTAL;

  // ---- clock / reset -----------------------------------------------------
  reg clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;                       // 100 MHz

  // ---- Axi_Mux master port (towards the DDR responder) -------------------
  wire [3:0]   m_awid;   wire [31:0] m_awaddr; wire [7:0] m_awlen;
  wire [2:0]   m_awsize; wire [1:0]  m_awburst, m_awlock;
  wire         m_awvalid; reg         m_awready = 1'b0;
  wire [3:0]   m_wid;    wire [127:0] m_wdata;  wire m_wlast;
  wire [15:0]  m_wstrb;  wire         m_wvalid; reg  m_wready = 1'b0;
  reg  [3:0]   m_bid = 4'd0; reg m_bvalid = 1'b0; wire m_bready;
  wire [3:0]   m_arid;   wire [31:0]  m_araddr; wire [7:0] m_arlen;
  wire [2:0]   m_arsize; wire [1:0]   m_arburst, m_arlock;
  wire         m_arvalid; wire         m_arready;
  reg  [3:0]   m_rid;    reg  [127:0] m_rdata;  reg m_rlast;
  reg  [1:0]   m_rresp;  reg          m_rvalid; wire m_rready;

  // ---- S2: the requester under test -------------------------------------
  reg  [3:0]   s2_arid    = 4'd2;
  reg  [31:0]  s2_araddr  = 32'h0010_0000;
  reg  [7:0]   s2_arlen   = `TB_AR_LEN;
  reg  [2:0]   s2_arsize  = 3'b100;
  reg  [1:0]   s2_arburst = 2'b01;
  reg  [1:0]   s2_arlock  = 2'b00;
  reg          s2_arvalid = 1'b0;
  wire         s2_arready;
  wire [3:0]   s2_rid;
  wire [127:0] s2_rdata;
  wire         s2_rlast, s2_rvalid;
  reg          s2_rready  = 1'b1;

  // ---- S0 / S1 held idle -------------------------------------------------
  wire [3:0] s0_rid, s1_rid;
  wire [127:0] s0_rdata, s1_rdata;
  wire s0_rlast, s1_rlast, s0_rvalid, s1_rvalid;
  wire [1:0] s0_rresp, s1_rresp;
  wire [2:0] aw_cn, w_cn, b_cn, ar_cn, r_cn;

  // ---- S0: a VDMA-like competitor ----------------------------------------
  // In the real system S0 is the video DMA, it holds the highest priority and
  // it never stops asking.  Everything above this line was measured with S0
  // silent, which is not the machine the engine actually runs on.
`ifdef TB_VDMA
  localparam S0_ACTIVE = 1'b1;
`else
  localparam S0_ACTIVE = 1'b0;
`endif
  localparam integer S0_MAXOUT = 2;      // a live VDMA keeps a couple in flight

  reg  [3:0]   s0_arid    = 4'd0;
  reg  [31:0]  s0_araddr  = 32'h0020_0000;
  reg  [7:0]   s0_arlen   = 8'd15;       // 16 beats a line, like the scanout
  reg  [2:0]   s0_arsize  = 3'b100;
  reg  [1:0]   s0_arburst = 2'b01;
  reg  [1:0]   s0_arlock  = 2'b00;
  reg          s0_arvalid = 1'b0;
  wire         s0_arready;
  reg          s0_rready  = 1'b1;
  integer      s0_sent = 0, s0_done = 0, s0_out = 0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0_arvalid <= 1'b0; s0_sent <= 0; s0_done <= 0; s0_out <= 0;
    end else begin
      if (s0_arvalid && s0_arready) begin
        s0_arvalid <= 1'b0;
        s0_sent    <= s0_sent + 1;
        s0_out     <= s0_out + 1;
        s0_araddr  <= s0_araddr + 32'h100;
      end
      if (s0_rvalid && s0_rready && s0_rlast) begin
        s0_done <= s0_done + 1;
        s0_out  <= s0_out - 1;
      end
      if (!s0_arvalid && S0_ACTIVE && (s0_out < S0_MAXOUT))
        s0_arvalid <= 1'b1;
    end
  end


  // ---- DUT ---------------------------------------------------------------
  Axi_Mux #(
      .SLAVE_ID_WIDTH (4),
      .AXI_DATA_WIDTH (128),
      .ID_MODE_SEL    ("Normal")
  ) dut (
      .Sys_Clk  (clk), .Sys_Rst_N (rst_n),

      .O_M_AW_ID (m_awid),  .O_M_AW_ADDR (m_awaddr), .O_M_AW_LEN (m_awlen),
      .O_M_AW_SIZE (m_awsize), .O_M_AW_BURST (m_awburst), .O_M_AW_LOCK (m_awlock),
      .O_M_AW_VALID (m_awvalid), .I_M_AW_READY (m_awready),
      .O_M_W_ID (m_wid), .O_M_W_DATA (m_wdata), .O_M_W_LAST (m_wlast),
      .O_M_W_STRB (m_wstrb), .O_M_W_VALID (m_wvalid), .I_M_W_READY (m_wready),
      .I_M_B_ID (m_bid), .I_M_B_VALID (m_bvalid), .O_M_B_READY (m_bready),
      .O_M_AR_ID (m_arid), .O_M_AR_ADDR (m_araddr), .O_M_AR_LEN (m_arlen),
      .O_M_AR_SIZE (m_arsize), .O_M_AR_BURST (m_arburst), .O_M_AR_LOCK (m_arlock),
      .O_M_AR_VALID (m_arvalid), .I_M_AR_READY (m_arready),
      .I_M_R_ID (m_rid), .I_M_R_DATA (m_rdata), .I_M_R_LAST (m_rlast),
      .I_M_R_RESP (m_rresp), .I_M_R_VALID (m_rvalid), .O_M_R_READY (m_rready),

      // S0 idle
      .I_S0_AW_ID (4'd0), .I_S0_AW_ADDR (32'd0), .I_S0_AW_LEN (8'd0),
      .I_S0_AW_SIZE (3'd0), .I_S0_AW_BURST (2'd0), .I_S0_AW_LOCK (2'd0),
      .I_S0_AW_VALID (1'b0), .O_S0_AW_READY (),
      .I_S0_W_ID (4'd0), .I_S0_W_DATA (128'd0), .I_S0_W_LAST (1'b0),
      .I_S0_W_STRB (16'd0), .I_S0_W_VALID (1'b0), .O_S0_W_READY (),
      .O_S0_B_ID (), .O_S0_B_VALID (), .I_S0_B_READY (1'b0),
      .I_S0_AR_ID (s0_arid), .I_S0_AR_ADDR (s0_araddr), .I_S0_AR_LEN (s0_arlen),
      .I_S0_AR_SIZE (s0_arsize), .I_S0_AR_BURST (s0_arburst), .I_S0_AR_LOCK (s0_arlock),
      .I_S0_AR_VALID (s0_arvalid), .O_S0_AR_READY (s0_arready),
      .O_S0_R_ID (s0_rid), .O_S0_R_DATA (s0_rdata), .O_S0_R_LAST (s0_rlast),
      .O_S0_R_RESP (s0_rresp), .O_S0_R_VALID (s0_rvalid), .I_S0_R_READY (s0_rready),

      // S1 idle
      .I_S1_AW_ID (4'd0), .I_S1_AW_ADDR (32'd0), .I_S1_AW_LEN (8'd0),
      .I_S1_AW_SIZE (3'd0), .I_S1_AW_BURST (2'd0), .I_S1_AW_LOCK (2'd0),
      .I_S1_AW_VALID (1'b0), .O_S1_AW_READY (),
      .I_S1_W_ID (4'd0), .I_S1_W_DATA (128'd0), .I_S1_W_LAST (1'b0),
      .I_S1_W_STRB (16'd0), .I_S1_W_VALID (1'b0), .O_S1_W_READY (),
      .O_S1_B_ID (), .O_S1_B_VALID (), .I_S1_B_READY (1'b0),
      .I_S1_AR_ID (4'd0), .I_S1_AR_ADDR (32'd0), .I_S1_AR_LEN (8'd0),
      .I_S1_AR_SIZE (3'd0), .I_S1_AR_BURST (2'd0), .I_S1_AR_LOCK (2'd0),
      .I_S1_AR_VALID (1'b0), .O_S1_AR_READY (),
      .O_S1_R_ID (s1_rid), .O_S1_R_DATA (s1_rdata), .O_S1_R_LAST (s1_rlast),
      .O_S1_R_RESP (s1_rresp), .O_S1_R_VALID (s1_rvalid), .I_S1_R_READY (1'b1),

      // S2: the requester
      .I_S2_AW_ID (4'd0), .I_S2_AW_ADDR (32'd0), .I_S2_AW_LEN (8'd0),
      .I_S2_AW_SIZE (3'd0), .I_S2_AW_BURST (2'd0), .I_S2_AW_LOCK (2'd0),
      .I_S2_AW_VALID (1'b0), .O_S2_AW_READY (),
      .I_S2_W_ID (4'd0), .I_S2_W_DATA (128'd0), .I_S2_W_LAST (1'b0),
      .I_S2_W_STRB (16'd0), .I_S2_W_VALID (1'b0), .O_S2_W_READY (),
      .O_S2_B_ID (), .O_S2_B_VALID (), .I_S2_B_READY (1'b0),
      .I_S2_AR_ID (s2_arid), .I_S2_AR_ADDR (s2_araddr), .I_S2_AR_LEN (s2_arlen),
      .I_S2_AR_SIZE (s2_arsize), .I_S2_AR_BURST (s2_arburst), .I_S2_AR_LOCK (s2_arlock),
      .I_S2_AR_VALID (s2_arvalid), .O_S2_AR_READY (s2_arready),
      .O_S2_R_ID (s2_rid), .O_S2_R_DATA (s2_rdata), .O_S2_R_LAST (s2_rlast),
      .O_S2_R_RESP (s2_rresp), .O_S2_R_VALID (s2_rvalid), .I_S2_R_READY (s2_rready),

      .Cfg_Arb_Type (1'b1),          // priority, S0 highest - as in ti60_top
      .Cfg_Cnl_Mask (3'b111),
      .O_AW_Cnl_Num (aw_cn), .O_W_Cnl_Num (w_cn), .O_B_Cnl_Num (b_cn),
      .O_AR_Cnl_Num (ar_cn), .O_R_Cnl_Num (r_cn)
  );

  // ---- hierarchical peeks into the mux -----------------------------------
  wire [4:0] fifo_depth = dut.U3_Axi_Mux_Rd_Ctrl.AR2R_Number;
  wire       fifo_full  = dut.U3_Axi_Mux_Rd_Ctrl.AR2R_Full;
  wire       fifo_err   = dut.U3_Axi_Mux_Rd_Ctrl.AR2R_Error;

  // ---- DDR responder: takes AR, returns R in AR ISSUE ORDER --------------
  // ARs are queued and one burst streams back at a time, in arrival order -
  // which is what the real controller does for a single ID, and what Axi_Mux
  // assumes.  Depth is head/tail only: the first draft kept a shared count
  // register written from two always blocks, which is a race.
  localparam integer LAT = 40;        // AR accepted -> first R beat

  reg [31:0] ar_addr_q [0:63];
  reg [7:0]  ar_len_q  [0:63];
  integer ar_head = 0, ar_tail = 0;
  integer ar_max  = 0;
  wire [7:0] ar_depth = ar_tail[7:0] - ar_head[7:0];
  assign m_arready = (ar_depth < 8'd48);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_tail <= 0;
      ar_max  <= 0;
    end else if (m_arvalid && m_arready) begin
      ar_addr_q[ar_tail[5:0]] <= m_araddr;
      ar_len_q [ar_tail[5:0]] <= m_arlen;
      ar_tail <= ar_tail + 1;
      if ((ar_depth + 8'd1) > ar_max) ar_max <= ar_depth + 8'd1;
    end
  end

  localparam R_IDLE = 2'd0, R_LAT = 2'd1, R_BEAT = 2'd2;
  reg [1:0] r_state    = R_IDLE;
  reg [8:0] beats_left = 9'd0;
  integer   lat_cnt     = 0;
  integer   total_beats = 0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_state <= R_IDLE; m_rvalid <= 1'b0; m_rlast <= 1'b0; m_rdata <= 128'd0;
      m_rid <= 4'd2; m_rresp <= 2'b00;
      beats_left <= 9'd0; lat_cnt <= 0; total_beats <= 0; ar_head <= 0;
    end else begin
      case (r_state)
        R_IDLE: begin
          m_rvalid <= 1'b0;
          m_rlast  <= 1'b0;
          if (ar_depth != 8'd0) begin
            beats_left <= {1'b0, ar_len_q[ar_head[5:0]]} + 9'd1;
            lat_cnt    <= 0;
            r_state    <= R_LAT;
          end
        end

        R_LAT: begin
          if (lat_cnt < LAT) lat_cnt <= lat_cnt + 1;
          else               r_state <= R_BEAT;
        end

        R_BEAT: begin
          // Present one beat and HOLD it until taken.  RLAST is set here, on
          // the beat that carries it - the previous version only ever set it
          // inside the "not currently valid" branch, which m_rvalid left after
          // the first beat, so RLAST was never asserted at all.
          if (!m_rvalid) begin
            m_rvalid <= 1'b1;
            m_rdata  <= {96'd0, 32'hDEAD_0000} + total_beats[31:0];
            m_rlast  <= (beats_left == 9'd1);
            m_rid    <= 4'd2;
            m_rresp  <= 2'b00;
          end else if (m_rready) begin
            total_beats <= total_beats + 1;
            m_rvalid    <= 1'b0;
            if (beats_left == 9'd1) begin
              m_rlast <= 1'b0;
              ar_head <= ar_head + 1;
              r_state <= R_IDLE;
            end else begin
              beats_left <= beats_left - 9'd1;
            end
          end
        end
      endcase
    end
  end

  // ---- the requester: keep up to MAXOUT bursts outstanding ---------------
  integer sent = 0, done_bursts = 0;
  integer outstanding = 0;
  integer fifo_peak = 0;
  integer err_seen = 0;
  integer s2_rv_cnt = 0;      // R beats Axi_Mux routed to S2
  integer s0_rv_cnt = 0;      // ... and to the two idle slaves, which would
  integer s1_rv_cnt = 0;      //     mean the data went to the wrong place
  // r_info_val_cnt and prev_m_rvalid used to live here: both were assigned on
  // every clock and never read by anything.  The one that looked useful -
  // counting the mux's internal R_Info_Val handshakes - measured nothing that
  // the queue depth and the overflow counter do not already say.

  always @(posedge clk) begin
    if (s2_rvalid) s2_rv_cnt <= s2_rv_cnt + 1;
    if (s0_rvalid) s0_rv_cnt <= s0_rv_cnt + 1;
    if (s1_rvalid) s1_rv_cnt <= s1_rv_cnt + 1;
  end

  // trace every AR that leaves the mux
  always @(posedge clk)
    if (m_arvalid && m_arready)
      $display("  [%0t] AR out  addr=%h len=%0d", $time, m_araddr, m_arlen);

  // trace every R beat on BOTH sides of the mux, so a dropped RLAST shows up
  always @(posedge clk) begin
    if (m_rvalid)
      $display("  [%0t] M  R beat data=%h last=%b ready=%b",
               $time, m_rdata, m_rlast, m_rready);
    if (s2_rvalid)
      $display("  [%0t] S2 R beat data=%h last=%b ready=%b",
               $time, s2_rdata, s2_rlast, s2_rready);
  end

  always @(posedge clk) begin
    if (fifo_depth > fifo_peak) fifo_peak <= fifo_depth;
    if (fifo_err) err_seen <= err_seen + 1;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_arvalid <= 1'b0; sent <= 0; done_bursts <= 0; outstanding <= 0;
    end else begin
      if (s2_arvalid && s2_arready) begin
        s2_arvalid <= 1'b0;
        sent       <= sent + 1;
        outstanding<= outstanding + 1;
      end
      if (s2_rvalid && s2_rready && s2_rlast) begin
        done_bursts <= done_bursts + 1;
        outstanding <= outstanding - 1;
      end
      // fire the next one when there is room
      if (!s2_arvalid && (sent < TOTAL) && (outstanding < MAXOUT))
        s2_arvalid <= 1'b1;
    end
  end

  // ---- run and report ----------------------------------------------------
  integer cyc = 0;
  integer fail = 0;
  always @(posedge clk) cyc <= cyc + 1;

  initial begin
    $display("=== tb_axi_mux_rd : MAXOUT=%0d TOTAL=%0d AR_LEN=%0d ===",
             MAXOUT, TOTAL, `TB_AR_LEN);
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;

    // wait for all bursts, or give up
    wait (done_bursts == TOTAL || cyc > 200000);
    repeat (20) @(posedge clk);

    $display("  sent          = %0d", sent);
    $display("  done_bursts   = %0d", done_bursts);
    $display("  total_beats   = %0d", total_beats);
    $display("  ar peak depth = %0d  (responder side)", ar_max);
    $display("  AR2R peak     = %0d  (mux internal queue, depth 16)", fifo_peak);
    $display("  AR2R overflow = %0d", err_seen);
    $display("  R beats routed: S0=%0d  S1=%0d  S2=%0d", s0_rv_cnt, s1_rv_cnt, s2_rv_cnt);
    $display("  S0 (VDMA) ARs sent=%0d done=%0d   (active=%b)",
             s0_sent, s0_done, S0_ACTIVE);
    // The three counters above used to be printed and never judged: the only
    // verdict was "all TOTAL bursts finished".  A mux that overflows its
    // AR-to-R queue, or that hands an R beat to a slave which never asked for
    // one, still completes every burst - so both of the failures this bench
    // exists to catch came out green.
    fail = 0;
    if (done_bursts != TOTAL) begin
      $display("  FAIL: %0d of %0d bursts completed (stuck or timed out after %0d cycles)",
               done_bursts, TOTAL, cyc);
      fail = 1;
    end
    if (sent != TOTAL) begin
      $display("  FAIL: %0d ARs were issued, expected %0d", sent, TOTAL);
      fail = 1;
    end
    if (err_seen != 0) begin
      $display("  FAIL: the AR-to-R queue overflowed %0d times - R data was dropped", err_seen);
      fail = 1;
    end
    if (s0_rv_cnt != 0 || s1_rv_cnt != 0) begin
      $display("  FAIL: %0d R beats reached S0 and %0d reached S1; both are idle here",
               s0_rv_cnt, s1_rv_cnt);
      fail = 1;
    end
    if (s2_rv_cnt == 0) begin
      $display("  FAIL: no R beat reached S2 at all");
      fail = 1;
    end
    if (fail == 0)
      $display("  RESULT: PASS - all %0d bursts completed with MAXOUT=%0d, queue never overflowed, no beat misrouted",
               TOTAL, MAXOUT);
    else
      $display("  RESULT: *** FAIL *** see the lines above");
    $finish(fail ? 1 : 0);
  end

endmodule
