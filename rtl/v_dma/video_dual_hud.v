`timescale 1ns/1ps
// 2x 8x12 scan overlay: CPU: NN FPS (yellow), FPGA: NN FPS (green).
// FPS inputs are frame-stable packed BCD values, measured from actual swaps.
// Split and window bounds follow the 1280x720 scan geometry: the half-screen
// boundary is x=640 and the right overlay starts at 656 (= 640 + 16).
module video_dual_hud (
 input wire [11:0] x,
 input wire [10:0] y,
 input wire [7:0] cpu_fps_bcd, fpga_fps_bcd,
 output wire visible,
 output wire [23:0] rgb
);
wire right_half = x >= 684;
wire [11:0] local_x = x - (right_half ? 12'd700 : 12'd16);
wire [10:0] local_y = y - 11'd8;
wire [3:0] cell_index = local_x[7:4];
wire [3:0] row = local_y[4:1];
wire [2:0] col = local_x[3:1];
wire [7:0] fps = right_half ? fpga_fps_bcd : cpu_fps_bcd;
assign visible = (y>=8 && y<32) && (right_half ? (x>=700 && x<892) : (x>=16 && x<192));
reg [4:0] character;
always @* begin
 character=14;
 if(right_half) begin
  case(cell_index)
   0: character=10; 1: character=11; 2: character=17; 3: character=18;
   4: character=13; 6: character={1'b0,fps[7:4]}; 7: character={1'b0,fps[3:0]};
   9: character=10; 10: character=11; 11: character=12;
   default: character=14;
  endcase
 end else begin
  case(cell_index)
   0: character=15; 1: character=11; 2: character=16; 3: character=13;
   5: character={1'b0,fps[7:4]}; 6: character={1'b0,fps[3:0]};
   8: character=10; 9: character=11; 10: character=12;
   default: character=14;
  endcase
 end
end
reg [95:0] bitmap;
always @* begin
 case(character)
  5'd0: bitmap=96'h3c66c3c3c3c3c3c3c3c3663c;
  5'd1: bitmap=96'h18387818181818181818187e;
  5'd2: bitmap=96'h3c66c303060c183060c0c3ff;
  5'd3: bitmap=96'h3c66c303061c060303c3663c;
  5'd4: bitmap=96'h060e1e3666c6ff060606060f;
  5'd5: bitmap=96'hffc0c0c0fc06030303c3663c;
  5'd6: bitmap=96'h3c66c0c0fcc6c3c3c3c3663c;
  5'd7: bitmap=96'hffc306060c0c181830303030;
  5'd8: bitmap=96'h3c66c3c3663c66c3c3c3663c;
  5'd9: bitmap=96'h3c66c3c3c3c33f030303663c;
  5'd10: bitmap=96'hffc0c0c0fcc0c0c0c0c0c0c0;
  5'd11: bitmap=96'hfcc6c3c3c3c6fcc0c0c0c0c0;
  5'd12: bitmap=96'h3c66c3c0c0780e0303c3663c;
  5'd13: bitmap=96'h000018180000001818000000;
  5'd14: bitmap=96'h000000000000000000000000;
  5'd15: bitmap=96'h3c66c3c0c0c0c0c0c0c3663c;
  5'd16: bitmap=96'hc3c3c3c3c3c3c3c3c3c3663c;
  5'd17: bitmap=96'h3c66c3c0c0cfc3c3c3c3663e;
  5'd18: bitmap=96'h183c66c3c3c3ffc3c3c3c3c3;
  default: bitmap=0;
 endcase
end
wire [6:0] bit_index = 7'd95 - {row,3'b000} - {4'd0,col};
wire foreground = bitmap[bit_index];
assign rgb = foreground ? (right_half ? 24'h00ff00 : 24'hffff00) : (right_half ? 24'h0000ff : 24'h000000);
endmodule
