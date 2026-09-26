`timescale 1ns/1ps
//=============================================================================
// tb_bitblt_v4 -- run the whole BitBlt engine, with the real Axi_Mux in front
//                 of a DDR responder, and see whether a command ever finishes.
//
// Background: on the board the engine deadlocked - busy stuck high, the
// firmware spinning in gpu2d_wait_idle().  Two earlier benches cleared it, but
// both used a behavioural AXI slave that accepts any number of ARs back to
// back.  A separate bench (tb_axi_mux_rd.v) has since shown the real Axi_Mux
// itself handles 4..12 outstanding read bursts cleanly, with no FIFO overflow,
// so the mux is not the culprit.  This bench puts the engine back on top of it.
//
// The chain under test is the whole read path:
//
//     APB -> stride_gen -> read_master -> Axi_Mux -> DDR responder
//              ^                                        |
//              +---------------- rd_done ----------------+
//
// A single 9x9 COPY is issued - the enemy-bullet shape, one read burst per row,
// which is the workload the frame rate actually lives on.
//=============================================================================
module tb_bitblt_v4;

`ifndef CMD_W
  `define CMD_W 9
`endif
`ifndef CMD_H
  `define CMD_H 9
`endif
`ifndef TIMEOUT
  `define TIMEOUT 400000
`endif
`ifndef TB_CMDS
  `define TB_CMDS 1
`endif

  localparam integer CW = `CMD_W;
  localparam integer CH = `CMD_H;
  localparam integer TIMEOUT_CYC = `TIMEOUT;
  localparam integer NCMDS = `TB_CMDS;
`ifdef TB_ALPHA
  localparam integer OP_SEL = 2;      // OP_ALPHA : two read streams
`else
  localparam integer OP_SEL = 1;      // OP_COPY  : one read stream
`endif

  // ---- clock / reset -----------------------------------------------------
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

  // ---- AXI from the engine ----------------------------------------------
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

  // ---- Axi_Mux master side -> DDR responder ------------------------------
  wire [3:0]   m_arid;   wire [31:0] m_araddr; wire [7:0]  m_arlen;
  wire [2:0]   m_arsize; wire [1:0]  m_arburst, m_arlock;
  wire         m_arvalid; wire        m_arready;
  reg  [3:0]   m_rid;    reg  [127:0] m_rdata;  reg [1:0] m_rresp;
  reg          m_rlast, m_rvalid; wire m_rready;
  wire [3:0]   m_awid;   wire [31:0] m_awaddr; wire [7:0]  m_awlen;
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

  // ---- S0: the video DMA, which on the board never stops ----------------
  // Every measurement above had S0 silent.  That is not the machine the engine
  // runs on: the scanout holds the highest priority and asks for a line
  // forever, so it interleaves with - and delays - every engine read.
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
        s0_arvalid <= 1'b0;
        s0_sent    <= s0_sent + 1;
        s0_out     <= s0_out + 1;
        s0_araddr  <= s0_araddr + 32'h400;
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

  // ---- Axi_Mux : S2 carries the engine ----------------------------------
  Axi_Mux #(
      .SLAVE_ID_WIDTH (4),
      .AXI_DATA_WIDTH (128),
      .ID_MODE_SEL    ("Normal")
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

      // S0 and S1 idle
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

  // ---- DDR responder -----------------------------------------------------
`ifndef TB_LAT
  `define TB_LAT 40
