`timescale 1ns/1ps
module tb_step3_autonomous_axi;
reg clk=0; always #5 clk=~clk;
reg rst_n=0;
reg [15:0] pa=0; reg ps=0,pe=0,pw=0; reg [31:0] pd=0;
wire [31:0] pr; wire pre,per;
wire [3:0] awid,wid; wire [27:0] awaddr; wire [7:0] awlen;
wire [2:0] awsize; wire [1:0] awburst,awlock;
wire awvalid,wvalid,wlast,bready; reg awready=0,wready=0,bvalid=0;
wire [127:0] wdata; wire [15:0] wstrb;
wire [27:0] next_base; reg [27:0] active=28'h0800000; reg vsync=0;
wire [27:0] right_next;
bitblt_top dut(.clk(clk),.rst_n(rst_n),.apb_paddr(pa),.apb_psel(ps),.apb_penable(pe),.apb_pwrite(pw),.apb_pwdata(pd),.apb_prdata(pr),.apb_pready(pre),.apb_pslverr(per),
 .m_axi_awid(awid),.m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),.m_axi_awburst(awburst),.m_axi_awlock(awlock),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
 .m_axi_wid(wid),.m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),.m_axi_bid(4'd2),.m_axi_bvalid(bvalid),.m_axi_bready(bready),.vdma_next_base(next_base),.vdma_active_base(active),.vdma_right_active_base(active),.vdma_right_next_base(right_next),.vsync_flag(vsync));
localparam BASE=28'h0E00000;
integer tick=0,beat=0,len=0,address=0,delay_b=0,byte_at,k,writes=0,frames=0;
reg transaction=0,aw_stalled=0,w_stalled=0;
reg [35:0] saved_aw; reg [144:0] saved_w;
reg [27:0] write_base;
integer expected_writes=0;
reg [81:0] expected[0:123];
integer command=0;
always @(negedge clk) begin
 awready=((tick%7)>=3) && !transaction && !bvalid && delay_b==0;
 wready=((tick%5)==1 || (tick%5)==4) && transaction;
end
always @(posedge clk) if(rst_n) begin
 tick=tick+1;
 if(dut.auto_start) begin
  if(command>=124 || {dut.auto_dst,dut.auto_width,dut.auto_height,dut.auto_color}!==expected[command]) $fatal(1,"command mismatch");
  command=command+1;
  expected_writes=expected_writes+dut.auto_width*dut.auto_height*4;
 end
 if(aw_stalled && (!awvalid || {awaddr,awlen} !== saved_aw)) $fatal(1,"AW changed while stalled");
 if(w_stalled && (!wvalid || {wdata,wstrb,wlast} !== saved_w)) $fatal(1,"W changed while stalled");
 aw_stalled=awvalid && !awready; saved_aw={awaddr,awlen};
 w_stalled=wvalid && !wready; saved_w={wdata,wstrb,wlast};
 if(awvalid && awready) begin
  if(transaction || awsize!=4 || awburst!=1 || awaddr[3:0]!=0 || awlen>15) $fatal(1,"bad AW");
  if(awaddr[11:0]+(awlen+1)*16>4096) $fatal(1,"4KiB crossing");
  if(awaddr>=active && awaddr<active+28'h600000) $fatal(1,"wrote active half");
  write_base=(awaddr>=28'h0E00000)?28'h0E00000:28'h0800000;
  transaction=1; address=awaddr-write_base; len=awlen; beat=0;
 end
 if(wvalid && wready) begin
  if(!transaction || wlast !== (beat==len)) $fatal(1,"bad WLAST");
  for(k=0;k<16;k=k+1) if(wstrb[k]) begin
   byte_at=address+beat*16+k;
   if(byte_at<0 || byte_at>=6291456 || byte_at%8192<2560) $fatal(1,"out of right half");
   writes=writes+1;
  end
  if(wlast) begin transaction=0; delay_b=19; end
  else beat=beat+1;
 end
 if(delay_b>0) begin delay_b=delay_b-1; if(delay_b==0) bvalid<=1; end
 if(bvalid && bready) bvalid<=0;
 // A scan opportunity every 1M clocks; deliberately independent of APB traffic.
 if(tick%1000000==0 && right_next!=active) begin
  if(transaction || bvalid || dut.busy || writes!=expected_writes || command!=(frames+1)*31) $fatal(1,"incomplete frame published");
  active<=right_next; frames=frames+1;
 end
end
task apb_write(input [15:0] off,input [31:0] value);
 begin
 @(negedge clk); pa=off; pd=value; ps=1; pw=1; pe=0;
 @(negedge clk); pe=1;
 @(negedge clk); ps=0; pe=0; pw=0;
 end
endtask
task apb_read(input [15:0] off,output [31:0] value);
 begin
 @(negedge clk); pa=off; ps=1; pw=0; pe=0;
 @(negedge clk); pe=1; #1; value=pr;
 @(negedge clk); ps=0; pe=0;
 end
endtask
initial begin
 $readmemh("demo_commands.hex",expected);
 repeat(5) @(negedge clk); rst_n=1;
 apb_write(48,1);
 // No further CPU/APB writes: right-side frames must keep running.
 wait(frames==4);
 $display("PASS autonomous AXI RTL: 4 right frames, %0d byte writes, backpressure and scan ownership",writes);
 $finish;
end
initial begin #50000000; $fatal(1,"global timeout"); end
endmodule
