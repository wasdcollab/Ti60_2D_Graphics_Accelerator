`timescale 1ns/1ps
module tb_step3_bitblt;
reg clk=0; always #5 clk=~clk;
reg rst_n=0;
reg [15:0] pa=0; reg ps=0,pe=0,pw=0; reg [31:0] pd=0;
wire [31:0] pr; wire pre,per;

// AXI Read Master wires
wire [3:0] arid; wire [27:0] araddr; wire [7:0] arlen;
wire [2:0] arsize; wire [1:0] arburst, arlock;
wire arvalid; reg arready=0;
wire [3:0] rid=4'd2; reg [127:0] rdata=0; wire [1:0] rresp=0; wire rlast; reg rvalid=0; wire rready;

// AXI Write Master wires
wire [3:0] awid,wid; wire [27:0] awaddr; wire [7:0] awlen;
wire [2:0] awsize; wire [1:0] awburst,awlock;
wire awvalid,wvalid,wlast,bready; reg awready=0,wready=0,bvalid=0;
wire [127:0] wdata; wire [15:0] wstrb;
wire [27:0] next_base; reg [27:0] active=28'h1000000; reg vsync=0;

bitblt_top dut(
    .clk(clk), .rst_n(rst_n),
    .apb_paddr(pa), .apb_psel(ps), .apb_penable(pe), .apb_pwrite(pw), .apb_pwdata(pd),
    .apb_prdata(pr), .apb_pready(pre), .apb_pslverr(per),
    
    // AXI Read
    .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
    .m_axi_arburst(arburst), .m_axi_arlock(arlock), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid), .m_axi_rready(rready),
    
    // AXI Write
    .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
    .m_axi_awburst(awburst), .m_axi_awlock(awlock), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wid(wid), .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid), .m_axi_wready(wready), .m_axi_bid(4'd2), .m_axi_bvalid(bvalid),
    .m_axi_bready(bready),
    
    .vdma_next_base(next_base), .vdma_active_base(active), .vdma_right_active_base(active),
    .vdma_right_next_base(), .cpu_fps_bcd(), .fpga_fps_bcd(), .scan_diagnostics(32'd0),
    .vsync_flag(vsync)
);

    // v2 engine: AXI bursts are no longer clamped to 16 beats
    // (see bitblt_stride_gen MAX_BURST_BEATS, default 64).
    localparam integer MAX_BURST_BEATS = 64;
    localparam BASE     = 28'h0130_0000;

localparam SRC_BASE = 28'h0160_0000;

integer expected[0:65535];
reg [7:0] src_mem[0:65535];

integer tick=0,beat=0,len=0,address=0,delay_b=0,byte_at,k,writes=0,tests=0;
reg transaction=0,aw_stalled=0,w_stalled=0;
reg [35:0] saved_aw; reg [144:0] saved_w;

// Read responder state
reg rd_active=0; reg [27:0] rd_current_addr=0; reg [7:0] rd_beats_left=0; reg [7:0] rd_total_len=0;
reg [7:0] rd_beat_cnt=0;

always @(negedge clk) begin
    awready   <= ((tick%7)>=3) && !transaction && !bvalid && delay_b==0;
    wready    <= ((tick%5)==1 || (tick%5)==4) && transaction;
    arready   <= ((tick%4)>=1) && !rd_active;
end

assign rlast = rd_active && (rd_beats_left == 1);

always @* begin
    for (int b = 0; b < 16; b = b + 1) begin
        automatic int s_idx = (rd_current_addr - SRC_BASE) + (rd_beat_cnt * 16) + b;
        if (s_idx >= 0 && s_idx < 65536)
            rdata[b*8 +: 8] = src_mem[s_idx];
        else
            rdata[b*8 +: 8] = 8'hAA;
    end
end

// Read responder logic
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_active <= 0; rvalid <= 0;
        rd_current_addr <= 0; rd_total_len <= 0; rd_beats_left <= 0; rd_beat_cnt <= 0;
    end else begin
        if (arvalid && arready) begin
            rd_active        <= 1;
            rd_current_addr  <= araddr;
            rd_total_len     <= arlen;
            rd_beats_left    <= arlen + 1;
            rd_beat_cnt      <= 0;
        end
        if (rd_active) begin
            rvalid <= 1;
            if (rvalid && rready) begin
                rd_beat_cnt     <= rd_beat_cnt + 1;
                rd_beats_left   <= rd_beats_left - 1;
                if (rd_beats_left == 1) begin
                    rd_active <= 0;
                    rvalid    <= 0;
                end
            end
        end else begin
            rvalid <= 0;
        end
    end
end

// Write responder and check logic
always @(posedge clk) if(rst_n) begin
    tick=tick+1;
    if(aw_stalled && (!awvalid || {awaddr,awlen} !== saved_aw)) $fatal(1,"AW changed while stalled");
    if(w_stalled && (!wvalid || {wdata,wstrb,wlast} !== saved_w)) $fatal(1,"W changed while stalled");
    aw_stalled=awvalid && !awready; saved_aw={awaddr,awlen};
    w_stalled=wvalid && !wready; saved_w={wdata,wstrb,wlast};
    if(awvalid && awready) begin
        if(transaction || awsize!=4 || awburst!=1 || awaddr[3:0]!=0 || awlen>(MAX_BURST_BEATS-1)) $fatal(1,"bad AW");
        if(awaddr[11:0]+(awlen+1)*16>4096) $fatal(1,"4KiB crossing");
        transaction=1; address=awaddr-BASE; len=awlen; beat=0;
    end
    if(wvalid && wready) begin
        if(!transaction || wlast !== (beat==len)) $fatal(1,"bad WLAST");
        for(k=0;k<16;k=k+1) if(wstrb[k]) begin
            byte_at=address+beat*16+k;
            if(byte_at<0 || byte_at>=65536 || expected[byte_at]<0) $fatal(1,"unexpected byte %0d",byte_at);
            if(wdata[k*8+:8] !== expected[byte_at][7:0]) $fatal(1,"wrong byte %0d: got %h exp %h",byte_at, wdata[k*8+:8], expected[byte_at][7:0]);
            expected[byte_at]=-1; writes=writes+1;
        end
        if(wlast) begin transaction=0; delay_b=19; end
        else beat=beat+1;
    end
    if(delay_b>0) begin delay_b=delay_b-1; if(delay_b==0) bvalid<=1; end
    if(bvalid && bready) bvalid<=0;
end

task apb_write(input [15:0] off,input [31:0] value);
    begin
    @(negedge clk); pa=off; pd=value; ps=1; pw=1; pe=0;
    @(negedge clk); pe=1;
    @(negedge clk); ps=0; pe=0; pw=0;
    end
endtask

task apb_read(input [15:0] off,output [31:0] value);
    begin
    @(negedge clk); pa=off; ps=1; pw=0; pe=0;
    @(negedge clk); pe=1; #1; value=pr;
    @(negedge clk); ps=0; pe=0;
    end
endtask

reg [31:0] status;

// Task: Solid Fill
task fill(input integer offset,input integer width,input integer height);
    integer x,y,b,n,expected_writes,old_writes; reg [31:0] color;
    begin
    color=32'h12A5F0C3; expected_writes=width*height*4; old_writes=writes;
    for(n=0;n<65536;n=n+1) expected[n]=-1;
    for(y=0;y<height;y=y+1) for(x=0;x<width;x=x+1) for(b=0;b<4;b=b+1)
        expected[offset+y*4096+x*4+b]=(color>>(b*8))&255;
    apb_write(16'h18, 32'd0); // OP_FILL
    apb_write(16'h04, BASE+offset);
    apb_write(16'h08, width);
    apb_write(16'h0C, height);
    apb_write(16'h10, color);
    apb_write(16'h14, 1);     // START
    apb_read(16'h00, status);
    if(width>0 && height>0 && status[1]) $fatal(1,"stale Done on START");
    n=0;
    while(!status[1] && n<100000) begin apb_read(16'h00, status); n=n+1; end
    if(!status[1] || status[0]) $fatal(1,"fill timeout");
    repeat(40) @(negedge clk);
    apb_read(16'h00, status); if(status!==2) $fatal(1,"Done not sticky");
    if(writes-old_writes!=expected_writes) $fatal(1,"missing bytes");
    for(n=0;n<65536;n=n+1) if(expected[n]>=0) $fatal(1,"missing byte %0d",n);
    tests=tests+1;
    end
endtask

// Task: Block Copy
task copy(input integer src_off, input integer dst_off, input integer width, input integer height);
    integer x,y,b,n,expected_writes,old_writes;
    begin
    expected_writes=width*height*4; old_writes=writes;
    for(n=0;n<65536;n=n+1) expected[n]=-1;
    for(y=0;y<height;y=y+1) for(x=0;x<width;x=x+1) for(b=0;b<4;b=b+1) begin
        expected[dst_off+y*4096+x*4+b] = src_mem[src_off+y*4096+x*4+b] & 8'hFF;
    end
    apb_write(16'h18, 32'd1); // OP_COPY
    apb_write(16'h04, BASE+dst_off);
    apb_write(16'h1C, SRC_BASE+src_off);
    apb_write(16'h08, width);
    apb_write(16'h0C, height);
    apb_write(16'h30, 32'd4096); // SRC_STRIDE
    apb_write(16'h48, 32'd4096); // DST_STRIDE
    apb_write(16'h14, 1);         // START
    apb_read(16'h00, status);
    n=0;
    while(!status[1] && n<100000) begin apb_read(16'h00, status); n=n+1; end
    if(!status[1] || status[0]) $fatal(1,"copy timeout");
    repeat(40) @(negedge clk);
    if(writes-old_writes!=expected_writes) $fatal(1,"copy: missing bytes (got %0d exp %0d)", writes-old_writes, expected_writes);
    for(n=0;n<65536;n=n+1) if(expected[n]>=0) $fatal(1,"copy: missing byte %0d",n);
    tests=tests+1;
    end
endtask

integer alignment,width;
initial begin
    // Initialize test source memory with recognizable pattern
    for (int i=0; i<65536; i=i+1) src_mem[i] = (i ^ 8'h5A) & 8'hFF;
    
    repeat(5) @(negedge clk); rst_n=1;
    
    // --- 1. Test OP_FILL (Solid Fill) ---
    for(alignment=0;alignment<4;alignment=alignment+1) begin
        for(width=1;width<=5;width=width+1) fill(alignment*4,width,3);
        fill(alignment*4,63,3); fill(alignment*4,64,3); fill(alignment*4,65,3);
    end
    fill(2048,512,4); fill(0,1024,2); fill(4092,65,2); fill(0,0,3); fill(0,32,0);
    
    // --- 2. Test OP_COPY (Block Copy) ---
    copy(0, 0, 16, 4);
    copy(64, 128, 32, 2);
    copy(0, 2048, 64, 3);
    copy(16, 4096+16, 65, 2);
    
    // --- 3. Test Double-buffering handshake ---
    vsync=1; repeat(3) @(negedge clk); vsync=0;
    apb_write(16'h20, 28'h0130_0000); apb_read(16'h28, status);
    if(status!==32'h0100_0000) $fatal(1,"active base acknowledged early");
    active=28'h0130_0000; apb_read(16'h28, status);
    if(status!==32'h0130_0000) $fatal(1,"active base readback");
    
    $display("PASS BitBlt RTL: %0d operations (OP_FILL + OP_COPY), %0d exact byte writes, AXI Read/Write bursts, sticky Done", tests, writes);
    $finish;
end

initial begin #50000000; $fatal(1,"global timeout"); end
endmodule
