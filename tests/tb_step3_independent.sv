`timescale 1ns/1ps
module tb_step3_independent;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,enable=0,busy=0;
reg [27:0] active=28'h1000000;
wire owns,start; wire [27:0] dst,next_base; wire [10:0] width,height; wire [31:0] color;
bitblt_demo_scheduler dut(.clk(clk),.rst_n(rst_n),.enable(enable),.active_base(active),.fill_busy(busy),.owns_engine(owns),.start(start),.dst(dst),.width(width),.height(height),.color(color),.next_base(next_base));
reg [81:0] expected[0:123]; integer command=0,ticks=0,remaining=0,frames=0;
always @(posedge clk) if(rst_n && enable) begin
 ticks=ticks+1;
 if(start) begin
  if(busy || command>=124) $fatal(1,"invalid command overlap");
  if({dst,width,height,color}!==expected[command]) $fatal(1,"geometry mismatch cmd=%0d actual=%h expected=%h",command,{dst,width,height,color},expected[command]);
  if(dst>=active && dst<active+28'h600000) $fatal(1,"rendered active right buffer");
  command=command+1; busy<=1; remaining=5+(command%19);
 end else if(remaining>0) begin
  remaining=remaining-1; if(remaining==0) busy<=0;
 end
 if(ticks%2000==0 && active!=next_base) begin
  if(busy || command!=(frames+1)*31) $fatal(1,"premature publication");
  active<=next_base; frames=frames+1;
 end
end
// Independent, common one-second counter windows with scaled clock for simulation.
reg [27:0] left_scan=28'h1000000,right_scan=28'h1000000;
wire [7:0] cpu_fps,fpga_fps;
wire [31:0] pr;
bitblt_apb_regs #(.CLOCK_HZ(1000)) counters(.clk(clk),.rst_n(rst_n),
 .apb_paddr(16'd0),.apb_psel(1'b0),.apb_penable(1'b0),.apb_pwrite(1'b0),.apb_pwdata(32'd0),.apb_prdata(pr),
 .cmd_busy(1'b0),.vdma_active_base(left_scan),.vdma_right_active_base(right_scan),.vdma_right_next_base(right_scan),.vsync_flag(1'b0),.cpu_fps_bcd(cpu_fps),.fpga_fps_bcd(fpga_fps));
integer n,old_command;
initial begin
 $readmemh("demo_commands.hex",expected);
 repeat(5) @(negedge clk); rst_n=1; enable=1;
 wait(frames==4);
 @(negedge clk); enable=0;
 if(command!=124) $fatal(1,"missing frames");
 // Never change left_scan: autonomous right renderer already proved CPU independence.
 rst_n=0; repeat(3) @(negedge clk); rst_n=1;
 for(n=1;n<=1000;n=n+1) begin
  if(n%100==50) left_scan=left_scan ^ 28'h600000;
  if(n%50==25) right_scan=right_scan ^ 28'h600000;
  @(negedge clk);
 end
 if(cpu_fps!==8'h10 || fpga_fps!==8'h20) $fatal(1,"wrong measured FPS %h %h",cpu_fps,fpga_fps);
 for(n=1;n<=1000;n=n+1) begin
  if(n%50==25) right_scan=right_scan ^ 28'h600000;
  @(negedge clk);
 end
 if(cpu_fps!==0 || fpga_fps!==8'h20) $fatal(1,"CPU pause must not stop FPGA FPS");
 $display("PASS independent RTL: four autonomous frames match AABB reference; CPU pause yields CPU=0, FPGA=20 in scaled window");
 $finish;
end
initial begin #2000000; $fatal(1,"timeout"); end
endmodule
