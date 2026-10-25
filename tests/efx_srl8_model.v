`timescale 1ns/1ps
// =============================================================================
// EFX_SRL8 -- simulation model of the Titanium 8-bit addressable shift register.
//
// Axi_Mux builds its AR-to-R queue out of EFX_SRL8 primitives. Without this file
// tb_axi_mux_rd cannot be elaborated by Verilator or iverilog at all
// (MODMISSING: Cannot find file containing module: 'EFX_SRL8'), which is one of
// the reasons that bench had no run script and was never executed.
//
//   A  [2:0] : selects which of the eight bits Q presents
//   D        : data in, shifted in on every enabled clock
//   Q7       : the far end of the register, used to cascade primitives
//              (Axi_Mux feeds stage i from stage i+1's Q7)
//
// Checked against Efinity 2026.1 sim_models/verilog/efx_srl8.v:
// D shifts into bit 0; Q is inverted and its address is reversed. Q7 is raw.
// These details are required by the mux's inverted data and depth-based tap.
// =============================================================================
module EFX_SRL8 #(
    parameter CLK_POLARITY = 1'b1,
    parameter CE_POLARITY  = 1'b1,
    parameter [7:0] INIT   = 8'h00
) (
    input  wire [2:0] A,
    input  wire       D,
    input  wire       CLK,
    input  wire       CE,
    output wire       Q,
    output wire       Q7
);
    reg [7:0] sr;
    initial sr = INIT;
    wire clk_eff = CLK_POLARITY ? CLK : ~CLK;
    wire ce_eff  = CE_POLARITY  ? CE  : ~CE;
    always @(posedge clk_eff)
        if (ce_eff) sr <= {sr[6:0], D};
    assign Q  = ~sr[3'd7 - A];
    assign Q7 = sr[7];
endmodule
