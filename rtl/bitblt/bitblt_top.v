`timescale 1ns/1ps
// =============================================================================
// bitblt_top  (v3 - real 2D read/write BitBlt engine with alpha blending)
// -----------------------------------------------------------------------------
// Datapath:
//
//   APB -> apb_regs -> stride_gen ─┬─> axi_read_master ─┬─> read_fifo ────┐
//                                  │  (tagged src/dst)  │                 ├─> align_shifter
//                                  │                    └─> dst_read_fifo ─┼──────────┐
//                                  │                                       │          ▼
//                                  │                                       │   alpha_blend
//                                  └─> axi_master (write) <───────────────┴──────────┘
//
// OP_FILL  : stride_gen replicates the colour register onto every write beat.
// OP_COPY  : stride_gen issues N_write read beats and N_write+1 read bursts worth
//            of data per row; the alignment shifter rotates the byte stream so a
//            source/destination pair with different low nibbles still lands
//            pixel-exact, and read bursts overlap write bursts in time.
// OP_ALPHA : the destination background is read back from DDR with exactly the
//            lanes that are about to be written (a second, tagged read stream),
//            realigned source and background are blended per pixel and the
//            result is written back.  The two read streams share one AXI read
//            master because the interconnect feeds DDR3 through a single AR/R
//            channel: a second master would only move the arbitration.
//
// Parameters:
//   MAX_BURST_BEATS   maximum AXI burst length (1..256).  Default 64 (1 KiB).
//                     Roll back to 16 if an on-board DDR controller rejects
//                     longer INCR bursts - nothing else has to change.
//   READ_FIFO_DEPTH   source read elasticity FIFO depth.
//   DST_FIFO_DEPTH    background read elasticity FIFO depth.  It must stay
//                     greater than 2*MAX_BURST_BEATS + 4: the credit check in
//                     stride_gen charges a whole read burst up front, so a
//                     shallower FIFO could refuse to refill while a write burst
//                     is still being fed and then deadlock.
// =============================================================================
module bitblt_top #(
    parameter integer MAX_BURST_BEATS = 64,
    parameter integer READ_FIFO_DEPTH = 192,
    parameter integer READ_FIFO_AW    = 8,
    parameter integer DST_FIFO_DEPTH  = 192,
    parameter integer DST_FIFO_AW     = 8,
    // Read-side prefetch window, forwarded to bitblt_align_shifter.  The
    // default of 2 is the historical value; raising it is what lets the
    // concurrent read master actually keep bursts in flight.
    parameter integer PREFETCH_BEATS  = 2
)(
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
    input  wire [4:0]   gamepad_buttons,
    input  wire         gamepad_online,
    input  wire         key_sw0_level,
    input  wire         key_sw2_level,
    input  wire         key_sw0_pulse,
    input  wire         key_sw2_pulse,
    output wire [6:0]   i2c_slave_addr,
    output wire         force_hud_disable,

    // Weather overlay control, registered at APB 0x78 and forwarded straight
    // to the scanout's overlay stage.
    output wire [31:0]  weather_ctrl,
    // The overlay's occlusion box (APB 0x8C / 0xAC): the rectangle the scanout
    // must not paint weather dots inside.  Same path as weather_ctrl, one more
    // stop on the way out of the register file.
    output wire [31:0]  weather_mask_x,
    output wire [31:0]  weather_mask_y,
    // Where the scanout's four laser columns stand (APB 0xB0 / 0xB4).
    output wire [23:0]  laser_colx_lo,
    output wire [23:0]  laser_colx_hi,
    output wire [31:0]  color_matrix_ctrl,
    output wire [31:0]  bloom_ctrl
);

    // ---- live engine probe --------------------------------------------
    // Declared up here, BEFORE the apb_regs instance that consumes them:
    // iverilog rejects a continuous assignment whose *target* is declared
    // later in the file ("Unable to bind wire/reg/memory"), even though
    // Efinity's elaborator accepts it.  A declaration at the bottom of the
    // file therefore builds a bitstream but breaks the bench, which is the
    // worst of both worlds - the regression suite would have silently kept
    // using the pre-probe RTL.
    //
    // The taps come from real ports on the two submodules, not from
    // hierarchical references: Efinity refuses to resolve a reference into
    // a submodule's internal register (VERI-1172), and q_cnt is 3 bits, so
    // the original "q_cnt[3:0]" also asked for a bit that does not exist.
    wire [2:0] tap_q_cnt;
    wire       tap_ar_pend;
    wire [1:0] tap_sg_state;

    wire [3:0] probe_q_cnt    = {1'b0, tap_q_cnt};
    wire       probe_ar_pend  = tap_ar_pend;
    wire [1:0] probe_sg_state = tap_sg_state;

    // apb_regs -> stride_gen
    wire        cmd_start;
    wire [1:0]  cmd_op_type;
    wire [27:0] cmd_dst_addr;
    wire [27:0] cmd_src_addr;
    wire [10:0] cmd_rect_w;
    wire [10:0] cmd_rect_h;
    wire [31:0] cmd_color;
    wire [15:0] cmd_src_stride;
    wire [15:0] cmd_dst_stride;
    wire        cmd_colorkey_en;
    wire [31:0] cmd_colorkey_val;
    wire        cmd_alpha_en;
    wire [7:0]  cmd_global_alpha;
    wire        busy;

    // How many read bursts may be outstanding at once.  This is the knob that
    // turns the read channel from "one burst per DDR round trip" into a pipelined
    // stream; it must match on the generator (request budget) and on the read
    // master (request queue depth).  Credit in the generator still caps the
    // useful value: a 64-beat burst plus its 4-beat residue has to fit in
    // READ_FIFO_DEPTH, so at 192/64 depth three are live and the fourth request
    // is refused for credit rather than for room here.
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

    // source read FIFO
    wire        fifo_winc;
    wire [127:0] fifo_wdata;
    wire        fifo_wfull;
    wire        fifo_rinc;
    wire [127:0] fifo_rdata;
    wire        fifo_rempty;
    wire [READ_FIFO_AW:0] fifo_used;

    // destination background read FIFO (OP_ALPHA)
    wire        dst_fifo_winc;
    wire        dst_fifo_wfull;
    wire        dst_fifo_rinc;
    wire [127:0] dst_fifo_rdata;
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
    // the shifter advances on the beat that was really consumed by the blend
    // pipeline; for every other operation that is the write master's own ack.
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

    wire         err_timeout;

    // The write master may only start a burst once its first beat is on the
    // wire; fills have their data in a register and are always valid.
    wire         wr_data_valid = data_from_fifo ? stream_valid : 1'b1;

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
        .cmd_busy               (busy),
        .engine_timeout         (err_timeout),
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
        .cmd_colorkey_en        (cmd_colorkey_en),
        .cmd_colorkey_val       (cmd_colorkey_val),
        .cmd_alpha_en           (cmd_alpha_en),
        .cmd_global_alpha       (cmd_global_alpha),
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
        .force_hud_disable      (force_hud_disable),
        // Live engine probe: layer-referenced out of the two submodules below.
        // Read-only observability, no datapath effect.
        .diag_rd_q_cnt          (probe_q_cnt),
        .diag_rd_ar_pend        (probe_ar_pend),
        .diag_sg_state          (probe_sg_state),
        .weather_ctrl           (weather_ctrl),
        .weather_mask_x         (weather_mask_x),
        .weather_mask_y         (weather_mask_y),
        .laser_colx_lo          (laser_colx_lo),
        .laser_colx_hi          (laser_colx_hi),
        .color_matrix_ctrl      (color_matrix_ctrl),
        .bloom_ctrl             (bloom_ctrl)
    );

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
        // "the write master has a beat ready" is the STREAM ready signal, not
        // the shifter's own: for OP_ALPHA the last beat of a row can already be
        // sitting in the blend hold register while the shifter itself has run
        // dry, and gating the burst request on the shifter would then never
        // issue that final write burst - the row would never complete.
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
        .clr               (fifo_clr),
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
        .clr               (fifo_clr),
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
        .clr               (fifo_clr),
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
        .clr               (fifo_clr),
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

    // The destination FIFO hands one entry per write beat to the blend stage.
    // The blend only accepts a destination beat together with a source beat, so
    // the two streams stay locked to the write beat index for the whole command.
    assign dst_fifo_rinc = blend_dst_ack;

    // The probe nets themselves are declared at the top of the file; see the
    // note next to them for why the declaration order matters here.

endmodule
