`timescale 1ns/1ps
module tb_step3_scanout;
reg clk=0,pclk=0,rst_n=0;
always #5 clk=~clk;
always #9.756 pclk=~pclk;
wire [27:0] araddr; wire arvalid,rready,de;
reg arready=0,rvalid=0,rlast=0; reg [127:0] rdata=0;
wire [7:0] red,green,blue;
wire video_priority;
integer beat=0,wait_cycles=0,tick=0,frames=0,pixels=0,errors=0;
video_dma_read dut(.axi_clk(clk),.axi_rst_n(rst_n),.cal_done(1'b1),.pixel_clk(pclk),.pixel_rst_n(rst_n),
 .next_frame_base_addr(28'h0800000),.next_right_base_addr(28'h0E00000),.cpu_fps_bcd(8'h30),.fpga_fps_bcd(8'h60),
 .m_axi_araddr(araddr),.m_axi_arvalid(arvalid),.m_axi_arready(arready),.m_axi_rid(4'd1),.m_axi_rdata(rdata),.m_axi_rresp(2'd0),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready),
 .weather_mask_x(32'd0),.weather_mask_y(32'd0),
 .video_read_priority(video_priority),.red_out(red),.green_out(green),.blue_out(blue),.de_out(de));
// A write-favouring DDR model: sustained render traffic denies read service
// while a write is outstanding. +UNGUARDED reproduces scan FIFO starvation.
reg unguarded=0;
initial unguarded=$test$plusargs("UNGUARDED");
wire guarded_awvalid,guarded_wvalid,guarded_awready,guarded_wready;
integer write_cycles=0,writes=0;
wire memory_awready=(write_cycles==0 && tick%7!=0);
wire memory_bvalid=(write_cycles==1);
video_write_guard guard(.clk(clk),.rst_n(rst_n),.video_priority(unguarded ? 1'b0 : video_priority),
 .s_awvalid(1'b1),.m_awready(memory_awready),.m_awvalid(guarded_awvalid),.s_awready(guarded_awready),
 .s_wvalid(1'b1),.m_wready(1'b1),.m_wvalid(guarded_wvalid),.s_wready(guarded_wready),
 .bvalid(memory_bvalid),.bready(1'b1));
always @(posedge clk) if(rst_n) begin
 if(guarded_awvalid && memory_awready) begin write_cycles<=80; writes<=writes+1; end
 else if(write_cycles>0) write_cycles<=write_cycles-1;
end
reg transaction=0; reg [27:0] addr;
always @(negedge clk) begin
 tick=tick+1; arready=!transaction && tick%3!=0;
 if(transaction && wait_cycles==0 && write_cycles==0) begin
  rvalid=1; rlast=(beat==15);
  rdata={4{addr[11] ? 32'h000000ff : 32'h00000000}};
 end else begin rvalid=0; rlast=0; end
end
always @(posedge clk) if(rst_n) begin
 if(arvalid && arready) begin transaction=1; addr=araddr; beat=0; wait_cycles=12; end
 else if(wait_cycles>0 && write_cycles==0) wait_cycles=wait_cycles-1;
 if(rvalid && rready) begin if(rlast) transaction=0; else beat=beat+1; end
end
reg [11:0] x_prev; reg [10:0] y_prev;
always @(posedge pclk) begin
 x_prev=dut.pixel_x_d1; y_prev=dut.pixel_y_d1;
 #1;
 if(rst_n && dut.h_cnt==0 && dut.v_cnt==768) frames=frames+1;
 if(frames>=2 && de && y_prev>=40 && x_prev>=16 && x_prev<1342 && (x_prev<624 || x_prev>=656)) begin
  pixels=pixels+1;
  if({red,green,blue} !== (x_prev<640 ? 24'h000000 : 24'h0000ff)) begin
   if(errors<8) $display("pixel mismatch x=%0d y=%0d rgb=%h empty=%b",x_prev,y_prev,{red,green,blue},dut.fifo_rempty);
   errors=errors+1;
  end
 end
 if(frames==4) begin
  if(dut.scan_diagnostics!==32'd0) $fatal(1,"unexpected scan diagnostics: %h",dut.scan_diagnostics);
  if(errors) $fatal(1,"scan pixels wrong: %0d/%0d",errors,pixels);
  if(writes<1000) $fatal(1,"render traffic starved");
  $display("PASS scanout RTL: %0d pixels, %0d concurrent write bursts, independent bases and natural timing",pixels,writes); $finish;
 end
end
initial begin repeat(5) @(negedge clk); rst_n=1; end
initial begin #100000000; $fatal(1,"timeout"); end
endmodule
