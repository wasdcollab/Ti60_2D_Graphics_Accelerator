`timescale 1ns/1ps
// =============================================================================
// simple_dual_read_ram -- one write port, TWO read ports, true dual port.
//
// WHY THIS EXISTS.  video_bullet_overlay.v looks up two tiles per pixel: the
// winning bucket entry's and the runner-up's, which is the entry the winner beat
// and the one that paints wherever the winner's own tile cell turns out to be
// transparent (role 0).  Both lookups are needed in the SAME pixel clock, so the
// store needs two read ports.
//
// The obvious way to get that is to instantiate simple_dual_port_ram twice, and
// that is what the first cut did.  It does not fit: the design packs to 257
// memory blocks in 256, and Efinity stops with
//
//     ERROR : Not enough physical locations for MEMORY blocks : capacity=256 usage=257
//
// WHY THE DEPTH IS EXACTLY WHAT THE STORE HOLDS.  The tile store's layout is
// 14,352 bytes - sixteen 26x26 enemy tiles at 832 bytes each, then the player
// shot, the orb with its ten transparent pad rows, and the missile.  Addressing
// it with a 14-bit address makes the tool build a 16,384-deep memory, which is
// 16 blocks, and two of those is one block too many for the device.
//
// So the array is declared at the depth it actually has.  Both ports still take
// a 14-bit address - the extra range is a don't-care that the live-candidate
// gating in the overlay never lets through - but the array the tool sizes is
// 14,352 deep, which is 15 blocks.  Two of those fit.
//
// TIMING is deliberately identical to simple_dual_port_ram with OUTPUT_REG="TRUE":
// one registered read, so the palette stage behind it still sees the tile byte
// exactly one cycle after the address.  Nothing about the overlay's five-stage
// pipeline changes.
//
// PORT A carries the write and read 0; port B carries read 1 only.  Writing is
// done once at boot through the APB clock, reading happens every pixel clock,
// and each port keeps its own clock so the two never have to be related.
// =============================================================================
module simple_dual_read_ram #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 14,
    // Entries the store actually holds.  See the header: this is what decides
    // how many memory blocks the tool builds, and it is the whole reason this
    // module exists rather than two copies of the single-read one.
    parameter DEPTH = 14352
)(
    input  wire                  wclk,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata,

    input  wire                  rclk,
    input  wire [ADDR_WIDTH-1:0] raddr0,
    input  wire [ADDR_WIDTH-1:0] raddr1,
    output reg  [DATA_WIDTH-1:0] rdata0,
    output reg  [DATA_WIDTH-1:0] rdata1
);

    reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];

    // Port A: write, plus read 0.  Two clocks on purpose - the write comes from
    // the config side at boot and the read happens per pixel.
    always @(posedge wclk)
        if (we)
            ram[waddr] <= wdata;

    always @(posedge rclk) begin
        rdata0 <= ram[raddr0];
        rdata1 <= ram[raddr1];
    end

endmodule
