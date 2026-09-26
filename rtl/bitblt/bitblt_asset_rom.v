`timescale 1ns/1ps
// =============================================================================
// bitblt_asset_rom -- the backdrop RLE bank, shipped inside the bitstream.
//
// WHY THIS EXISTS
//   The three stage plates are RLE streams totalling 12,313 bytes.  They used
//   to live in .rodata, i.e. inside the firmware image in the SoC's own 64 KiB
//   on-chip RAM -- which had 80 bytes free.  DDR cannot hold them across a
//   power cycle, so the only non-volatile place the CPU can reach is the
//   bitstream itself: this BRAM is initialised from rtl/bitblt/bg_rle.hex at
//   configuration time (the same mechanism that pre-loads the Sapphire's own
//   system RAM from its four byte-lane .bin files), and the firmware copies it
//   to DDR once at boot through the APB window below.
//
//   Nothing here touches the BitBlt datapath.  It is a read-only window at two
//   addresses inside a peripheral the engine already owns, so the engine's
//   behaviour, its timing and its AXI traffic are all unchanged -- which
//   matters, because that engine renders every frame of the actual game.
//
// APB WINDOW (BitBlt peripheral, base 0xF8100000)
//   0x80  W  rom_addr[13:0]     select a byte
//   0x84  R  {24'd0, rom_data}  read it
//
//   Two accesses per byte, deliberately.  The ROM is a synchronous BRAM read,
//   so the byte for a freshly written address is only valid one clock later.
//   The one-access form would have to return the PREVIOUS address's byte, and
//   that is a silent off-by-one waiting to happen.  The firmware pays 12,313
//   extra APB writes once, at boot.
//
// INIT_FILE is one hex byte per line.  $readmemh loads one array element per
// line, so a packed line would load a 32-bit value into an 8-bit element.
// =============================================================================
`include "bg_rle_path.vh"

module bitblt_asset_rom #(
    parameter         INIT_FILE  = `BG_ROM_INIT_FILE,
    parameter integer ROM_BYTES  = 12313,
    parameter integer ADDR_WIDTH = 14
)(
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] addr,
    output reg  [7:0]            dout
);
    (* ramstyle = "block_ram" *) reg [7:0] mem [0:ROM_BYTES-1];
    integer i;
    initial begin
        for (i = 0; i < ROM_BYTES; i = i + 1) mem[i] = 8'h00;
        $readmemh(INIT_FILE, mem);
    end
    always @(posedge clk) dout <= mem[addr];
endmodule

