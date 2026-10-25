`timescale 1ns/1ps
module tb_scanline_prefetch;
    reg ac=0,pc=0,ar=0,pr=0;
    always #5 ac=~ac;
    always #6 pc=~pc;
    reg clear=0,fb_busy=0;
    reg [27:0] base=28'h4800000,frame=28'h800000;
    reg [11:0] x=1;
    reg [10:0] y=768;
    reg [9:0] addr=0;
    reg half=0;
    wire [31:0] entry;
    wire ready,pend,act,av,rr;
    wire [27:0] aa;
    wire [7:0] al;
    wire [11:0] missed;
    reg arv=0,rv=0,rl=0;
    reg [127:0] rd=0;
    dma_scanline_prefetch dut (
        .axi_clk(ac),.axi_rst_n(ar),.cal_done(1'b1),
        .bucket_base(base),.active_base(frame),.frame_clear_axi(clear),
        .at_line_start(1'b1),.fb_busy(fb_busy),.bk_pend(pend),.bk_act(act),
        .bk_araddr(aa),.bk_arlen(al),.bk_arvalid(av),.bk_arready(arv),
        .bk_rdata(rd),.bk_rlast(rl),.bk_rvalid(rv),.bk_rready(rr),
        .pixel_clk(pc),.pixel_rst_n(pr),.h_cnt(x),.v_cnt(y),
        .entry_addr(addr),.entry_group(half),.entry_data(entry),.entry_ready(ready),
        .missed_lines(missed)
    );
    integer remaining=0,tick=0,requests=0;
    reg [27:0] read_addr=0;
    reg old_stall=0;
    reg [27:0] held;
    function [31:0] value(input [27:0] a);
        value={4'hd,a} ^ 32'h12345678;
    endfunction
    always @(negedge ac) begin
        arv=(remaining==0 && tick%7!=0);
        tick=tick+1;
    end
    always @(posedge ac) if(ar) begin
        if(old_stall && (!av || aa!==held)) $fatal(1,"AR changed under stall");
        old_stall=av&&!arv;held=aa;
        if(av&&arv) begin
            if(al!=15 || aa[7:0]!=0) $fatal(1,"burst address/length");
            read_addr=aa;remaining=16;requests=requests+1;
        end
        if(rv&&rr) begin rv<=0;remaining=remaining-1;read_addr=read_addr+16;end
        if(!rv && remaining>0 && tick%3==0) begin
            rd<={value(read_addr+12),value(read_addr+8),value(read_addr+4),value(read_addr)};
            rv<=1;rl<=remaining==1;
        end
        if(tick>200000) $fatal(1,"timeout");
    end
    task request_row(input integer row);
        begin
            @(negedge pc); y=row;x=0;
            @(negedge pc); x=1;
        end
    endtask
    task check_group(input integer group_no,input integer table_no);
        integer k;
        reg [27:0] a;
        begin
            @(negedge pc);y=group_no==0?781:group_no*8-1;
            half=group_no%2;x=100;
            repeat(5) @(negedge pc);
            if(!ready) $fatal(1,"group not published: %0d",group_no);
            for(k=0;k<1024;k=k+1) begin
                addr=k;
                @(posedge pc);#1;
                a=28'h4800000+table_no*393216+group_no*4096+k*4;
                if(entry!==value(a)) $fatal(1,"group=%0d slot=%0d got=%h want=%h",group_no,k,entry,value(a));
                @(negedge pc);
            end
        end
    endtask
    initial begin
        repeat(5) @(negedge ac);
        ar=1;pr=1;
        request_row(769);
        wait(act); wait(!act);
        check_group(0,0);
        request_row(0);
        wait(act); wait(!act);
        check_group(1,0);
        check_group(0,0);
        // Invalidate old pages at blanking, then preload the new table's group 0.
        request_row(768);
        @(negedge ac);clear=1;frame=28'he00000;
        repeat(20) @(negedge ac);
        clear=0;
        request_row(769);
        wait(act);wait(!act);
        check_group(0,1);
        // Page flip during an outstanding transaction must drain it without
        // publishing the partially fetched group.
        request_row(0);
        wait(rr);
        @(negedge ac);clear=1;
        repeat(10) @(negedge ac);
        clear=0;
        wait(!act);
        @(negedge pc);y=7;half=1;x=100;
        repeat(5) @(negedge pc);
        if(ready) $fatal(1,"discarded group published");
        $display("PASS prefetch: 4096 entries, two pages, %0d bursts, abort/drain, CDC tags",requests);
        $finish;
    end
endmodule
