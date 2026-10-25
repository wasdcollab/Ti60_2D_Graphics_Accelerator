`timescale 1ns/1ps
// Autonomous right-half renderer. Each completed frame waits for its own
// scan acknowledgement, independently of CPU progress on the left half.
// NOT INSTANTIATED, AND ITS GEOMETRY IS FROM AN OLDER SCREEN.
//
// Nothing in the project instantiates this module: the name appears in its own
// module declaration and nowhere else, so it does not reach the bitstream.
//
// If it is ever wired up, every constant in it has to be re-derived first - it
// was written for the 1024x600 screen and still carries that geometry:
//   * x bound 1024 and y bound 1200 (the screen is 1366x768),
//   * a 512x600 clear rectangle (the screen is 1366x768),
//   * row addresses as (y/2)*4096 (the framebuffer pitch is 8192).
// Wired up unchanged, sprites would walk off screen, each line's bytes would
// only be half covered, and 600 of the 768 rows would be cleared.

module bitblt_demo_scheduler (
 input wire clk, rst_n, enable,
 input wire [27:0] active_base,
 input wire fill_busy,
 output wire owns_engine,
 output reg start,
 output reg [27:0] dst,
 output reg [10:0] width, height,
 output reg [31:0] color,
 output reg [27:0] next_base
);
localparam OFF=0, INIT=1, PAIR=2, MOVE=3, CLEAR=4, BOX=5,
           LAUNCH=6, BUSY=7, DONE=8, PUBLISH=9, SWAP=10;
reg [3:0] state;
reg [4:0] i,j,index;
reg clearing;
reg [27:0] back_base;
// Half-pixel positions give the 60-Hz side half the displacement per update.
reg signed [11:0] x[0:29], y[0:29];
reg signed [7:0] vx[0:29], vy[0:29];
reg [5:0] size[0:29];
assign owns_engine = (state != OFF);
function [11:0] initial_x;
 input [4:0] n;
 begin case(n)
  5'd0: initial_x = 12'h8c;
  5'd1: initial_x = 12'h216;
  5'd2: initial_x = 12'h39c;
  5'd3: initial_x = 12'h3a8;
  5'd4: initial_x = 12'h290;
  5'd5: initial_x = 12'h1c2;
  5'd6: initial_x = 12'h314;
  5'd7: initial_x = 12'h108;
  5'd8: initial_x = 12'h288;
  5'd9: initial_x = 12'h84;
  5'd10: initial_x = 12'h358;
  5'd11: initial_x = 12'h1e0;
  5'd12: initial_x = 12'h356;
  5'd13: initial_x = 12'h2d0;
  5'd14: initial_x = 12'h2ca;
  5'd15: initial_x = 12'hea;
  5'd16: initial_x = 12'h114;
  5'd17: initial_x = 12'h180;
  5'd18: initial_x = 12'h220;
  5'd19: initial_x = 12'h62;
  5'd20: initial_x = 12'h170;
  5'd21: initial_x = 12'h24e;
  5'd22: initial_x = 12'h13a;
  5'd23: initial_x = 12'ha4;
  5'd24: initial_x = 12'h2a8;
  5'd25: initial_x = 12'h2f0;
  5'd26: initial_x = 12'h2c;
  5'd27: initial_x = 12'h188;
  5'd28: initial_x = 12'h1c4;
  5'd29: initial_x = 12'h1ac;
  default: initial_x = 0;
 endcase end
endfunction
function [11:0] initial_y;
 input [4:0] n;
 begin case(n)
  5'd0: initial_y = 12'h2e8;
  5'd1: initial_y = 12'h12c;
  5'd2: initial_y = 12'h13e;
  5'd3: initial_y = 12'h2c0;
  5'd4: initial_y = 12'h292;
  5'd5: initial_y = 12'h446;
  5'd6: initial_y = 12'h3e0;
  5'd7: initial_y = 12'h5c;
  5'd8: initial_y = 12'hac;
  5'd9: initial_y = 12'h180;
  5'd10: initial_y = 12'h122;
  5'd11: initial_y = 12'h70;
  5'd12: initial_y = 12'h3ea;
  5'd13: initial_y = 12'h250;
  5'd14: initial_y = 12'h19a;
  5'd15: initial_y = 12'h386;
  5'd16: initial_y = 12'h322;
  5'd17: initial_y = 12'h392;
  5'd18: initial_y = 12'h2e6;
  5'd19: initial_y = 12'h33e;
  5'd20: initial_y = 12'h110;
  5'd21: initial_y = 12'h2b0;
  5'd22: initial_y = 12'h22e;
  5'd23: initial_y = 12'h3da;
  5'd24: initial_y = 12'h32a;
  5'd25: initial_y = 12'h2d2;
  5'd26: initial_y = 12'h34c;
  5'd27: initial_y = 12'h232;
  5'd28: initial_y = 12'hb6;
  5'd29: initial_y = 12'h3ea;
  default: initial_y = 0;
 endcase end
endfunction
function [7:0] initial_vx;
 input [4:0] n;
 begin case(n)
  5'd0: initial_vx = 8'h2;
  5'd1: initial_vx = 8'hfe;
  5'd2: initial_vx = 8'h3;
  5'd3: initial_vx = 8'hfd;
  5'd4: initial_vx = 8'h1;
  5'd5: initial_vx = 8'hff;
  5'd6: initial_vx = 8'h4;
  5'd7: initial_vx = 8'hfc;
  5'd8: initial_vx = 8'h2;
  5'd9: initial_vx = 8'hfe;
  5'd10: initial_vx = 8'h3;
  5'd11: initial_vx = 8'hfd;
  5'd12: initial_vx = 8'h1;
  5'd13: initial_vx = 8'hff;
  5'd14: initial_vx = 8'h4;
  5'd15: initial_vx = 8'hfc;
  5'd16: initial_vx = 8'h2;
  5'd17: initial_vx = 8'hfe;
  5'd18: initial_vx = 8'h3;
  5'd19: initial_vx = 8'hfd;
  5'd20: initial_vx = 8'h1;
  5'd21: initial_vx = 8'hff;
  5'd22: initial_vx = 8'h4;
  5'd23: initial_vx = 8'hfc;
  5'd24: initial_vx = 8'h2;
  5'd25: initial_vx = 8'hfe;
  5'd26: initial_vx = 8'h3;
  5'd27: initial_vx = 8'hfd;
  5'd28: initial_vx = 8'h1;
  5'd29: initial_vx = 8'hff;
  default: initial_vx = 0;
 endcase end
endfunction
function [7:0] initial_vy;
 input [4:0] n;
 begin case(n)
  5'd0: initial_vy = 8'hfd;
  5'd1: initial_vy = 8'h3;
  5'd2: initial_vy = 8'hff;
  5'd3: initial_vy = 8'h2;
  5'd4: initial_vy = 8'hfc;
  5'd5: initial_vy = 8'h3;
  5'd6: initial_vy = 8'hfe;
  5'd7: initial_vy = 8'h2;
  5'd8: initial_vy = 8'hfd;
  5'd9: initial_vy = 8'h3;
  5'd10: initial_vy = 8'hff;
  5'd11: initial_vy = 8'h2;
  5'd12: initial_vy = 8'hfc;
  5'd13: initial_vy = 8'h3;
  5'd14: initial_vy = 8'hfe;
  5'd15: initial_vy = 8'h2;
  5'd16: initial_vy = 8'hfd;
  5'd17: initial_vy = 8'h3;
  5'd18: initial_vy = 8'hff;
  5'd19: initial_vy = 8'h2;
  5'd20: initial_vy = 8'hfc;
  5'd21: initial_vy = 8'h3;
  5'd22: initial_vy = 8'hfe;
  5'd23: initial_vy = 8'h2;
  5'd24: initial_vy = 8'hfd;
  5'd25: initial_vy = 8'h3;
  5'd26: initial_vy = 8'hff;
  5'd27: initial_vy = 8'h2;
  5'd28: initial_vy = 8'hfc;
  5'd29: initial_vy = 8'h3;
  default: initial_vy = 0;
 endcase end
endfunction
function [5:0] initial_size;
 input [4:0] n;
 begin case(n)
  5'd0: initial_size = 6'h14;
  5'd1: initial_size = 6'h17;
  5'd2: initial_size = 6'h1a;
  5'd3: initial_size = 6'h1d;
  5'd4: initial_size = 6'h20;
  5'd5: initial_size = 6'h14;
  5'd6: initial_size = 6'h17;
  5'd7: initial_size = 6'h1a;
  5'd8: initial_size = 6'h1d;
  5'd9: initial_size = 6'h20;
  5'd10: initial_size = 6'h14;
  5'd11: initial_size = 6'h17;
  5'd12: initial_size = 6'h1a;
  5'd13: initial_size = 6'h1d;
  5'd14: initial_size = 6'h20;
  5'd15: initial_size = 6'h14;
  5'd16: initial_size = 6'h17;
  5'd17: initial_size = 6'h1a;
  5'd18: initial_size = 6'h1d;
  5'd19: initial_size = 6'h20;
  5'd20: initial_size = 6'h14;
  5'd21: initial_size = 6'h17;
  5'd22: initial_size = 6'h1a;
  5'd23: initial_size = 6'h1d;
  5'd24: initial_size = 6'h20;
  5'd25: initial_size = 6'h14;
  5'd26: initial_size = 6'h17;
  5'd27: initial_size = 6'h1a;
  5'd28: initial_size = 6'h1d;
  5'd29: initial_size = 6'h20;
  default: initial_size = 0;
 endcase end
endfunction
function [31:0] box_color;
 input [4:0] n;
 begin case(n)
  5'd0: box_color = 32'hff0000;
  5'd1: box_color = 32'hff00;
  5'd2: box_color = 32'hffff00;
  5'd3: box_color = 32'hffff;
  5'd4: box_color = 32'hff00ff;
  5'd5: box_color = 32'hffa500;
  5'd6: box_color = 32'hffffff;
  5'd7: box_color = 32'hff7f;
  5'd8: box_color = 32'hff1493;
  5'd9: box_color = 32'h7fff00;
  5'd10: box_color = 32'hff4500;
  5'd11: box_color = 32'hced1;
  5'd12: box_color = 32'hffd700;
  5'd13: box_color = 32'hadff2f;
  5'd14: box_color = 32'hff69b4;
  5'd15: box_color = 32'he0ffff;
  5'd16: box_color = 32'h9370db;
  5'd17: box_color = 32'h32cd32;
  5'd18: box_color = 32'hff6347;
  5'd19: box_color = 32'h40e0d0;
  5'd20: box_color = 32'hee82ee;
  5'd21: box_color = 32'hf0e68c;
  5'd22: box_color = 32'h87ceeb;
  5'd23: box_color = 32'hffb6c1;
  5'd24: box_color = 32'h98fb98;
  5'd25: box_color = 32'hdda0dd;
  5'd26: box_color = 32'hffa07a;
  5'd27: box_color = 32'h20b2aa;
  5'd28: box_color = 32'h87cefa;
  5'd29: box_color = 32'hff8c00;
  default: box_color = 0;
 endcase end
endfunction
wire signed [12:0] xi_end = $signed(x[i]) + $signed({6'd0,size[i],1'b0});
wire signed [12:0] xj_end = $signed(x[j]) + $signed({6'd0,size[j],1'b0});
wire signed [12:0] yi_end = $signed(y[i]) + $signed({6'd0,size[i],1'b0});
wire signed [12:0] yj_end = $signed(y[j]) + $signed({6'd0,size[j],1'b0});
wire overlap = ($signed(x[i]) < xj_end) && ($signed(x[j]) < xi_end) &&
               ($signed(y[i]) < yj_end) && ($signed(y[j]) < yi_end);
wire signed [12:0] dx = $signed(x[i]) - $signed(x[j]);
wire signed [12:0] dy = $signed(y[i]) - $signed(y[j]);
wire signed [8:0] dvx = $signed(vx[i]) - $signed(vx[j]);
wire signed [8:0] dvy = $signed(vy[i]) - $signed(vy[j]);
wire signed [12:0] nx = $signed(x[index]) + $signed(vx[index]);
wire signed [12:0] ny = $signed(y[index]) + $signed(vy[index]);
wire signed [12:0] max_x = 13'sd1024 - $signed({6'd0,size[index],1'b0});
wire signed [12:0] max_y = 13'sd1200 - $signed({6'd0,size[index],1'b0});
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  state<=OFF; i<=0; j<=1; index<=0; clearing<=0;
  back_base<=28'h01300000; next_base<=28'h01000000;
  start<=0; dst<=0; width<=0; height<=0; color<=0;
 end else begin
  start<=0;
  case(state)
   OFF: if(enable && !fill_busy) begin index<=0; state<=INIT; end
   INIT: begin
    x[index]<=initial_x(index); y[index]<=initial_y(index);
    vx[index]<=initial_vx(index); vy[index]<=initial_vy(index);
    size[index]<=initial_size(index);
    if(index==29) begin i<=0; j<=1; index<=0; state<=PAIR; end
    else index<=index+1'b1;
   end
   PAIR: begin
    if(overlap) begin
     if(dx[12] ^ dvx[8]) begin vx[i]<=vx[j]; vx[j]<=vx[i]; end
     if(dy[12] ^ dvy[8]) begin vy[i]<=vy[j]; vy[j]<=vy[i]; end
    end
    if(j==29) begin
     if(i==28) begin index<=0; state<=MOVE; end
     else begin i<=i+1'b1; j<=i+2'd2; end
    end else j<=j+1'b1;
   end
   MOVE: begin
    if(nx<0) begin x[index]<=0; vx[index]<=-vx[index]; end
    else if(nx>max_x) begin x[index]<=max_x[11:0]; vx[index]<=-vx[index]; end
    else x[index]<=nx[11:0];
    if(ny<72) begin y[index]<=72; vy[index]<=-vy[index]; end
    else if(ny>max_y) begin y[index]<=max_y[11:0]; vy[index]<=-vy[index]; end
    else y[index]<=ny[11:0];
    if(index==29) begin index<=0; state<=CLEAR; end
    else index<=index+1'b1;
   end
   CLEAR: begin
    dst<=back_base+28'd2048; width<=512; height<=600; color<=32'hff;
    clearing<=1; state<=LAUNCH;
   end
   BOX: begin
    dst<=back_base+28'd2048+{5'd0,y[index][11:1],12'd0}+{15'd0,x[index][11:1],2'd0};
    width<={5'd0,size[index]}; height<={5'd0,size[index]}; color<=box_color(index);
    clearing<=0; state<=LAUNCH;
   end
   LAUNCH: if(!fill_busy) begin start<=1; state<=BUSY; end
   BUSY: if(fill_busy) state<=DONE;
   DONE: if(!fill_busy) begin
    if(clearing) begin index<=0; state<=BOX; end
    else if(index==29) state<=PUBLISH;
    else begin index<=index+1'b1; state<=BOX; end
   end
   PUBLISH: begin next_base<=back_base; state<=SWAP; end
   SWAP: if(active_base==back_base) begin
    back_base<=back_base ^ 28'h00300000;
    if(enable) begin i<=0; j<=1; state<=PAIR; end
    else state<=OFF;
   end
   default: state<=OFF;
  endcase
 end
end
endmodule
