`timescale 1ns/1ps
module tb_axi_background_fair;
    reg clk=0,rst_n=0,priority_mode=1,video_req=1;
    always #5 clk=~clk;
    integer tick=0,total=0,i,phase;
    integer grants[0:3],skips[0:3];
    wire ready=tick%13!=4 && tick%13!=5 && tick%13!=6;
    wire enabled=tick%29!=7;
    wire [3:0] valid={3'b111,priority_mode ? video_req : 1'b1};
    wire mv,ended;
    wire [3:0] sr,list;
    wire [1:0] number;
    reg held=0;
    reg [5:0] held_selection;
    Axi_Mux_Addr_Ctrl #(.AXI_CHANNEL_NUM(4)) dut(
        .Sys_Clk(clk),.Sys_Rst_N(rst_n),.O_M_A_VALID(mv),.I_M_A_READY(ready),
        .I_S_A_VALID(valid),.O_S_A_READY(sr),.Cfg_Arb_Type(priority_mode),
        .Cfg_Cnl_Mask(4'b1111),.I_Cnl_Sw_En(enabled),.O_Act_Cnl_End(ended),
        .O_Act_Cnl_Num(number),.O_Act_Cnl_List(list));
    always @(posedge clk) begin
        if(!rst_n) begin
            tick=0;total=0;held=0;video_req<=1;
            for(i=0;i<4;i=i+1) begin grants[i]=0;skips[i]=0;end
        end else begin
            tick=tick+1;
            if(held && (!mv || {number,list}!==held_selection)) $fatal(1,"grant changed while stalled");
            held=mv&&!ready;held_selection={number,list};
            if(mv && ready) begin
                if(total==0 && number!=0) $fatal(1,"video lost initial priority");
                if(list !== (4'b0001<<number) || sr!==list) $fatal(1,"one-hot routing mismatch");
                total=total+1;grants[number]=grants[number]+1;
                if(!priority_mode || number!=0) begin
                    for(i=priority_mode?1:0;i<4;i=i+1) begin
                        if(i==number) skips[i]=0;
                        else skips[i]=skips[i]+1;
                        if(skips[i]>(priority_mode?2:3))
                            $fatal(1,"master %0d starved: grants=%0d,%0d,%0d,%0d",i,grants[0],grants[1],grants[2],grants[3]);
                    end
                end
                if(number==0) video_req<=0;
            end
            if(tick%23==0) video_req<=1;
        end
    end
    initial begin
        for(phase=0;phase<2;phase=phase+1) begin
            rst_n=0;priority_mode=phase==0;
            repeat(4) @(negedge clk);rst_n=1;
            repeat(2000) @(negedge clk);
            for(i=0;i<4;i=i+1) if(grants[i]<20) $fatal(1,"master %0d made no progress",i);
            $display("PASS arbitration mode=%0d: grants=%0d,%0d,%0d,%0d; bounded background service and stable stalls",
                priority_mode,grants[0],grants[1],grants[2],grants[3]);
        end
        $finish;
    end
endmodule
