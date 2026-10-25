`timescale 1ns/1ps
// =============================================================================
// lut_dual_port_ram -- a 256 x 32 palette that MUST NOT become a block memory.
//
// WHY.  video_bullet_overlay.v reads two tiles per pixel now (the winning bucket
// entry and the runner-up it beat), so the tile store is instantiated twice and
// the design lands one memory block over the device:
//
//     ERROR : Not enough physical locations for MEMORY blocks : capacity=256 usage=257
//
// The palette is 256 entries of 32 bits, it is worth 2 blocks in this device, and
// it is the only memory here that can be given up without touching the picture or
// the DDR interface.  Built from registers it costs LUTs, and LUTs are what this
// design has spare.
//
// WHY A CASE STATEMENT rather than a plain ram[raddr] read.  A register array
// read by an address IS how a block memory gets inferred - that is exactly what
// happened to the first two attempts, and the ram_style attribute did not stop
// it.  An explicit 256-way case is a multiplexer and nothing else, so the tool
// has no memory to build.  The list is written out by tools/gen_lut_ram.py.
//
// Timing: one registered read, exactly as the block-RAM version was, so the
// palette stage behind it does not change.
// =============================================================================
module lut_dual_port_ram #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 8
)(
    input  wire                  wclk,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata,

    input  wire                  rclk,
    input  wire [ADDR_WIDTH-1:0] raddr,
    output reg  [DATA_WIDTH-1:0] rdata
);

    reg [DATA_WIDTH-1:0] mem [0:255];
    reg [DATA_WIDTH-1:0] rd;

    integer i;
    initial
        for (i = 0; i < 256; i = i + 1)
            mem[i] = {DATA_WIDTH{1'b0}};

    always @(posedge wclk)
        if (we)
            mem[waddr] <= wdata;

    // The 256-way select.  This is a mux, not a memory.
    always @(*) begin
        case (raddr)
            8'd0: rd = mem[0];
            8'd1: rd = mem[1];
            8'd2: rd = mem[2];
            8'd3: rd = mem[3];
            8'd4: rd = mem[4];
            8'd5: rd = mem[5];
            8'd6: rd = mem[6];
            8'd7: rd = mem[7];
            8'd8: rd = mem[8];
            8'd9: rd = mem[9];
            8'd10: rd = mem[10];
            8'd11: rd = mem[11];
            8'd12: rd = mem[12];
            8'd13: rd = mem[13];
            8'd14: rd = mem[14];
            8'd15: rd = mem[15];
            8'd16: rd = mem[16];
            8'd17: rd = mem[17];
            8'd18: rd = mem[18];
            8'd19: rd = mem[19];
            8'd20: rd = mem[20];
            8'd21: rd = mem[21];
            8'd22: rd = mem[22];
            8'd23: rd = mem[23];
            8'd24: rd = mem[24];
            8'd25: rd = mem[25];
            8'd26: rd = mem[26];
            8'd27: rd = mem[27];
            8'd28: rd = mem[28];
            8'd29: rd = mem[29];
            8'd30: rd = mem[30];
            8'd31: rd = mem[31];
            8'd32: rd = mem[32];
            8'd33: rd = mem[33];
            8'd34: rd = mem[34];
            8'd35: rd = mem[35];
            8'd36: rd = mem[36];
            8'd37: rd = mem[37];
            8'd38: rd = mem[38];
            8'd39: rd = mem[39];
            8'd40: rd = mem[40];
            8'd41: rd = mem[41];
            8'd42: rd = mem[42];
            8'd43: rd = mem[43];
            8'd44: rd = mem[44];
            8'd45: rd = mem[45];
            8'd46: rd = mem[46];
            8'd47: rd = mem[47];
            8'd48: rd = mem[48];
            8'd49: rd = mem[49];
            8'd50: rd = mem[50];
            8'd51: rd = mem[51];
            8'd52: rd = mem[52];
            8'd53: rd = mem[53];
            8'd54: rd = mem[54];
            8'd55: rd = mem[55];
            8'd56: rd = mem[56];
            8'd57: rd = mem[57];
            8'd58: rd = mem[58];
            8'd59: rd = mem[59];
            8'd60: rd = mem[60];
            8'd61: rd = mem[61];
            8'd62: rd = mem[62];
            8'd63: rd = mem[63];
            8'd64: rd = mem[64];
            8'd65: rd = mem[65];
            8'd66: rd = mem[66];
            8'd67: rd = mem[67];
            8'd68: rd = mem[68];
            8'd69: rd = mem[69];
            8'd70: rd = mem[70];
            8'd71: rd = mem[71];
            8'd72: rd = mem[72];
            8'd73: rd = mem[73];
            8'd74: rd = mem[74];
            8'd75: rd = mem[75];
            8'd76: rd = mem[76];
            8'd77: rd = mem[77];
            8'd78: rd = mem[78];
            8'd79: rd = mem[79];
            8'd80: rd = mem[80];
            8'd81: rd = mem[81];
            8'd82: rd = mem[82];
            8'd83: rd = mem[83];
            8'd84: rd = mem[84];
            8'd85: rd = mem[85];
            8'd86: rd = mem[86];
            8'd87: rd = mem[87];
            8'd88: rd = mem[88];
            8'd89: rd = mem[89];
            8'd90: rd = mem[90];
            8'd91: rd = mem[91];
            8'd92: rd = mem[92];
            8'd93: rd = mem[93];
            8'd94: rd = mem[94];
            8'd95: rd = mem[95];
            8'd96: rd = mem[96];
            8'd97: rd = mem[97];
            8'd98: rd = mem[98];
            8'd99: rd = mem[99];
            8'd100: rd = mem[100];
            8'd101: rd = mem[101];
            8'd102: rd = mem[102];
            8'd103: rd = mem[103];
            8'd104: rd = mem[104];
            8'd105: rd = mem[105];
            8'd106: rd = mem[106];
            8'd107: rd = mem[107];
            8'd108: rd = mem[108];
            8'd109: rd = mem[109];
            8'd110: rd = mem[110];
            8'd111: rd = mem[111];
            8'd112: rd = mem[112];
            8'd113: rd = mem[113];
            8'd114: rd = mem[114];
            8'd115: rd = mem[115];
            8'd116: rd = mem[116];
            8'd117: rd = mem[117];
            8'd118: rd = mem[118];
            8'd119: rd = mem[119];
            8'd120: rd = mem[120];
            8'd121: rd = mem[121];
            8'd122: rd = mem[122];
            8'd123: rd = mem[123];
            8'd124: rd = mem[124];
            8'd125: rd = mem[125];
            8'd126: rd = mem[126];
            8'd127: rd = mem[127];
            8'd128: rd = mem[128];
            8'd129: rd = mem[129];
            8'd130: rd = mem[130];
            8'd131: rd = mem[131];
            8'd132: rd = mem[132];
            8'd133: rd = mem[133];
            8'd134: rd = mem[134];
            8'd135: rd = mem[135];
            8'd136: rd = mem[136];
            8'd137: rd = mem[137];
            8'd138: rd = mem[138];
            8'd139: rd = mem[139];
            8'd140: rd = mem[140];
            8'd141: rd = mem[141];
            8'd142: rd = mem[142];
            8'd143: rd = mem[143];
            8'd144: rd = mem[144];
            8'd145: rd = mem[145];
            8'd146: rd = mem[146];
            8'd147: rd = mem[147];
            8'd148: rd = mem[148];
            8'd149: rd = mem[149];
            8'd150: rd = mem[150];
            8'd151: rd = mem[151];
            8'd152: rd = mem[152];
            8'd153: rd = mem[153];
            8'd154: rd = mem[154];
            8'd155: rd = mem[155];
            8'd156: rd = mem[156];
            8'd157: rd = mem[157];
            8'd158: rd = mem[158];
            8'd159: rd = mem[159];
            8'd160: rd = mem[160];
            8'd161: rd = mem[161];
            8'd162: rd = mem[162];
            8'd163: rd = mem[163];
            8'd164: rd = mem[164];
            8'd165: rd = mem[165];
            8'd166: rd = mem[166];
            8'd167: rd = mem[167];
            8'd168: rd = mem[168];
            8'd169: rd = mem[169];
            8'd170: rd = mem[170];
            8'd171: rd = mem[171];
            8'd172: rd = mem[172];
            8'd173: rd = mem[173];
            8'd174: rd = mem[174];
            8'd175: rd = mem[175];
            8'd176: rd = mem[176];
            8'd177: rd = mem[177];
            8'd178: rd = mem[178];
            8'd179: rd = mem[179];
            8'd180: rd = mem[180];
            8'd181: rd = mem[181];
            8'd182: rd = mem[182];
            8'd183: rd = mem[183];
            8'd184: rd = mem[184];
            8'd185: rd = mem[185];
            8'd186: rd = mem[186];
            8'd187: rd = mem[187];
            8'd188: rd = mem[188];
            8'd189: rd = mem[189];
            8'd190: rd = mem[190];
            8'd191: rd = mem[191];
            8'd192: rd = mem[192];
            8'd193: rd = mem[193];
            8'd194: rd = mem[194];
            8'd195: rd = mem[195];
            8'd196: rd = mem[196];
            8'd197: rd = mem[197];
            8'd198: rd = mem[198];
            8'd199: rd = mem[199];
            8'd200: rd = mem[200];
            8'd201: rd = mem[201];
            8'd202: rd = mem[202];
            8'd203: rd = mem[203];
            8'd204: rd = mem[204];
            8'd205: rd = mem[205];
            8'd206: rd = mem[206];
            8'd207: rd = mem[207];
            8'd208: rd = mem[208];
            8'd209: rd = mem[209];
            8'd210: rd = mem[210];
            8'd211: rd = mem[211];
            8'd212: rd = mem[212];
            8'd213: rd = mem[213];
            8'd214: rd = mem[214];
            8'd215: rd = mem[215];
            8'd216: rd = mem[216];
            8'd217: rd = mem[217];
            8'd218: rd = mem[218];
            8'd219: rd = mem[219];
            8'd220: rd = mem[220];
            8'd221: rd = mem[221];
            8'd222: rd = mem[222];
            8'd223: rd = mem[223];
            8'd224: rd = mem[224];
            8'd225: rd = mem[225];
            8'd226: rd = mem[226];
            8'd227: rd = mem[227];
            8'd228: rd = mem[228];
            8'd229: rd = mem[229];
            8'd230: rd = mem[230];
            8'd231: rd = mem[231];
            8'd232: rd = mem[232];
            8'd233: rd = mem[233];
            8'd234: rd = mem[234];
            8'd235: rd = mem[235];
            8'd236: rd = mem[236];
            8'd237: rd = mem[237];
            8'd238: rd = mem[238];
            8'd239: rd = mem[239];
            8'd240: rd = mem[240];
            8'd241: rd = mem[241];
            8'd242: rd = mem[242];
            8'd243: rd = mem[243];
            8'd244: rd = mem[244];
            8'd245: rd = mem[245];
            8'd246: rd = mem[246];
            8'd247: rd = mem[247];
            8'd248: rd = mem[248];
            8'd249: rd = mem[249];
            8'd250: rd = mem[250];
            8'd251: rd = mem[251];
            8'd252: rd = mem[252];
            8'd253: rd = mem[253];
            8'd254: rd = mem[254];
            8'd255: rd = mem[255];
            default: rd = {DATA_WIDTH{1'b0}};
        endcase
    end

    always @(posedge rclk)
        rdata <= rd;

endmodule

