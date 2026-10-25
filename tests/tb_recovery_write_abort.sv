`timescale 1ns/1ps
module tb_recovery_write_abort;
    reg clk=0, rst_n=0, abort=0, request=0, awready=0, wready=0, valid=1;
    always #5 clk=~clk;
    wire busy, done, awvalid, wvalid, wlast, ack;
    wire [127:0] data;
    wire [15:0] mask;
    wire [27:0] address;
    reg [127:0] source=128'h12345678123456781234567812345678;
    integer beats=0, completions=0, cycles=0;
    reg stalled=0, awstalled=0;
    reg [127:0] held_data;
    reg [15:0] held_mask;
    reg held_last;
    reg [27:0] held_address;
    bitblt_axi_master dut(
        .clk(clk),.rst_n(rst_n),.abort(abort),.busy(busy),
        .burst_req(request),.burst_addr(28'h0801000),.burst_len(8'd15),
        .burst_data(128'd0),.burst_wstrb_first(16'hffff),.burst_wstrb_last(16'hffff),
        .burst_done(done),.data_from_fifo(1'b1),.align_data(source),.data_valid(valid),
        .beat_ack(ack),.colorkey_en(1'b0),.colorkey_val(32'd0),
        .stream_mask(16'hffff),.stream_mask_en(1'b0),
        .m_axi_awaddr(address),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(data),.m_axi_wstrb(mask),.m_axi_wvalid(wvalid),
        .m_axi_wlast(wlast),.m_axi_wready(wready),.m_axi_bid(4'd2),.m_axi_bvalid(1'b0)
    );
    always @(posedge clk) if(rst_n) begin
        cycles=cycles+1;
        if(cycles>5000) $fatal(1,"timeout");
        if(stalled && (!wvalid || data!==held_data || mask!==held_mask || wlast!==held_last))
            $fatal(1,"stalled write changed during abort");
        if(awstalled && (!awvalid || address!==held_address))
            $fatal(1,"stalled address changed during abort");
        stalled=wvalid&&!wready;held_data=data;held_mask=mask;held_last=wlast;
        awstalled=awvalid&&!awready;held_address=address;
        if(wvalid&&wready) begin
            beats=beats+1;
            if(wlast !== (beats%16==0)) $fatal(1,"incorrect burst length");
        end
        if(done) completions=completions+1;
    end
    task start_burst;
        begin
            @(negedge clk);request=1;
            @(negedge clk);request=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        start_burst();
        wait(awvalid);repeat(4) @(negedge clk);
        abort=1;valid=0;repeat(4) @(negedge clk);
        awready=1;wready=1;
        wait(completions==1);@(negedge clk);
        if(beats!=16 || busy) $fatal(1,"AW-stall abort did not finish");
        abort=0;valid=1;start_burst();
        wait(beats==20);@(negedge clk);wready=0;
        repeat(3) @(negedge clk);abort=1;valid=0;
        repeat(5) @(negedge clk);wready=1;
        wait(completions==2);@(negedge clk);
        if(beats!=32 || busy) $fatal(1,"W-stall abort did not finish");
        abort=0;valid=1;start_burst();
        wait(completions==3);@(negedge clk);
        if(beats!=48 || busy) $fatal(1,"next command did not recover");
        $display("PASS write abort: AW/W stalls stay stable, padding completes, next burst recovers");
        $finish;
    end
endmodule