`endif
  localparam integer LAT = `TB_LAT;

  reg [31:0] ar_addr_q [0:127];
  reg [7:0]  ar_len_q  [0:127];
  integer    ar_head = 0, ar_tail = 0, ar_max = 0, ar_total = 0;
  wire [7:0] ar_depth = ar_tail[7:0] - ar_head[7:0];
  assign m_arready = (ar_depth < 8'd96);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_tail <= 0; ar_max <= 0; ar_total <= 0;
    end else if (m_arvalid && m_arready) begin
      ar_addr_q[ar_tail[6:0]] <= m_araddr;
      ar_len_q [ar_tail[6:0]] <= m_arlen;
      ar_tail  <= ar_tail + 1;
      ar_total <= ar_total + 1;
      if ((ar_depth + 8'd1) > ar_max) ar_max <= ar_depth + 8'd1;
    end
  end

  localparam R_IDLE = 2'd0, R_LAT = 2'd1, R_BEAT = 2'd2;
  reg [1:0] r_state = R_IDLE;
  reg [8:0] beats_left = 9'd0;
  integer   lat_cnt = 0, r_beats = 0;
  integer   r_lat_ent = 0, r_beat_ent = 0, r_idle_ent = 0;
  reg [1:0] prev_r_state = 2'd0;
  always @(posedge clk) begin
    prev_r_state <= r_state;
    if (r_state != prev_r_state) begin
      if (r_state == 2'd0) r_idle_ent <= r_idle_ent + 1;
      if (r_state == 2'd1) r_lat_ent  <= r_lat_ent  + 1;
      if (r_state == 2'd2) r_beat_ent <= r_beat_ent + 1;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_state <= R_IDLE; m_rvalid <= 1'b0; m_rlast <= 1'b0; m_rdata <= 128'd0;
      m_rid <= 4'd2; m_rresp <= 2'b00;
      beats_left <= 9'd0; lat_cnt <= 0; r_beats <= 0; ar_head <= 0;
    end else begin
      case (r_state)
        R_IDLE: begin
          m_rvalid <= 1'b0; m_rlast <= 1'b0;
          if (ar_depth != 8'd0) begin
            beats_left <= {1'b0, ar_len_q[ar_head[6:0]]} + 9'd1;
            lat_cnt    <= 0;
            r_state    <= R_LAT;
          end
        end
        R_LAT: begin
          if (lat_cnt < LAT) lat_cnt <= lat_cnt + 1;
          else               r_state <= R_BEAT;
        end
        R_BEAT: begin
          if (!m_rvalid) begin
            m_rvalid <= 1'b1;
            m_rdata  <= {96'd0, 32'hC0DE_0000} + r_beats[31:0];
            m_rlast  <= (beats_left == 9'd1);
            m_rid    <= 4'd2; m_rresp <= 2'b00;
          end else if (m_rready) begin
            r_beats <= r_beats + 1;
            m_rvalid <= 1'b0;
            if (beats_left == 9'd1) begin
              m_rlast <= 1'b0;
              ar_head <= ar_head + 1;
              r_state <= R_IDLE;
            end else beats_left <= beats_left - 9'd1;
          end
        end
      endcase
    end
  end

  // ---- write channel -----------------------------------------------------
  // Count AW and WLAST SEPARATELY and pair them up.  The first version required
  // the AW, the last W beat and everything else in one and the same cycle,
  // which is not how a writer behaves - AW and W are independent channels and
  // arrive in either order.  That bench would have blamed the engine for its
  // own missing B response.
  reg [4:0] aw_cnt = 5'd0;
  reg [4:0] wl_cnt = 5'd0;
  reg       b_pend = 1'b0;

  wire aw_inc   = m_awvalid && m_awready;
  wire wl_inc   = m_wvalid && m_wready && m_wlast;
  wire b_fire   = !b_pend && !m_bvalid && (aw_cnt > 5'd0) && (wl_cnt > 5'd0);
  wire b_retire = m_bvalid && m_bready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_cnt <= 5'd0; wl_cnt <= 5'd0; b_pend <= 1'b0;
      m_bvalid <= 1'b0; m_bid <= 4'd2;
      m_awready <= 1'b1; m_wready <= 1'b1;
    end else begin
      aw_cnt <= aw_cnt + (aw_inc ? 5'd1 : 5'd0) - (b_fire ? 5'd1 : 5'd0);
      wl_cnt <= wl_cnt + (wl_inc ? 5'd1 : 5'd0) - (b_fire ? 5'd1 : 5'd0);
      if (b_retire)    m_bvalid <= 1'b0;
      else if (b_fire) m_bvalid <= 1'b1;
      if (b_fire)        b_pend <= 1'b1;
      else if (b_retire) b_pend <= 1'b0;
      m_bid <= 4'd2;
    end
  end

  // ---- observability -----------------------------------------------------
  wire [2:0]  sg_rd_out_src = dut.u_stride_gen.rd_out_src;
  wire [2:0]  sg_rd_out_dst = dut.u_stride_gen.rd_out_dst;
  wire        sg_rd_tx_pend = dut.u_stride_gen.rd_tx_pend;
  wire        sg_row_done   = dut.u_stride_gen.row_done;
  wire [1:0]  sg_state      = dut.u_stride_gen.state;
  integer     row_done_cnt = 0, rd_done_cnt = 0;
  integer     aw_total = 0, wl_total = 0;
  always @(posedge clk) begin
    if (aw_inc) aw_total <= aw_total + 1;
    if (wl_inc) wl_total <= wl_total + 1;
  end
  integer     peak_src = 0;

  always @(posedge clk) begin
    if (sg_row_done) row_done_cnt <= row_done_cnt + 1;
    if (dut.rd_done)  rd_done_cnt  <= rd_done_cnt + 1;
    if (sg_rd_out_src > peak_src) peak_src <= sg_rd_out_src;
  end

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

  wire [31:0] status = {28'd0, dut.u_apb_regs.timeout_sticky, dut.u_apb_regs.cfg_error_sticky,
                        dut.u_apb_regs.done_seen, dut.busy};

  integer cyc = 0;
  integer t_start = 0;
  integer cmd_i = 0;

  // Periodic probe: a state that "stopped" is very different from one that is
  // still ticking and merely slow, and a single end-of-run snapshot cannot
  // tell them apart.
  always @(posedge clk) begin
    if (cyc != 0 && (cyc % 40000) == 0)
      $display("    [probe %0d] r_state=%0d lat_cnt=%0d beats_left=%0d ar_depth=%0d m_rvalid=%b m_rready=%b bb_rready=%b",
               cyc, r_state, lat_cnt, beats_left, ar_depth, m_rvalid, m_rready, bb_rready);
  end
  always @(posedge clk) cyc <= cyc + 1;

  initial begin
    $display("=== tb_bitblt_v4 : %0dx%0d COPY, engine + real Axi_Mux + DDR ===", CW, CH);
    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
    repeat (20) @(posedge clk);

    // ---- run NCMDS commands back to back -------------------------------
    // Multi-command matters: the read master's queue (q_head/q_tail/q_cnt) is
    // only cleared by reset, never between commands.  If one command leaves an
    // entry behind, the second command inherits the offset.
    for (cmd_i = 0; cmd_i < NCMDS; cmd_i = cmd_i + 1) begin

      apb_write(16'h18, OP_SEL);                                   // op type
      apb_write(16'h04, 32'h0100_0000 + cmd_i * 32'h0002_0000);    // dst
      apb_write(16'h1C, 32'h0200_0000 + cmd_i * 32'h0002_0000);    // src
      apb_write(16'h08, CW);                                       // width
      apb_write(16'h0C, CH);                                       // height
`ifdef TB_SSTRIDE
      apb_write(16'h30, `TB_SSTRIDE);
`else
      apb_write(16'h30, 32'd48);
`endif
      apb_write(16'h48, 32'd8192);                                 // dst stride
`ifdef TB_ALPHA
      apb_write(16'h68, 32'd1);                                    // ALPHA_CTRL
      apb_write(16'h6C, 32'd170);                                  // GLOBAL_ALPHA
`endif
      row_done_cnt = 0;
      rd_done_cnt  = 0;
      peak_src     = 0;
      t_start      = cyc;

      apb_write(16'h14, 32'd1);                                    // START

      // Two-step: first wait for START to actually land (done_seen clears),
      // THEN wait for completion.  A single "done_seen==1 && !busy" wait races
      // with the PREVIOUS command's done_seen, which is still 1 until the new
      // START is taken - that made every command after the first look stuck
      // after ~23 cycles and cut the run short.
      wait (dut.u_apb_regs.done_seen == 1'b0 || (cyc - t_start) > 5000);
      wait ((dut.u_apb_regs.done_seen == 1'b1 && dut.busy == 1'b0) ||
            (cyc - t_start) > TIMEOUT_CYC);
      repeat (20) @(posedge clk);

      $display("  cmd %0d: %6d cycles (%6.1f/row)  row_done=%0d/%0d  rd_done=%0d  peak_out=%0d  busy=%b",
               cmd_i, cyc - t_start, (cyc - t_start) * 1.0 / CH,
               row_done_cnt, CH, rd_done_cnt, peak_src, dut.busy);

      if (row_done_cnt != CH || dut.busy == 1'b1) begin
        $display("    *** STUCK on command %0d ***", cmd_i);
        $display("    stride_gen: state=%0d row_idx=%0d wr_left=%0d rd_left=%0d wr_inflight=%b",
                 dut.u_stride_gen.state, dut.u_stride_gen.row_idx,
                 dut.u_stride_gen.wr_left, dut.u_stride_gen.rd_left,
                 dut.u_stride_gen.wr_inflight);
        $display("    stride_gen: rd_out_src=%0d rd_out_dst=%0d rd_tx_pend=%b rd_accept=%b",
                 dut.u_stride_gen.rd_out_src, dut.u_stride_gen.rd_out_dst,
                 dut.u_stride_gen.rd_tx_pend, dut.rd_accept);
        $display("    DDR side  : ar_depth=%0d ar_total=%0d r_beats=%0d aw=%0d wl=%0d",
                 ar_depth, ar_total, r_beats, aw_total, wl_total);
        $display("    DDR resp  : r_state=%0d lat_cnt=%0d beats_left=%0d m_rvalid=%b m_rready=%b",
                 r_state, lat_cnt, beats_left, m_rvalid, m_rready);
        $display("    DDR state entries: IDLE=%0d LAT=%0d BEAT=%0d  (spinning = re-entering)",
                 r_idle_ent, r_lat_ent, r_beat_ent);
        $display("    mux AXI   : m_arvalid=%b m_arready=%b m_rlast=%b",
                 m_arvalid, m_arready, m_rlast);
        $display("    mux inside: AR2R depth=%0d empty=%b full=%b err=%0d",
                 u_mux.U3_Axi_Mux_Rd_Ctrl.AR2R_Number,
                 u_mux.U3_Axi_Mux_Rd_Ctrl.AR2R_Empty,
                 u_mux.U3_Axi_Mux_Rd_Ctrl.AR2R_Full,
                 u_mux.U3_Axi_Mux_Rd_Ctrl.AR2R_Error);
        $display("    bitblt rdy: bb_arvalid=%b bb_arready=%b bb_rvalid=%b bb_rready=%b bb_rlast=%b",
                 bb_arvalid, bb_arready, bb_rvalid, bb_rready, bb_rlast);
        $finish;
      end
    end

    $display("  S0 (VDMA) sent=%0d done=%0d  active=%b", s0_sent, s0_done, S0_ACTIVE);
    $display("  RESULT: PASS - %0d command(s) of %0dx%0d completed", NCMDS, CW, CH);
    $finish;
  end

endmodule
