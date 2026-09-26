// ti60_top.v
// Top-level module: Sapphire RISC-V SoC + DDR3 Controller + Video DMA + HDMI TX (1366x768)
`timescale 1ps/1ps
`include "ddr3_controller/ddr3_parameter.vh"

module ti60_top #(
    parameter RANK_RATIO    = 1,
    parameter CK_RATIO      = `CK_RATIO,
    parameter ASYN_AXI_CLK  = `ASYN_AXI_CLK,
    parameter RANKS         = `RANKS,
    parameter CK_WIDTH      = `CK_WIDTH,
    parameter CKE_WIDTH     = `CKE_WIDTH,
    parameter CS_WIDTH      = `CS_WIDTH,
    parameter BANK_WIDTH    = `BANK_WIDTH,
    parameter ROW_WIDTH     = `ROW_WIDTH,
    parameter COL_WIDTH     = `COL_WIDTH,
    parameter DM_WIDTH      = `DM_WIDTH,
    parameter DQS_WIDTH     = `DQS_WIDTH,
    parameter DQ_WIDTH      = `DQ_WIDTH,
    parameter ODT_WIDTH     = `ODT_WIDTH,
    parameter DQ_CNT_WIDTH  = `DQ_CNT_WIDTH,
    parameter DQS_CNT_WIDTH = `DQS_CNT_WIDTH,
    parameter DRAM_WIDTH    = `DRAM_WIDTH,
    parameter DATA_WIDTH    = `DATA_WIDTH,
    parameter ADDR_WIDTH    = `ADDR_WIDTH,
    parameter AXI_ID_WIDTH  = `AXI_ID_WIDTH,
    parameter AXI_ADDR_WIDTH= `AXI_ADDR_WIDTH,
    parameter AXI_DATA_WIDTH= `AXI_DATA_WIDTH
)(
    // Clocks and Resets from Interface Designer
    input  wire                               clk_25m,
    input  wire                               core_clk,           // 100 MHz from PLL_TL0
    input  wire                               sdram_clk,          // 400 MHz from PLL_TR0
    input  wire                               rx_cal_clk,         // 400 MHz
    input  wire                               tx_cal_clk,         // 400 MHz
    input  wire                               tx_cal_clk_90edge,  // 400 MHz
    input  wire                               hdmi_tx_slow_clk,   // 85.71 MHz from PLL_BR0
    input  wire                               hdmi_tx_fast_clk,   // 428.6 MHz (5x) from PLL_BR0

    input  wire                               pll_locked,         // PLL_TR0 locked
    input  wire                               user_pll_locked,    // PLL_TL0 locked
    input  wire                               hdmi_tx_locked,     // PLL_BR0 locked

    // PLL Dynamic Phase Shift
    output wire [2:0]                         pll_shift,
    output wire [4:0]                         pll_shift_sel,
    output wire                               pll_shift_ena,

    // DDR3 Memory Bus
    output wire                               ddr_ck_hi,
    output wire                               ddr_ck_lo,
    output wire                               ddr_reset_n,
    output wire [CKE_WIDTH-1:0]               ddr_cke,
    output wire [ROW_WIDTH-1:0]               ddr_addr,
    output wire [BANK_WIDTH-1:0]              ddr_ba,
    output wire                               ddr_cas_n,
    output wire [CS_WIDTH*RANK_RATIO-1:0]     ddr_cs_n,
    output wire                               ddr_ras_n,
    output wire                               ddr_we_n,

    input  wire [DQS_WIDTH-1:0]               ddr_dqs_in_hi,
    input  wire [DQS_WIDTH-1:0]               ddr_dqs_in_lo,
    input  wire [DQ_WIDTH-1:0]                ddr_dq_in_hi,
    input  wire [DQ_WIDTH-1:0]                ddr_dq_in_lo,

    output wire [DQS_WIDTH-1:0]               ddr_dqs_oe,
    output wire [DQS_WIDTH-1:0]               ddr_dqs_oe_n,
    output wire [DQ_WIDTH-1:0]                ddr_dq_oe,
    output wire [DQS_WIDTH-1:0]               ddr_dqs_out_hi,
    output wire [DQS_WIDTH-1:0]               ddr_dqs_out_lo,
    output wire [DQ_WIDTH-1:0]                ddr_dq_out_hi,
    output wire [DQ_WIDTH-1:0]                ddr_dq_out_lo,
    output wire [DM_WIDTH-1:0]                ddr_dm_hi,
    output wire [DM_WIDTH-1:0]                ddr_dm_lo,
    output wire [ODT_WIDTH-1:0]               ddr_odt,

    // HDMI LVDS Interface
    output wire [9:0]                         tmds_clk_o,
    output wire                               tmds_clk_TX_OE,
    output wire                               tmds_clk_TX_RST,
    output wire [9:0]                         tmds_data0_o,
    output wire                               tmds_data0_TX_OE,
    output wire                               tmds_data0_TX_RST,
    output wire [9:0]                         tmds_data1_o,
    output wire                               tmds_data1_TX_OE,
    output wire                               tmds_data1_TX_RST,
    output wire [9:0]                         tmds_data2_o,
    output wire                               tmds_data2_TX_OE,
    output wire                               tmds_data2_TX_RST,

    // UART
    output wire                               system_uart_0_io_txd,
    input  wire                               system_uart_0_io_rxd,

    // Hard JTAG
    input  wire                               jtag_inst1_CAPTURE,
    input  wire                               jtag_inst1_DRCK,
    input  wire                               jtag_inst1_RESET,
    input  wire                               jtag_inst1_RUNTEST,
    input  wire                               jtag_inst1_SEL,
    input  wire                               jtag_inst1_SHIFT,
    input  wire                               jtag_inst1_TCK,
    input  wire                               jtag_inst1_TDI,
    input  wire                               jtag_inst1_TMS,
    input  wire                               jtag_inst1_UPDATE,
    output wire                               jtag_inst1_TDO,

    // Diagnostic LEDs & GPIO
    input  wire [3:0]                         soc_gpio_IN,
    output wire [3:0]                         soc_gpio_OUT,
    output wire [3:0]                         soc_gpio_OE,

    // Gamepad I2C & Mode Switches (from 40-Pin Header & Onboard Keys)
    input  wire                               key_sw0_in,
    input  wire                               key_sw2_in,
    input  wire                               i2c_scl_IN,
    output wire                               i2c_scl_OUT,
    output wire                               i2c_scl_OE,
    input  wire                               i2c_sda_IN,
    output wire                               i2c_sda_OUT,
    output wire                               i2c_sda_OE
);

    // LVDS TX Control
    assign tmds_clk_TX_OE    = 1'b1;
    assign tmds_clk_TX_RST   = ~hdmi_tx_locked;
    assign tmds_data0_TX_OE  = 1'b1;
    assign tmds_data0_TX_RST = ~hdmi_tx_locked;
    assign tmds_data1_TX_OE  = 1'b1;
    assign tmds_data1_TX_RST = ~hdmi_tx_locked;
    assign tmds_data2_TX_OE  = 1'b1;
    assign tmds_data2_TX_RST = ~hdmi_tx_locked;

    // Reset Logic
    wire sys_rst = pll_locked & user_pll_locked;
    localparam CNT_INIT = 200 * 1000;
    reg [19:0] rst_cnt;
    always @(posedge core_clk or negedge sys_rst) begin
        if (!sys_rst)
            rst_cnt <= 20'd0;
        else if (rst_cnt != CNT_INIT)
            rst_cnt <= rst_cnt + 20'd1;
    end
    wire ddr_rstn = (rst_cnt == CNT_INIT);
    wire cal_done;

    // AXI Arbiter / Mux Signals
    // Master port to DDR3 controller
    wire [AXI_ID_WIDTH-1:0]   m_axi_awid;
    wire [31:0]               m_axi_awaddr_32;
    wire [7:0]                m_axi_awlen;
    wire [2:0]                m_axi_awsize;
    wire [1:0]                m_axi_awburst;
    wire [1:0]                m_axi_awlock;
    wire                      m_axi_awvalid;
    wire                      m_axi_awready;

    wire [AXI_ID_WIDTH-1:0]   m_axi_wid;
    wire [AXI_DATA_WIDTH-1:0] m_axi_wdata;
    wire                      m_axi_wlast;
    wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb;
    wire                      m_axi_wvalid;
    wire                      m_axi_wready;

    wire [AXI_ID_WIDTH-1:0]   m_axi_bid;
    wire                      m_axi_bvalid;
    wire                      m_axi_bready;

    wire video_read_priority;
    wire ddr_awvalid, ddr_awready, ddr_wvalid, ddr_wready;
    video_write_guard u_video_write_guard (
        .clk(core_clk), .rst_n(ddr_rstn), .video_priority(video_read_priority),
        .s_awvalid(m_axi_awvalid), .s_awready(m_axi_awready),
        .m_awvalid(ddr_awvalid), .m_awready(ddr_awready),
        .s_wvalid(m_axi_wvalid), .s_wready(m_axi_wready),
        .m_wvalid(ddr_wvalid), .m_wready(ddr_wready),
        .bvalid(m_axi_bvalid), .bready(m_axi_bready)
    );

    wire [AXI_ID_WIDTH-1:0]   m_axi_arid;
    wire [31:0]               m_axi_araddr_32;
    wire [7:0]                m_axi_arlen;
    wire [2:0]                m_axi_arsize;
    wire [1:0]                m_axi_arburst;
    wire [1:0]                m_axi_arlock;
    wire                      m_axi_arvalid;
    wire                      m_axi_arready;

    wire [AXI_ID_WIDTH-1:0]   m_axi_rid;
    wire [AXI_DATA_WIDTH-1:0] m_axi_rdata;
    wire                      m_axi_rlast;
    wire [1:0]                m_axi_rresp;
    wire                      m_axi_rvalid;
    wire                      m_axi_rready;

    // Slave 0 (Sapphire SoC AXI4 Master)
    wire [7:0]                soc_aw_id;
    wire [31:0]               soc_aw_addr;
    wire [7:0]                soc_aw_len;
    wire [2:0]                soc_aw_size;
    wire [1:0]                soc_aw_burst;
    wire                      soc_aw_lock;
    wire                      soc_aw_valid;
    wire                      soc_aw_ready;

    wire [127:0]              soc_w_data;
    wire [15:0]               soc_w_strb;
    wire                      soc_w_last;
    wire                      soc_w_valid;
    wire                      soc_w_ready;

    wire [7:0]                soc_b_id;
    wire                      soc_b_valid;
    wire                      soc_b_ready;

    wire [7:0]                soc_ar_id;
    wire [31:0]               soc_ar_addr;
    wire [7:0]                soc_ar_len;
    wire [2:0]                soc_ar_size;
    wire [1:0]                soc_ar_burst;
    wire                      soc_ar_lock;
    wire                      soc_ar_valid;
    wire                      soc_ar_ready;

    wire [7:0]                soc_r_id;
    wire [127:0]              soc_r_data;
    wire [1:0]                soc_r_resp;
    wire                      soc_r_last;
    wire                      soc_r_valid;
    wire                      soc_r_ready;

    // Slave 1 (Video DMA AXI4 Read Master)
    wire [3:0]                vdma_arid;
    wire [27:0]               vdma_araddr;
    wire [7:0]                vdma_arlen;
    wire [2:0]                vdma_arsize;
    wire [1:0]                vdma_arburst;
    wire [1:0]                vdma_arlock;
    wire                      vdma_arvalid;
    wire                      vdma_arready;

    wire [3:0]                vdma_rid;
    wire [127:0]              vdma_rdata;
    wire [1:0]                vdma_rresp;
    wire                      vdma_rlast;
    wire                      vdma_rvalid;
    wire                      vdma_rready;

    // Slave 2: BitBlt read/write AXI master
    wire [3:0] bb_awid; wire [27:0] bb_awaddr; wire [7:0] bb_awlen;
    wire [2:0] bb_awsize; wire [1:0] bb_awburst, bb_awlock; wire bb_awvalid, bb_awready;
    wire [3:0] bb_wid; wire [127:0] bb_wdata; wire [15:0] bb_wstrb; wire bb_wlast, bb_wvalid, bb_wready;
    wire [3:0] bb_bid; wire bb_bvalid, bb_bready;
    wire [3:0] bb_arid; wire [27:0] bb_araddr; wire [7:0] bb_arlen;
    wire [2:0] bb_arsize; wire [1:0] bb_arburst, bb_arlock; wire bb_arvalid, bb_arready;
    wire [3:0] bb_rid; wire [127:0] bb_rdata; wire [1:0] bb_rresp; wire bb_rlast, bb_rvalid, bb_rready;

    // Axi_Mux 3-to-1 Arbiter (VDMA read, Sapphire CPU, BitBlt write)
    Axi_Mux #(
        .SLAVE_ID_WIDTH(4),
        .AXI_DATA_WIDTH(128),
        .ID_MODE_SEL("Normal")
    ) u_axi_mux (
        .Sys_Clk        (core_clk),
        .Sys_Rst_N      (ddr_rstn),

        // Master to DDR3
        .O_M_AW_ID      (m_axi_awid),
        .O_M_AW_ADDR    (m_axi_awaddr_32),
        .O_M_AW_LEN     (m_axi_awlen),
        .O_M_AW_SIZE    (m_axi_awsize),
        .O_M_AW_BURST   (m_axi_awburst),
        .O_M_AW_LOCK    (m_axi_awlock),
        .O_M_AW_VALID   (m_axi_awvalid),
        .I_M_AW_READY   (m_axi_awready),

        .O_M_W_ID       (m_axi_wid),
        .O_M_W_DATA     (m_axi_wdata),
        .O_M_W_LAST     (m_axi_wlast),
        .O_M_W_STRB     (m_axi_wstrb),
        .O_M_W_VALID    (m_axi_wvalid),
        .I_M_W_READY    (m_axi_wready),

        .I_M_B_ID       (m_axi_bid),
        .I_M_B_VALID    (m_axi_bvalid),
        .O_M_B_READY    (m_axi_bready),

        .O_M_AR_ID      (m_axi_arid),
        .O_M_AR_ADDR    (m_axi_araddr_32),
        .O_M_AR_LEN     (m_axi_arlen),
        .O_M_AR_SIZE    (m_axi_arsize),
        .O_M_AR_BURST   (m_axi_arburst),
        .O_M_AR_LOCK    (m_axi_arlock),
        .O_M_AR_VALID   (m_axi_arvalid),
        .I_M_AR_READY   (m_axi_arready),

        .I_M_R_ID       (m_axi_rid),
        .I_M_R_DATA     (m_axi_rdata),
        .I_M_R_LAST     (m_axi_rlast),
        .I_M_R_RESP     (m_axi_rresp),
        .I_M_R_VALID    (m_axi_rvalid),
        .O_M_R_READY    (m_axi_rready),

        // Slave 0: Video DMA Read Master (Priority 0: Hard Real-Time Display Feed)
        .I_S0_AW_ID     (4'd0),
        .I_S0_AW_ADDR   (32'd0),
        .I_S0_AW_LEN    (8'd0),
        .I_S0_AW_SIZE   (3'd0),
        .I_S0_AW_BURST  (2'd0),
        .I_S0_AW_LOCK   (2'd0),
        .I_S0_AW_VALID  (1'b0),
        .O_S0_AW_READY  (),

        .I_S0_W_ID      (4'd0),
        .I_S0_W_DATA    (128'd0),
        .I_S0_W_LAST    (1'b0),
        .I_S0_W_STRB    (16'd0),
        .I_S0_W_VALID   (1'b0),
        .O_S0_W_READY   (),

        .O_S0_B_ID      (),
        .O_S0_B_VALID   (),
        .I_S0_B_READY   (1'b0),

        .I_S0_AR_ID     (vdma_arid),
        .I_S0_AR_ADDR   ({4'd0, vdma_araddr}),
        .I_S0_AR_LEN    (vdma_arlen),
        .I_S0_AR_SIZE   (vdma_arsize),
        .I_S0_AR_BURST  (vdma_arburst),
        .I_S0_AR_LOCK   (vdma_arlock),
        .I_S0_AR_VALID  (vdma_arvalid),
        .O_S0_AR_READY  (vdma_arready),

        .O_S0_R_ID      (vdma_rid),
        .O_S0_R_DATA    (vdma_rdata),
        .O_S0_R_LAST    (vdma_rlast),
        .O_S0_R_RESP    (vdma_rresp),
        .O_S0_R_VALID   (vdma_rvalid),
        .I_S0_R_READY   (vdma_rready),

        // Slave 1: Sapphire SoC (Read/Write Master, Priority 1)
        .I_S1_AW_ID     (soc_aw_id[3:0]),
        .I_S1_AW_ADDR   (soc_aw_addr),
        .I_S1_AW_LEN    (soc_aw_len),
        .I_S1_AW_SIZE   (soc_aw_size),
        .I_S1_AW_BURST  (soc_aw_burst),
        .I_S1_AW_LOCK   ({1'b0, soc_aw_lock}),
        .I_S1_AW_VALID  (soc_aw_valid),
        .O_S1_AW_READY  (soc_aw_ready),

        .I_S1_W_ID      (soc_aw_id[3:0]),
        .I_S1_W_DATA    (soc_w_data),
        .I_S1_W_LAST    (soc_w_last),
        .I_S1_W_STRB    (soc_w_strb),
        .I_S1_W_VALID   (soc_w_valid),
        .O_S1_W_READY   (soc_w_ready),

        .O_S1_B_ID      (soc_b_id[3:0]),
        .O_S1_B_VALID   (soc_b_valid),
        .I_S1_B_READY   (soc_b_ready),

        .I_S1_AR_ID     (soc_ar_id[3:0]),
        .I_S1_AR_ADDR   (soc_ar_addr),
        .I_S1_AR_LEN    (soc_ar_len),
        .I_S1_AR_SIZE   (soc_ar_size),
        .I_S1_AR_BURST  (soc_ar_burst),
        .I_S1_AR_LOCK   ({1'b0, soc_ar_lock}),
        .I_S1_AR_VALID  (soc_ar_valid),
        .O_S1_AR_READY  (soc_ar_ready),

        .O_S1_R_ID      (soc_r_id[3:0]),
        .O_S1_R_DATA    (soc_r_data),
        .O_S1_R_LAST    (soc_r_last),
        .O_S1_R_RESP    (soc_r_resp),
        .O_S1_R_VALID   (soc_r_valid),
        .I_S1_R_READY   (soc_r_ready),

        // Slave 2: BitBlt hardware read/write master
        .I_S2_AW_ID     (bb_awid), .I_S2_AW_ADDR   ({4'd0,bb_awaddr}), .I_S2_AW_LEN    (bb_awlen),
        .I_S2_AW_SIZE   (bb_awsize), .I_S2_AW_BURST  (bb_awburst), .I_S2_AW_LOCK   (bb_awlock),
        .I_S2_AW_VALID  (bb_awvalid), .O_S2_AW_READY  (bb_awready),
        .I_S2_W_ID      (bb_wid), .I_S2_W_DATA     (bb_wdata), .I_S2_W_LAST     (bb_wlast),
        .I_S2_W_STRB    (bb_wstrb), .I_S2_W_VALID   (bb_wvalid), .O_S2_W_READY   (bb_wready),
        .O_S2_B_ID      (bb_bid), .O_S2_B_VALID   (bb_bvalid), .I_S2_B_READY   (bb_bready),
        .I_S2_AR_ID     (bb_arid), .I_S2_AR_ADDR   ({4'd0,bb_araddr}), .I_S2_AR_LEN    (bb_arlen),
        .I_S2_AR_SIZE   (bb_arsize), .I_S2_AR_BURST  (bb_arburst), .I_S2_AR_LOCK   (bb_arlock),
        .I_S2_AR_VALID  (bb_arvalid), .O_S2_AR_READY  (bb_arready),
        .O_S2_R_ID      (bb_rid), .O_S2_R_DATA    (bb_rdata), .O_S2_R_LAST    (bb_rlast),
        .O_S2_R_RESP    (bb_rresp), .O_S2_R_VALID   (bb_rvalid), .I_S2_R_READY   (bb_rready),

        // Arbiter configuration
        // ---- arbitration: HARD PRIORITY, scanout first ----------------------
        // This was briefly changed to round robin (1'b0) on the theory that the
        // scanout only needs ~12% of the DDR bandwidth and that hard priority
        // was starving BitBlt.  Both halves of that were wrong:
        //
        //   * the scanout load is NOT 12%.  One scan line is 1366 px = 342 AXI
        //     beats, and a line lasts 1366 / 85.714 MHz = 15.94 us, so it needs
        //     342 / 15.94 = 21.5 beats/us.  The bus delivers 100 beats/us at
        //     100 MHz, so the scanout needs 21.5% of it - nearly double the
        //     figure the round-robin change was justified with;
        //   * round robin gives it 1/3 (Cfg_Cnl_Mask = 3'b111), which is enough
        //     ON AVERAGE but gives no deadline guarantee, and the scanout is
        //     hard real time: every line has a 15.94 us deadline.
        //
        // Board symptom of getting this wrong: a single 8x8 OP_ADD hung for
        // WATCHDOG_CYCLES (50,001,011 cycles = 0.5 s) against a 1.33 M cycle
        // frame, i.e. the reported freeze.  The engine's row loop waits on
        // !wr_inflight, wr_inflight clears only on write completion, and a write
        // completes only through video_write_guard - which shuts the write
        // channel for as long as video_read_priority is high.  A scanout that
        // misses its deadline therefore stops BitBlt completing anything.
        //
        // Hard priority is the safe direction: the scanout's own read request
        // stops once its FIFO reaches 960 words (video_dma_read.v:292), so it
        // hands the bus back instead of holding it forever.
        .Cfg_Arb_Type   (1'b1), // Hard priority: scanout first, then SoC/BitBlt
        .Cfg_Cnl_Mask   (3'b111), // Enable Video DMA, SoC, and BitBlt
        .O_AW_Cnl_Num   (),
        .O_W_Cnl_Num    (),
        .O_B_Cnl_Num    (),
        .O_AR_Cnl_Num   (),
        .O_R_Cnl_Num    ()
    );

    assign soc_b_id[7:4] = 4'd0;
    assign soc_r_id[7:4] = 4'd0;

    // Diagnostic Heartbeat & Board Status LEDs
    reg [25:0] heartbeat_cnt;
    always @(posedge core_clk or negedge ddr_rstn) begin
        if (!ddr_rstn)
            heartbeat_cnt <= 26'd0;
        else
            heartbeat_cnt <= heartbeat_cnt + 26'd1;
    end

    // Diagnostic LEDs:
    // LED0 (P13, 3.3V): DDR3 Calibration Done (cal_done)
    // LED1 (N13, 3.3V): All PLLs Locked (pll_locked & user_pll_locked & hdmi_tx_locked)
    // LED2 (G3,  1.8V): Video DMA Active (bursts_left > 0)
    // LED3 (N2,  1.8V): Core Clock Heartbeat (~1.49 Hz blink)
    assign soc_gpio_OE     = 4'b1111;
    assign soc_gpio_OUT[0] = cal_done;
    assign soc_gpio_OUT[1] = pll_locked & user_pll_locked & hdmi_tx_locked;
    assign soc_gpio_OUT[2] = (vdma_arvalid | vdma_rvalid);
    assign soc_gpio_OUT[3] = heartbeat_cnt[25];

    // DDR3 Controller Core
    ddr3_top u_ddr3_top (
        .axi_clk            (core_clk),
        .core_clk           (core_clk),
        .sdram_clk          (sdram_clk),
        .rx_cal_clk         (rx_cal_clk),
        .tx_cal_clk         (tx_cal_clk),
        .tx_cal_clk_90edge  (tx_cal_clk_90edge),
        .rstn               (ddr_rstn),
        .pll_shift          (pll_shift),
        .pll_shift_sel      (pll_shift_sel),
        .pll_shift_ena      (pll_shift_ena),

        .ddr_ck_hi          (ddr_ck_hi),
        .ddr_ck_lo          (ddr_ck_lo),
        .ddr_cke            (ddr_cke),
        .ddr_reset_n        (ddr_reset_n),
        .ddr_cs_n           (ddr_cs_n),
        .ddr_ras_n          (ddr_ras_n),
        .ddr_cas_n          (ddr_cas_n),
        .ddr_we_n           (ddr_we_n),
        .ddr_addr           (ddr_addr),
        .ddr_ba             (ddr_ba),

        .ddr_dqs_oe         (ddr_dqs_oe),
        .ddr_dqs_oe_n       (ddr_dqs_oe_n),
        .ddr_dq_oe          (ddr_dq_oe),
        .ddr_dqs_in_hi      (ddr_dqs_in_hi),
        .ddr_dqs_in_lo      (ddr_dqs_in_lo),
        .ddr_dq_in_hi       (ddr_dq_in_hi),
        .ddr_dq_in_lo       (ddr_dq_in_lo),

        .ddr_dqs_out_hi     (ddr_dqs_out_hi),
        .ddr_dqs_out_lo     (ddr_dqs_out_lo),
        .ddr_dq_out_hi      (ddr_dq_out_hi),
        .ddr_dq_out_lo      (ddr_dq_out_lo),

        .ddr_dm_hi          (ddr_dm_hi),
        .ddr_dm_lo          (ddr_dm_lo),
        .ddr_odt            (ddr_odt),

        .app_sr_req         (1'b0),
        .app_ref_req        (1'b0),
        .app_zq_req         (1'b0),
        .app_sr_active      (),
        .app_ref_ack        (),
        .app_zq_ack         (),

        // AXI4 Slave Ports from Axi_Mux Master
        .s_axi_awid         (m_axi_awid),
        .s_axi_awaddr       (m_axi_awaddr_32[AXI_ADDR_WIDTH-1:0]),
        .s_axi_awlen        (m_axi_awlen),
        .s_axi_awsize       (m_axi_awsize),
        .s_axi_awburst      (m_axi_awburst),
        .s_axi_awlock       (m_axi_awlock[0]),
        .s_axi_awcache      (4'h0),
        .s_axi_awprot       (3'h0),
        .s_axi_awqos        (4'h0),
        .s_axi_awvalid      (ddr_awvalid),
        .s_axi_awready      (ddr_awready),

        .s_axi_wdata        (m_axi_wdata),
        .s_axi_wstrb        (m_axi_wstrb),
        .s_axi_wlast        (m_axi_wlast),
        .s_axi_wvalid       (ddr_wvalid),
        .s_axi_wready       (ddr_wready),

        .s_axi_bid          (m_axi_bid),
        .s_axi_bresp        (),
        .s_axi_bvalid       (m_axi_bvalid),
        .s_axi_bready       (m_axi_bready),

        .s_axi_arid         (m_axi_arid),
        .s_axi_araddr       (m_axi_araddr_32[AXI_ADDR_WIDTH-1:0]),
        .s_axi_arlen        (m_axi_arlen),
        .s_axi_arsize       (m_axi_arsize),
        .s_axi_arburst      (m_axi_arburst),
        .s_axi_arlock       (m_axi_arlock[0]),
        .s_axi_arcache      (4'h0),
        .s_axi_arprot       (3'h0),
        .s_axi_arqos        (4'h0),
        .s_axi_arvalid      (m_axi_arvalid),
        .s_axi_arready      (m_axi_arready),

        .s_axi_rid          (m_axi_rid),
        .s_axi_rdata        (m_axi_rdata),
        .s_axi_rresp        (m_axi_rresp),
        .s_axi_rlast        (m_axi_rlast),
        .s_axi_rvalid       (m_axi_rvalid),
        .s_axi_rready       (m_axi_rready),

        .wrlvl_dq_check     (),
        .rd_level_dqs_check (),
        .rdlvl_shift        (),
        .wrlvl_shift        (),
        .init_cur_state     (),
        .idelay_ld          (),
        .mpr_rdlvl_dly      (),
        .ddr_debug_port     (),
        .cal_done           (cal_done)
    );

    // Video Signals & VSync Synchronizer for Sapphire SoC
    wire [7:0] video_r, video_g, video_b;
    wire       video_hs, video_vs, video_de;

    // 2-stage synchronizer: cross video_vs from hdmi_tx_slow_clk (85.71 MHz) to core_clk (100 MHz)
    reg vsync_sync1, vsync_sync2;
    always @(posedge core_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            vsync_sync1 <= 1'b0;
            vsync_sync2 <= 1'b0;
        end else begin
            vsync_sync1 <= video_vs;
            vsync_sync2 <= vsync_sync1;
        end
    end

    // Sapphire RISC-V SoC
    soc u_sapphire_soc (
        .io_asyncReset                      (!pll_locked || !cal_done),
        .io_systemClk                       (core_clk),

        .system_uart_0_io_txd               (system_uart_0_io_txd),
        .system_uart_0_io_rxd               (system_uart_0_io_rxd),
        .io_memoryClk                       (core_clk),
        .io_memoryReset                     (),
        .io_systemReset                     (),

        // External Memory AXI4 Interface
        .io_ddrA_aw_payload_prot            (),
        .io_ddrA_aw_payload_qos             (),
        .io_ddrA_aw_payload_cache           (),
        .io_ddrA_aw_payload_lock            (soc_aw_lock),
        .io_ddrA_aw_payload_burst           (soc_aw_burst),
        .io_ddrA_aw_payload_size            (soc_aw_size),
        .io_ddrA_aw_payload_len             (soc_aw_len),
        .io_ddrA_aw_payload_region          (),
        .io_ddrA_aw_payload_id              (soc_aw_id),
        .io_ddrA_aw_payload_addr            (soc_aw_addr),
        .io_ddrA_aw_ready                   (soc_aw_ready),
        .io_ddrA_aw_valid                   (soc_aw_valid),

        .io_ddrA_w_payload_last             (soc_w_last),
        .io_ddrA_w_ready                    (soc_w_ready),
        .io_ddrA_w_valid                    (soc_w_valid),
        .io_ddrA_w_payload_strb             (soc_w_strb),
        .io_ddrA_w_payload_data             (soc_w_data),

        .io_ddrA_b_payload_resp             (),
        .io_ddrA_b_payload_id               (soc_b_id),
        .io_ddrA_b_ready                    (soc_b_ready),
        .io_ddrA_b_valid                    (soc_b_valid),

        .io_ddrA_ar_payload_prot            (),
        .io_ddrA_ar_payload_qos             (),
        .io_ddrA_ar_payload_cache           (),
        .io_ddrA_ar_payload_region          (),
        .io_ddrA_ar_payload_lock            (soc_ar_lock),
        .io_ddrA_ar_payload_burst           (soc_ar_burst),
        .io_ddrA_ar_payload_size            (soc_ar_size),
        .io_ddrA_ar_payload_len             (soc_ar_len),
        .io_ddrA_ar_payload_id              (soc_ar_id),
        .io_ddrA_ar_payload_addr            (soc_ar_addr),
        .io_ddrA_ar_ready                   (soc_ar_ready),
        .io_ddrA_ar_valid                   (soc_ar_valid),

        .io_ddrA_r_payload_last             (soc_r_last),
        .io_ddrA_r_payload_resp             (soc_r_resp),
        .io_ddrA_r_payload_id               (soc_r_id),
        .io_ddrA_r_payload_data             (soc_r_data),
        .io_ddrA_r_ready                    (soc_r_ready),
        .io_ddrA_r_valid                    (soc_r_valid),

        // SPI 0 (Tie-off unused)
        .system_spi_0_io_sclk_write         (),
        .system_spi_0_io_data_0_writeEnable (),
        .system_spi_0_io_data_0_read        (1'b0),
        .system_spi_0_io_data_0_write       (),
        .system_spi_0_io_data_1_writeEnable (),
        .system_spi_0_io_data_1_read        (1'b0),
        .system_spi_0_io_data_1_write       (),
        .system_spi_0_io_data_2_writeEnable (),
        .system_spi_0_io_data_2_read        (1'b0),
        .system_spi_0_io_data_2_write       (),
        .system_spi_0_io_data_3_writeEnable (),
        .system_spi_0_io_data_3_read        (1'b0),
        .system_spi_0_io_data_3_write       (),
        .system_spi_0_io_ss                 (),

        // APB 0 (connected to BitBlt 2D Accelerator)
        .io_apbSlave_0_PADDR                (apb0_paddr),
        .io_apbSlave_0_PSEL                 (apb0_psel),
        .io_apbSlave_0_PENABLE              (apb0_penable),
        .io_apbSlave_0_PREADY               (apb0_pready),
        .io_apbSlave_0_PWRITE               (apb0_pwrite),
        .io_apbSlave_0_PWDATA               (apb0_pwdata),
        .io_apbSlave_0_PRDATA               (apb0_prdata),
        .io_apbSlave_0_PSLVERROR            (apb0_pslverr),

        .system_gpio_0_io_write             (),
        .system_gpio_0_io_read              ({1'b0, sw2_pressed, sw0_pressed, vsync_sync2}),
        .system_gpio_0_io_writeEnable       (),

        // Hard JTAG
        .jtagCtrl_tck                       (jtag_inst1_TCK),
        .jtagCtrl_tdi                       (jtag_inst1_TDI),
        .jtagCtrl_tdo                       (jtag_inst1_TDO),
        .jtagCtrl_enable                    (jtag_inst1_SEL),
        .jtagCtrl_capture                   (jtag_inst1_CAPTURE),
        .jtagCtrl_shift                     (jtag_inst1_SHIFT),
        .jtagCtrl_update                    (jtag_inst1_UPDATE),
        .jtagCtrl_reset                     (jtag_inst1_RESET)
    );

    // Gamepad & Board Keys Controller
    wire [7:0] pad_joy_x, pad_joy_y;
    wire [4:0] pad_buttons;
    wire       pad_online;
    wire       sw0_pressed, sw2_pressed;
    wire       sw0_pulse, sw2_pulse;
    wire [6:0] i2c_slave_addr;
    wire       force_hud_disable;
    wire [31:0] blit_color_matrix_ctrl;
    wire [31:0] blit_bloom_ctrl;

    i2c_gamepad_top #(
        .CLK_FREQ_HZ (100_000_000),
        .I2C_FREQ_HZ (100_000)
    ) u_i2c_gamepad (
        .clk            (core_clk),
        .rst_n          (ddr_rstn),
        .key_sw0_in     (key_sw0_in),
        .key_sw2_in     (key_sw2_in),
        .i2c_scl_in     (i2c_scl_IN),
        .i2c_scl_out    (i2c_scl_OUT),
        .i2c_scl_oe     (i2c_scl_OE),
        .i2c_sda_in     (i2c_sda_IN),
        .i2c_sda_out    (i2c_sda_OUT),
        .i2c_sda_oe     (i2c_sda_OE),
        .i2c_slave_addr (i2c_slave_addr),
        .sw0_pressed    (sw0_pressed),
        .sw2_pressed    (sw2_pressed),
        .sw0_pulse      (sw0_pulse),
        .sw2_pulse      (sw2_pulse),
        .joy_x          (pad_joy_x),
        .joy_y          (pad_joy_y),
        .buttons        (pad_buttons),
        .gamepad_online (pad_online)
    );

    // Video DMA Read Engine (reads Framebuffer from DDR3, dynamic base address)
    wire [27:0] vdma_next_base;
    wire [27:0] vdma_active_base;
    wire [27:0] vdma_right_next_base, vdma_right_active_base;
    wire [7:0] cpu_fps_bcd, fpga_fps_bcd;
    wire [31:0] scan_diagnostics;
    wire        vdma_vsync_flag;
    wire [31:0] blit_weather_ctrl;
    wire [31:0] blit_weather_mask_x;
    wire [31:0] blit_weather_mask_y;
    // Live BitBlt engine probe.  Sourced inside bitblt_top (read master queue
    // depth / AR pending / stride_gen state) and published on APB 0x74 so the
    // firmware can see WHERE the engine is stuck, not just THAT it is stuck.

    video_dma_read #(
        .FRAME_BASE_ADDR (28'h0080_0000),
        .H_ACT           (1366),
        .V_ACT           (768)
    ) u_video_dma (
        .axi_clk        (core_clk),
        .axi_rst_n      (ddr_rstn),
        .cal_done       (cal_done),

        // AXI4 Read Master
        .m_axi_arid     (vdma_arid),
        .m_axi_araddr   (vdma_araddr),
        .m_axi_arlen    (vdma_arlen),
        .m_axi_arsize   (vdma_arsize),
        .m_axi_arburst  (vdma_arburst),
        .m_axi_arlock   (vdma_arlock),
        .m_axi_arvalid  (vdma_arvalid),
        .m_axi_arready  (vdma_arready),

        .m_axi_rid      (vdma_rid),
        .m_axi_rdata    (vdma_rdata),
        .m_axi_rresp    (vdma_rresp),
        .m_axi_rlast    (vdma_rlast),
        .m_axi_rvalid   (vdma_rvalid),
        .m_axi_rready   (vdma_rready),

        // Pixel Clock Domain
        .pixel_clk      (hdmi_tx_slow_clk),
        .pixel_rst_n    (hdmi_tx_locked),

        // Double-buffer control
        .next_frame_base_addr (vdma_next_base),
        .active_frame_base_addr (vdma_active_base),
        .next_right_base_addr (vdma_right_next_base),
        .scan_diagnostics (scan_diagnostics),
        .video_read_priority (video_read_priority),
        .active_right_base_addr (vdma_right_active_base),
        .cpu_fps_bcd (cpu_fps_bcd), .fpga_fps_bcd (fpga_fps_bcd),
        .hud_enable     (~force_hud_disable),
        .weather_ctrl   (blit_weather_ctrl),
        .weather_mask_x (blit_weather_mask_x),
        .weather_mask_y (blit_weather_mask_y),
        .vsync_flag           (vdma_vsync_flag),

        // Video Output
        .red_out        (video_r),
        .green_out      (video_g),
        .blue_out       (video_b),
        .hsync_out      (video_hs),
        .vsync_out      (video_vs),
        .de_out         (video_de)
    );

    // =========================================================================
    // BitBlt 2D Hardware Accelerator
    // =========================================================================

    // APB Bus wires (SoC APB Slave 0 <-> BitBlt)
    wire [15:0] apb0_paddr;
    wire        apb0_psel;
    wire        apb0_penable;
    wire        apb0_pwrite;
    wire [31:0] apb0_pwdata;
    wire [31:0] apb0_prdata;
    wire        apb0_pready;
    wire        apb0_pslverr;

    // BitBlt engine v3: 64-beat (1 KiB) AXI bursts, a 256-beat source read
    // elasticity FIFO and a 192-beat destination-background FIFO (OP_ALPHA
    // reads the live background back before blending).  Both depths stay above
    // 2*MAX_BURST_BEATS + 4, which is what keeps the credit accounting in
    // bitblt_stride_gen deadlock free.  Set MAX_BURST_BEATS back to 16 if the
    // DDR3 controller ever rejects the longer INCR bursts - no other change is
    // required.
    bitblt_top #(
        // ---- burst sizing, and why it is 192 and not 64 -----------------
        //
        // The engine issues one AXI burst at a time (see the note above), so
        // its throughput is
        //
        //     (burst bytes) / (AR->RLAST round trip through Axi_Mux + DDR3)
        //
        // and the round trip is a couple of hundred core clocks whatever the
        // burst length is.  A full-screen COPY is 768 rows x 342 write beats,
        // and the game redraws two surfaces of that size every frame, so at a
        // 1 KiB burst that is ~8200 round trips - tens of milliseconds, and the
        // reason the board sat at 30 FPS with the frame loop waiting on nothing
        // but the scanout handshake.
        //
        // Widening the burst is the one lever that costs nothing anywhere else:
        // the AXI traffic is identical, Axi_Mux sees one request instead of
        // three, and NO extra request is ever outstanding.  It is deliberately
        // preferred over letting several bursts be in flight, which was tried,
        // passed the RTL regression on the idealised bench and HUNG THE BOARD -
        // the bench models an AXI slave that accepts requests back to back,
        // while the real Axi_Mux is a channel-arbitrating mux with its own
        // AR-to-R bookkeeping.
        //
        // 192 keeps the credit invariant the generator was written around,
        // DST_FIFO_DEPTH > 2*MAX_BURST_BEATS + 4, inside the 512-deep FIFOs
        // below (2*192+4 = 388), and 192 beats is 3 KiB - AXI allows up to 256.
        // ---- BURST EXPERIMENT 2026-09-25 --------------------------------
        // 64 -> 192 beats and 192 -> 448 deep FIFOs.
        // tb_bitblt_cost measured, at three read latencies:
        //   full-screen COPY  64 beats 579081/2216457/4059657 cyc
        //                   192 beats 579081/1039881/1500681 cyc  (2.7x)
        //   bursts for one full-screen COPY   4608 -> 2304
        // and the outstanding count went 2 -> 3, i.e. this does NOT add
        // concurrency - it removes round trips.  The credit rule needs
        // DEPTH > 2*MAX_BURST_BEATS + 4 = 388, hence 448.
        .MAX_BURST_BEATS (192),
        .READ_FIFO_DEPTH (448),
        .READ_FIFO_AW    (9),
        .DST_FIFO_DEPTH  (448),
        .DST_FIFO_AW     (9)
    ) u_bitblt (
        .clk            (core_clk),
        .rst_n          (ddr_rstn),

        // APB Slave
        .apb_paddr      (apb0_paddr),
        .apb_psel       (apb0_psel),
        .apb_penable    (apb0_penable),
        .apb_pwrite     (apb0_pwrite),
        .apb_pwdata     (apb0_pwdata),
        .apb_prdata     (apb0_prdata),
        .apb_pready     (apb0_pready),
        .apb_pslverr    (apb0_pslverr),

        // AXI4 Read Master
        .m_axi_arid     (bb_arid),
        .m_axi_araddr   (bb_araddr),
        .m_axi_arlen    (bb_arlen),
        .m_axi_arsize   (bb_arsize),
        .m_axi_arburst  (bb_arburst),
        .m_axi_arlock   (bb_arlock),
        .m_axi_arvalid  (bb_arvalid),
        .m_axi_arready  (bb_arready),
        .m_axi_rid      (bb_rid),
        .m_axi_rdata    (bb_rdata),
        .m_axi_rresp    (bb_rresp),
        .m_axi_rlast    (bb_rlast),
        .m_axi_rvalid   (bb_rvalid),
        .m_axi_rready   (bb_rready),

        // AXI4 Write Master
        .m_axi_awid     (bb_awid),
        .m_axi_awaddr   (bb_awaddr),
        .m_axi_awlen    (bb_awlen),
        .m_axi_awsize   (bb_awsize),
        .m_axi_awburst  (bb_awburst),
        .m_axi_awlock   (bb_awlock),
        .m_axi_awvalid  (bb_awvalid),
        .m_axi_awready  (bb_awready),
        .m_axi_wid      (bb_wid),
        .m_axi_wdata    (bb_wdata),
        .m_axi_wstrb    (bb_wstrb),
        .m_axi_wlast    (bb_wlast),
        .m_axi_wvalid   (bb_wvalid),
        .m_axi_wready   (bb_wready),
        .m_axi_bid      (bb_bid),
        .m_axi_bvalid   (bb_bvalid),
        .m_axi_bready   (bb_bready),

        // Double-buffer control
        .vdma_next_base (vdma_next_base),
        .vdma_active_base (vdma_active_base),
        .vdma_right_next_base (vdma_right_next_base),
        .scan_diagnostics (scan_diagnostics),
        .vdma_right_active_base (vdma_right_active_base),
        .cpu_fps_bcd (cpu_fps_bcd), .fpga_fps_bcd (fpga_fps_bcd),
        .vsync_flag     (vdma_vsync_flag),

        // Gamepad & Board Keys
        .gamepad_joy_x     (pad_joy_x),
        .gamepad_joy_y     (pad_joy_y),
        .gamepad_buttons   (pad_buttons),
        .gamepad_online    (pad_online),
        .key_sw0_level     (sw0_pressed),
        .key_sw2_level     (sw2_pressed),
        .key_sw0_pulse     (sw0_pulse),
        .key_sw2_pulse     (sw2_pulse),
        .i2c_slave_addr    (i2c_slave_addr),
        .force_hud_disable (force_hud_disable),
        .weather_ctrl       (blit_weather_ctrl),
        .weather_mask_x     (blit_weather_mask_x),
        .weather_mask_y     (blit_weather_mask_y),
        .color_matrix_ctrl  (blit_color_matrix_ctrl),
        .bloom_ctrl         (blit_bloom_ctrl)
    );

    // =========================================================================
    // Video Processing Chain:
    // u_video_dma -> u_bloom_filter -> u_color_matrix -> u_dvi_encoder
    // =========================================================================

    wire [7:0] bloom_r, bloom_g, bloom_b;
    wire       bloom_hs, bloom_vs, bloom_de;

    video_bloom_filter u_bloom_filter (
        .pixel_clk   (hdmi_tx_slow_clk),
        .pixel_rst_n (hdmi_tx_locked),
        .de_in       (video_de),
        .hsync_in    (video_hs),
        .vsync_in    (video_vs),
        .r_in        (video_r),
        .g_in        (video_g),
        .b_in        (video_b),
        .ctrl        (blit_bloom_ctrl),
        .de_out      (bloom_de),
        .hsync_out   (bloom_hs),
        .vsync_out   (bloom_vs),
        .r_out       (bloom_r),
        .g_out       (bloom_g),
        .b_out       (bloom_b)
    );

    wire [7:0] final_r, final_g, final_b;
    wire       final_hs, final_vs, final_de;

    video_color_matrix u_color_matrix (
        .pixel_clk   (hdmi_tx_slow_clk),
        .pixel_rst_n (hdmi_tx_locked),
        .de_in       (bloom_de),
        .hsync_in    (bloom_hs),
        .vsync_in    (bloom_vs),
        .r_in        (bloom_r),
        .g_in        (bloom_g),
        .b_in        (bloom_b),
        .ctrl        (blit_color_matrix_ctrl),
        .de_out      (final_de),
        .hsync_out   (final_hs),
        .vsync_out   (final_vs),
        .r_out       (final_r),
        .g_out       (final_g),
        .b_out       (final_b)
    );

    // DVI Encoder (8-bit RGB + sync -> 10-bit TMDS words)
    wire [9:0] tmds_data0, tmds_data1, tmds_data2, tmds_clk;

    dvi_encoder u_dvi_encoder (
        .pixelclk   (hdmi_tx_slow_clk),
        .rstin      (~hdmi_tx_locked),
        .blue_din   (final_b),
        .green_din  (final_g),
        .red_din    (final_r),
        .hsync      (final_hs),
        .vsync      (final_vs),
        .de         (final_de),

        .tmds_data0 (tmds_data0),
        .tmds_data1 (tmds_data1),
        .tmds_data2 (tmds_data2),
        .tmds_clk   (tmds_clk)
    );

    // Invert TMDS outputs to match board differential LVDS PCB trace polarities
    assign tmds_clk_o   = ~tmds_clk;
    assign tmds_data0_o = ~tmds_data0;
    assign tmds_data1_o = ~tmds_data1;
    assign tmds_data2_o = ~tmds_data2;

endmodule
