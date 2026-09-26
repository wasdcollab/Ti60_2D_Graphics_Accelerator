`timescale 1ns/1ps
// =============================================================================
// bitblt_read_fifo  (v3 - block RAM based, first-word fall-through)
// -----------------------------------------------------------------------------
// WHY THIS EXISTS
//   v2 used a combinational read (`assign rdata = mem[raddr]`).  Elitestek
//   cannot infer a block RAM from that and falls back to plain flip-flops plus a
//   wide read multiplexer: the 256 x 128 array alone became 32768 FFs, which is
//   more than half of the Ti60F225 and put the whole design 28% over capacity
//   ("Not enough physical locations for Logic blocks : capacity=60800
//   usage=77647").
//
//   This version keeps the exact external behaviour - data is visible on
//   `rdata` whenever `rempty` is low, and `rinc` pops one entry - but stores the
//   payload in a simple dual-port block RAM:
//
//     mem   : 2**ADDR_WIDTH x DATA_WIDTH, synchronous write, synchronous read
//             (one clock of read latency, matching the vendor BRAM model
//              `r_rdata_1P <= ram[raddr]` inside efx_fifo_wrapper)
//     hold  : fall-through register holding the current head
//
//   `hold` is prefetched one entry ahead of the consumer, so the FIFO still
//   sustains one pop per cycle; `rempty` additionally requires `hold_v`, which
//   hides the one cycle between "a word was written" and "the word is on the
//   read port".
//
// Counts
//   count    = entries in the RAM + (hold_v ? 1 : 0)
//   br_count = count - hold_v = entries still inside the RAM
// =============================================================================
module bitblt_read_fifo #(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 8,           // 2**ADDR_WIDTH storage entries
    parameter DEPTH      = 256          // usable depth (<= 2**ADDR_WIDTH)
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  clr,

    // write side (AXI read master)
    input  wire                  winc,
    input  wire [DATA_WIDTH-1:0] wdata,
    output wire                  wfull,
    output wire [ADDR_WIDTH:0]   wusedw,

    // read side (alignment shifter)
    input  wire                  rinc,
    output wire [DATA_WIDTH-1:0] rdata,
    output wire                  rempty,
    output wire [ADDR_WIDTH:0]   rusedw,

    output wire [ADDR_WIDTH:0]   used
);

    localparam integer MEM_DEPTH = (1 << ADDR_WIDTH);

    (* ramstyle = "block_ram" *) reg [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

    reg [ADDR_WIDTH-1:0] waddr;      // write pointer
    reg [ADDR_WIDTH-1:0] raddr;      // address of the next entry to prefetch
    reg [ADDR_WIDTH:0]   count;      // RAM entries + hold
    reg [DATA_WIDTH-1:0] hold;       // fall-through head
    reg                  hold_v;     // hold contains a valid entry

    wire wpush = winc && !wfull;
    wire rpop  = rinc && !rempty;

    wire [ADDR_WIDTH:0] br_count = count - {{ADDR_WIDTH{1'b0}}, hold_v};
    wire prefetch = (br_count != 0) && (!hold_v || rpop);

    assign wfull  = (count == DEPTH[ADDR_WIDTH:0]);
    assign rempty = (count == 0) || !hold_v;
    assign rdata  = hold;
    assign used   = count;
    assign wusedw = count;
    assign rusedw = count;

    // ---- simple dual-port block RAM -----------------------------------------
    always @(posedge clk) begin
        if (wpush)
            mem[waddr] <= wdata;
    end

    always @(posedge clk) begin
        if (prefetch)
            hold <= mem[raddr];
    end

    // ---- pointers -----------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            waddr  <= {ADDR_WIDTH{1'b0}};
            raddr  <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
            hold_v <= 1'b0;
        end else if (clr) begin
            waddr  <= {ADDR_WIDTH{1'b0}};
            raddr  <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
            hold_v <= 1'b0;
        end else begin
            if (wpush)    waddr <= waddr + 1'b1;
            if (prefetch) raddr <= raddr + 1'b1;

            count <= count + (wpush ? 1'b1 : 1'b0) - (rpop ? 1'b1 : 1'b0);

            if (prefetch)  hold_v <= 1'b1;
            else if (rpop) hold_v <= 1'b0;
        end
    end

endmodule
