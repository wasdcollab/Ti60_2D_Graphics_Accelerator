`timescale 1ns/1ps
// Keep the wide cross product local to each DSP pair and carry
// only a three-bit light profile into the compositor priority stage.
// Active raster: x<2048, y<1024 (1366x768, total 1456x782). Parameters
// remain stable during active video through the upstream VBlank handshake.
module video_spell_beams (
    input wire pixel_clk,pixel_rst_n,input wire [11:0] x,input wire [10:0] y,
    input wire de,input wire [767:0] p,input wire [31:0] mask_x,mask_y,
    output reg visible,add,output reg [7:0] alpha,output reg [23:0] rgb
);
    reg [2:0] profile [0:5];reg valid_a;
    wire in_box=mask_x[31] && x>={1'b0,mask_x[10:0]} && x<={1'b0,mask_x[21:11]} && y>=mask_y[10:0] && y<=mask_y[21:11];
    always @(posedge pixel_clk)valid_a<=de && x>=181 && x<1185 && !in_box;
    genvar i;
    generate for(i=0;i<6;i=i+1)begin:g_beam
        wire signed [11:0] dx=$signed({1'b0,x[10:0]})-$signed({1'b0,p[i*128+:11]});
        wire signed [10:0] dy=$signed({1'b0,y[9:0]})-$signed({1'b0,p[i*128+11+:10]});
        wire signed [9:0] nx=p[i*128+32+:10],ny=p[i*128+48+:10];
        wire signed [21:0] xp=dx*ny;
        wire signed [20:0] yp=dy*nx;
        wire signed [23:0] cross_value=$signed({{2{xp[21]}},xp})-$signed({{3{yp[20]}},yp});
        wire [23:0] distance=cross_value[23] ? -cross_value : cross_value;
        wire [23:0] half_width={13'd0,p[i*128+104+:4],7'd0};
        wire [9:0] ax=nx[9] ? -nx : nx,ay=ny[9] ? -ny : ny;
        wire dash=ax>=ay ? x[3] : y[3];
        reg [2:0] code;
        always @* begin
            code=0;
            if(p[i*128+31] && p[i*128+104+:4]!=0 && p[i*128+96+:8]!=0 && (nx!=0 || ny!=0)) begin
                if(p[i*128+30])begin if(distance<=256 && dash)code=6;end
                else if(distance<=(half_width>>1))code=1;
                else if(distance<=half_width)code=2;
                else if(distance<=half_width+1024)code=3;
                else if(distance<=half_width+2048)code=4;
                else if(distance<=half_width+3072)code=5;
            end
        end
        always @(posedge pixel_clk)profile[i]<=code;
    end endgenerate
    wire [5:0] covered,winner;
    generate for(i=0;i<6;i=i+1)begin:g_pick
        assign covered[i]=profile[i]!=0;
        if(i==0)assign winner[i]=covered[i];
        else assign winner[i]=covered[i] && !(|covered[i-1:0]);
    end endgenerate
    integer k;
    reg [23:0] raw_color,color;reg [7:0] gain;reg [2:0] kind;
    reg [15:0] red,green,blue;
    always @* begin
        raw_color=0;gain=0;kind=0;
        for(k=0;k<6;k=k+1)begin
            raw_color=raw_color|(p[k*128+64+:24]&{24{winner[k]}});
            gain=gain|(p[k*128+96+:8]&{8{winner[k]}});
            kind=kind|(profile[k]&{3{winner[k]}});
        end
        case(kind)
            1:color=24'hffffff;
            3:color=(raw_color>>1)&24'h7f7f7f;
            4:color=(raw_color>>2)&24'h3f3f3f;
            5:color=(raw_color>>3)&24'h1f1f1f;
            default:color=raw_color;
        endcase
        red=color[23:16]*gain;green=color[15:8]*gain;blue=color[7:0]*gain;
    end
    always @(posedge pixel_clk or negedge pixel_rst_n)begin
        if(!pixel_rst_n)begin visible<=0;add<=0;alpha<=0;rgb<=0;end
        else if(valid_a && (|covered))begin
            visible<=1;add<=kind!=6;alpha<=kind==6?8'd210:8'd255;rgb<={red[15:8],green[15:8],blue[15:8]};
        end else begin visible<=0;add<=0;alpha<=0;rgb<=0;end
    end
endmodule
