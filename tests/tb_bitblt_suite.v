`timescale 1ns/1ps
//=============================================================================
// tb_bitblt_suite -- full-engine bench with INVARIANT MONITORS + FAULT INJECTION.
//
// Why this exists: the v4 concurrent read master has an intermittent failure
// that showed up ONCE on the board.  A one-in-N-runs bug cannot be validated by
// "flash it and play for five minutes", so this bench does two things the older
// ones did not:
//
//   1. It checks INVARIANTS every cycle, so a bug that used to be invisible
//      ("the counters were off by one but nothing crashed yet") becomes a
//      printed, reproducible FAILURE.  The single most important invariant is
//      that the engine's own view of how many read bursts it has outstanding
//      (rd_out_src + rd_out_dst) matches the read master's queue occupancy.
//      If those two ever disagree, a later command inherits the offset -
//      because the queue is cleared ONLY by reset.
//
//   2. It can INJECT the DDR-side stutters that a real controller produces
//      (variable latency, stalled ARREADY, delayed R beats).  Against a
//      perfectly obedient responder the engine never sees the corner it dies
//      on.  With -DTB_JITTER the corners come to the bench on demand.
//
// Also: dynamic arrays for the DDR model, so a full-screen command fits.
// The older bench used 128-entry arrays and wrapped at ar_tail[6:0], which
// silently corrupts any command longer than 128 bursts (a 1366-wide row alone
// is 342 beats, so a 1366x768 copy is ~4150 bursts).
//
// Macros:
//   CMD_W CMD_H        rectangle, default full screen 1366x768
//   CMD_OP             0=FILL 1=COPY 2=ALPHA     (default 1)
//   TB_LAT             base DDR read latency      (default 150, board-like)
//   TB_JITTER          enable latency/stall injection
//   TB_CMDS            number of back-to-back commands (default 1)
//   TB_TIMEOUT         cycle budget per command   (default auto)
//   TB_VDMA            add the S0 scanout competitor
//   TB_VERBOSE         per-probe chatter
//=============================================================================
module tb_bitblt_suite;

`ifndef CMD_W
  `define CMD_W 1366
`endif
`ifndef CMD_H
  `define CMD_H 768
`endif
`ifndef CMD_OP
  `define CMD_OP 1
`endif
`ifndef TB_LAT
  `define TB_LAT 150
`endif
`ifndef TB_CMDS
  `define TB_CMDS 1
`endif

  localparam integer CW   = `CMD_W;
  localparam integer CH   = `CMD_H;
  localparam integer OP_SEL = `CMD_OP;
  localparam integer NCMDS  = `TB_CMDS;
  localparam integer LAT    = `TB_LAT;
  localparam integer TIMEOUT_CYC = (CW > 128) ? (CH * 900 + 200000)
                                             : (CH * 400 + 20000);

  reg clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---- APB ---------------------------------------------------------------
  reg  [15:0] apb_paddr   = 16'd0;
  reg         apb_psel    = 1'b0;
  reg         apb_penable = 1'b0;
  reg         apb_pwrite  = 1'b0;
  reg  [31:0] apb_pwdata  = 32'd0;
  wire [31:0] apb_prdata;
  wire        apb_pready, apb_pslverr;

  // ---- engine AXI --------------------------------------------------------
  wire [3:0]   bb_arid;   wire [27:0] bb_araddr; wire [7:0]  bb_arlen;
  wire [2:0]   bb_arsize; wire [1:0]  bb_arburst, bb_arlock;
  wire         bb_arvalid; wire        bb_arready;
  wire [3:0]   bb_rid;    wire [127:0] bb_rdata;  wire [1:0] bb_rresp;
  wire         bb_rlast, bb_rvalid, bb_rready;
  wire [3:0]   bb_awid;   wire [27:0]  bb_awaddr; wire [7:0] bb_awlen;
  wire [2:0]   bb_awsize; wire [1:0]   bb_awburst, bb_awlock;
  wire         bb_awvalid; wire        bb_awready;
  wire [3:0]   bb_wid;    wire [127:0] bb_wdata;  wire [15:0] bb_wstrb;
  wire         bb_wlast, bb_wvalid, bb_wready;
  wire [3:0]   bb_bid;    wire         bb_bvalid, bb_bready;

  // ---- mux master side ---------------------------------------------------
  wire [3:0]   m_arid;   wire [31:0] m_araddr; wire [7:0]  m_arlen;
  wire [2:0]   m_arsize; wire [1:0]  m_arburst, m_arlock;
  wire         m_arvalid; wire        m_arready;
  reg  [3:0]   m_rid;    reg  [127:0] m_rdata;  reg [1:0] m_rresp;
  reg          m_rlast, m_rvalid; wire m_rready;
  wire [3:0]   m_awid;   wire [31:0] m_awaddr; wire [7:0] m_awlen;
  wire [2:0]   m_awsize; wire [1:0]  m_awburst, m_awlock;
  wire         m_awvalid; reg         m_awready;
  wire [3:0]   m_wid;    wire [127:0] m_wdata; wire [15:0] m_wstrb;
  wire         m_wlast, m_wvalid; reg  m_wready;
  reg  [3:0]   m_bid;    reg          m_bvalid; wire m_bready;

  wire [2:0] aw_cn, w_cn, b_cn, ar_cn, r_cn;
  wire [27:0] vdma_next_base, vdma_right_next_base;
  wire [7:0]  cpu_fps_bcd, fpga_fps_bcd;
  wire [6:0]  i2c_slave_addr;
  wire        force_hud_disable;

  // ---- S0 scanout competitor ---------------------------------------------
`ifdef TB_VDMA
  localparam S0_ACTIVE = 1'b1;
