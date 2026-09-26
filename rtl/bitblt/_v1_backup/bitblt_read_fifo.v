`timescale 1ns/1ps

module bitblt_read_fifo #(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 6, // depth = 64
    parameter DEPTH      = 64
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  clr,
    
    // Write interface (from AXI Read Master)
    input  wire                  winc,
    input  wire [DATA_WIDTH-1:0] wdata,
    output wire                  wfull,
    output reg  [ADDR_WIDTH:0]   wusedw,
    
    // Read interface (to AXI Write Master / Pixel Proc)
    input  wire                  rinc,
    output wire [DATA_WIDTH-1:0] rdata,
    output wire                  rempty,
    output reg  [ADDR_WIDTH:0]   rusedw
);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] waddr;
    reg [ADDR_WIDTH-1:0] raddr;
    reg [ADDR_WIDTH:0]   count;

    assign wfull  = (count == DEPTH);
    assign rempty = (count == 0);
    assign rdata  = mem[raddr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            waddr  <= {ADDR_WIDTH{1'b0}};
            raddr  <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
            wusedw <= {(ADDR_WIDTH+1){1'b0}};
            rusedw <= {(ADDR_WIDTH+1){1'b0}};
        end else if (clr) begin
            waddr  <= {ADDR_WIDTH{1'b0}};
            raddr  <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
            wusedw <= {(ADDR_WIDTH+1){1'b0}};
            rusedw <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            case ({winc && !wfull, rinc && !rempty})
                2'b10: begin
                    mem[waddr] <= wdata;
                    waddr <= waddr + 1'b1;
                    count <= count + 1'b1;
                end
                2'b01: begin
                    raddr <= raddr + 1'b1;
                    count <= count - 1'b1;
                end
                2'b11: begin
                    mem[waddr] <= wdata;
                    waddr <= waddr + 1'b1;
                    raddr <= raddr + 1'b1;
                end
                default: ;
            endcase
            wusedw <= count;
            rusedw <= count;
        end
    end

endmodule
