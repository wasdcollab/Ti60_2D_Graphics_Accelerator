`timescale 1ns/1ps
module tb_audio_apb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, ps = 0, pe = 0, pw = 0;
    reg [15:0] addr = 0;
    reg [31:0] wd = 0;
    wire [31:0] rd, ctrl, status, underflows, played;
    wire enabled, clear, wr;
    wire [7:0] data;
    wire [27:0] dst;
    wire [767:0] spell_pack;wire spell_req;reg spell_ack=0;
    wire signed [15:0] sample;
    reg [7:0] expected_rom [0:16383];
    integer i;
    apb_command_dispatcher dut (
        .clk(clk), .rst_n(rst_n), .apb_paddr(addr), .apb_psel(ps),
        .apb_penable(pe), .apb_pwrite(pw), .apb_pwdata(wd), .apb_prdata(rd),
        .cmd_busy(1'b0), .engine_timeout(1'b0), .vsync_flag(1'b0),
        .bucket_debug(32'h2468ace0),
        .key_sw0_pulse(1'b0), .key_sw2_pulse(1'b0),
        .cmd_dst_addr(dst), .audio_ctrl(ctrl), .spell_beams(spell_pack),.spell_commit(spell_req),.spell_ack(spell_ack),
        .pcm_enabled(enabled), .pcm_clear(clear), .pcm_write(wr), .pcm_data(data),
        .pcm_status(status), .pcm_underflows(underflows), .pcm_played(played)
    );
    bgm_pcm_fifo fifo (
        .clk(clk), .rst_n(rst_n), .sample_tick(1'b0), .enabled(enabled),
        .clear(clear), .write_strobe(wr), .write_data(data), .sample(sample),
        .status(status), .underflows(underflows), .played(played)
    );
    task write_reg;
        input [15:0] address;
        input [31:0] value;
        begin
            @(negedge clk); ps = 1; pe = 0; pw = 1; addr = address; wd = value;
            @(negedge clk); pe = 1;
            @(negedge clk); ps = 0; pe = 0; pw = 0;
            @(negedge clk);
        end
    endtask
    task read_expect;
        input [15:0] address;
        input [31:0] value;
        begin
            @(negedge clk); ps = 1; pe = 0; pw = 0; addr = address;
            @(negedge clk); pe = 1;
            #1; if (rd !== value) $fatal(1, "APB %h got %h want %h", address, rd, value);
            @(negedge clk); ps = 0; pe = 0;
        end
    endtask
    initial begin
        $readmemh("rtl/bitblt/asset_rom.hex", expected_rom);
        repeat (3) @(negedge clk); rst_n = 1;
        write_reg(16'h0004, 32'h01234560);
        read_expect(16'h0138, 32'h2468ace0);
        write_reg(16'h0100, 1);
        for (i = 0; i < 24; i = i + 1) write_reg(16'h0104, i);
        read_expect(16'h0108, 24);
        if (dst !== 28'h1234560) $fatal(1, "audio page aliases graphics destination");
        write_reg(16'h014c, 0);
        read_expect(16'h004c, 32'h3300);
        write_reg(16'h0100, 2);
        read_expect(16'h0108, 0);
        read_expect(16'h010c, 0);
        read_expect(16'h0110, 0);
        for (i = 15360; i < 16120; i = i + 1) begin
            write_reg(16'h0080, i);
            read_expect(16'h0084, {24'd0, expected_rom[i]});
        end
        for(i=0;i<24;i=i+1)begin
            write_reg(16'h0400+i*4,32'h12340000+i);
            if(spell_pack[i*32+:32]!==32'h12340000+i)$fatal(1,"spell bank write %0d",i);
        end
        read_expect(16'h0460,1);
        write_reg(16'h0400,32'hffffffff);
        if(spell_pack[31:0]!==32'h12340000)$fatal(1,"busy source packet was mutated");
        spell_ack=spell_req;repeat(3)@(negedge clk);
        read_expect(16'h0460,0);
        write_reg(16'h0460,32'hffffffff);
        for(i=0;i<24;i=i+1)if(spell_pack[i*32+:32]!==32'h12340000+i)$fatal(1,"out-of-range spell write aliased");
        read_expect(16'h0400,0);
        if(dst!==28'h1234560)$fatal(1,"spell bank aliases graphics destination");
        $display("TB_PASS: 24 spell beam words, commit/busy/ack ownership, write-only readback, range isolation, audio isolation and all 760 font bytes");
        $finish;
    end
    initial begin #100000; $fatal(1, "timeout"); end
endmodule
