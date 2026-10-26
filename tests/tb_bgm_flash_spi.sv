`timescale 1ns/1ps
module tb_bgm_flash_spi;
    reg clk=0, rst_n=0, ps=0, pe=0, pw=0;
    always #5 clk=~clk;
    reg [15:0] addr=0;
    reg [31:0] wd=0;
    wire [31:0] rd;
    wire start, cs, busy, sclk, mosi;
    wire [7:0] tx, rx;
    wire [14:0] eb_count;
    wire motion;
    reg pad_clk=0, pad_mosi=0, pad_cs=1, miso_reg=0;
    reg [7:0] miso_byte=0, sent=0, received=0;
    integer bit_no=0, bytes_seen=0, expected_addr=0, i, n, reads;
    reg [31:0] result;
    always @(posedge clk) begin
        pad_clk <= sclk; pad_mosi <= mosi; pad_cs <= cs;
        miso_reg <= miso_byte[7-bit_no];
    end
    always @(posedge pad_cs) begin bit_no=0; bytes_seen=0; expected_addr=0; end
    always @(posedge pad_clk) if (!pad_cs) begin
        received = {received[6:0],pad_mosi};
        if (bit_no == 7) begin
            if (bytes_seen == 0 && received != 3) $fatal(1,"wrong opcode %h",received);
            if (bytes_seen > 0 && bytes_seen < 4) expected_addr=(expected_addr<<8)|received;
            if (bytes_seen >= 4 && received != 0) $fatal(1,"unexpected dummy value");
            bytes_seen=bytes_seen+1;
        end
    end
    always @(negedge pad_clk) if (!pad_cs) begin
        if (bit_no == 7) begin
            bit_no=0;
            if (bytes_seen >= 4) begin
                miso_byte=(expected_addr*37)^8'hA5;
                expected_addr=expected_addr+1;
            end
        end else bit_no=bit_no+1;
    end
    apb_command_dispatcher apb (
        .clk(clk),.rst_n(rst_n),.apb_paddr(addr),.apb_psel(ps),.apb_penable(pe),
        .apb_pwrite(pw),.apb_pwdata(wd),.apb_prdata(rd),
        .cmd_busy(1'b0),.engine_timeout(1'b0),.vsync_flag(1'b0),
        .key_sw0_pulse(1'b0),.key_sw2_pulse(1'b0),
        .flash_start(start),.flash_cs_n(cs),.flash_tx(tx),.flash_busy(busy),.flash_rx(rx),
        .bucket_eb_count(eb_count),.bucket_motion_en(motion)
    );
    bgm_flash_spi dut(.clk(clk),.rst_n(rst_n),.start(start),.cs_n(cs),.tx_data(tx),
        .miso(miso_reg),.sclk(sclk),.mosi(mosi),.busy(busy),.rx_data(rx));
    task write_reg(input [15:0] a,input [31:0] v);
        begin
            @(negedge clk);ps=1;pe=0;pw=1;addr=a;wd=v;
            @(negedge clk);pe=1;
            @(negedge clk);ps=0;pe=0;pw=0;
        end
    endtask
    task read_reg(input [15:0] a);
        begin
            @(negedge clk);ps=1;pe=0;pw=0;addr=a;
            @(negedge clk);pe=1;
            #1;result=rd;
            @(negedge clk);ps=0;pe=0;
        end
    endtask
    task transfer(input [7:0] value);
        begin
            write_reg(16'h13c,value);
            read_reg(16'h13c);
            if (!result[8]) $fatal(1,"SPI busy missing at APB start");
            reads=0;
            while (result[8]) begin
                read_reg(16'h13c); reads=reads+1;
                if(reads>60) $fatal(1,"SPI hangs");
            end
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        read_reg(16'h140);if(result!=1 || sclk) $fatal(1,"SPI reset unsafe");
        for(i=8190;i<=10240;i=i+1) begin
            write_reg(16'h120,32'h80000000|((i&8191)<<16)|((i&8192)<<1));
            if(eb_count!==i || motion!==0) $fatal(1,"count/motion alias at %0d",i);
            write_reg(16'h120,32'hA0000000|((i&8191)<<16)|((i&8192)<<1));
            if(eb_count!==i || motion!==1) $fatal(1,"motion count loss at %0d",i);
        end
        begin
            integer hi;
            integer samples[0:5];
            samples[0]=16383; samples[1]=16384; samples[2]=20000;
            samples[3]=20480; samples[4]=32767; samples[5]=0;
            for(hi=0;hi<6;hi=hi+1) begin
                i=samples[hi];
                write_reg(16'h120,32'h80000000|((i&8191)<<16)|((i&24576)<<1));
                if(eb_count!==i[14:0] || motion!==0) $fatal(1,"15-bit count alias at %0d got %0d",i,eb_count);
                write_reg(16'h120,32'hA0000000|((i&8191)<<16)|((i&24576)<<1));
                if(eb_count!==i[14:0] || motion!==1) $fatal(1,"15-bit motion loss at %0d got %0d",i,eb_count);
            end
        end
        for(n=0;n<4;n=n+1) begin
            write_reg(16'h140,0);
            transfer(3); transfer(8'h20); transfer(n); transfer(8'hF8);
            for(i=0;i<256;i=i+1) begin
                transfer(0);
                if(result[7:0] !== (((32'h2000F8+(n<<8)+i)*37)^8'hA5) % 256)
                    $fatal(1,"SPI byte order/pad latency failure n=%0d i=%0d rx=%h",n,i,result);
            end
            write_reg(16'h140,1);
        end
        write_reg(16'h140,0);write_reg(16'h13c,3);
        write_reg(16'h140,1);repeat(3) @(negedge clk);
        if(busy || sclk) $fatal(1,"CS abort failed");
        $display("PASS: SPI read 1024 bytes, registered IO pads, 24-bit addresses, CS abort; APB counts 8190..10240 and 16383..32767 with motion on/off");
        $finish;
    end
    initial begin #5000000;$fatal(1,"test timeout");end
endmodule
