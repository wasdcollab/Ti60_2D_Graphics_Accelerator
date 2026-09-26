`timescale 1ns/1ps

module bitblt_axi_master (
    input  wire         clk,
    input  wire         rst_n,
    
    // Burst request interface from stride_gen
    input  wire         burst_req,
    input  wire [27:0]  burst_addr,
    input  wire [7:0]   burst_len,    // 0-based (0=1beat, 15=16beats)
    input  wire [127:0] burst_data,   // same data replicated for all beats (used when data_from_fifo==0)
    input  wire [15:0]  burst_wstrb_first,
    input  wire [15:0]  burst_wstrb_last,
    output reg          burst_done,   // single-cycle pulse when burst completes
    
    // Streaming data interface from read FIFO
    input  wire         data_from_fifo,
    input  wire [127:0] fifo_rdata,
    output wire         fifo_rinc,
    input  wire         colorkey_en,
    input  wire [31:0]  colorkey_val,
    
    // AXI4 Write Master Interface (128-bit)
    output reg  [3:0]   m_axi_awid,
    output reg  [27:0]  m_axi_awaddr,
    output reg  [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire [1:0]   m_axi_awlock,
    output reg          m_axi_awvalid,
    input  wire         m_axi_awready,
    
    output reg  [3:0]   m_axi_wid,
    output wire [127:0] m_axi_wdata,
    output wire [15:0]  m_axi_wstrb,
    output reg          m_axi_wlast,
    output reg          m_axi_wvalid,
    input  wire         m_axi_wready,
    
    input  wire [3:0]   m_axi_bid,
    input  wire         m_axi_bvalid,
    output reg          m_axi_bready
);

    assign m_axi_awsize  = 3'b100; // 16 bytes per beat
    assign m_axi_awburst = 2'b01;  // INCR
    assign m_axi_awlock  = 2'b00;

    localparam S_IDLE = 2'd0;
    localparam S_AW   = 2'd1;
    localparam S_W    = 2'd2;
    localparam S_B    = 2'd3;

    reg [1:0] state;
    reg [7:0] beat_cnt;
    
    reg [7:0]   latch_len;
    reg [127:0] latch_data;
    reg [15:0]  latch_wstrb_first;
    reg [15:0]  latch_wstrb_last;
    reg [15:0]  base_wstrb;

    // ColorKey mask calculation: if pixel matches colorkey_val, disable its 4 byte strobes
    wire [15:0] colorkey_mask = {
        (fifo_rdata[127:96] == colorkey_val) ? 4'b0000 : 4'b1111,
        (fifo_rdata[95:64]  == colorkey_val) ? 4'b0000 : 4'b1111,
        (fifo_rdata[63:32]  == colorkey_val) ? 4'b0000 : 4'b1111,
        (fifo_rdata[31:0]   == colorkey_val) ? 4'b0000 : 4'b1111
    };

    assign m_axi_wdata = data_from_fifo ? fifo_rdata : latch_data;
    assign m_axi_wstrb = (data_from_fifo && colorkey_en) ? (base_wstrb & colorkey_mask) : base_wstrb;
    assign fifo_rinc   = data_from_fifo && (state == S_W) && m_axi_wready && m_axi_wvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            burst_done <= 1'b0;
            
            m_axi_awid <= 4'd2;
            m_axi_awaddr <= 28'd0;
            m_axi_awlen <= 8'd0;
            m_axi_awvalid <= 1'b0;
            
            m_axi_wid <= 4'd2;
            base_wstrb <= 16'd0;
            m_axi_wlast <= 1'b0;
            m_axi_wvalid <= 1'b0;
            
            m_axi_bready <= 1'b0;
            
            beat_cnt <= 8'd0;
            latch_len <= 8'd0;
            latch_data <= 128'd0;
            latch_wstrb_first <= 16'd0;
            latch_wstrb_last <= 16'd0;
        end else begin
            burst_done <= 1'b0; // default
            
            case (state)
                S_IDLE: begin
                    if (burst_req) begin
                        latch_len <= burst_len;
                        latch_data <= burst_data;
                        latch_wstrb_first <= burst_wstrb_first;
                        latch_wstrb_last <= burst_wstrb_last;
                        
                        m_axi_awid <= 4'd2;
                        m_axi_awaddr <= burst_addr;
                        m_axi_awlen <= burst_len;
                        m_axi_awvalid <= 1'b1;
                        state <= S_AW;
                    end
                end
                
                S_AW: begin
                    if (m_axi_awready && m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b0;
                        beat_cnt <= 8'd0;
                        
                        m_axi_wid <= 4'd2;
                        m_axi_wvalid <= 1'b1;
                        
                        if (latch_len == 8'd0) begin
                            m_axi_wlast <= 1'b1;
                            base_wstrb <= latch_wstrb_first & latch_wstrb_last;
                        end else begin
                            m_axi_wlast <= 1'b0;
                            base_wstrb <= latch_wstrb_first;
                        end
                        
                        state <= S_W;
                    end
                end
                
                S_W: begin
                    if (m_axi_wready && m_axi_wvalid) begin
                        if (m_axi_wlast) begin
                            m_axi_wvalid <= 1'b0;
                            m_axi_wlast <= 1'b0;
                            m_axi_bready <= 1'b1;
                            state <= S_B;
                        end else begin
                            beat_cnt <= beat_cnt + 8'd1;
                            if ((beat_cnt + 8'd1) == latch_len) begin
                                m_axi_wlast <= 1'b1;
                                base_wstrb <= latch_wstrb_last;
                            end else begin
                                m_axi_wlast <= 1'b0;
                                base_wstrb <= 16'hFFFF;
                            end
                        end
                    end
                end
                
                S_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        burst_done <= 1'b1;
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
