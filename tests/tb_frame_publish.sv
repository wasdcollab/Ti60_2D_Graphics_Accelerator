`timescale 1ns/1ps
module tb_frame_publish;
    reg clk=0, rst=0, ps=0, pe=0, pw=0;
    always #5 clk=~clk;
    reg [15:0] addr=0;
    reg [31:0] wd=0;
    wire [27:0] left_next,right_next;
    reg [27:0] left_active=28'h0800000,right_active=28'h0800000;
    integer tick=0,i;
    reg split=0;
    apb_command_dispatcher dut (
        .clk(clk),.rst_n(rst),.cal_done(1'b1),.apb_paddr(addr),.apb_psel(ps),
        .apb_penable(pe),.apb_pwrite(pw),.apb_pwdata(wd),
        .cmd_busy(1'b0),.engine_timeout(1'b0),.vsync_flag(1'b0),
        .key_sw0_pulse(1'b0),.key_sw2_pulse(1'b0),
        .vdma_next_base(left_next),.vdma_right_next_base(right_next)
    );
    always @(posedge clk) if(rst) begin
        tick <= tick+1;
        if(tick%7==0) begin left_active<=left_next;right_active<=right_next;end
        if(!split && left_active!==right_active) $fatal(1,"split frame at vblank");
    end
    task wr(input [15:0] a,input [31:0] d);
        begin
            @(negedge clk);ps=1;pe=0;pw=1;addr=a;wd=d;
            @(negedge clk);pe=1;
            @(negedge clk);ps=0;pe=0;pw=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=1;
        for(i=0;i<50;i=i+1) begin
            repeat(i%9) @(negedge clk);
            wr(16'h134,i%2 ? 32'h00E00000 : 32'h00800000);
            if(left_next!==right_next) $fatal(1,"non-atomic publication");
        end
        repeat(8) @(negedge clk);
        split=1;
        wr(16'h20,32'h00800000);wr(16'h40,32'h00E00000);
        if(left_next!==28'h0800000 || right_next!==28'h0E00000)
            $fatal(1,"independent benchmark channels broken");
        $display("PASS atomic frame publication: 50 vblank phases and split mode");$finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
