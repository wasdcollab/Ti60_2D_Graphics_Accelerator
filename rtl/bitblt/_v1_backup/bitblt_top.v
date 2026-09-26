`timescale 1ns/1ps

module bitblt_top (
    input  wire         clk,
    input  wire         rst_n,
    
    // APB Slave Interface (from Sapphire SoC io_apbSlave_0)
    input  wire [15:0]  apb_paddr,
    input  wire         apb_psel,
    input  wire         apb_penable,
    input  wire         apb_pwrite,
    input  wire [31:0]  apb_pwdata,
    output wire [31:0]  apb_prdata,
    output wire         apb_pready,
    output wire         apb_pslverr,
    
    // AXI4 Read Master Interface (to Axi_Mux S2)
    output wire [3:0]   m_axi_arid,
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

    // AXI4 Write Master Interface (to Axi_Mux S2)
    output wire [3:0]   m_axi_awid,
    output wire [27:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire [1:0]   m_axi_awlock,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,
    
    output wire [3:0]   m_axi_wid,
    output wire [127:0] m_axi_wdata,
    output wire [15:0]  m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    
    input  wire [3:0]   m_axi_bid,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,
    
    // Double-buffer control
    output wire [27:0]  vdma_next_base,
    input  wire [27:0]  vdma_active_base,
    output wire [27:0]  vdma_right_next_base,
    input  wire [27:0]  vdma_right_active_base,
    output wire [7:0]   cpu_fps_bcd,
    output wire [7:0]   fpga_fps_bcd,
    input  wire [31:0]  scan_diagnostics,
    input  wire         vsync_flag,

    // Gamepad & Board Keys
    input  wire [7:0]   gamepad_joy_x,
    input  wire [7:0]   gamepad_joy_y,
    input  wire [3:0]   gamepad_buttons,
    input  wire         gamepad_online,
    input  wire         key_sw0_level,
    input  wire         key_sw2_level,
    input  wire         key_sw0_pulse,
    input  wire         key_sw2_pulse,
    output wire [6:0]   i2c_slave_addr,
    output wire         force_hud_disable
);

    // Internal signals from apb_regs to stride_gen
    wire        cmd_start;
    wire [1:0]  cmd_op_type;
    wire [27:0] cmd_dst_addr;
    wire [27:0] cmd_src_addr;
    wire [10:0] cmd_rect_w;
    wire [10:0] cmd_rect_h;
    wire [31:0] cmd_color;
    wire [15:0] cmd_src_stride;
    wire [15:0] cmd_dst_stride;
    wire        busy;
    
    // Internal signals from stride_gen to read master & FIFO
    wire        rd_req;
    wire [27:0] rd_addr;
    wire [7:0]  rd_len;
    wire        rd_done;
    wire        rd_busy;
    wire        fifo_clr;
    
    // FIFO signals
    wire        fifo_winc;
    wire [127:0] fifo_wdata;
    wire        fifo_wfull;
    wire        fifo_rinc;
    wire [127:0] fifo_rdata;
    wire        fifo_rempty;
    
    // Internal signals from stride_gen to write master
    wire         data_from_fifo;
    wire         burst_req;
    wire [27:0]  burst_addr;
    wire [7:0]   burst_len;
    wire [127:0] burst_data;
    wire [15:0]  burst_wstrb_first;
    wire [15:0]  burst_wstrb_last;
    wire         burst_done;

    bitblt_apb_regs u_apb_regs (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .apb_paddr              (apb_paddr),
        .apb_psel               (apb_psel),
        .apb_penable            (apb_penable),
        .apb_pwrite             (apb_pwrite),
        .apb_pwdata             (apb_pwdata),
        .apb_prdata             (apb_prdata),
        .apb_pready             (apb_pready),
        .apb_pslverr            (apb_pslverr),
        .cmd_busy               (busy | rd_busy),
        .vsync_flag             (vsync_flag),
        .vdma_active_base       (vdma_active_base),
        .vdma_right_active_base (vdma_right_active_base),
        .vdma_right_next_base   (vdma_right_next_base),
        .cpu_fps_bcd            (cpu_fps_bcd),
        .fpga_fps_bcd           (fpga_fps_bcd),
        .scan_diagnostics       (scan_diagnostics),
        .cmd_start              (cmd_start),
        .cmd_op_type            (cmd_op_type),
        .cmd_dst_addr           (cmd_dst_addr),
        .cmd_src_addr           (cmd_src_addr),
        .cmd_rect_w             (cmd_rect_w),
        .cmd_rect_h             (cmd_rect_h),
        .cmd_color              (cmd_color),
        .cmd_src_stride         (cmd_src_stride),
        .cmd_dst_stride         (cmd_dst_stride),
        .vdma_next_base         (vdma_next_base),
        .gamepad_joy_x          (gamepad_joy_x),
        .gamepad_joy_y          (gamepad_joy_y),
        .gamepad_buttons        (gamepad_buttons),
        .gamepad_online         (gamepad_online),
        .key_sw0_level          (key_sw0_level),
        .key_sw2_level          (key_sw2_level),
        .key_sw0_pulse          (key_sw0_pulse),
        .key_sw2_pulse          (key_sw2_pulse),
        .i2c_slave_addr         (i2c_slave_addr),
        .force_hud_disable      (force_hud_disable)
    );

    bitblt_stride_gen u_stride_gen (
        .clk               (clk),
        .rst_n             (rst_n),
        .cmd_start         (cmd_start),
        .cmd_op_type       (cmd_op_type),
        .cmd_dst_addr      (cmd_dst_addr),
        .cmd_src_addr      (cmd_src_addr),
        .cmd_rect_w        (cmd_rect_w),
        .cmd_rect_h        (cmd_rect_h),
        .cmd_color         (cmd_color),
        .cmd_src_stride    (cmd_src_stride),
        .cmd_dst_stride    (cmd_dst_stride),
        .busy              (busy),
        
        // Read Master interface
        .rd_req            (rd_req),
        .rd_addr           (rd_addr),
        .rd_len            (rd_len),
        .rd_done           (rd_done),
        .fifo_clr          (fifo_clr),
        
        // Write Master interface
        .data_from_fifo    (data_from_fifo),
        .burst_req         (burst_req),
        .burst_addr        (burst_addr),
        .burst_len         (burst_len),
        .burst_data        (burst_data),
        .burst_wstrb_first (burst_wstrb_first),
        .burst_wstrb_last  (burst_wstrb_last),
        .burst_done        (burst_done)
    );

    bitblt_axi_read_master u_read_master (
        .clk               (clk),
        .rst_n             (rst_n),
        .rd_req            (rd_req),
        .rd_addr           (rd_addr),
        .rd_len            (rd_len),
        .rd_done           (rd_done),
        .rd_busy           (rd_busy),
        .m_axi_arid        (m_axi_arid),
        .m_axi_araddr      (m_axi_araddr),
        .m_axi_arlen       (m_axi_arlen),
        .m_axi_arsize      (m_axi_arsize),
        .m_axi_arburst     (m_axi_arburst),
        .m_axi_arlock      (m_axi_arlock),
        .m_axi_arvalid     (m_axi_arvalid),
        .m_axi_arready     (m_axi_arready),
        .m_axi_rid         (m_axi_rid),
        .m_axi_rdata       (m_axi_rdata),
        .m_axi_rresp       (m_axi_rresp),
        .m_axi_rlast       (m_axi_rlast),
        .m_axi_rvalid      (m_axi_rvalid),
        .m_axi_rready      (m_axi_rready),
        .fifo_winc         (fifo_winc),
        .fifo_wdata        (fifo_wdata)
    );

    bitblt_read_fifo #(
        .DATA_WIDTH(128),
        .ADDR_WIDTH(6),
        .DEPTH(64)
    ) u_read_fifo (
        .clk               (clk),
        .rst_n             (rst_n),
        .clr               (fifo_clr),
        .winc              (fifo_winc),
        .wdata             (fifo_wdata),
        .wfull             (fifo_wfull),
        .wusedw            (),
        .rinc              (fifo_rinc),
        .rdata             (fifo_rdata),
        .rempty            (fifo_rempty),
        .rusedw            ()
    );

    bitblt_axi_master u_write_master (
        .clk               (clk),
        .rst_n             (rst_n),
        .burst_req         (burst_req),
        .burst_addr        (burst_addr),
        .burst_len         (burst_len),
        .burst_data        (burst_data),
        .burst_wstrb_first (burst_wstrb_first),
        .burst_wstrb_last  (burst_wstrb_last),
        .burst_done        (burst_done),
        
        // Streaming interface from FIFO
        .data_from_fifo    (data_from_fifo),
        .fifo_rdata        (fifo_rdata),
        .fifo_rinc         (fifo_rinc),
        .colorkey_en       (1'b0),          // Pure Block Copy for Step 3
        .colorkey_val      (32'd0),
        
        // AXI Write Master
        .m_axi_awid        (m_axi_awid),
        .m_axi_awaddr      (m_axi_awaddr),
        .m_axi_awlen       (m_axi_awlen),
        .m_axi_awsize      (m_axi_awsize),
        .m_axi_awburst     (m_axi_awburst),
        .m_axi_awlock      (m_axi_awlock),
        .m_axi_awvalid     (m_axi_awvalid),
        .m_axi_awready     (m_axi_awready),
        .m_axi_wid         (m_axi_wid),
        .m_axi_wdata       (m_axi_wdata),
        .m_axi_wstrb       (m_axi_wstrb),
        .m_axi_wlast       (m_axi_wlast),
        .m_axi_wvalid      (m_axi_wvalid),
        .m_axi_wready      (m_axi_wready),
        .m_axi_bid         (m_axi_bid),
        .m_axi_bvalid      (m_axi_bvalid),
        .m_axi_bready      (m_axi_bready)
    );

endmodule
