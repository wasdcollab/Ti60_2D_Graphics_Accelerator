`timescale 1ns/1ps
module tb_alpha_fade #(parameter ADD_MODE=0);
    reg clk=0, rst_n=0, clr=0;
    always #5 clk=~clk;
    reg [7:0] ga=255;
    reg [127:0] src=0,dst=0;
    reg valid=0, ready=0;
    wire sa,da,ov;
    wire [127:0] result;
    wire [15:0] mask;
    bitblt_alpha_blend dut(.clk(clk),.rst_n(rst_n),.clr(clr),.enable(1'b1),
        .is_add(ADD_MODE!=0),.global_alpha(ga),.colorkey_en(1'b1),.colorkey_val(32'h00ff00ff),
        .src_data(src),.src_valid(valid),.src_ack(sa),.dst_data(dst),.dst_valid(valid),.dst_ack(da),
        .out_data(result),.out_mask(mask),.out_valid(ov),.out_ack(ready));
    reg [127:0] expected[0:4095];
    reg [15:0] expected_mask[0:4095];
    integer sent=0,received=0,tick=0,lane,ch,a,n;
    reg [31:0] s,d,p;
    always @(posedge clk) if(rst_n && !clr) begin
        tick=tick+1;
        if(sa!==da) $fatal(1,"unpaired source/destination");
        if(sa) begin
            expected_mask[sent]=16'hffff;
            for(lane=0;lane<4;lane=lane+1) begin
                s=src[lane*32+:32];d=dst[lane*32+:32];p=d;
                a=(s[31:24]*ga+127)/255;
                for(ch=0;ch<3;ch=ch+1) begin
                    n=(s[ch*8+:8]*a+d[ch*8+:8]*(255-a)+127)/255;
                    if(ADD_MODE) begin
                        n=s[ch*8+:8]+d[ch*8+:8];
                        if(n>255) n=255;
                    end
                    p[ch*8+:8]=n;
                end
                expected[sent][lane*32+:32]=p;
                if(s==32'h00ff00ff)expected_mask[sent][lane*4+:4]=0;
            end
            sent=sent+1;
        end
        if(ov && ready) begin
            if(received>=sent || mask!==expected_mask[received]) $fatal(1,"mask/order mismatch");
            for(lane=0;lane<4;lane=lane+1)
                if(mask[lane*4] && result[lane*32+:32]!==expected[received][lane*32+:32])
                    $fatal(1,"blend mismatch at beat %0d lane %0d",received,lane);
            received=received+1;
        end
        if(tick>50000)$fatal(1,"timeout");
    end
    integer phase,i,k;
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        for(phase=0;phase<2;phase=phase+1) begin
            ga=phase?70:255;
            for(i=0;i<1024;i=i+1)begin
                for(k=0;k<4;k=k+1) begin
                    src[k*32+:32]={8'(i+k),24'((i*571+k*111777))};
                    dst[k*32+:32]=32'h7f000000|((i*99331+k*517)&24'hffffff);
                    if((i+k)%11==0)src[k*32+:32]=32'h00ff00ff;
                end
                valid=1;ready=(i%5)!=0;
                @(posedge clk);
                while(!sa)begin @(negedge clk);ready=1;@(posedge clk);end
                @(negedge clk);valid=0;
            end
            ready=1;
            wait(received==sent);@(negedge clk);
        end
        if(ADD_MODE) $display("PASS additive blend: %0d pixels, saturation, key holes, destination alpha and stalls",received*4);
        else $display("PASS alpha fade: %0d pixels, alpha 0..255, global 255/70, key holes and stalls",received*4);
        $finish;
    end
endmodule
