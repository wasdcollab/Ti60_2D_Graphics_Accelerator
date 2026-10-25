`timescale 1ns/1ps
// =============================================================================
// bitblt_top.v
// -----------------------------------------------------------------------------
// Pure 2D Graphics Acceleration Engine (Rasterizer / 2D GPU)
// Part of the Triad Architecture refactoring (rtl/bitblt/)
//
// Responsibilities:
// - Protocol Decoupled: Zero APB/MMIO bus awareness, pure 2D command bus.
// - Performs OP_FILL, OP_COPY, OP_ALPHA, and OP_ADD rasterization.
// - Manages AXI4 read and write master channels for DDR3 access.
// - Hardware alpha blending, colorkey masking, and byte alignment shifting.
// - Diagnostic probes for engine status observability.
// =============================================================================

module bitblt_top #(
    parameter integer MAX_BURST_BEATS = 64,
    parameter integer READ_FIFO_DEPTH = 192,
    parameter integer READ_FIFO_AW    = 8,
    parameter integer DST_FIFO_DEPTH  = 192,
    parameter integer DST_FIFO_AW     = 8,
    parameter integer PREFETCH_BEATS  = 2
)(
    input  wire         clk,
    input  wire         rst_n,

    // =========================================================================
    // Pure 2D Command Bus (Driven by rtl/apb/apb_command_dispatcher)
    // =========================================================================
    input  wire         cmd_start,
    input  wire [1:0]   cmd_op_type,        // 0: OP_FILL, 1: OP_COPY, 2: OP_ALPHA, 3: OP_ADD
    input  wire [27:0]  cmd_dst_addr,
    input  wire [27:0]  cmd_src_addr,
    input  wire [10:0]  cmd_rect_w,
    input  wire [10:0]  cmd_rect_h,
    input  wire [31:0]  cmd_color,
    input  wire [15:0]  cmd_src_stride,
    input  wire [15:0]  cmd_dst_stride,
    input  wire         cmd_colorkey_en,
    input  wire [31:0]  cmd_colorkey_val,
    input  wire         cmd_alpha_en,
    input  wire [7:0]   cmd_global_alpha,
    output wire         cmd_busy,
    output wire         engine_timeout,

    // =========================================================================
    // Live Engine Diagnostic Probe
    // =========================================================================
    output wire [3:0]   probe_q_cnt,
    output wire         probe_ar_pend,
    output wire [1:0]   probe_sg_state,

    // =========================================================================
    // AXI4 Read Master Interface (to Axi_Mux S2)
    // =========================================================================
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

    // =========================================================================
    // AXI4 Write Master Interface (to Axi_Mux S2)
    // =========================================================================
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
    output wire         m_axi_bready
);

    // Diagnostic probes from submodules
    wire [2:0] tap_q_cnt;
    wire       tap_ar_pend;
    wire [1:0] tap_sg_state;

    assign probe_q_cnt    = {1'b0, tap_q_cnt};
    assign probe_ar_pend  = tap_ar_pend;
    assign probe_sg_state = tap_sg_state;

    // How many read bursts may be outstanding at once.
    localparam integer RD_MAX_OUT = 4;

    // stride_gen -> read master
    wire        rd_req;
    wire        rd_is_dst;
    wire [27:0] rd_addr;
    wire [7:0]  rd_len;
    wire        rd_done;
    wire        rd_done_is_dst;
    wire [8:0]  rd_done_len;
    wire        rd_accept;
    wire        rd_busy;
    wire        fifo_clr;

    // read master -> FIFOs
    wire        fifo_winc;
    wire        dst_fifo_winc;
    wire [127:0] fifo_wdata;

    // source FIFO -> shifter / blend
    wire        fifo_rinc;
    wire [127:0] fifo_rdata;
    wire        fifo_rempty;
    wire        fifo_wfull;
    wire [READ_FIFO_AW:0] fifo_used;

    // destination FIFO -> blend
    wire        dst_fifo_rinc;
    wire [127:0] dst_fifo_rdata;
    wire        dst_fifo_wfull;
    wire        dst_fifo_rempty;
    wire [DST_FIFO_AW:0] dst_fifo_used;

    // shifter / blend -> write master
    wire [127:0] align_data;
    wire         beat_valid;
    wire         wr_beat_ack;

    wire [127:0] blend_data;
    wire [15:0]  blend_mask;
    wire         blend_valid;
    wire         blend_src_ack;
    wire         blend_dst_ack;

    wire         alpha_op       = (cmd_op_type == 2'd2);
    wire         add_op         = (cmd_op_type == 2'd3);
    wire         blend_op       = alpha_op | add_op;
    wire [127:0] stream_data    = blend_op ? blend_data  : align_data;
    wire         stream_valid   = blend_op ? blend_valid : beat_valid;
    wire [15:0]  stream_mask    = blend_mask;
    wire         stream_mask_en = blend_op;
    wire         shifter_ack    = blend_op ? blend_src_ack : wr_beat_ack;

    // stride_gen -> write master
    wire         data_from_fifo;
    wire         burst_req;
    wire [27:0]  burst_addr;
    wire [7:0]   burst_len;
    wire [127:0] burst_data;
    wire [15:0]  burst_wstrb_first;
    wire [15:0]  burst_wstrb_last;
    wire         burst_done;

    // stride_gen -> shifter
    wire [4:0]   align_shift;
    wire [9:0]   rows_done;

    wire         busy;
    wire         err_timeout;
    wire         engine_abort, write_busy;
    wire         buffer_clear = fifo_clr || engine_abort;
    // The stride generator retires a burst at WLAST so the next burst can
    // start without waiting for DDR.  A framebuffer must not be published
    // until every accepted write has received its AXI B response, though.
    reg [15:0] writes_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            writes_pending <= 16'd0;
        else begin
            case ({m_axi_awvalid && m_axi_awready,
                   m_axi_bvalid && m_axi_bready})
                2'b10: writes_pending <= writes_pending + 16'd1;
                2'b01: writes_pending <= writes_pending - 16'd1;
                default: ;
            endcase
        end
    end
    assign cmd_busy       = busy || write_busy || (writes_pending != 16'd0) || (engine_abort && rd_busy);
    assign engine_timeout = err_timeout;

    wire         wr_data_valid = data_from_fifo ? stream_valid : 1'b1;

    bitblt_stride_gen #(
        .MAX_BURST_BEATS (MAX_BURST_BEATS),
        .FIFO_DEPTH      (READ_FIFO_DEPTH),
        .DST_FIFO_DEPTH  (DST_FIFO_DEPTH),
        .RD_MAX_OUT      (RD_MAX_OUT)
    ) u_stride_gen (
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
        .cmd_done          (),
        .engine_abort      (engine_abort),
        .rd_req            (rd_req),
        .rd_is_dst         (rd_is_dst),
        .rd_addr           (rd_addr),
        .rd_len            (rd_len),
        .rd_done           (rd_done),
        .rd_done_is_dst    (rd_done_is_dst),
        .rd_done_len       (rd_done_len),
        .rd_accept         (rd_accept),
        .fifo_clr          (fifo_clr),
        .data_from_fifo    (data_from_fifo),
        .burst_req         (burst_req),
        .burst_addr        (burst_addr),
        .burst_len         (burst_len),
        .burst_data        (burst_data),
        .burst_wstrb_first (burst_wstrb_first),
        .burst_wstrb_last  (burst_wstrb_last),
        .burst_done        (burst_done),
        .align_shift       (align_shift),
        .rows_done         (rows_done),
        .beat_valid        (stream_valid),
        .err_timeout       (err_timeout),
        .probe_state       (tap_sg_state)
    );

    bitblt_axi_read_master #(
        .MAX_OUTSTANDING (RD_MAX_OUT)
    ) u_read_master (
        .clk               (clk),
        .rst_n             (rst_n),
        .rd_req            (rd_req),
        .rd_is_dst         (rd_is_dst),
        .rd_addr           (rd_addr),
        .rd_len            (rd_len),
        .rd_done           (rd_done),
        .rd_done_is_dst    (rd_done_is_dst),
        .rd_done_len       (rd_done_len),
        .rd_accept         (rd_accept),
        .rd_busy           (rd_busy),
        .fifo_full_src     (fifo_wfull),
        .fifo_full_dst     (dst_fifo_wfull),
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
        .fifo_winc_src     (fifo_winc),
        .fifo_winc_dst     (dst_fifo_winc),
        .fifo_wdata        (fifo_wdata),
        .probe_q_cnt       (tap_q_cnt),
        .probe_ar_pend     (tap_ar_pend)
    );

    bitblt_read_fifo #(
        .DATA_WIDTH (128),
        .ADDR_WIDTH (READ_FIFO_AW),
        .DEPTH      (READ_FIFO_DEPTH)
    ) u_read_fifo (
        .clk               (clk),
        .rst_n             (rst_n),
        .clr               (buffer_clear),
        .winc              (fifo_winc),
        .wdata             (fifo_wdata),
        .wfull             (fifo_wfull),
        .wusedw            (),
        .rinc              (fifo_rinc),
        .rdata             (fifo_rdata),
        .rempty            (fifo_rempty),
        .rusedw            (),
        .used              (fifo_used)
    );

    bitblt_read_fifo #(
        .DATA_WIDTH (128),
        .ADDR_WIDTH (DST_FIFO_AW),
        .DEPTH      (DST_FIFO_DEPTH)
    ) u_dst_read_fifo (
        .clk               (clk),
        .rst_n             (rst_n),
        .clr               (buffer_clear),
        .winc              (dst_fifo_winc),
        .wdata             (fifo_wdata),
        .wfull             (dst_fifo_wfull),
        .wusedw            (),
        .rinc              (dst_fifo_rinc),
        .rdata             (dst_fifo_rdata),
        .rempty            (dst_fifo_rempty),
        .rusedw            (),
        .used              (dst_fifo_used)
    );

    bitblt_align_shifter #(
        .DATA_BYTES     (16),
        .PREFETCH_BEATS (PREFETCH_BEATS)
    ) u_align_shifter (
        .clk               (clk),
        .rst_n             (rst_n),
        .clr               (buffer_clear),
        .shift_bytes       (align_shift),
        .fifo_rdata        (fifo_rdata),
        .fifo_empty        (fifo_rempty),
        .fifo_rinc         (fifo_rinc),
        .beat_data         (align_data),
        .beat_ack          (shifter_ack),
        .beat_valid        (beat_valid),
        .rows_done         (rows_done)
    );

    bitblt_alpha_blend u_alpha_blend (
        .clk               (clk),
        .rst_n             (rst_n),
        .clr               (buffer_clear),
        .enable            (blend_op),
        .is_add            (add_op),
        .global_alpha      (cmd_global_alpha),
        .colorkey_en       (cmd_colorkey_en),
        .colorkey_val      (cmd_colorkey_val),
        .src_data          (align_data),
        .src_valid         (beat_valid),
        .src_ack           (blend_src_ack),
        .dst_data          (dst_fifo_rdata),
        .dst_valid         (!dst_fifo_rempty),
        .dst_ack           (blend_dst_ack),
        .out_data          (blend_data),
        .out_mask          (blend_mask),
        .out_valid         (blend_valid),
        .out_ack           (wr_beat_ack)
    );

    bitblt_axi_master u_write_master (
        .clk               (clk),
        .rst_n             (rst_n),
        .abort             (engine_abort),
        .busy              (write_busy),
        .burst_req         (burst_req),
        .burst_addr        (burst_addr),
        .burst_len         (burst_len),
        .burst_data        (burst_data),
        .burst_wstrb_first (burst_wstrb_first),
        .burst_wstrb_last  (burst_wstrb_last),
        .burst_done        (burst_done),
        .data_from_fifo    (data_from_fifo),
        .align_data        (stream_data),
        .data_valid        (wr_data_valid),
        .beat_ack          (wr_beat_ack),
        .colorkey_en       (cmd_colorkey_en),
        .colorkey_val      (cmd_colorkey_val),
        .stream_mask       (stream_mask),
        .stream_mask_en    (stream_mask_en),
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

    assign dst_fifo_rinc = blend_dst_ack;

endmodule
