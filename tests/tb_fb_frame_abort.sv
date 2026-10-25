`timescale 1ns/1ps
module tb_fb_frame_abort;
    reg clk=0,rst=0,fs=0,fc=0,arready=0,rv=0,rl=0;
    always #5 clk=~clk;
    wire [27:0] addr;
    wire [7:0] len;
    wire av,rr,push;
    integer i,k,n;
    dma_fb_reader dut (
        .axi_clk(clk),.axi_rst_n(rst),.cal_done(1'b1),
        .active_base(28'h0800000),.right_base(28'h0800000),
        .frame_start_axi(fs),.frame_clear_axi(fc),.fifo_wusedw(11'd0),
        .fifo_winc(push),.bk_pend(1'b0),.bk_act(1'b0),
        .fb_araddr(addr),.fb_arlen(len),.fb_arvalid(av),.fb_arready(arready),
        .fb_rdata(128'd0),.fb_rlast(rl),.fb_rvalid(rv),.fb_rready(rr)
    );
    task response(input integer count);
        begin
            for(k=0;k<count;k=k+1) begin
                @(negedge clk);rv=1;rl=k==count-1;
                @(posedge clk);if(!rr) $fatal(1,"response not drained");
                if(fc && push) $fatal(1,"old frame entered FIFO");
            end
            @(negedge clk);rv=0;rl=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=1;fs=1;
        @(negedge clk);fs=0;
        for(i=0;i<5;i=i+1) begin
            wait(av);@(negedge clk);
            if(addr!==28'h0800000+i*1024 || len!==63) $fatal(1,"row stepping");
            arready=1;@(negedge clk);arready=0;response(64);
        end
        wait(av);@(negedge clk);
        if(len!==21 || addr!==28'h0801400) $fatal(1,"tail request");
        fc=1;
        repeat(4) begin
            @(negedge clk);
            if(!av || len!==21 || addr!==28'h0801400) $fatal(1,"AR payload changed under stall/clear");
        end
        arready=1;@(negedge clk);arready=0;fc=0;fs=1;
        @(negedge clk);fs=0;
        response(22);
        wait(av);@(negedge clk);
        if(addr!==28'h0800000 || len!==63 || dut.burst_in_row!==0)
            $fatal(1,"new frame inherited old burst index");
        arready=1;@(negedge clk);arready=0;response(64);
        wait(av);@(negedge clk);
        if(addr!==28'h0800400 || len!==63) $fatal(1,"new frame second burst");
        $display("PASS frame abort: stalled tail AR stable, old R drained, new row restarts");$finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
