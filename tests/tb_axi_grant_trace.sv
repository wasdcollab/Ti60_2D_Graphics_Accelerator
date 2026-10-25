`timescale 1ns/1ps
// Instrumented copy of tests/tb_axi_background_fair.sv: prints the grant
// sequence with timestamps so the vendor arbiter's behaviour is visible
// instead of inferred.
module tb_axi_grant_trace;
    reg clk=0,rst_n=0,priority_mode=1,video_req=1;
    always #5 clk=~clk;
    integer tick=0,total=0,i,phase;
    integer grants[0:3];
    wire ready=tick%13!=4 && tick%13!=5 && tick%13!=6;
    wire enabled=tick%29!=7;
    wire [3:0] valid={3'b111,priority_mode ? video_req : 1'b1};
    wire mv,ended;
    wire [3:0] sr,list;
    wire [1:0] number;
    Axi_Mux_Addr_Ctrl #(.AXI_CHANNEL_NUM(4)) dut(
        .Sys_Clk(clk),.Sys_Rst_N(rst_n),.O_M_A_VALID(mv),.I_M_A_READY(ready),
        .I_S_A_VALID(valid),.O_S_A_READY(sr),.Cfg_Arb_Type(priority_mode),
        .Cfg_Cnl_Mask(4'b1111),.I_Cnl_Sw_En(enabled),.O_Act_Cnl_End(ended),
        .O_Act_Cnl_Num(number),.O_Act_Cnl_List(list));
    always @(posedge clk) begin
        if(!rst_n) begin
            tick=0;total=0;video_req<=1;
            for(i=0;i<4;i=i+1) grants[i]=0;
        end else begin
            tick=tick+1;
            if(mv && ready) begin
                total=total+1;grants[number]=grants[number]+1;
                if(total<=20 || total%1000==0)
                    $display("t=%0d grant #%0d -> ch%0d  (n=%0d,%0d,%0d,%0d) en=%b rdy=%b vreq=%b",
                             tick,total,number,grants[0],grants[1],grants[2],grants[3],
                             enabled,ready,video_req);
                if(number==0) video_req<=0;
            end
            if(tick%23==0) video_req<=1;
        end
    end
    initial begin
        rst_n=0;repeat(4) @(negedge clk);rst_n=1;
        repeat(4000) @(negedge clk);
        $display("TOTAL grants=%0d : %0d,%0d,%0d,%0d",total,grants[0],grants[1],grants[2],grants[3]);
        $finish;
    end
endmodule
