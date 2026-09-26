`timescale 1ns/1ps
module tb_step3_write_guard;
reg clk=0,rst_n=0,priority_read=1;
always #5 clk=~clk;
reg awvalid=0,awready=0,wvalid=0,wready=0,bvalid=0,bready=0;
wire ma,sa,mw,sw;
video_write_guard dut(.clk(clk),.rst_n(rst_n),.video_priority(priority_read),
 .s_awvalid(awvalid),.m_awready(awready),.m_awvalid(ma),.s_awready(sa),
 .s_wvalid(wvalid),.m_wready(wready),.m_wvalid(mw),.s_wready(sw),.bvalid(bvalid),.bready(bready));
initial begin
 repeat(3) @(negedge clk); rst_n=1; awvalid=1; wvalid=1; wready=1;
 repeat(5) begin @(negedge clk); if(ma || sa || mw || sw) $fatal(1,"write entered during refill"); end
 priority_read=0;
 @(negedge clk); if(!ma || mw) $fatal(1,"AW admission or early W");
 priority_read=1;
 repeat(5) begin @(negedge clk); if(!ma) $fatal(1,"AWVALID cancelled while stalled"); end
 awready=1;
 @(negedge clk); awvalid=0; awready=0;
 if(!mw || !sw) $fatal(1,"admitted W blocked by video priority");
 repeat(16) @(negedge clk);
 wvalid=0; awvalid=1; priority_read=0; bvalid=1;
 repeat(5) begin @(negedge clk); if(ma) $fatal(1,"new AW before B handshake"); end
 bready=1;
 @(negedge clk); bvalid=0; bready=0; #1;
 if(!ma) $fatal(1,"write did not resume after B");
 $display("PASS write_guard RTL: stalled AW preserved, accepted write drains, B limits outstanding writes");
 $finish;
end
initial begin #10000; $fatal(1,"timeout"); end
endmodule
