`timescale 1ns/1ps
module tb_step3_hud;
reg [11:0] x=0; reg [10:0] y=0;
reg [7:0] cpu=8'h30,fpga=8'h60;
wire visible; wire [23:0] rgb;
video_dual_hud dut(.x(x),.y(y),.cpu_fps_bcd(cpu),.fpga_fps_bcd(fpga),.visible(visible),.rgb(rgb));
integer row,col,file_id,count_left=0,count_right=0;
initial begin
 file_id=$fopen("dual_hud.ppm","w");
 $fwrite(file_id,"P3\n1366 40\n255\n");
 for(row=0;row<40;row=row+1) begin
  for(col=0;col<1366;col=col+1) begin
   x=col; y=row; #1;
   if(visible) begin
    if(col<640) begin
     if(rgb!==24'hffff00 && rgb!==24'h000000) $fatal(1,"left color");
     if(rgb==24'hffff00) count_left=count_left+1;
    end else begin
     if(rgb!==24'h00ff00 && rgb!==24'h0000ff) $fatal(1,"right color");
     if(rgb==24'h00ff00) count_right=count_right+1;
    end
    $fwrite(file_id,"%0d %0d %0d\n",rgb[23:16],rgb[15:8],rgb[7:0]);
   end else if(col<640) $fwrite(file_id,"0 0 0\n");
   else $fwrite(file_id,"0 0 255\n");
  end
 end
 $fclose(file_id);
 if(count_left<1000 || count_right<1000) $fatal(1,"missing HUD pixels");
 // Independently known font row 0: 3 = 0x3c, 6 = 0x3c; row 4 differs.
 x=16+5*16; y=8+4*2; #1;
 if(dut.character!==3 || dut.bitmap[63:56]!==8'h06) $fatal(1,"CPU BCD digit");
 x=656+6*16; #1;
 if(dut.character!==6 || dut.bitmap[63:56]!==8'hfc) $fatal(1,"FPGA BCD digit");
 cpu=0; x=16+5*16; #1;
 if(dut.character!==0) $fatal(1,"CPU zero rate not shown");
 x=656+6*16; #1;
 if(dut.character!==6) $fatal(1,"CPU change affected FPGA HUD");
 $display("PASS HUD RTL: independent BCD digits, 2x font, yellow CPU and green FPGA, zero FPS");
 $finish;
end
endmodule
