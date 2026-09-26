// async_fifo.v
// Standard Cummings Asynchronous FIFO with inferred synchronous BRAM
`timescale 1ns / 1ps

module async_fifo #(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 10   // Depth = 1024
)(
    input  wire                  wclk,
    input  wire                  wrst_n,
    input  wire                  wclr,
    input  wire                  winc,
    input  wire [DATA_WIDTH-1:0] wdata,
    output wire                  wfull,
    output reg  [ADDR_WIDTH:0]   wusedw,

    input  wire                  rclk,
    input  wire                  rrst_n,
    input  wire                  rclr,
    input  wire                  rinc,
    output reg  [DATA_WIDTH-1:0] rdata,
    output wire                  rempty
);

    localparam DEPTH = 1 << ADDR_WIDTH;
    reg [DATA_WIDTH-1:0] mem [DEPTH-1:0];

    // Write Pointer
    reg [ADDR_WIDTH:0] wbin;
    reg [ADDR_WIDTH:0] wptr;
    wire [ADDR_WIDTH:0] wbin_next = wbin + (winc & ~wfull);
    wire [ADDR_WIDTH:0] wptr_next = (wbin_next >> 1) ^ wbin_next;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin <= 0;
            wptr <= 0;
        end else if (wclr) begin
            wbin <= 0;
            wptr <= 0;
        end else begin
            wbin <= wbin_next;
            wptr <= wptr_next;
        end
    end

    always @(posedge wclk) begin
        if (winc & ~wfull & ~wclr)
            mem[wbin[ADDR_WIDTH-1:0]] <= wdata;
    end

    // Read Pointer
    reg [ADDR_WIDTH:0] rbin;
    reg [ADDR_WIDTH:0] rptr;
    wire [ADDR_WIDTH:0] rbin_next = rbin + (rinc & ~rempty);
    wire [ADDR_WIDTH:0] rptr_next = (rbin_next >> 1) ^ rbin_next;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin <= 0;
            rptr <= 0;
        end else if (rclr) begin
            rbin <= 0;
            rptr <= 0;
        end else begin
            rbin <= rbin_next;
            rptr <= rptr_next;
        end
    end

    // Synchronous BRAM Read (infers Ti60 BRAM block directly)
    always @(posedge rclk) begin
        if (rinc & ~rempty)
            rdata <= mem[rbin[ADDR_WIDTH-1:0]];
    end

    // Synchronizers
    reg [ADDR_WIDTH:0] rptr_wclk_m, rptr_wclk;
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rptr_wclk_m <= 0;
            rptr_wclk   <= 0;
        end else begin
            rptr_wclk_m <= rptr;
            rptr_wclk   <= rptr_wclk_m;
        end
    end

    reg [ADDR_WIDTH:0] wptr_rclk_m, wptr_rclk;
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wptr_rclk_m <= 0;
            wptr_rclk   <= 0;
        end else begin
            wptr_rclk_m <= wptr;
            wptr_rclk   <= wptr_rclk_m;
        end
    end

    // Full & Empty Flags (no combinational feedback)
    assign wfull  = (wptr == {~rptr_wclk[ADDR_WIDTH:ADDR_WIDTH-1], rptr_wclk[ADDR_WIDTH-2:0]});
    assign rempty = (rptr == wptr_rclk);

    // Convert synchronized rptr back to binary in wclk domain for wusedw
    reg [ADDR_WIDTH:0] rbin_wclk;
    integer i;
    always @(*) begin
        rbin_wclk[ADDR_WIDTH] = rptr_wclk[ADDR_WIDTH];
        for (i = ADDR_WIDTH - 1; i >= 0; i = i - 1)
            rbin_wclk[i] = rbin_wclk[i+1] ^ rptr_wclk[i];
    end

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n)
            wusedw <= 0;
        else
            wusedw <= wbin - rbin_wclk;
    end

endmodule