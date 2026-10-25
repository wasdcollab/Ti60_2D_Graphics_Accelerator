`timescale 1ns / 1ps
// =============================================================================
// dma_top.v
// -----------------------------------------------------------------------------
// Dedicated Framebuffer & Bullet Bucket AXI4 Data Extraction Engine (rtl/dma/)
//
// Triad Architecture Role: "Pure Data Water Supply Plant" (rtl/dma/)
// - Completely protocol-decoupled from game rendering logic.
// - Arbitrates AXI4 Read Master requests between Framebuffer and Bucket prefetch.
// - Safely crosses memory data from 100 MHz axi_clk to 85.714 MHz pixel_clk.
// - Unpacks 128-bit memory words into a pure 32-bit ARGB baseboard pixel stream.
// - Atomic double-buffering page swap strictly at VSync blanking interval.
// =============================================================================

module dma_top #(
    parameter FRAME_BASE_ADDR    = 28'h0080_0000,
    parameter H_ACT              = 1366,
    parameter H_TOTAL            = 1456,
    parameter V_ACT              = 768,
    parameter V_TOTAL            = 782,
    parameter AXI_ADDR_WIDTH     = 28,
    parameter AXI_DATA_WIDTH     = 128,
    parameter BUCKET_SLOTS       = 128,
    // On-chip pool depth.  Independent of BUCKET_SLOTS: the DDR table stays at
    // one entry per sprite per group, while the scanout pool also holds the
    // sprites carried down from earlier groups.  See dma_bucket_prefetch.v.
    parameter POOL_SLOTS         = 128,
    // Scanlines sharing one bucket entry.  Must match MM_BUCKET_GROUP_ROWS in
    // sw/driver/memory_map.h and BUCKET_GROUP_ROWS in video_bullet_overlay.v;
    // the shift is log2 of it and is what turns a scanline into a group.
    parameter BUCKET_GROUP_ROWS  = 8,
    parameter BUCKET_GROUP_SHIFT = 3,
    parameter ACTIVE_POOL_EN     = 1,
    parameter SCANLINE_EN       = 0
)(
    // AXI Clock & Reset (100 MHz)
    input  wire                       axi_clk,
    input  wire                       axi_rst_n,
    input  wire                       cal_done,

    // AXI4 Read Master Interface (to Axi_Mux Slave 0)
    output wire [3:0]                 m_axi_arid,
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_araddr,
    output wire [7:0]                 m_axi_arlen,
    output wire [2:0]                 m_axi_arsize,
    output wire [1:0]                 m_axi_arburst,
    output wire [1:0]                 m_axi_arlock,
    output wire                       m_axi_arvalid,
    input  wire                       m_axi_arready,

    input  wire [3:0]                 m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_rdata,
    input  wire [1:0]                 m_axi_rresp,
    input  wire                       m_axi_rlast,
    input  wire                       m_axi_rvalid,
    output wire                       m_axi_rready,

    // Pixel Clock & Reset (85.714 MHz)
    input  wire                       pixel_clk,
    input  wire                       pixel_rst_n,

    // Timing Inputs from rtl/display_engine/
    input  wire [11:0]                h_cnt,
    input  wire [10:0]                v_cnt,
    input  wire                       t_de,
    input  wire                       t_frame_start,
    input  wire                       t_frame_clear,

    // Double-Buffer Control (from/to apb_command_dispatcher)
    input  wire [AXI_ADDR_WIDTH-1:0]  next_frame_base_addr,
    output wire [AXI_ADDR_WIDTH-1:0]  active_frame_base_addr,
    input  wire [AXI_ADDR_WIDTH-1:0]  next_right_base_addr,
    output wire [AXI_ADDR_WIDTH-1:0]  active_right_base_addr,
    output wire                       vsync_flag,
    output wire                       video_read_priority,
    output wire [31:0]                scan_diagnostics,

    // Bullet Bucket Prefetch Control & Data
    input  wire [AXI_ADDR_WIDTH-1:0]  bucket_base,
    output wire [32*POOL_SLOTS-1:0]   bucket_row,
    output wire                       bucket_ready,
    // Scanout pool overflow for this frame (see dma_bucket_prefetch.v).
    output wire [11:0]                bucket_pool_drop,
    input wire [$clog2(BUCKET_SLOTS)-1:0] bucket_entry_addr,
    input wire bucket_entry_group,
    output wire [31:0] bucket_entry_data,

    // Pure Baseboard Pixel Output (to rtl/display_engine/)
    output wire [31:0]                fb_pixel
);

    // -------------------------------------------------------------------------
    // Cross frame_start & frame_clear from pixel_clk to axi_clk domain
    // -------------------------------------------------------------------------
    reg frame_toggle_p;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n)
            frame_toggle_p <= 1'b0;
        else if (t_frame_start)
            frame_toggle_p <= ~frame_toggle_p;
    end

    reg [2:0] frame_toggle_sync;
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n)
            frame_toggle_sync <= 3'b0;
        else
            frame_toggle_sync <= {frame_toggle_sync[1:0], frame_toggle_p};
    end
    wire frame_start_axi = frame_toggle_sync[2] ^ frame_toggle_sync[1];

    reg [2:0] frame_clear_sync;
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n)
            frame_clear_sync <= 3'b0;
        else
            frame_clear_sync <= {frame_clear_sync[1:0], t_frame_clear};
    end
    wire frame_clear_axi       = frame_clear_sync[1];
    wire frame_clear_axi_pulse = frame_clear_sync[1] && !frame_clear_sync[2];

    // -------------------------------------------------------------------------
    // Dynamic Frame Base Address Atomic Latch at VSync
    // -------------------------------------------------------------------------
    reg [AXI_ADDR_WIDTH-1:0] active_base;
    reg [AXI_ADDR_WIDTH-1:0] right_base;

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            active_base <= FRAME_BASE_ADDR;
            right_base  <= FRAME_BASE_ADDR;
        end else if (frame_clear_axi_pulse) begin
            active_base <= next_frame_base_addr;
            right_base  <= next_right_base_addr;
        end
    end

    assign vsync_flag             = frame_clear_axi;
    assign active_frame_base_addr = active_base;
    assign active_right_base_addr = right_base;

    // -------------------------------------------------------------------------
    // Submodules: Framebuffer Reader & Bullet Bucket Prefetch
    // -------------------------------------------------------------------------
    wire         bk_pend;
    wire         bk_act;
    wire [27:0]  bk_araddr;
    wire [7:0]   bk_arlen;
    wire         bk_arvalid;
    wire         bk_rready;

    wire [27:0]  fb_araddr;
    wire [7:0]   fb_arlen;
    wire         fb_arvalid;
    wire         fb_rready;

    wire         at_line_start;
    wire [4:0]   burst_in_row;
    wire [12:0]  col_off;
    wire         discard_frame;

    wire         fifo_winc;
    wire [127:0] fifo_wdata;
    wire [10:0]  fifo_wusedw;

    dma_fb_reader #(
        .FRAME_BASE_ADDR (FRAME_BASE_ADDR),
        .H_ACT           (H_ACT),
        .V_ACT           (V_ACT),
        .AXI_ADDR_WIDTH  (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH  (AXI_DATA_WIDTH)
    ) u_fb_reader (
        .axi_clk             (axi_clk),
        .axi_rst_n           (axi_rst_n),
        .cal_done            (cal_done),
        .active_base         (active_base),
        .right_base          (right_base),
        .frame_start_axi     (frame_start_axi),
        .frame_clear_axi     (frame_clear_axi),
        .fifo_wusedw         (fifo_wusedw),
        .fifo_winc           (fifo_winc),
        .fifo_wdata          (fifo_wdata),
        .video_read_priority (video_read_priority),
        // A disabled bucket may still have a pending line request.  It must
        // never reserve the line-start slot or the framebuffer reader stalls
        // forever while the pixel FIFO drains to black.
        .bk_pend             (bk_pend && (bucket_base != 28'd0)),
        .bk_act              (bk_act),
        .at_line_start       (at_line_start),
        .burst_in_row        (burst_in_row),
        .col_off             (col_off),
        .discard_frame       (discard_frame),
        .fb_araddr           (fb_araddr),
        .fb_arlen            (fb_arlen),
        .fb_arvalid          (fb_arvalid),
        .fb_arready          (m_axi_arready && !bk_act),
        .fb_rdata            (m_axi_rdata),
        .fb_rlast            (m_axi_rlast),
        .fb_rvalid           (m_axi_rvalid && !bk_act),
        .fb_rready           (fb_rready)
    );

    generate if (SCANLINE_EN) begin : g_scanline
    assign bucket_row = 0;
    dma_scanline_prefetch #(.SLOTS(BUCKET_SLOTS),.V_TOTAL(V_TOTAL)) u_scanline (
        .axi_clk(axi_clk),.axi_rst_n(axi_rst_n),.cal_done(cal_done),
        .bucket_base(bucket_base),.active_base(active_base),
        .frame_clear_axi(frame_clear_axi),.at_line_start(at_line_start),
        .fb_busy(fb_arvalid | fb_rready),
        .bk_pend(bk_pend),.bk_act(bk_act),.bk_araddr(bk_araddr),
        .bk_arlen(bk_arlen),.bk_arvalid(bk_arvalid),.bk_arready(m_axi_arready && bk_act),
        .bk_rdata(m_axi_rdata),.bk_rlast(m_axi_rlast),
        .bk_rvalid(m_axi_rvalid && bk_act),.bk_rready(bk_rready),
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),.h_cnt(h_cnt),.v_cnt(v_cnt),
        .entry_addr(bucket_entry_addr),.entry_group(bucket_entry_group),
        .entry_data(bucket_entry_data),.entry_ready(bucket_ready),
        .missed_lines(bucket_pool_drop)
    );
    end else begin : g_legacy
    assign bucket_entry_data = 0;
    dma_bucket_prefetch #(
        .BUCKET_SLOTS        (BUCKET_SLOTS),
        .POOL_SLOTS          (POOL_SLOTS),
        .BUCKET_GROUP_ROWS   (BUCKET_GROUP_ROWS),
        .BUCKET_GROUP_SHIFT  (BUCKET_GROUP_SHIFT),
        .ACTIVE_POOL_EN      (ACTIVE_POOL_EN),
        .H_ACT               (H_ACT),
        .V_ACT               (V_ACT),
        .V_TOTAL             (V_TOTAL),
        .AXI_ADDR_WIDTH      (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH      (AXI_DATA_WIDTH)
    ) u_bucket_prefetch (
        .axi_clk         (axi_clk),
        .axi_rst_n       (axi_rst_n),
        .cal_done        (cal_done),
        .bucket_base     (bucket_base),
        .active_base     (active_base),
        .frame_clear_axi (frame_clear_axi),
        .discard_frame   (discard_frame),
        .at_line_start   (at_line_start),
        .fb_busy         (fb_arvalid | fb_rready),
        .bk_pend         (bk_pend),
        .bk_act          (bk_act),
        .bk_araddr       (bk_araddr),
        .bk_arlen        (bk_arlen),
        .bk_arvalid      (bk_arvalid),
        .bk_arready      (m_axi_arready && bk_act),
        .bk_rdata        (m_axi_rdata),
        .bk_rlast        (m_axi_rlast),
        .bk_rvalid       (m_axi_rvalid && bk_act),
        .bk_rready       (bk_rready),
        .pixel_clk       (pixel_clk),
        .pixel_rst_n     (pixel_rst_n),
        .h_cnt           (h_cnt),
        .v_cnt           (v_cnt),
        .bucket_row      (bucket_row),
        .bucket_ready    (bucket_ready),
        .pool_drop       (bucket_pool_drop)
    );
    end endgenerate

    // -------------------------------------------------------------------------
    // AXI Read Channel Arbitrated Multiplexer
    // -------------------------------------------------------------------------
    assign m_axi_arid    = 4'd1;
    assign m_axi_arsize  = 3'b100;    // 16 bytes per beat (128-bit)
    assign m_axi_arburst = 2'b01;     // INCR
    assign m_axi_arlock  = 2'b00;

    assign m_axi_araddr  = bk_act ? bk_araddr  : fb_araddr;
    assign m_axi_arlen   = bk_act ? bk_arlen   : fb_arlen;
    assign m_axi_arvalid = bk_act ? bk_arvalid : fb_arvalid;
    assign m_axi_rready  = bk_act ? bk_rready  : fb_rready;

    // -------------------------------------------------------------------------
    // Async FIFO Buffer (100 MHz AXI -> 85.714 MHz Pixel Clock)
    // -------------------------------------------------------------------------
    wire         fifo_wfull;
    wire [127:0] fifo_rdata;
    wire         fifo_rempty;
    wire         fifo_rinc;

    async_fifo #(
        .DATA_WIDTH (AXI_DATA_WIDTH),
        .ADDR_WIDTH (10) // 1024 depth
    ) u_fifo (
        .wclk   (axi_clk),
        .wrst_n (axi_rst_n),
        .wclr   (frame_clear_axi),
        .winc   (fifo_winc),
        .wdata  (fifo_wdata),
        .wfull  (fifo_wfull),
        .wusedw (fifo_wusedw),

        .rclk   (pixel_clk),
        .rrst_n (pixel_rst_n),
        .rclr   (t_frame_clear),
        .rinc   (fifo_rinc),
        .rdata  (fifo_rdata),
        .rempty (fifo_rempty)
    );

    // -------------------------------------------------------------------------
    // Pixel Domain Gearbox (128-bit word -> 32-bit ARGB pixel)
    // with Strict Scanline Synchronization & Underflow Isolation
    // -------------------------------------------------------------------------
    localparam [8:0] WORDS_PER_ROW = (H_ACT + 3) / 4; // 1366 -> 342

    reg [1:0]   sub_pix_cnt;
    reg [127:0] cur_word;
    reg [31:0]  cur_pixel;

    wire prefetch_line = (v_cnt == V_TOTAL - 1) || (v_cnt < V_ACT - 1);
    wire line_prefetch = (h_cnt == H_TOTAL - 2) && prefetch_line;
    wire word_fetch    = (sub_pix_cnt == 2'd2) && (h_cnt < H_ACT - 2) && t_de;
    wire need_word     = line_prefetch || word_fetch;
    // A missed word still occupies four display positions. Discard its late
    // response before displaying later words, rather than shifting the image.
    reg [18:0] late_words;
    reg fetch_valid;
    wire drop_word = (late_words != 0) && !fifo_rempty;
    wire take_word = need_word && (late_words == 0) && !fifo_rempty;
    assign fifo_rinc = !t_frame_clear && (drop_word || take_word);

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            late_words <= 19'd0;
            fetch_valid <= 1'b0;
        end else if (t_frame_clear) begin
            late_words <= 19'd0;
            fetch_valid <= 1'b0;
        end else begin
            fetch_valid <= take_word;
            case ({need_word && !take_word, drop_word})
                2'b10: late_words <= late_words + 19'd1;
                2'b01: late_words <= late_words - 19'd1;
                default: ;
            endcase
        end
    end

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            sub_pix_cnt <= 2'd0;
            cur_word    <= 128'd0;
            cur_pixel   <= 32'd0;
        end else begin
            if ((h_cnt == H_TOTAL - 1) && prefetch_line) begin
                cur_word    <= fetch_valid ? fifo_rdata : 128'd0;
                sub_pix_cnt <= 2'd0;
                cur_pixel   <= 32'd0;
            end else if (t_de) begin
                sub_pix_cnt <= sub_pix_cnt + 2'd1;

                case (sub_pix_cnt)
                    2'd0: cur_pixel <= cur_word[31:0];
                    2'd1: cur_pixel <= cur_word[63:32];
                    2'd2: cur_pixel <= cur_word[95:64];
                    2'd3: begin
                        cur_pixel <= cur_word[127:96];
                        cur_word  <= fetch_valid ? fifo_rdata : 128'd0;
                    end
                endcase
            end else begin
                sub_pix_cnt <= 2'd0;
                cur_pixel   <= 32'd0;
            end
        end
    end

    assign fb_pixel = cur_pixel;

    // -------------------------------------------------------------------------
    // Diagnostics & Underflow Accounting
    // -------------------------------------------------------------------------
    reg [15:0] underflow_count, background_errors;
    reg [31:0] scan_snapshot, scan_sync1, scan_sync2;
    reg [7:0] ar_count, r_count, ar_last, r_last;

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            ar_count <= 8'd0;
            r_count  <= 8'd0;
            ar_last  <= 8'd0;
            r_last   <= 8'd0;
        end else if (frame_clear_axi_pulse) begin
            // Snapshot on the rising EDGE, not on the level.  frame_clear_axi
            // is synchronised and stays high for the width of t_frame_clear
            // (~18 axi_clk), so the old level-triggered form re-sampled the
            // already-zeroed counters every cycle and always latched 0 - which
            // made the ar_last/r_last diagnostic in scan_diagnostics read as
            // "no traffic at all" no matter what the reader was doing.
            ar_last  <= ar_count;
            r_last   <= r_count;
            ar_count <= 8'd0;
            r_count  <= 8'd0;
        end else begin
            if (m_axi_arvalid && m_axi_arready && ar_count != 8'd63)
                ar_count <= ar_count + 8'd1;
            if (m_axi_rvalid && m_axi_rready && r_count != 8'd31)
                r_count <= r_count + 8'd1;
        end
    end

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            underflow_count   <= 16'd0;
            background_errors <= 16'd0;
            scan_snapshot     <= 32'd0;
        end else if (v_cnt == V_ACT && h_cnt == 12'd32) begin
            scan_snapshot     <= {background_errors, underflow_count};
            underflow_count   <= 16'd0;
            background_errors <= 16'd0;
        end else begin
            if (((h_cnt == H_TOTAL - 12'd2 && prefetch_line) ||
                 (sub_pix_cnt == 2'd2 && h_cnt < H_ACT - 12'd2 && t_de)) &&
                fifo_rempty && underflow_count != 16'hffff)
                underflow_count <= underflow_count + 1'b1;
        end
    end

    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            scan_sync1 <= 32'd0;
            scan_sync2 <= 32'd0;
        end else begin
            scan_sync1 <= scan_snapshot;
            scan_sync2 <= scan_sync1;
        end
    end
    // High bits identify whether the framebuffer or bucket owns a stalled
    // read.  The counters saturate; 63 ARs / 31 R beats is enough to tell a
    // dead channel from a live one without consuming extra APB registers.
    assign scan_diagnostics = {
        (bucket_base != 28'd0), bk_act, fb_arvalid, fb_rready, bk_pend,
        ar_last[5:0], r_last[4:0], scan_sync2[15:0]
    };

endmodule
