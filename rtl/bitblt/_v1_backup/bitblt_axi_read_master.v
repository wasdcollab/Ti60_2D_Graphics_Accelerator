`timescale 1ns/1ps

module bitblt_axi_read_master (
    input  wire         clk,
    input  wire         rst_n,
    
    // Command interface from stride_gen
    input  wire         rd_req,
    input  wire [27:0]  rd_addr,
    input  wire [7:0]   rd_len,      // 0-based: 0=1 beat, 15=16 beats
    output reg          rd_done,     // single-cycle pulse when burst completes
    output wire         rd_busy,
    
    // AXI4 Read Master Interface (128-bit)
    output reg  [3:0]   m_axi_arid,
    output reg  [27:0]  m_axi_araddr,
    output reg  [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire [1:0]   m_axi_arlock,
    output reg          m_axi_arvalid,
    input  wire         m_axi_arready,
    
    input  wire [3:0]   m_axi_rid,
    input  wire [127:0] m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output reg          m_axi_rready,
    
    // Output to read FIFO
    output wire         fifo_winc,
    output wire [127:0] fifo_wdata
);

    assign m_axi_arsize  = 3'b100; // 16 bytes per beat (128-bit)
    assign m_axi_arburst = 2'b01;  // INCR
    assign m_axi_arlock  = 2'b00;

    localparam S_IDLE = 2'd0;
    localparam S_AR   = 2'd1;
    localparam S_R    = 2'd2;

    reg [1:0] state;

    assign rd_busy    = (state != S_IDLE);
    assign fifo_winc  = (state == S_R) && m_axi_rvalid && m_axi_rready;
    assign fifo_wdata = m_axi_rdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            rd_done       <= 1'b0;
            m_axi_arid    <= 4'd2;
            m_axi_araddr  <= 28'd0;
            m_axi_arlen   <= 8'd0;
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b0;
        end else begin
            rd_done <= 1'b0; // default pulse

            case (state)
                S_IDLE: begin
                    if (rd_req) begin
                        m_axi_arid    <= 4'd2;
                        m_axi_araddr  <= rd_addr;
                        m_axi_arlen   <= rd_len;
                        m_axi_arvalid <= 1'b1;
                        state         <= S_AR;
                    end
                end

                S_AR: begin
                    if (m_axi_arready && m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        state         <= S_R;
                    end
                end

                S_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (m_axi_rlast) begin
                            m_axi_rready <= 1'b0;
                            rd_done      <= 1'b1;
                            state        <= S_IDLE;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
