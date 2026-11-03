`timescale 1ns/1ps
// Bundled-data toggle handshake. Source holds all parameters after commit
// until acknowledge returns through its own two-flop synchronizer. The toggle
// has two destination synchronizer stages; data is sampled only at VBlank,
// after that settling interval. A whole packet is applied or none of it is.
module spell_beam_cdc (
    input wire pixel_clk,pixel_rst_n,
    input wire vblank,
    input wire commit,
    input wire [767:0] parameters,
    output reg acknowledge,
    output reg [767:0] latched
);
    (* async_reg = "true" *) reg commit_s1,commit_s2;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n)begin commit_s1<=0;commit_s2<=0;acknowledge<=0;latched<=0;end
        else begin
            commit_s1<=commit;commit_s2<=commit_s1;
            if(vblank && commit_s2!=acknowledge)begin
                latched<=parameters;acknowledge<=commit_s2;
            end
        end
    end
endmodule
