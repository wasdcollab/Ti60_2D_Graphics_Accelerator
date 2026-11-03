`timescale 1ns/1ps
module tb_spell_beams;
    reg clk=0,rst=0;always #5 clk=~clk;
    reg [11:0] x=0;reg [10:0] y=0;reg de=0;
    reg [767:0] p=0;reg [31:0] mx=0,my=0;
    wire vis,ad;wire [7:0] alpha;wire [23:0] rgb;
    video_spell_beams dut(.pixel_clk(clk),.pixel_rst_n(rst),.x(x),.y(y),.de(de),.p(p),.mask_x(mx),.mask_y(my),.visible(vis),.add(ad),.alpha(alpha),.rgb(rgb));
    function [33:0] reference(input integer xx,yy,live);
        integer i,cx,cy,nx,ny,distance,half,warning,gain,width,colour,op,mode,found,rr,gg,bb;
        begin
            found=0;op=0;mode=0;rr=0;gg=0;bb=0;
            for(i=0;i<6;i=i+1) begin
                cx=p[i*128+:11];cy=p[i*128+11+:10];
                nx=$signed(p[i*128+32+:10]);ny=$signed(p[i*128+48+:10]);
                warning=p[i*128+30];gain=p[i*128+96+:8];width=p[i*128+104+:4];
                distance=(xx-cx)*ny-(yy-cy)*nx;if(distance<0)distance=-distance;half=width*128;
                if(!found && p[i*128+31] && (nx||ny) && gain && width) begin
                    colour=p[i*128+64+:24];
                    if(warning && distance<=256 && (((nx<0?-nx:nx)>=(ny<0?-ny:ny)?xx:yy)&8))begin found=1;op=210;mode=0;end
                    else if(!warning && distance<=half+3072)begin
                        found=1;op=255;mode=1;
                        if(distance<=half/2)colour=24'hffffff;
                        else if(distance>half)begin
                            if(distance<=half+1024)colour=(colour>>1)&24'h7f7f7f;
                            else if(distance<=half+2048)colour=(colour>>2)&24'h3f3f3f;
                            else colour=(colour>>3)&24'h1f1f1f;
                        end
                    end
                    if(found)begin rr=((colour>>16)&255)*gain/256;gg=((colour>>8)&255)*gain/256;bb=(colour&255)*gain/256;end
                end
            end
            if(!live || xx<181 || xx>=1185 || (mx[31] && xx>=mx[10:0] && xx<=mx[21:11] && yy>=my[10:0] && yy<=my[21:11]))found=0;
            reference=found?{1'b1,mode[0],op[7:0],rr[7:0],gg[7:0],bb[7:0]}:34'd0;
        end
    endfunction
    reg [33:0] queue[0:1];integer checks=0,errors=0,i,j,k,phase;
    task pixel(input integer xx,yy,live);
        reg [33:0] want;
        begin
            @(negedge clk);x=xx;y=yy;de=live;want=reference(xx,yy,live);
            @(posedge clk);#1;
            if(checks>0 && {vis,ad,alpha,rgb}!==queue[0])begin
                if(errors<10)$display("pixel %0d,%0d got %h want %h",xx,yy,{vis,ad,alpha,rgb},queue[0]);errors++;
            end
            queue[0]=want;checks++;
        end
    endtask
    initial begin
        queue[0]=0;repeat(4)@(negedge clk);rst=1;
        for(phase=0;phase<4;phase++)begin
            pixel(0,0,0);pixel(0,0,0);
            p=0;
            for(i=0;i<6;i++)begin
                p[i*128+:32]=32'h80000000|((phase==0?1:0)<<30)|(300<<11)|(480+i*45);
                case(i)
                    0:p[i*128+32+:32]=32'h00000100;
                    1:p[i*128+32+:32]=32'h01000000;
                    2:p[i*128+32+:32]=32'h00b500b5;
                    3:p[i*128+32+:32]=32'hff4b00b5;
                    4:p[i*128+32+:32]=32'h0070ff1a;
                    5:p[i*128+32+:32]=32'hff00ff00;
                endcase
                p[i*128+64+:32]=i%2?24'hd080ff:24'hff8050;
                p[i*128+96+:32]=(i%2?9:7)<<8|(phase==2?63:255);
            end
            mx=phase==3?32'h80000000|(700<<11)|500:0;my=(400<<11)|200;
            for(j=180;j<421;j+=3)for(k=170;k<1200;k+=3)pixel(k,j,1);
            pixel(800,300,0);
        end
        pixel(0,0,0);pixel(0,0,0);p=0;
        p[31:0]=32'h80000000|(1023<<11)|2047;
        p[63:32]=(121<<16)|220;p[95:64]=24'hff8050;p[127:96]=(9<<8)|255;
        p[159:128]=32'h80000000|(1023<<11);
        p[191:160]=(16'hff38<<16)|200;p[223:192]=24'hd080ff;p[255:224]=(7<<8)|255;
        mx=0;my=0;
        for(j=0;j<782;j+=17)for(k=0;k<1456;k+=11)pixel(k,j,j<768);
        pixel(0,0,0);pixel(0,0,0);
        p=0;pixel(500,300,1);pixel(500,300,1);pixel(500,300,0);
        if(errors)$fatal(1,"spell beam: %0d errors / %0d",errors,checks);
        $display("PASS DSP spell beams: %0d pixels, six directions, warning/fire/fade/priority/clip/mask/disable, two-cycle alignment",checks);$finish;
    end
endmodule
