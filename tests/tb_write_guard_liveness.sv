`timescale 1ns/1ps
module tb_write_guard_liveness;
    reg clk=0,rst_n=0,awvalid=1,awready=0,wvalid=1,bvalid=0,bready=0;
    always #5 clk=~clk;
    wire ma,sa,mw,sw;
    integer age=0,addresses=0,beats=0;
    video_write_guard dut(.clk(clk),.rst_n(rst_n),.video_priority(1'b1),
        .s_awvalid(awvalid),.s_awready(sa),.m_awvalid(ma),.m_awready(awready),
        .s_wvalid(wvalid),.s_wready(sw),.m_wvalid(mw),.m_wready(1'b1),
        .bvalid(bvalid),.bready(bready));
    always @(posedge clk) if(rst_n) begin
        age=age+1;
        if(ma && awready) addresses=addresses+1;
        if(mw && sw) begin
            if(addresses==0) $fatal(1,"W passed before AW");
            beats=beats+1;
        end
        if(age>900) $fatal(1,"unbounded write starvation");
    end
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        repeat(250) begin @(negedge clk);if(ma) $fatal(1,"refill reserve bypassed early");end
        repeat(12) @(negedge clk);
        if(!ma) $fatal(1,"pending AW was never admitted with priority held high");
        repeat(5) begin @(negedge clk);if(!ma) $fatal(1,"stalled AW revoked");end
        awready=1;@(negedge clk);awvalid=0;
        wait(beats==16);@(negedge clk);wvalid=0;awvalid=1;bvalid=1;
        repeat(9) begin @(negedge clk);if(ma) $fatal(1,"new AW before previous B response");end
        bready=1;@(negedge clk);bvalid=0;wvalid=1;
        wait(addresses==2);@(negedge clk);awvalid=0;
        wait(beats==32);@(negedge clk);wvalid=0;bvalid=1;
        @(negedge clk);bvalid=0;
        if(dut.write_pending) $fatal(1,"pending write not retired");
        $display("PASS bounded write service: continuous video priority, stalled AW, 16-beat W, stalled B, next request");
        $finish;
    end
endmodule
