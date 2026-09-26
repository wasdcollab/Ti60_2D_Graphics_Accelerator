`timescale 1ns/1ps
module tb_step3_vdma;
reg clk=0,pclk=0,rst_n=0;
always #5 clk=~clk;
always #9.756 pclk=~pclk;
reg [27:0] next_base=28'h0800000;
wire [27:0] active,araddr,right_active;
reg [27:0] next_right=28'h0800000;
wire arvalid,rready,vsync;
reg arready=0,rvalid=0,rlast=0;
video_dma_read dut(.axi_clk(clk),.axi_rst_n(rst_n),.cal_done(1'b1),
 .pixel_clk(pclk),.pixel_rst_n(rst_n),.next_frame_base_addr(next_base),.active_frame_base_addr(active),.next_right_base_addr(next_right),.active_right_base_addr(right_active),.cpu_fps_bcd(8'h30),.fpga_fps_bcd(8'h60),.vsync_flag(vsync),
 .weather_mask_x(32'd0),.weather_mask_y(32'd0),
 .m_axi_araddr(araddr),.m_axi_arvalid(arvalid),.m_axi_arready(arready),.m_axi_rid(4'd1),.m_axi_rdata(128'd0),.m_axi_rresp(2'd0),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
task start_frame;
 begin
 @(negedge clk); force dut.frame_start_axi=1'b1;
 @(negedge clk); force dut.frame_start_axi=1'b0;
 end
endtask
task clear_begin;
 begin
 @(negedge clk); force dut.frame_clear_sync=3'b010;
 @(negedge clk); force dut.frame_clear_sync=3'b110;
 end
endtask
task clear_end;
 begin @(negedge clk); force dut.frame_clear_sync=3'b000; end
endtask
task wait_ar;
 integer n;
 begin
 n=0;
 while(!arvalid && n<100) begin @(negedge clk); n=n+1; end
 if(!arvalid) $fatal(1,"AR timeout");
 end
endtask
task accept_ar;
 begin
 @(negedge clk); arready=1;
 @(negedge clk); arready=0;
 if(!rready) $fatal(1,"R not ready after AR");
 end
endtask
task respond;
 integer beat;
 begin
 for(beat=0;beat<16;beat=beat+1) begin
  @(negedge clk); rvalid=1; rlast=(beat==15);
  if(!rready) $fatal(1,"stranded outstanding R");
 end
 @(negedge clk); rvalid=0; rlast=0;
 end
endtask
reg [27:0] held_addr, expected_addr;
integer burst;
initial begin
 force dut.frame_start_axi=0;
 force dut.frame_clear_sync=0;
 repeat(5) @(negedge clk); rst_n=1;
 start_frame; wait_ar;
 if(araddr!==28'h0800000) $fatal(1,"reset base");
 held_addr=araddr;
 next_base=28'h0E00000;
 repeat(5) @(negedge clk);
 if(active!==28'h0800000) $fatal(1,"base changed outside blank");
 // AR must remain asserted across blanking until its handshake.
 clear_begin;
 if(active!==28'h0E00000) $fatal(1,"base not latched at blank");
 next_base=28'h0800000;
 repeat(5) begin
  @(negedge clk);
  if(!arvalid || araddr!==held_addr) $fatal(1,"AR cancelled at blank");
  if(active!==28'h0E00000) $fatal(1,"base relatched during extended blank");
 end
 clear_end;
 accept_ar;
 // An unusually late old response must drain, even after next frame start.
 start_frame;
 if(dut.fifo_winc) $fatal(1,"old data entering new FIFO");
 respond;
 wait_ar;
 if(araddr!==28'h0E00000) $fatal(1,"DMA used pending rather than active base");
 accept_ar;
 // Also test a clear in the R phase; RREADY cannot be withdrawn.
 clear_begin;
 if(active!==28'h0800000) $fatal(1,"second latch");
 clear_end;
 start_frame;
 respond;
 wait_ar;
 if(araddr!==28'h0800000) $fatal(1,"second frame wrong base");
 // Reset between protocol and full-raster cases to remove outstanding work.
 @(negedge clk); rst_n=0;
 force dut.frame_start_axi=0; force dut.frame_clear_sync=0;
 repeat(5) @(negedge clk); rst_n=1;
 next_base=28'h0800000; next_right=28'h0E00000;
 clear_begin; clear_end;
 if(active!==28'h0800000 || right_active!==28'h0E00000) $fatal(1,"half independence");
 start_frame;
 force dut.fifo_wusedw=0;
 for(burst=0;burst<16896;burst=burst+1) begin
  wait_ar;
  expected_addr=((burst%22)>=10 ? 28'h0E00000 : 28'h0800000) + burst*256;
  if(araddr!==expected_addr) $fatal(1,"wrong half address burst=%0d got=%h expected=%h",burst,araddr,expected_addr);
  accept_ar; respond;
 end
 repeat(10) @(negedge clk);
 if(arvalid) $fatal(1,"extra frame burst");
 $display("PASS VDMA RTL: atomic blank edge, latched address, AR/R preserved and drained across blanking");
 $finish;
end
initial begin #5000000; $fatal(1,"timeout"); end
endmodule
