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
    input wire system_spi_0_io_data_0_IN,
    input wire system_spi_0_io_data_1_IN,
    output wire system_spi_0_io_data_0_OUT, system_spi_0_io_data_0_OE,
    output wire system_spi_0_io_data_1_OUT, system_spi_0_io_data_1_OE,
    output wire system_spi_0_io_sclk_write, system_spi_0_io_ss,

    // MAX98357A standard-I2S output; pins are defined in ti60_top.peri.xml.
    output wire                               audio_i2s_bclk,
    output wire                               audio_i2s_lrclk,
    output wire                               audio_i2s_din,

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
    wire debug_write_pending;
    wire ddr_awvalid, ddr_awready, ddr_wvalid, ddr_wready;
    video_write_guard u_video_write_guard (
        .clk(core_clk), .rst_n(ddr_rstn), .video_priority(video_read_priority),
        .s_awvalid(m_axi_awvalid), .s_awready(m_axi_awready),
        .m_awvalid(ddr_awvalid), .m_awready(ddr_awready),
        .s_wvalid(m_axi_wvalid), .s_wready(m_axi_wready),
        .m_wvalid(ddr_wvalid), .m_wready(ddr_wready),
        .bvalid(m_axi_bvalid), .bready(m_axi_bready),.pending(debug_write_pending)
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

    // Slave 2 Direct Connection to BitBlt

    // Axi_Mux 3-to-1 Arbiter (VDMA read, Sapphire CPU, BitBlt write)
    localparam integer BUCKET_SLOTS = 1024;
    localparam integer POOL_SLOTS = 128;
    wire  cfg_bucket_start;
    wire  cfg_bucket_clear;
    wire  cfg_bucket_buffer;
    wire [14:0] cfg_bucket_eb_count;
    wire [9:0] cfg_bucket_pb_count;
    wire [31:0] cfg_bucket_player;
    wire  cfg_bucket_motion;
    wire  cfg_bucket_busy;
    wire  cfg_bucket_done;
    wire [15:0] cfg_bucket_drop;
    wire  cfg_bucket_fault;
    wire [31:0] cfg_bucket_cycles;
    wire [31:0] raw_bucket_debug,cfg_bucket_debug;
    wire [1:0] debug_r_channel;
    wire [15:0] cfg_bucket_live;
    wire [15:0] cfg_bucket_cand;
    wire [3:0] bc_arid;
    wire [28-1:0] bc_araddr;
    wire [7:0] bc_arlen;
    wire [2:0] bc_arsize;
    wire [1:0] bc_arburst;
    wire [1:0] bc_arlock;
    wire  bc_arvalid;
    wire  bc_arready;
    wire [3:0] bc_rid;
    wire [128-1:0] bc_rdata;
    wire [1:0] bc_rresp;
    wire  bc_rlast;
    wire  bc_rvalid;
    wire  bc_rready;
    wire [3:0] bc_awid;
    wire [28-1:0] bc_awaddr;
    wire [7:0] bc_awlen;
    wire [2:0] bc_awsize;
    wire [1:0] bc_awburst;
    wire [1:0] bc_awlock;
    wire  bc_awvalid;
    wire  bc_awready;
    wire [3:0] bc_wid;
    wire [128-1:0] bc_wdata;
    wire [15:0] bc_wstrb;
    wire  bc_wlast;
    wire  bc_wvalid;
    wire  bc_wready;
    wire [3:0] bc_bid;
    wire [1:0] bc_bresp;
    wire  bc_bvalid;
    wire  bc_bready;
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
        .Cfg_Cnl_Mask   (4'b1111),
        .I_S3_AW_ID(bc_awid),
        .I_S3_AW_ADDR({4'd0,bc_awaddr}),
        .I_S3_AW_LEN(bc_awlen),
        .I_S3_AW_SIZE(bc_awsize),
        .I_S3_AW_BURST(bc_awburst),
        .I_S3_AW_LOCK(bc_awlock),
        .I_S3_AW_VALID(bc_awvalid),
        .I_S3_W_ID(bc_wid),
        .I_S3_W_DATA(bc_wdata),
        .I_S3_W_STRB(bc_wstrb),
        .I_S3_W_LAST(bc_wlast),
        .I_S3_W_VALID(bc_wvalid),
        .I_S3_B_READY(bc_bready),
        .I_S3_AR_ID(bc_arid),
        .I_S3_AR_ADDR({4'd0,bc_araddr}),
        .I_S3_AR_LEN(bc_arlen),
        .I_S3_AR_SIZE(bc_arsize),
        .I_S3_AR_BURST(bc_arburst),
        .I_S3_AR_LOCK(bc_arlock),
        .I_S3_AR_VALID(bc_arvalid),
        .I_S3_R_READY(bc_rready),
        .O_S3_AW_READY(bc_awready),
        .O_S3_W_READY(bc_wready),
        .O_S3_B_ID(bc_bid),
        .O_S3_B_VALID(bc_bvalid),
        .O_S3_AR_READY(bc_arready),
        .O_S3_R_ID(bc_rid),
        .O_S3_R_DATA(bc_rdata),
        .O_S3_R_LAST(bc_rlast),
        .O_S3_R_RESP(bc_rresp),
        .O_S3_R_VALID(bc_rvalid),
        .O_AW_Cnl_Num   (),
        .O_W_Cnl_Num    (),
        .O_B_Cnl_Num    (),
        .O_AR_Cnl_Num   (),
        .O_R_Cnl_Num    (debug_r_channel)
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
        .s_axi_bresp        (bc_bresp),
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
    wire [7:0] final_r, final_g, final_b;
    wire       final_hs, final_vs, final_de;

    // 2-stage synchronizer: cross final_vs from hdmi_tx_slow_clk (85.71 MHz) to core_clk (100 MHz)
    reg vsync_sync1, vsync_sync2;
    always @(posedge core_clk or negedge ddr_rstn) begin
        if (!ddr_rstn) begin
            vsync_sync1 <= 1'b0;
            vsync_sync2 <= 1'b0;
        end else begin
            vsync_sync1 <= final_vs;
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

        .io_ddrA_b_payload_resp             (bc_bresp),
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

    // =========================================================================
    // Triad Architecture (三权分立架构)
    // 1. Central Military Command (rtl/apb/apb_command_dispatcher.v)
    // 2. Pure 2D Graphics Engine (rtl/bitblt/bitblt_top.v)
    // 3. Pure Data Water Supply Plant (rtl/dma/dma_top.v)
    // 4. Pure Streaming Art Workshop (rtl/display_engine/display_engine_top.v)
    // =========================================================================

    // -------------------------------------------------------------------------
    // Interconnect: APB Dispatcher -> BitBlt (Pure 2D Command Bus)
    // -------------------------------------------------------------------------
    wire        disp_cmd_start;
    wire [1:0]  disp_cmd_op_type;
    wire [27:0] disp_cmd_dst_addr;
    wire [27:0] disp_cmd_src_addr;
    wire [10:0] disp_cmd_rect_w;
    wire [10:0] disp_cmd_rect_h;
    wire [31:0] disp_cmd_color;
    wire [15:0] disp_cmd_src_stride;
    wire [15:0] disp_cmd_dst_stride;
    wire        disp_cmd_colorkey_en;
    wire [31:0] disp_cmd_colorkey_val;
    wire        disp_cmd_alpha_en;
    wire [7:0]  disp_cmd_global_alpha;
    wire        disp_cmd_busy;
    wire        disp_engine_timeout;
    wire [3:0]  disp_probe_q_cnt;
    wire        disp_probe_ar_pend;
    wire [1:0]  disp_probe_sg_state;

    // -------------------------------------------------------------------------
    // Interconnect: APB Dispatcher -> Display Engine & DMA (Display Config Bus)
    // -------------------------------------------------------------------------
    wire [27:0] vdma_next_base;
    wire [27:0] vdma_active_base;
    wire [27:0] vdma_right_next_base;
    wire [27:0] vdma_right_active_base;
    wire [7:0]  cpu_fps_bcd;
    wire [7:0]  fpga_fps_bcd;
    wire [31:0] scan_diagnostics;
    wire        vdma_vsync_flag;

    wire [31:0] cfg_weather_ctrl;
    wire [31:0] cfg_weather_mask_x;
    wire [31:0] cfg_weather_mask_y;
    wire [47:0] cfg_laser_colx;
    wire [11:0] cfg_beam_x;
    wire [11:0] cfg_beam_len;
    wire        cfg_beam_en;
    wire [35:0] cfg_hair_x;
    wire [71:0] cfg_hair_out;
    wire [71:0] cfg_hair_lft;
    wire [71:0] cfg_hair_mid;

    wire [127:0] cfg_fx_a, cfg_fx_b, cfg_fx_c;

    wire [27:0] cfg_bucket_base;
    wire [14:0] cfg_btile_addr;
    wire [7:0]  cfg_btile_data;
    wire        cfg_btile_we;
    wire [31:0] cfg_bpal_data;
    wire [7:0]  cfg_bpal_addr;
    wire        cfg_bpal_we;

    wire [31:0] cfg_color_matrix_ctrl;
    wire [31:0] cfg_bloom_ctrl;
    wire [31:0] cfg_audio_ctrl;
    wire        cfg_audio_event_strobe;
    wire        pcm_enabled, pcm_clear, pcm_write;
    wire [7:0]  pcm_data;
    wire [31:0] pcm_status, pcm_underflows, pcm_played;
    wire signed [15:0] pcm_sample;
    wire flash_start, flash_busy;
    wire [7:0] flash_tx, flash_rx;
    assign system_spi_0_io_data_0_OE = 1'b1;
    assign system_spi_0_io_data_1_OE = 1'b0;
    assign system_spi_0_io_data_1_OUT = 1'b0;
    bgm_flash_spi u_bgm_flash_spi (
        .clk(core_clk), .rst_n(ddr_rstn), .start(flash_start),
        .cs_n(system_spi_0_io_ss), .tx_data(flash_tx),
        .miso(system_spi_0_io_data_1_IN), .sclk(system_spi_0_io_sclk_write),
        .mosi(system_spi_0_io_data_0_OUT), .busy(flash_busy), .rx_data(flash_rx)
    );

    // -------------------------------------------------------------------------
    // Interconnect: Display Engine <-> DMA (Streaming & Timing Bus)
    // -------------------------------------------------------------------------
    wire [11:0]       disp_h_cnt;
    wire [10:0]       disp_v_cnt;
    wire              disp_t_de;
    wire              disp_t_frame_start;
    wire              disp_t_frame_clear;
    wire [31:0]       vdma_fb_pixel;
    wire [32*POOL_SLOTS-1:0] vdma_bucket_row;
    wire [$clog2(BUCKET_SLOTS)-1:0] vdma_entry_addr;
    wire vdma_entry_group;
    wire [31:0] vdma_entry_data;
    wire [11:0] vdma_pool_drop;
    wire              vdma_bucket_ready;

    // APB Bus wires (SoC APB Slave 0 <-> Dispatcher)
    wire [15:0] apb0_paddr;
    wire        apb0_psel;
    wire        apb0_penable;
    wire        apb0_pwrite;
    wire [31:0] apb0_pwdata;
    wire [31:0] apb0_prdata;
    wire        apb0_pready;
    wire        apb0_pslverr;

    // =========================================================================
    // 1. Central Command Dispatcher (rtl/apb/)
    // =========================================================================
    apb_command_dispatcher #(
        .CLOCK_HZ (100_000_000)
    ) u_apb_command_dispatcher (
        .clk                    (core_clk),
        .rst_n                  (ddr_rstn),
        .cal_done               (cal_done),

        // APB3 Slave Interface
        .apb_paddr              (apb0_paddr),
        .apb_psel               (apb0_psel),
        .apb_penable            (apb0_penable),
        .apb_pwrite             (apb0_pwrite),
        .apb_pwdata             (apb0_pwdata),
        .apb_prdata             (apb0_prdata),
        .apb_pready             (apb0_pready),
        .apb_pslverr            (apb0_pslverr),

        // Pure 2D BitBlt Command Bus
        .cmd_start              (disp_cmd_start),
        .cmd_op_type            (disp_cmd_op_type),
        .cmd_dst_addr           (disp_cmd_dst_addr),
        .cmd_src_addr           (disp_cmd_src_addr),
        .cmd_rect_w             (disp_cmd_rect_w),
        .cmd_rect_h             (disp_cmd_rect_h),
        .cmd_color              (disp_cmd_color),
        .cmd_src_stride         (disp_cmd_src_stride),
        .cmd_dst_stride         (disp_cmd_dst_stride),
        .cmd_colorkey_en        (disp_cmd_colorkey_en),
        .cmd_colorkey_val       (disp_cmd_colorkey_val),
        .cmd_alpha_en           (disp_cmd_alpha_en),
        .cmd_global_alpha       (disp_cmd_global_alpha),
        .cmd_busy               (disp_cmd_busy),
        .engine_timeout         (disp_engine_timeout),

        // BitBlt Engine Live Probe
        .diag_rd_q_cnt          (disp_probe_q_cnt),
        .diag_rd_ar_pend        (disp_probe_ar_pend),
        .diag_sg_state          (disp_probe_sg_state),

        // Double-Buffer Control & Frame Telemetry
        .vdma_next_base         (vdma_next_base),
        .vdma_right_next_base   (vdma_right_next_base),
        .vdma_active_base       (vdma_active_base),
        .vdma_right_active_base (vdma_right_active_base),
        .cpu_fps_bcd            (cpu_fps_bcd),
        .fpga_fps_bcd           (fpga_fps_bcd),
        .scan_diagnostics       (scan_diagnostics),
        .vsync_flag             (vdma_vsync_flag),

        // Gamepad & Board Keys Interface
        .gamepad_joy_x          (pad_joy_x),
        .gamepad_joy_y          (pad_joy_y),
        .gamepad_buttons        (pad_buttons),
        .gamepad_online         (pad_online),
        .key_sw0_level          (sw0_pressed),
        .key_sw2_level          (sw2_pressed),
        .key_sw0_pulse          (sw0_pulse),
        .key_sw2_pulse          (sw2_pulse),
        .i2c_slave_addr         (i2c_slave_addr),
        .force_hud_disable      (force_hud_disable),

        // Pure Display / Effect Configuration Bus
        .weather_ctrl           (cfg_weather_ctrl),
        .weather_mask_x         (cfg_weather_mask_x),
        .weather_mask_y         (cfg_weather_mask_y),
        .laser_colx_lo          (),
        .laser_colx_hi          (),
        .laser_colx             (cfg_laser_colx),
        .beam_x                 (cfg_beam_x),
        .beam_len               (cfg_beam_len),
        .beam_en                (cfg_beam_en),
        .hair_x                 (cfg_hair_x),
        .hair_out               (cfg_hair_out),
        .hair_lft               (cfg_hair_lft),
        .hair_mid               (cfg_hair_mid),
        .fx_a                   (cfg_fx_a),
        .fx_b                   (cfg_fx_b),
        .fx_c                   (cfg_fx_c),

        // Bullet Bucket Table & Tile Store Write Port
        .bucket_base            (cfg_bucket_base),
        .btile_addr             (cfg_btile_addr),
        .btile_data             (cfg_btile_data),
        .btile_we               (cfg_btile_we),
        .bpal_data              (cfg_bpal_data),
        .bpal_addr              (cfg_bpal_addr),
        .bpal_we                (cfg_bpal_we),

        // Video Post-Processing Controls
        .color_matrix_ctrl      (cfg_color_matrix_ctrl),
        .bloom_ctrl             (cfg_bloom_ctrl),

        // Game-audio control and one-shot events
        .audio_ctrl             (cfg_audio_ctrl),
        .audio_event_strobe     (cfg_audio_event_strobe),
        .pcm_enabled(pcm_enabled), .pcm_clear(pcm_clear),
        .pcm_write(pcm_write), .pcm_data(pcm_data),
        .pcm_status(pcm_status), .pcm_underflows(pcm_underflows),
        .pcm_played(pcm_played),
        .flash_start(flash_start), .flash_cs_n(system_spi_0_io_ss),
        .flash_tx(flash_tx), .flash_busy(flash_busy), .flash_rx(flash_rx),
        .bucket_start(cfg_bucket_start),.bucket_clear_req(cfg_bucket_clear),
        .bucket_motion_en(cfg_bucket_motion),.bucket_buffer_sel(cfg_bucket_buffer),
        .bucket_pb_count(cfg_bucket_pb_count),.bucket_eb_count(cfg_bucket_eb_count),
        .bucket_player_xy(cfg_bucket_player),.bucket_busy(cfg_bucket_busy),
        .bucket_done(cfg_bucket_done),.bucket_fault(cfg_bucket_fault),
        .bucket_drop_count(cfg_bucket_drop),.bucket_pool_drop(vdma_pool_drop),
        .bucket_cycles(cfg_bucket_cycles),.bucket_eb_live(cfg_bucket_live),
        .bucket_debug(cfg_bucket_debug),
        .bucket_eb_cand(cfg_bucket_cand),.hb_we(),.hb_val()
    );

    dma_bucket_coprocessor #(.EB_CAPACITY(20480),.BURST_READ_LEN(16),
        .SINGLE_GROUP_REG(0),.TABLE_SLOTS(BUCKET_SLOTS)) u_bucket_coprocessor (
        .clk(core_clk),
        .rst_n(ddr_rstn),
        .start(cfg_bucket_start),
        .clear_ledger(cfg_bucket_clear),
        .buffer_sel(cfg_bucket_buffer),
        .eb_count(cfg_bucket_eb_count),
        .pb_count(cfg_bucket_pb_count),
        .player_xy(cfg_bucket_player),
        .motion_en(cfg_bucket_motion),
        .bound_x(32'h03DC00B6),
        .bound_y(32'h02FF0001),
        .busy(cfg_bucket_busy),
        .done(cfg_bucket_done),
        .drop_count(cfg_bucket_drop),
        .fault(cfg_bucket_fault),
        .cycles(cfg_bucket_cycles),
        .debug_snapshot(raw_bucket_debug),
        .eb_live(cfg_bucket_live),
        .eb_kill(),
        .eb_free(),
        .eb_cand(cfg_bucket_cand),
        .m_axi_arid(bc_arid),
        .m_axi_araddr(bc_araddr),
        .m_axi_arlen(bc_arlen),
        .m_axi_arsize(bc_arsize),
        .m_axi_arburst(bc_arburst),
        .m_axi_arlock(bc_arlock),
        .m_axi_arvalid(bc_arvalid),
        .m_axi_arready(bc_arready),
        .m_axi_rid(bc_rid),
        .m_axi_rdata(bc_rdata),
        .m_axi_rresp(bc_rresp),
        .m_axi_rlast(bc_rlast),
        .m_axi_rvalid(bc_rvalid),
        .m_axi_rready(bc_rready),
        .m_axi_awid(bc_awid),
        .m_axi_awaddr(bc_awaddr),
        .m_axi_awlen(bc_awlen),
        .m_axi_awsize(bc_awsize),
        .m_axi_awburst(bc_awburst),
        .m_axi_awlock(bc_awlock),
        .m_axi_awvalid(bc_awvalid),
        .m_axi_awready(bc_awready),
        .m_axi_wid(bc_wid),
        .m_axi_wdata(bc_wdata),
        .m_axi_wstrb(bc_wstrb),
        .m_axi_wlast(bc_wlast),
        .m_axi_wvalid(bc_wvalid),
        .m_axi_wready(bc_wready),
        .m_axi_bid(bc_bid),
        .m_axi_bresp(bc_bresp),
        .m_axi_bvalid(bc_bvalid),
        .m_axi_bready(bc_bready)
    );
    // 100 MHz core-domain audio, independent of DDR/BitBlt/video bandwidth.
    wire        audio_sample_tick;
    wire signed [15:0] audio_left, audio_right;
    bgm_pcm_fifo u_bgm_pcm_fifo (
        .clk(core_clk), .rst_n(ddr_rstn), .sample_tick(audio_sample_tick),
        .enabled(pcm_enabled), .clear(pcm_clear),
        .write_strobe(pcm_write), .write_data(pcm_data),
        .sample(pcm_sample), .status(pcm_status),
        .underflows(pcm_underflows), .played(pcm_played)
    );
    game_audio_synth #(.PCM_BGM(2)) u_game_audio_synth (
        .clk          (core_clk),
        .rst_n        (ddr_rstn),
        .sample_tick  (audio_sample_tick),
        .enabled      (cfg_audio_ctrl[8]),
        .bgm_enabled  (cfg_audio_ctrl[9]),
        .volume       (cfg_audio_ctrl[14:12]),
        .event_strobe (cfg_audio_event_strobe),
        .event_code   (cfg_audio_ctrl[3:0]),
        .stream_sample(pcm_sample),
        .sample_left  (audio_left),
        .sample_right (audio_right)
    );
    i2s_tx #(.BCLK_HALF_DIV(16)) u_i2s_tx (
        .clk          (core_clk),
        .rst_n        (ddr_rstn),
        .sample_left  (audio_left),
        .sample_right (audio_right),
        .sample_tick  (audio_sample_tick),
        .i2s_bclk     (audio_i2s_bclk),
        .i2s_lrclk    (audio_i2s_lrclk),
        .i2s_din      (audio_i2s_din)
    );

    // =========================================================================
    // 2. Pure 2D Graphics Engine (rtl/bitblt/)
    // =========================================================================
    bitblt_top #(
        .MAX_BURST_BEATS (192),
        .READ_FIFO_DEPTH (448),
        .READ_FIFO_AW    (9),
        .DST_FIFO_DEPTH  (448),
        .DST_FIFO_AW     (9)
    ) u_bitblt (
        .clk                    (core_clk),
        .rst_n                  (ddr_rstn),

        // Pure 2D Command Bus (Driven by u_apb_command_dispatcher)
        .cmd_start              (disp_cmd_start),
        .cmd_op_type            (disp_cmd_op_type),
        .cmd_dst_addr           (disp_cmd_dst_addr),
        .cmd_src_addr           (disp_cmd_src_addr),
        .cmd_rect_w             (disp_cmd_rect_w),
        .cmd_rect_h             (disp_cmd_rect_h),
        .cmd_color              (disp_cmd_color),
        .cmd_src_stride         (disp_cmd_src_stride),
        .cmd_dst_stride         (disp_cmd_dst_stride),
        .cmd_colorkey_en        (disp_cmd_colorkey_en),
        .cmd_colorkey_val       (disp_cmd_colorkey_val),
        .cmd_alpha_en           (disp_cmd_alpha_en),
        .cmd_global_alpha       (disp_cmd_global_alpha),
        .cmd_busy               (disp_cmd_busy),
        .engine_timeout         (disp_engine_timeout),

        // Live Engine Diagnostic Probe
        .probe_q_cnt            (disp_probe_q_cnt),
        .probe_ar_pend          (disp_probe_ar_pend),
        .probe_sg_state         (disp_probe_sg_state),

        // AXI4 Read Master (to Axi_Mux S2)
        .m_axi_arid             (bb_arid),
        .m_axi_araddr           (bb_araddr),
        .m_axi_arlen            (bb_arlen),
        .m_axi_arsize           (bb_arsize),
        .m_axi_arburst          (bb_arburst),
        .m_axi_arlock           (bb_arlock),
        .m_axi_arvalid          (bb_arvalid),
        .m_axi_arready          (bb_arready),
        .m_axi_rid              (bb_rid),
        .m_axi_rdata            (bb_rdata),
        .m_axi_rresp            (bb_rresp),
        .m_axi_rlast            (bb_rlast),
        .m_axi_rvalid           (bb_rvalid),
        .m_axi_rready           (bb_rready),

        // AXI4 Write Master (to Axi_Mux S2)
        .m_axi_awid             (bb_awid),
        .m_axi_awaddr           (bb_awaddr),
        .m_axi_awlen            (bb_awlen),
        .m_axi_awsize           (bb_awsize),
        .m_axi_awburst          (bb_awburst),
        .m_axi_awlock           (bb_awlock),
        .m_axi_awvalid          (bb_awvalid),
        .m_axi_awready          (bb_awready),
        .m_axi_wid              (bb_wid),
        .m_axi_wdata            (bb_wdata),
        .m_axi_wstrb            (bb_wstrb),
        .m_axi_wlast            (bb_wlast),
        .m_axi_wvalid           (bb_wvalid),
        .m_axi_wready           (bb_wready),
        .m_axi_bid              (bb_bid),
        .m_axi_bvalid           (bb_bvalid),
        .m_axi_bready           (bb_bready)
    );

    // =========================================================================
    // 3. Pure Data Extraction Engine (rtl/dma/)
    // =========================================================================
    dma_top #(
        .FRAME_BASE_ADDR        (28'h0080_0000),
        .H_ACT                  (1366),
        .H_TOTAL                (1456),
        .V_ACT                  (768),
        .V_TOTAL                (782),
        .AXI_ADDR_WIDTH         (28),
        .AXI_DATA_WIDTH         (128),
        .BUCKET_SLOTS           (BUCKET_SLOTS),
        .POOL_SLOTS             (POOL_SLOTS),
        .SCANLINE_EN            (1),
        // Scanlines per bucket entry.  Must match MM_BUCKET_GROUP_ROWS in
        // sw/driver/memory_map.h and BUCKET_GROUP_ROWS in
        // rtl/display_engine/2_layer_generators/video_bullet_overlay.v.
        .BUCKET_GROUP_ROWS      (8),
        .BUCKET_GROUP_SHIFT     (3)
    ) u_dma (
        .axi_clk                (core_clk),
        .axi_rst_n              (ddr_rstn),
        .cal_done               (cal_done),

        // AXI4 Read Master Interface (to Axi_Mux S0)
        .m_axi_arid             (vdma_arid),
        .m_axi_araddr           (vdma_araddr),
        .m_axi_arlen            (vdma_arlen),
        .m_axi_arsize           (vdma_arsize),
        .m_axi_arburst          (vdma_arburst),
        .m_axi_arlock           (vdma_arlock),
        .m_axi_arvalid          (vdma_arvalid),
        .m_axi_arready          (vdma_arready),
        .m_axi_rid              (vdma_rid),
        .m_axi_rdata            (vdma_rdata),
        .m_axi_rresp            (vdma_rresp),
        .m_axi_rlast            (vdma_rlast),
        .m_axi_rvalid           (vdma_rvalid),
        .m_axi_rready           (vdma_rready),

        // Pixel Clock Domain
        .pixel_clk              (hdmi_tx_slow_clk),
        .pixel_rst_n            (hdmi_tx_locked),

        // Timing inputs from u_display_engine
        .h_cnt                  (disp_h_cnt),
        .v_cnt                  (disp_v_cnt),
        .t_de                   (disp_t_de),
        .t_frame_start          (disp_t_frame_start),
        .t_frame_clear          (disp_t_frame_clear),

        // Double-buffer control
        .next_frame_base_addr   (vdma_next_base),
        .active_frame_base_addr (vdma_active_base),
        .next_right_base_addr   (vdma_right_next_base),
        .active_right_base_addr (vdma_right_active_base),
        .vsync_flag             (vdma_vsync_flag),
        .video_read_priority    (video_read_priority),
        .scan_diagnostics       (scan_diagnostics),

        // Bullet bucket prefetch
        .bucket_base            (cfg_bucket_base),
        .bucket_row             (vdma_bucket_row),
        .bucket_ready           (vdma_bucket_ready),
        .bucket_pool_drop       (vdma_pool_drop),
        .bucket_entry_addr      (vdma_entry_addr),
        .bucket_entry_group     (vdma_entry_group),
        .bucket_entry_data      (vdma_entry_data),

        // Pure baseboard pixel stream
        .fb_pixel               (vdma_fb_pixel)
    );

    // =========================================================================
    // 4. Pure Streaming Display Engine (rtl/display_engine/)
    // =========================================================================
    display_engine_top #(
        .H_ACT                  (1366),
        .H_FP                   (8),
        .H_SYNC                 (56),
        .H_BP                   (26),
        .H_TOTAL                (1456),
        .V_ACT                  (768),
        .V_FP                   (2),
        .V_SYNC                 (3),
        .V_BP                   (9),
        .V_TOTAL                (782),
        .POOL_SLOTS             (POOL_SLOTS),
        .BUCKET_SLOTS           (BUCKET_SLOTS),
        .SCANLINE_EN            (1)
    ) u_display_engine (
        .pixel_clk              (hdmi_tx_slow_clk),
        .pixel_rst_n            (hdmi_tx_locked),

        // Timing Reference Outputs
        .h_cnt                  (disp_h_cnt),
        .v_cnt                  (disp_v_cnt),
        .t_de                   (disp_t_de),
        .t_frame_start          (disp_t_frame_start),
        .t_frame_clear          (disp_t_frame_clear),

        // Baseboard pixel input
        .fb_pixel               (vdma_fb_pixel),

        // Bullet bucket prefetch data
        .bucket_row             (vdma_bucket_row),
        .bucket_ready           (vdma_bucket_ready),
        .bucket_entry_addr      (vdma_entry_addr),
        .bucket_entry_group     (vdma_entry_group),
        .bucket_entry_data      (vdma_entry_data),

        // Boot-time Tile Store & Palette Write Port (from APB Dispatcher)
        .cfg_clk                (core_clk),
        .cfg_rst_n              (ddr_rstn),
        .btile_we               (cfg_btile_we),
        .btile_addr             (cfg_btile_addr),
        .btile_data             (cfg_btile_data),
        .bpal_we                (cfg_bpal_we),
        .bpal_addr              (cfg_bpal_addr),
        .bpal_data              (cfg_bpal_data),

        // Control Inputs (from APB Dispatcher)
        .weather_ctrl           (cfg_weather_ctrl),
        .weather_mask_x         (cfg_weather_mask_x),
        .weather_mask_y         (cfg_weather_mask_y),
        .laser_colx             (cfg_laser_colx),
        .beam_x                 (cfg_beam_x),
        .beam_len               (cfg_beam_len),
        .beam_en                (cfg_beam_en),
        .hair_x                 (cfg_hair_x),
        .hair_out               (cfg_hair_out),
        .hair_lft               (cfg_hair_lft),
        .hair_mid               (cfg_hair_mid),
        .fx_a                   (cfg_fx_a),
        .fx_b                   (cfg_fx_b),
        .fx_c                   (cfg_fx_c),

        // HUD & FPS Telemetry
        .hud_enable             (~force_hud_disable),
        .cpu_fps_bcd            (cpu_fps_bcd),
        .fpga_fps_bcd           (fpga_fps_bcd),

        // Post-Processing Filter Controls
        .bloom_ctrl             (cfg_bloom_ctrl),
        .color_matrix_ctrl      (cfg_color_matrix_ctrl),

        // Final Video Output Stream
        .video_r                (final_r),
        .video_g                (final_g),
        .video_b                (final_b),
        .video_hs               (final_hs),
        .video_vs               (final_vs),
        .video_de               (final_de)
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

    reg [9:0] fault_bus_context;
    reg fault_context_valid;
    assign cfg_bucket_debug={raw_bucket_debug[31:10],fault_bus_context};
    always @(posedge core_clk or negedge ddr_rstn) begin
        if(!ddr_rstn) begin fault_bus_context<=0;fault_context_valid<=0;end
        else if(cfg_bucket_clear) begin fault_bus_context<=0;fault_context_valid<=0;end
        else if(!fault_context_valid && raw_bucket_debug[31:29]!=0) begin
            fault_bus_context<={debug_r_channel,disp_probe_q_cnt[2:0],bb_rready,
                m_axi_rready,debug_write_pending,video_read_priority,m_axi_rvalid};
            fault_context_valid<=1;
        end
    end

endmodule
