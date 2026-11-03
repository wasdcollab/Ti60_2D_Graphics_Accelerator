`timescale 1ns/1ps
module tb_spell_beam_cdc;
    reg core=0,pixel=0;always #5 core=~core;always #7 pixel=~pixel;
    reg rst=0,commit=0;reg [767:0] source=0,expected=0;
    reg vblank=0;wire ack;wire [767:0] latched;
    spell_beam_cdc dut(.pixel_clk(pixel),.pixel_rst_n(rst),.vblank(vblank),.commit(commit),.parameters(source),.acknowledge(ack),.latched(latched));
    integer count=0,packets=0,i,j,ticks;reg last_ack=0;reg [767:0] last_data=0;
    always @(negedge pixel)begin count=count+1;vblank=count%17==0;end
    always @(posedge pixel)begin
        #1;
        if(rst)begin
            if(ack!=last_ack)begin
                if(!vblank)$fatal(1,"packet changed outside VBlank");
                if(latched!==expected)$fatal(1,"mixed or incomplete parameter packet");
                packets=packets+1;
            end else if(latched!==last_data)$fatal(1,"data changed without acknowledge");
        end
        last_ack=ack;last_data=latched;
    end
    initial begin
        repeat(5)@(negedge core);rst=1;
        for(i=1;i<=24;i=i+1)begin
            for(j=0;j<24;j=j+1)begin @(negedge core);source[j*32+:32]=(i<<24)|(j<<8)|i;end
            @(negedge core);expected=source;commit=~commit;
            ticks=0;
            while(ack!=commit && ticks<50)begin @(negedge pixel);ticks=ticks+1;end
            if(ack!=commit)$fatal(1,"packet not acknowledged");
            // Source waits for its return synchronizer before mutating data.
            repeat(3)@(negedge core);
        end
        if(packets!=24)$fatal(1,"packet count %0d",packets);
        $display("PASS beam CDC: 24 asynchronous packets, stable data, VBlank atomicity and acknowledgement");$finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
