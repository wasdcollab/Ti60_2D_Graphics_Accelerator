`timescale 1ns/1ps
module tb_read_drain_busy;
    reg clk=0,rst_n=0,req=0,dst=0,full=0,rv=0;
    always #5 clk=~clk;
    wire accept,busy,av,rr,src_push,dst_push;
    integer ars=0,received=0,n,j,ticks=0;
    bitblt_axi_read_master #(.MAX_OUTSTANDING(4)) dut(
        .clk(clk),.rst_n(rst_n),.rd_req(req),.rd_is_dst(dst),.rd_addr(28'h2000000),.rd_len(8'd0),
        .rd_accept(accept),.rd_busy(busy),.fifo_full_src(full),.fifo_full_dst(full),
        .m_axi_arvalid(av),.m_axi_arready(1'b1),.m_axi_rid(4'd2),.m_axi_rdata(128'd1),
        .m_axi_rresp(2'd0),.m_axi_rlast(1'b1),.m_axi_rvalid(rv),.m_axi_rready(rr),
        .fifo_winc_src(src_push),.fifo_winc_dst(dst_push));
    always @(posedge clk) begin
        if(!rst_n) begin ars=0;received=0;ticks=0;end
        else begin
            ticks=ticks+1;
            if(ticks>200) $fatal(1,"drain stalled");
            if(av) ars=ars+1;
            if(src_push || dst_push) begin
                if({dst_push,src_push} !== (received%2 ? 2'b10 : 2'b01)) $fatal(1,"stream tag corrupted");
                received=received+1;
            end
        end
    end
    initial begin
        for(n=1;n<=3;n=n+1) begin
            rst_n=0;req=0;rv=0;full=0;
            repeat(3) @(negedge clk);rst_n=1;
            for(j=0;j<n;j=j+1) begin
                @(negedge clk);req=1;dst=j%2;
                while(!accept) @(negedge clk);
                @(negedge clk);req=0;
            end
            wait(ars==n);repeat(2) @(negedge clk);
            if(!busy) $fatal(1,"false idle with %0d outstanding read(s)",n);
            full=1;rv=1;
            repeat(4) begin @(negedge clk);if(!busy || rr) $fatal(1,"pending read lost under FIFO backpressure");end
            full=0;
            wait(received==n);@(negedge clk);rv=0;
            repeat(2) @(negedge clk);
            if(busy) $fatal(1,"busy stayed asserted after all responses drained");
            $display("PASS read drain: %0d outstanding, stalled FIFO, correct streams, busy until last response",n);
        end
        $finish;
    end
endmodule
