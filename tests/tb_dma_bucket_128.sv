`timescale 1ns/1ps
module tb_dma_bucket_128;
    reg aclk=0, pclk=0, rst=0;
    always #5 aclk=~aclk;
    always #6 pclk=~pclk;
    reg [11:0] h=1;
    reg [10:0] v=0;
    reg [27:0] active=28'h0800000;
    reg arready=0, rv=0, last=0;
    reg [127:0] data=0;
    wire av, rr, act, pend, ready;
    wire [27:0] addr;
    wire [7:0] len;
    wire [4095:0] row;
    dma_bucket_prefetch #(.BUCKET_SLOTS(128)) dut (
        .axi_clk(aclk),.axi_rst_n(rst),.cal_done(1'b1),
        .bucket_base(28'h4800000),.active_base(active),
        .frame_clear_axi(1'b0),.discard_frame(1'b0),
        .at_line_start(1'b1),.fb_busy(1'b0),.bk_pend(pend),.bk_act(act),
        .bk_araddr(addr),.bk_arlen(len),.bk_arvalid(av),.bk_arready(arready),
        .bk_rdata(data),.bk_rlast(last),.bk_rvalid(rv),.bk_rready(rr),
        .pixel_clk(pclk),.pixel_rst_n(rst),.h_cnt(h),.v_cnt(v),
        .bucket_row(row),.bucket_ready(ready)
    );
    task exercise(input integer line, input bit back);
        integer burst, beat, wordidx, slot;
        reg [27:0] expect_addr;
        begin
            active=back ? 28'h0e00000 : 28'h0800000;
            @(negedge pclk);v=line-2;h=0;
            @(negedge pclk);h=1;
            for (burst=0;burst<2;burst=burst+1) begin
                wait(av);
                expect_addr=28'h4800000 + (back ? 28'h60000 : 0) + line*512 + burst*256;
                repeat(4) begin
                    @(negedge aclk);
                    if (!av || addr!==expect_addr || len!==15)
                        $fatal(1,"AR/stride/backpressure mismatch addr=%h expected=%h len=%d",addr,expect_addr,len);
                end
                if ({1'b0,addr[11:0]} + 13'd256 > 13'd4096)
                    $fatal(1,"AXI burst crosses 4K");
                arready=1;
                @(negedge aclk);arready=0;
                for (beat=0;beat<16;beat=beat+1) begin
                    repeat(2) @(negedge aclk);
                    if (!rr) $fatal(1,"lost R owner");
                    for(wordidx=0;wordidx<4;wordidx=wordidx+1)
                        data[wordidx*32+:32]=line*1000+burst*64+beat*4+wordidx;
                    rv=1;last=(beat==15);
                    @(negedge aclk);rv=0;last=0;
                end
            end
            @(negedge aclk);
            if(act) $fatal(1,"transaction did not retire");
            // Lift bank line[0] during the preceding scanline's blanking.
            @(negedge pclk);v=line-1;h=1366;
            for(slot=0;slot<32;slot=slot+1) begin
                @(negedge pclk);h=h+1;
            end
            if(!ready) $fatal(1,"row never became ready");
            for(slot=0;slot<128;slot=slot+1)
                if(row[slot*32+:32] !== line*1000+slot)
                    $fatal(1,"wrong slot %d: %h",slot,row[slot*32+:32]);
        end
    endtask
    initial begin
        repeat(4) @(negedge aclk);rst=1;
        exercise(10,0);exercise(11,1);exercise(767,1);
        $display("PASS tb_dma_bucket_128: both pages, 128 entries, stalls, last row");
        $finish;
    end
    initial begin #200000;$fatal(1,"timeout");end
endmodule
