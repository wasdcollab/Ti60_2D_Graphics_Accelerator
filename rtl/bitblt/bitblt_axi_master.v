`timescale 1ns/1ps
// =============================================================================
// bitblt_axi_master  (v3)
// -----------------------------------------------------------------------------
// One AXI4 write burst per request, 128-bit beats (AWSIZE = 16 bytes).
//
// Changes against v3:
//
//   * the B response is no longer on the critical path.  v3 sat in S_B until
//     BRESP arrived before it would look at `burst_req` again, so every write
//     burst paid a full DDR write round trip even though AXI writes are posted
//     and nothing downstream needed the acknowledgement.  BREADY is now held
//     high permanently and the burst retires as soon as its last W beat is
//     accepted - which is also the moment the data has physically left the
//     read/align FIFO, so the beat credit bitblt_stride_gen derives from
//     `burst_done` gets *more* accurate, not less.
//
// Changes against v2:
//   * the byte strobes can now come from an upstream per-pixel mask
//     (`stream_mask` + `stream_mask_en`).  OP_ALPHA needs this: whether a
//     pixel is written is decided inside bitblt_alpha_blend, on the *source*
//     pixel, because a Color-Key hit must be skipped before blending and the
//     blended value is no longer equal to the key.  For every other operation
//     the mask is derived here from the streamed data exactly as before.
//
// Changes against v1 (kept):
//   * the pixel source is the realigned stream coming out of
//     bitblt_align_shifter (or the blended stream for OP_ALPHA) instead of the
//     raw read FIFO.
//   * WVALID is gated by `data_valid`, so a burst may start as soon as its
//     first beat is ready and simply stall on the W channel if the reader falls
//     behind.  This is what allows the read of the next chunk to overlap the
//     write of the current one instead of running strictly one after the other.
//   * `beat_ack` (one pulse per accepted beat) drives the shifter's window
//     advance (and, for OP_ALPHA, the blend pipeline's output handshake).
// =============================================================================
module bitblt_axi_master (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         abort,
    output wire         busy,

    // Burst request interface from stride_gen
    input  wire         burst_req,
    input  wire [27:0]  burst_addr,
    input  wire [7:0]   burst_len,        // 0-based (0 = 1 beat, 15 = 16 beats)
    input  wire [127:0] burst_data,       // replicated colour, used when data_from_fifo == 0
    input  wire [15:0]  burst_wstrb_first,
    input  wire [15:0]  burst_wstrb_last,
    output reg          burst_done,       // single-cycle pulse when the burst completes

    // Streaming data interface (from bitblt_align_shifter or bitblt_alpha_blend)
    input  wire         data_from_fifo,
    input  wire [127:0] align_data,
    input  wire         data_valid,
    output wire         beat_ack,

    input  wire         colorkey_en,
    input  wire [31:0]  colorkey_val,

    // Upstream per-pixel byte strobe mask (OP_ALPHA)
    input  wire [15:0]  stream_mask,
    input  wire         stream_mask_en,

    // AXI4 Write Master (128-bit)
    output reg  [3:0]   m_axi_awid,
    output reg  [27:0]  m_axi_awaddr,
    output reg  [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire [1:0]   m_axi_awlock,
    output reg          m_axi_awvalid,
    input  wire         m_axi_awready,

    output wire [3:0]   m_axi_wid,
    output wire [127:0] m_axi_wdata,
    output wire [15:0]  m_axi_wstrb,
    output reg          m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,

    input  wire [3:0]   m_axi_bid,
    input  wire         m_axi_bvalid,
    output reg          m_axi_bready
);

    assign m_axi_awsize  = 3'b100; // 16 bytes per beat
    assign m_axi_awburst = 2'b01;  // INCR
    assign m_axi_awlock  = 2'b00;
    assign m_axi_wid     = 4'd2;

    localparam S_IDLE = 2'd0;
    localparam S_AW   = 2'd1;
    localparam S_W    = 2'd2;

    reg [1:0] state;
    reg padding, stalled;
    reg [127:0] stalled_data;
    reg [15:0] stalled_mask;
    assign busy = state != S_IDLE;
    reg [7:0] beat_cnt;

    reg [7:0]   latch_len;
    reg [127:0] latch_data;
    reg [15:0]  latch_wstrb_first;
    reg [15:0]  latch_wstrb_last;
    reg [15:0]  base_wstrb;

    // Colour-key: a pixel equal to colorkey_val has all four of its byte strobes
    // cleared, so the background shows through (irregular sprite edges).  This is
    // the OP_COPY path; OP_ALPHA brings its own mask with the blended beat.
    wire [15:0] colorkey_mask = {
        (align_data[127:96] == colorkey_val) ? 4'b0000 : 4'b1111,
        (align_data[95:64]  == colorkey_val) ? 4'b0000 : 4'b1111,
        (align_data[63:32]  == colorkey_val) ? 4'b0000 : 4'b1111,
        (align_data[31:0]   == colorkey_val) ? 4'b0000 : 4'b1111
    };

    wire [15:0] eff_stream_mask = stream_mask_en ? stream_mask
                                                 : (colorkey_en ? colorkey_mask : 16'hFFFF);

    assign m_axi_wdata  = stalled ? stalled_data : padding ? latch_data : data_from_fifo ? align_data : latch_data;
    assign m_axi_wstrb  = stalled ? stalled_mask : padding ? 16'd0 : data_from_fifo ? (base_wstrb & eff_stream_mask) : base_wstrb;
    assign m_axi_wvalid = (state == S_W) && (stalled || padding || data_valid);
    assign beat_ack     = m_axi_wvalid && m_axi_wready && !padding && !abort;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            padding <= 1'b0;
            stalled <= 1'b0;
            stalled_data <= 128'd0;
            stalled_mask <= 16'd0;
        end else begin
            if (state == S_IDLE) padding <= 1'b0;
            else if (abort && (!m_axi_wvalid || m_axi_wready)) padding <= 1'b1;
            stalled <= m_axi_wvalid && !m_axi_wready;
            if (m_axi_wvalid && !m_axi_wready) begin
                stalled_data <= m_axi_wdata;
                stalled_mask <= m_axi_wstrb;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            burst_done <= 1'b0;

            m_axi_awid    <= 4'd2;
            m_axi_awaddr  <= 28'd0;
            m_axi_awlen   <= 8'd0;
            m_axi_awvalid <= 1'b0;

            base_wstrb    <= 16'd0;
            m_axi_wlast   <= 1'b0;

            // Permanently ready: the response is informational, and waiting
            // for it is what used to serialise one write burst per round trip.
            m_axi_bready  <= 1'b1;

            beat_cnt          <= 8'd0;
            latch_len         <= 8'd0;
            latch_data        <= 128'd0;
            latch_wstrb_first <= 16'd0;
            latch_wstrb_last  <= 16'd0;
        end else begin
            burst_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (burst_req) begin
                        latch_len         <= burst_len;
                        latch_data        <= burst_data;
                        latch_wstrb_first <= burst_wstrb_first;
                        latch_wstrb_last  <= burst_wstrb_last;

                        m_axi_awid    <= 4'd2;
                        m_axi_awaddr  <= burst_addr;
                        m_axi_awlen   <= burst_len;
                        m_axi_awvalid <= 1'b1;
                        state         <= S_AW;
                    end
                end

                S_AW: begin
                    if (m_axi_awready && m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b0;
                        beat_cnt      <= 8'd0;

                        if (latch_len == 8'd0) begin
                            m_axi_wlast <= 1'b1;
                            base_wstrb  <= latch_wstrb_first & latch_wstrb_last;
                        end else begin
                            m_axi_wlast <= 1'b0;
                            base_wstrb  <= latch_wstrb_first;
                        end

                        state <= S_W;
                    end
                end

                S_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        if (m_axi_wlast) begin
                            // Done as far as the engine is concerned: the last
                            // beat is on the bus and out of the FIFO.  The B
                            // response arrives on its own and is accepted by
                            // the permanently-asserted BREADY.
                            m_axi_wlast <= 1'b0;
                            burst_done  <= 1'b1;
                            state       <= S_IDLE;
                        end else begin
                            beat_cnt <= beat_cnt + 8'd1;
                            if ((beat_cnt + 8'd1) == latch_len) begin
                                m_axi_wlast <= 1'b1;
                                base_wstrb  <= latch_wstrb_last;
                            end else begin
                                m_axi_wlast <= 1'b0;
                                base_wstrb  <= 16'hFFFF;
                            end
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