`else
  localparam S0_ACTIVE = 1'b0;
`endif
  localparam integer S0_MAXOUT = 2;
  reg  [3:0]   s0_arid    = 4'd0;
  reg  [31:0]  s0_araddr  = 32'h0020_0000;
  reg  [7:0]   s0_arlen   = 8'd15;
  reg  [2:0]   s0_arsize  = 3'b100;
  reg  [1:0]   s0_arburst = 2'b01;
  reg  [1:0]   s0_arlock  = 2'b00;
  reg          s0_arvalid = 1'b0;
  wire         s0_arready;
  reg          s0_rready  = 1'b1;
  wire [3:0]   s0_rid;
  wire [127:0] s0_rdata;
  wire         s0_rlast, s0_rvalid;
  wire [1:0]   s0_rresp;
  integer      s0_sent = 0, s0_done = 0, s0_out = 0;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0_arvalid <= 1'b0; s0_sent <= 0; s0_done <= 0; s0_out <= 0;
    end else begin
      if (s0_arvalid && s0_arready) begin
        s0_arvalid <= 1'b0; s0_sent <= s0_sent + 1; s0_out <= s0_out + 1;
        s0_araddr  <= s0_araddr + 32'h400;
      end
      if (s0_rvalid && s0_rready && s0_rlast) begin
        s0_done <= s0_done + 1; s0_out <= s0_out - 1;
      end
      if (!s0_arvalid && S0_ACTIVE && (s0_out < S0_MAXOUT)) s0_arvalid <= 1'b1;
    end
  end

  // ---- DUT --------------------------------------------------------------
  bitblt_top dut (
      .clk (clk), .rst_n (rst_n),
      .apb_paddr (apb_paddr), .apb_psel (apb_psel), .apb_penable (apb_penable),
      .apb_pwrite (apb_pwrite), .apb_pwdata (apb_pwdata),
      .apb_prdata (apb_prdata), .apb_pready (apb_pready), .apb_pslverr (apb_pslverr),
      .m_axi_arid (bb_arid), .m_axi_araddr (bb_araddr), .m_axi_arlen (bb_arlen),
      .m_axi_arsize (bb_arsize), .m_axi_arburst (bb_arburst), .m_axi_arlock (bb_arlock),
      .m_axi_arvalid (bb_arvalid), .m_axi_arready (bb_arready),
      .m_axi_rid (bb_rid), .m_axi_rdata (bb_rdata), .m_axi_rresp (bb_rresp),
      .m_axi_rlast (bb_rlast), .m_axi_rvalid (bb_rvalid), .m_axi_rready (bb_rready),
      .m_axi_awid (bb_awid), .m_axi_awaddr (bb_awaddr), .m_axi_awlen (bb_awlen),
      .m_axi_awsize (bb_awsize), .m_axi_awburst (bb_awburst), .m_axi_awlock (bb_awlock),
      .m_axi_awvalid (bb_awvalid), .m_axi_awready (bb_awready),
      .m_axi_wid (bb_wid), .m_axi_wdata (bb_wdata), .m_axi_wstrb (bb_wstrb),
      .m_axi_wlast (bb_wlast), .m_axi_wvalid (bb_wvalid), .m_axi_wready (bb_wready),
      .m_axi_bid (bb_bid), .m_axi_bvalid (bb_bvalid), .m_axi_bready (bb_bready),
      .vdma_next_base (vdma_next_base), .vdma_active_base (28'h0080_0000),
      .vdma_right_next_base (vdma_right_next_base),
      .vdma_right_active_base (28'h0080_0000),
      .cpu_fps_bcd (cpu_fps_bcd), .fpga_fps_bcd (fpga_fps_bcd),
      .scan_diagnostics (32'd0), .vsync_flag (1'b0),
      .gamepad_joy_x (8'd128), .gamepad_joy_y (8'd128),
      .gamepad_buttons (5'd0), .gamepad_online (1'b1),
      .key_sw0_level (1'b1), .key_sw2_level (1'b1),
      .key_sw0_pulse (1'b0), .key_sw2_pulse (1'b0),
      .i2c_slave_addr (i2c_slave_addr), .force_hud_disable (force_hud_disable)
  );

  // ---- Axi_Mux -----------------------------------------------------------
  Axi_Mux #(
      .SLAVE_ID_WIDTH (4), .AXI_DATA_WIDTH (128), .ID_MODE_SEL ("Normal")
  ) u_mux (
      .Sys_Clk (clk), .Sys_Rst_N (rst_n),
      .O_M_AW_ID (m_awid), .O_M_AW_ADDR (m_awaddr), .O_M_AW_LEN (m_awlen),
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
      .I_S1_AW_ID (4'd0), .I_S1_AW_ADDR (32'd0), .I_S1_AW_LEN (8'd0),
      .I_S1_AW_SIZE (3'd0), .I_S1_AW_BURST (2'd0), .I_S1_AW_LOCK (2'd0),
      .I_S1_AW_VALID (1'b0), .O_S1_AW_READY (),
      .I_S1_W_ID (4'd0), .I_S1_W_DATA (128'd0), .I_S1_W_LAST (1'b0),
      .I_S1_W_STRB (16'd0), .I_S1_W_VALID (1'b0), .O_S1_W_READY (),
      .O_S1_B_ID (), .O_S1_B_VALID (), .I_S1_B_READY (1'b0),
      .I_S1_AR_ID (4'd0), .I_S1_AR_ADDR (32'd0), .I_S1_AR_LEN (8'd0),
      .I_S1_AR_SIZE (3'd0), .I_S1_AR_BURST (2'd0), .I_S1_AR_LOCK (2'd0),
      .I_S1_AR_VALID (1'b0), .O_S1_AR_READY (),
      .O_S1_R_ID (), .O_S1_R_DATA (), .O_S1_R_LAST (),
      .O_S1_R_RESP (), .O_S1_R_VALID (), .I_S1_R_READY (1'b1),
      .I_S2_AW_ID (bb_awid), .I_S2_AW_ADDR ({4'd0, bb_awaddr}), .I_S2_AW_LEN (bb_awlen),
      .I_S2_AW_SIZE (bb_awsize), .I_S2_AW_BURST (bb_awburst), .I_S2_AW_LOCK (bb_awlock),
      .I_S2_AW_VALID (bb_awvalid), .O_S2_AW_READY (bb_awready),
      .I_S2_W_ID (bb_wid), .I_S2_W_DATA (bb_wdata), .I_S2_W_LAST (bb_wlast),
      .I_S2_W_STRB (bb_wstrb), .I_S2_W_VALID (bb_wvalid), .O_S2_W_READY (bb_wready),
      .O_S2_B_ID (bb_bid), .O_S2_B_VALID (bb_bvalid), .I_S2_B_READY (bb_bready),
      .I_S2_AR_ID (bb_arid), .I_S2_AR_ADDR ({4'd0, bb_araddr}), .I_S2_AR_LEN (bb_arlen),
      .I_S2_AR_SIZE (bb_arsize), .I_S2_AR_BURST (bb_arburst), .I_S2_AR_LOCK (bb_arlock),
      .I_S2_AR_VALID (bb_arvalid), .O_S2_AR_READY (bb_arready),
      .O_S2_R_ID (bb_rid), .O_S2_R_DATA (bb_rdata), .O_S2_R_LAST (bb_rlast),
      .O_S2_R_RESP (bb_rresp), .O_S2_R_VALID (bb_rvalid), .I_S2_R_READY (bb_rready),
      .Cfg_Arb_Type (1'b1), .Cfg_Cnl_Mask (3'b111),
      .O_AW_Cnl_Num (aw_cn), .O_W_Cnl_Num (w_cn), .O_B_Cnl_Num (b_cn),
      .O_AR_Cnl_Num (ar_cn), .O_R_Cnl_Num (r_cn)
  );

  // ---- DDR responder with DYNAMIC queues ---------------------------------
  // Dynamic, not [0:127]: a 1366x768 copy issues ~4150 read bursts, and the
  // old fixed array wrapped its index at 7 bits.  That is a bench bug, not an
  // engine bug, but it would have shown up as one.
  reg [31:0] ar_addr_q [0:65535];
  reg [7:0]  ar_len_q  [0:65535];
  integer    ar_head = 0, ar_tail = 0, ar_max = 0, ar_total = 0;
  wire [16:0] ar_depth = ar_tail[16:0] - ar_head[16:0];
  assign m_arready = (ar_depth < 17'd4096);

`ifdef TB_JITTER
  // ---- fault injection ---------------------------------------------------
  // A real DDR3 controller does not answer on a fixed schedule.  These knobs
  // create the corners the engine has to survive:
  //   ar_stall : ARREADY low for a stretch  -> the request queue backs up
  //   r_gap    : extra latency mid-burst    -> a stream stalls while the other
  //   r_stall  : RREADY blocked             -> FIFO full back-pressure
  reg [15:0] rnd = 16'hACE1;
  function [15:0] lfsr16;
    input [15:0] s;
    begin lfsr16 = {s[14:0], s[15]^s[13]^s[12]^s[10]}; end
  endfunction
  reg [7:0] ar_stall = 8'd0;
  reg [7:0] r_gap    = 8'd0;
`endif

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_tail <= 0; ar_max <= 0; ar_total <= 0;
    end else if (m_arvalid && m_arready) begin
      ar_addr_q[ar_tail[15:0]] <= m_araddr;
      ar_len_q [ar_tail[15:0]] <= m_arlen;
      ar_tail  <= ar_tail + 1;
      ar_total <= ar_total + 1;
      if ((ar_depth + 17'd1) > ar_max) ar_max <= ar_depth + 17'd1;
    end
  end

  localparam R_IDLE = 2'd0, R_LAT = 2'd1, R_BEAT = 2'd2, R_GAP = 2'd3;
  reg [1:0] r_state = R_IDLE;
  reg [8:0] beats_left = 9'd0;
  integer   lat_cnt = 0, r_beats = 0;
  reg [15:0] goff = 16'd0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_state <= R_IDLE; m_rvalid <= 1'b0; m_rlast <= 1'b0; m_rdata <= 128'd0;
      m_rid <= 4'd2; m_rresp <= 2'b00;
      beats_left <= 9'd0; lat_cnt <= 0; r_beats <= 0; ar_head <= 0;
      goff <= 16'd0;
    end else begin
`ifdef TB_JITTER
      rnd <= lfsr16(rnd);
      // occasionally stall ARREADY
      if (ar_stall != 8'd0) begin
        ar_stall <= ar_stall - 8'd1;
        m_arready <= 1'b0;
      end else begin
        m_arready <= (ar_depth < 17'd4096);
        if (rnd[7:0] < 8'd3) ar_stall <= rnd[15:10];
      end
`endif
      case (r_state)
        R_IDLE: begin
          m_rvalid <= 1'b0; m_rlast <= 1'b0;
          if (ar_depth != 17'd0) begin
            beats_left <= {1'b0, ar_len_q[ar_head[15:0]]} + 9'd1;
            lat_cnt    <= 0;
`ifdef TB_JITTER
            goff <= {8'd0, rnd[7:0]};
`endif
            r_state    <= R_LAT;
          end
        end
        R_LAT: begin
          if (lat_cnt < (LAT + goff)) lat_cnt <= lat_cnt + 1;
          else                        r_state <= R_BEAT;
        end
        R_GAP: begin
          if (goff == 16'd0) r_state <= R_BEAT;
          else               goff <= goff - 16'd1;
        end
        R_BEAT: begin
          if (!m_rvalid) begin
            m_rvalid <= 1'b1;
            m_rdata  <= {96'd0, 32'hC0DE_0000} + r_beats[31:0];
            m_rlast  <= (beats_left == 9'd1);
            m_rid    <= 4'd2; m_rresp <= 2'b00;
          end else if (m_rready) begin
            r_beats  <= r_beats + 1;
            m_rvalid <= 1'b0;
            if (beats_left == 9'd1) begin
              m_rlast <= 1'b0;
              ar_head <= ar_head + 1;
`ifdef TB_JITTER
              if (rnd[9:8] == 2'd0) begin goff <= {12'd0, rnd[7:4]}; r_state <= R_GAP; end
              else r_state <= R_IDLE;
`else
              r_state <= R_IDLE;
`endif
            end else beats_left <= beats_left - 9'd1;
          end
        end
      endcase
    end
  end

  // ---- write channel -----------------------------------------------------
  reg [7:0] aw_cnt = 8'd0;
  reg [7:0] wl_cnt = 8'd0;
  reg       b_pend = 1'b0;
  wire aw_inc   = m_awvalid && m_awready;
  wire wl_inc   = m_wvalid && m_wready && m_wlast;
  wire b_fire   = !b_pend && !m_bvalid && (aw_cnt > 8'd0) && (wl_cnt > 8'd0);
  wire b_retire = m_bvalid && m_bready;
  integer aw_total = 0, wl_total = 0, b_total = 0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_cnt <= 8'd0; wl_cnt <= 8'd0; b_pend <= 1'b0;
      m_bvalid <= 1'b0; m_bid <= 4'd2; m_awready <= 1'b1; m_wready <= 1'b1;
    end else begin
      aw_cnt <= aw_cnt + (aw_inc ? 8'd1 : 8'd0) - (b_fire ? 8'd1 : 8'd0);
      wl_cnt <= wl_cnt + (wl_inc ? 8'd1 : 8'd0) - (b_fire ? 8'd1 : 8'd0);
      if (b_retire)    m_bvalid <= 1'b0;
      else if (b_fire) m_bvalid <= 1'b1;
      if (b_fire)        b_pend <= 1'b1;
      else if (b_retire) b_pend <= 1'b0;
      m_bid <= 4'd2;
      if (aw_inc)   aw_total <= aw_total + 1;
      if (wl_inc)   wl_total <= wl_total + 1;
      if (b_retire) b_total  <= b_total + 1;
    end
  end

  //=========================================================================
  // INVARIANT MONITORS -- the actual reason this bench exists
  //=========================================================================
  wire [2:0] sg_src   = dut.u_stride_gen.rd_out_src;
  wire [2:0] sg_dst   = dut.u_stride_gen.rd_out_dst;
  wire       sg_pend  = dut.u_stride_gen.rd_tx_pend;
  wire [1:0] sg_state = dut.u_stride_gen.state;
  wire [2:0] rm_cnt   = dut.u_read_master.q_cnt;
  wire       rm_pend  = dut.u_read_master.ar_pend;
  wire [1:0] rm_head  = dut.u_read_master.q_head;
  wire [1:0] rm_tail  = dut.u_read_master.q_tail;

  integer err_cnt = 0;
  integer cyc = 0, t_start = 0, cmd_i = 0;
  integer row_done_cnt = 0, rd_done_cnt = 0, peak_src = 0, peak_dst = 0;
  integer stall_cyc = 0, max_stall = 0;
  integer err_insync = 0, err_leak = 0, err_neg = 0, err_qptr = 0;

  // (1) The engine's outstanding-burst count must equal the read master's
  //     queue depth plus the staging register.  rd_out_* is bumped when a
  //     request is STAGED; the master pushes it onto q_cnt when rd_accept
  //     fires.  So at every cycle, ignoring the one-cycle moment when a
  //     request is being handed over, we must have
  //         sg_src + sg_dst == rm_cnt + (sg_pend ? 1 : 0)
  //     A mismatch means one side believes in a burst the other has lost.
  //     That discrepancy is exactly what makes a LATER command hang, because
  //     the master's queue is reset only by rst_n.
  always @(posedge clk) begin
    if (rst_n && (sg_state != 2'd0)) begin
      if ((sg_src + sg_dst) > (rm_cnt + {2'd0, sg_pend})) begin
        if (err_insync == 0)
          $display("  [INVARIANT] cyc=%0d MISMATCH staged=%0d q_cnt=%0d pend=%b (engine believes more bursts are live than the master has)",
                   cyc, sg_src + sg_dst, rm_cnt, sg_pend);
        err_insync <= err_insync + 1;
        err_cnt    <= err_cnt + 1;
      end
      // counters must never go negative (3-bit wrap shows as 7)
      if (sg_src > 3'd4 || sg_dst > 3'd4) begin
        if (err_neg == 0)
          $display("  [INVARIANT] cyc=%0d COUNTER OVERFLOW src=%0d dst=%0d", cyc, sg_src, sg_dst);
        err_neg <= err_neg + 1; err_cnt <= err_cnt + 1;
      end
    end
    // (2) ring-buffer pointer sanity: q_head must always equal q_tail - q_cnt
    if (rst_n && (rm_head !== (rm_tail - rm_cnt[1:0]))) begin
      if (err_qptr == 0)
        $display("  [INVARIANT] cyc=%0d QUEUE POINTER DESYNC head=%0d tail=%0d cnt=%0d",
                 cyc, rm_head, rm_tail, rm_cnt);
      err_qptr <= err_qptr + 1; err_cnt <= err_cnt + 1;
    end
    // (3) after a command retires, everything must be back to zero before the
    //     next START, or the next command inherits the offset.
    if (rst_n && (sg_state == 2'd0) && dut.u_apb_regs.done_seen && !dut.busy) begin
      if ((rm_cnt != 3'd0) || sg_pend || (sg_src != 3'd0) || (sg_dst != 3'd0)) begin
        if (err_leak == 0)
          $display("  [INVARIANT] cyc=%0d LEAK AT COMMAND END: q_cnt=%0d pend=%b src=%0d dst=%0d",
                   cyc, rm_cnt, sg_pend, sg_src, sg_dst);
        err_leak <= err_leak + 1; err_cnt <= err_cnt + 1;
      end
    end
  end

  // stall detector: how long does the engine sit with work outstanding and
  // nothing moving?  On the board that is the 500 ms watchdog penalty.
  always @(posedge clk) begin
    if (rst_n && dut.busy && (ar_depth != 17'd0) && (r_state == R_IDLE) && !m_rvalid)
      stall_cyc <= stall_cyc + 1;
    else begin
      if (stall_cyc > max_stall) max_stall <= stall_cyc;
      stall_cyc <= 0;
    end
  end

  always @(posedge clk) begin
    if (dut.u_stride_gen.row_done) row_done_cnt <= row_done_cnt + 1;
    if (dut.rd_done)               rd_done_cnt  <= rd_done_cnt + 1;
    if (sg_src > peak_src) peak_src <= sg_src;
    if (sg_dst > peak_dst) peak_dst <= sg_dst;
  end

`ifdef TB_VERBOSE
  always @(posedge clk) begin
    if (cyc != 0 && (cyc % 200000) == 0)
      $display("    [probe] cyc=%0d state=%0d row=%0d wr_left=%0d rd_left=%0d src=%0d dst=%0d q=%0d",
               cyc, sg_state, dut.u_stride_gen.row_idx, dut.u_stride_gen.wr_left,
               dut.u_stride_gen.rd_left, sg_src, sg_dst, rm_cnt);
  end
`endif
  always @(posedge clk) cyc <= cyc + 1;

  // ---- APB helpers -------------------------------------------------------
  task apb_write(input [15:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      apb_paddr <= addr; apb_pwdata <= data; apb_pwrite <= 1'b1;
      apb_psel  <= 1'b1; apb_penable <= 1'b0;
      @(posedge clk);
      apb_penable <= 1'b1;
      @(posedge clk);
      apb_psel <= 1'b0; apb_penable <= 1'b0; apb_pwrite <= 1'b0;
    end
  endtask

  integer failed = 0;
  integer got_row = 0, got_timeout = 0;

  initial begin
    $display("=== tb_bitblt_suite : %0dx%0d op=%0d  LAT=%0d  cmds=%0d ===",
             CW, CH, OP_SEL, LAT, NCMDS);
`ifdef TB_JITTER
    $display("    fault injection ENABLED (AR stalls, latency spread, R gaps)");
`endif
`ifdef TB_VDMA
    $display("    S0 scanout competitor ENABLED");
`endif
    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
    repeat (20) @(posedge clk);

    for (cmd_i = 0; cmd_i < NCMDS; cmd_i = cmd_i + 1) begin
      apb_write(16'h18, OP_SEL);
      apb_write(16'h04, 32'h0100_0000 + cmd_i * 32'h0020_0000);
      apb_write(16'h1C, 32'h0200_0000 + cmd_i * 32'h0020_0000);
      apb_write(16'h08, CW);
      apb_write(16'h0C, CH);
      apb_write(16'h30, 32'd4096);
      apb_write(16'h48, 32'd8192);
      if (OP_SEL == 2) begin
        apb_write(16'h68, 32'd1);
        apb_write(16'h6C, 32'd170);
      end
      row_done_cnt = 0; rd_done_cnt = 0; peak_src = 0; peak_dst = 0;
      stall_cyc = 0; max_stall = 0;
      t_start = cyc;
      apb_write(16'h14, 32'd1);
      // two-step wait: done_seen is still 1 from the PREVIOUS command until
      // the new START lands.  Waiting on it directly races.
      wait (dut.u_apb_regs.done_seen == 1'b0 || (cyc - t_start) > 20000);
      wait ((dut.u_apb_regs.done_seen == 1'b1 && dut.busy == 1'b0) ||
            (cyc - t_start) > TIMEOUT_CYC);
      repeat (30) @(posedge clk);

      got_timeout = dut.u_apb_regs.timeout_sticky;
      got_row     = row_done_cnt;
      $display("  cmd %0d: %8d cycles  (%6.1f/row)  rows=%0d/%0d  rd_done=%0d  peak_src=%0d peak_dst=%0d  ar_max=%0d",
               cmd_i, cyc - t_start, (cyc - t_start) * 1.0 / CH,
               got_row, CH, rd_done_cnt, peak_src, peak_dst, ar_max);

      if (dut.busy == 1'b1) begin
        failed = 1;
        $display("    *** STUCK: busy still high after timeout ***");
        $display("    stride_gen state=%0d row_idx=%0d wr_left=%0d rd_left=%0d dst_rd_left=%0d",
                 sg_state, dut.u_stride_gen.row_idx, dut.u_stride_gen.wr_left,
                 dut.u_stride_gen.rd_left, dut.u_stride_gen.dst_rd_left);
        $display("    wr_inflight=%b src=%0d dst=%0d pend=%b rd_accept=%b rd_busy=%b",
                 dut.u_stride_gen.wr_inflight, sg_src, sg_dst, sg_pend,
                 dut.rd_accept, dut.rd_busy);
        $display("    master q_cnt=%0d head=%0d tail=%0d ar_pend=%b arvalid=%b arready=%b",
                 rm_cnt, rm_head, rm_tail, rm_pend, bb_arvalid, bb_arready);
        $display("    DDR ar_depth=%0d ar_total=%0d r_state=%0d m_rvalid=%b m_rready=%b",
                 ar_depth, ar_total, r_state, m_rvalid, m_rready);
        $display("    fifo src used=%0d dst used=%0d",
                 dut.u_read_fifo.used, dut.u_dst_read_fifo.used);
        $finish;
      end
      if ((got_row != CH) || got_timeout) begin
        failed = 1;
        $display("    *** INCOMPLETE: rows=%0d expected=%0d timeout_sticky=%b ***",
                 got_row, CH, got_timeout);
        $finish;
      end
    end

    $display("  peaks: src=%0d dst=%0d  max_ddr_idle_stall=%0d cycles", peak_src, peak_dst, max_stall);
    $display("  invariant violations: insync=%0d leak=%0d overflow=%0d qptr=%0d  (total=%0d)",
             err_insync, err_leak, err_neg, err_qptr, err_cnt);
    if (failed == 0 && err_cnt == 0)
      $display("  RESULT: PASS - %0d cmd(s) of %0dx%0d, all invariants held", NCMDS, CW, CH);
    else
      $display("  RESULT: FAIL - failed=%0d invariant_violations=%0d", failed, err_cnt);
    $finish;
  end

endmodule
