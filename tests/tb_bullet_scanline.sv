`timescale 1ns/1ps
module tb_bullet_scanline;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=0;
    reg [11:0] x=0;
    reg [10:0] y=781;
    reg de=0,ready=1;
    wire [9:0] addr;
    wire group_bit;
    reg [31:0] data=0;
    reg [31:0] entries [0:1023];
    reg [7:0] tiles [0:32767];
    reg [31:0] pal [0:255];
    reg tile_we=0,pal_we=0;
    reg [14:0] tile_addr=0;
    reg [7:0] tile_data=0,pal_addr=0;
    reg [31:0] pal_data=0,mask_x=0,mask_y=0;
    wire visible,add;
    wire [23:0] rgb;
    wire [7:0] alpha;
    video_bullet_scanline dut (
        .pixel_clk(clk),.pixel_rst_n(rst),.x(x),.y(y),.de(de),
        .entry_addr(addr),.entry_group(group_bit),.entry_data(data),.entry_ready(ready),
        .cfg_clk(clk),.cfg_rst_n(rst),.tile_we(tile_we),.tile_waddr(tile_addr),
        .tile_wdata(tile_data),.pal_we(pal_we),.pal_waddr(pal_addr),.pal_wdata(pal_data),
        .mask_x(mask_x),.mask_y(mask_y),.visible(visible),.bullet_add(add),.rgb(rgb),.alpha(alpha)
    );
    always @(posedge clk) data <= entries[addr];
    function integer base(input integer slot);
        base = slot<16 ? slot*832 : slot==16 ? 13312 : slot==17 ? 13520 : slot==18 ? 13936 : 14368+(slot-19)*832;
    endfunction
    function integer stride(input integer slot);
        stride = slot<16 || slot>=19 ? 32 : slot==16 ? 8 : 16;
    endfunction
    function [33:0] expected(input integer xx,input integer yy);
        integer j,bx,row,slot,w,hue,index;
        reg [31:0] color;
        reg valid;
        begin
            valid=0; color=0;
            for(j=0;j<1024;j=j+1) begin
                bx=entries[j][10:0]; row=entries[j][16:11]-8+(yy%8);
                slot=entries[j][23:17]; w=entries[j][28:24]; hue=entries[j][31:29];
                if (xx>=bx && xx<bx+w && row>=0 && row<26 && slot<37) begin
                    index=tiles[base(slot)+row*stride(slot)+xx-bx]&31;
                    if(index!=0) begin valid=1; color=pal[hue*32+index]; end
                end
            end
            if(xx<181 || xx>=1185 || yy>=768 ||
                (mask_x[31] && xx>=mask_x[10:0] && xx<=mask_x[21:11] &&
                 yy>=mask_y[10:0] && yy<=mask_y[21:11])) valid=0;
            expected=valid ? {1'b1,color[31:24]==254,color} : 34'd0;
        end
    endfunction
    reg [33:0] queue [0:3];
    reg [33:0] actual;
    integer i,j,line,xx,slot,w,bx,row,checks=0,errors=0,fd;
    initial begin
        fd=$fopen("simulator/output/bullet_tiles.hex","r");
        if(!fd) $fatal(1,"generate firmware tile fixtures first: python tools/gen_bullet_tiles.py");
        $fclose(fd);
        fd=$fopen("simulator/output/bullet_palette.hex","r");
        if(!fd) $fatal(1,"missing firmware palette fixture");
        $fclose(fd);
        $readmemh("simulator/output/bullet_tiles.hex",tiles);
        $readmemh("simulator/output/bullet_palette.hex",pal);
        for(i=0;i<32768;i=i+1) if(^tiles[i]===1'bx) $fatal(1,"unknown tile byte %0d",i);
        for(i=0;i<256;i=i+1) if(^pal[i]===1'bx) $fatal(1,"unknown palette entry %0d",i);
        for(i=0;i<1024;i=i+1) entries[i]=0;
        for(i=0;i<4;i=i+1) queue[i]=0;
        repeat(4) @(negedge clk);
        rst=1;
        for(i=0;i<32768;i=i+1) begin
            tile_we=1; tile_addr=i; tile_data=tiles[i]; @(negedge clk);
        end
        tile_we=0;
        for(i=0;i<256;i=i+1) begin
            pal_we=1; pal_addr=i; pal_data=pal[i]; @(negedge clk);
        end
        pal_we=0;
        // All 1024 entries, all 19 tile kinds/hues, unaligned X, clipping and
        // dense overlaps. The top slot is not special-cased by the oracle.
        for(i=0;i<1024;i=i+1) begin
            slot=i%37; w=slot<16 || slot>=29 ? 26 : slot==16 ? 7 : slot==17 || slot>=27 ? 16 : slot==18 ? 13 : 24;
            bx=(i*37)%1400;
            row=(i*13)%27;
            entries[i]=(i%8<<29)|(w<<24)|(slot<<17)|(row<<11)|bx;
        end
        for(line=0;line<34;line=line+1) begin
            y=line==0 ? 781 : line-1;
            // Changing masks must affect the current line, not the build.
            mask_x=line>15 ? 32'h80000000|(700<<11)|500 : 0;
            mask_y=(767<<11);
            for(xx=0;xx<1456;xx=xx+1) begin
                x=xx; de=xx<1366 && line!=0;
                for(j=3;j>0;j=j-1) queue[j]=queue[j-1];
                queue[0]=line==0 ? 0 : expected(xx,y);
                @(posedge clk); #1;
                actual=visible ? {visible,add,alpha,rgb} : 0;
                if(line>0 && actual!==queue[3]) begin
                    if(errors<12) $display("mismatch y=%0d x=%0d got=%h expected=%h",y,x,actual,queue[3]);
                    errors=errors+1;
                end
                checks=checks+1;
                @(negedge clk);
            end
        end
        if(errors) $fatal(1,"%0d errors / %0d pixels",errors,checks);
        $display("PASS scanline: %0d pixels, 1024 overlapping entries, 37 kinds, masks",checks);
        $finish;
    end
endmodule
