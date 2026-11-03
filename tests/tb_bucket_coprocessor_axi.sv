`timescale 1ns/1ps
module tb_bucket_coprocessor_axi;
`ifdef BUCKET_TEST_20000
    localparam SLOTS=1024, ECAP=20480, RLEN=16;
`elsif BUCKET_TEST_10000
    localparam SLOTS=1024, ECAP=10240, RLEN=16;
`elsif BUCKET_TEST_LARGE
    localparam SLOTS=1024, ECAP=8192, RLEN=16;
`else
    localparam SLOTS=128, ECAP=6144, RLEN=1;
`endif
    localparam WORDS=96*SLOTS, UBYTES=SLOTS>255?2:1;
`ifdef BUCKET_TEST_BUS_LOADED
    localparam integer TICK_LIMIT = 60000000;
`else
    localparam integer TICK_LIMIT = 10000000;
`endif
    reg clk=0, rst_n=0, start=0, clear_ledger=0, buffer_sel=0;
    always #5 clk=~clk;
    reg [14:0] eb_count=0;
    reg [9:0] pb_count=0;
    reg [31:0] player_xy={16'd512,16'd683};
    wire busy, done, fault;
    wire [15:0] drop_count;
    wire [31:0] cycles;
    wire [3:0] arid, awid, wid;
    wire [27:0] araddr, awaddr;
    wire [7:0] arlen, awlen;
    wire [2:0] arsize, awsize;
    wire [1:0] arburst, arlock, awburst, awlock;
    wire arvalid, arready, rready, awvalid, awready, wlast, wvalid, wready, bready;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    reg [127:0] rdata=0;
    reg rvalid=0, bvalid=0, rlast=0;
    wire c_rlast;
    reg [1:0] rresp=0, bresp=0;
    wire [3:0] c_arid;
    wire [27:0] c_araddr;
    wire [7:0] c_arlen;
    wire [2:0] c_arsize;
    wire [1:0] c_arburst;
    wire [1:0] c_arlock;
    wire c_arvalid;
    wire c_arready;
    wire [3:0] c_awid;
    wire [27:0] c_awaddr;
    wire [7:0] c_awlen;
    wire [2:0] c_awsize;
    wire [1:0] c_awburst;
    wire [1:0] c_awlock;
    wire c_awvalid;
    wire c_awready;
    wire [3:0] c_wid;
    wire [127:0] c_wdata;
    wire [15:0] c_wstrb;
    wire c_wlast;
    wire c_wvalid;
    wire c_wready;
    wire [127:0] c_rdata;
    wire [1:0] c_rresp;
    wire c_rvalid;
    wire c_rready;
    wire [1:0] c_bresp;
    wire c_bvalid;
    wire c_bready;
`ifdef BUCKET_TEST_MUX
    wire [31:0] mux_awaddr,mux_araddr;
    reg compete=0;
    reg [7:0] compete_tick=0;
    wire compete_ready;
    wire bus_awvalid,bus_awready,bus_wvalid,bus_wready;
`ifdef BUCKET_TEST_BOARD
    reg [8:0] refill_tick=0;
    always @(posedge clk) refill_tick<=rst_n ? refill_tick+1'b1 : 0;
`ifdef BUCKET_TEST_BUS_LOADED
    // -DBUCKET_TEST_BUS_LOADED reproduces the board at sprite 1300: the CPU
    // (S1) holds ARVALID high for the whole job - a dcache miss on every
    // bullet access - and a BitBlt-style master (S2) asks for read bursts
    // back to back.  Both are in the request set at every cycle, which is the
    // one condition the vendor address arbiter cannot serve: see
    // tb_axi_grant_trace, where channel 3 gets 0 of 1538 grants.
    //
    // The scanout is also given a normal 12.5% refill duty instead of the 94%
    // of the plain board test, because the board's measured job time is
    // 45-54k cycles (fast), not 1.4M: writes are almost never held at the
    // guard, so the job is READ bound and its read channel has to be handed
    // the bus often enough to finish inside the 4,000,000-cycle watchdog.
    wire s1_ar_valid=1'b1, s1_r_ready=1'b1;
    wire s1_ar_ready;
    wire s2_ar_valid=1'b1, s2_r_ready=1'b1;
    wire s2_ar_ready;
    wire video_prio = refill_tick<9'd64;
    integer s1_grants=0, s2_grants=0;
    always @(posedge clk) begin
        if(rst_n && s1_ar_valid && s1_ar_ready) s1_grants=s1_grants+1;
        if(rst_n && s2_ar_valid && s2_ar_ready) s2_grants=s2_grants+1;
    end
`else
    wire s1_ar_valid=1'b0, s1_r_ready=1'b0;
    wire s2_ar_valid=1'b0, s2_r_ready=1'b0;
    wire video_prio = refill_tick<9'd480;
`endif
    video_write_guard guard(.clk(clk),.rst_n(rst_n),.video_priority(video_prio),
        .s_awvalid(bus_awvalid),.s_awready(bus_awready),.m_awvalid(awvalid),.m_awready(awready),
        .s_wvalid(bus_wvalid),.s_wready(bus_wready),.m_wvalid(wvalid),.m_wready(wready),
        .bvalid(bvalid),.bready(bready));
`else
    assign awvalid=bus_awvalid;
    assign bus_awready=awready;
    assign wvalid=bus_wvalid;
    assign bus_wready=wready;
`endif
    always @(posedge clk) compete_tick<=rst_n ? compete_tick+1'b1 : 0;
    always @(posedge clk) begin
        if(!rst_n) compete<=0;
        else if(compete && compete_ready) compete<=0;
        else if(compete_tick==0) compete<=1;
    end
    assign awaddr=mux_awaddr[27:0];
    assign araddr=mux_araddr[27:0];
    assign c_bresp=bresp;
    Axi_Mux #(.SLAVE_ID_WIDTH(4),.AXI_DATA_WIDTH(128)) mux (
        .Sys_Clk(clk),
        .Sys_Rst_N(rst_n),
        .Cfg_Arb_Type(1'b1),
        .Cfg_Cnl_Mask(4'b1111),
        .O_M_AW_ID(awid),
        .O_M_AW_ADDR({mux_awaddr}),
        .O_M_AW_LEN(awlen),
        .O_M_AW_SIZE(awsize),
        .O_M_AW_BURST(awburst),
        .O_M_AW_LOCK(awlock),
        .O_M_AW_VALID(bus_awvalid),
        .I_M_AW_READY(bus_awready),
        .O_M_W_ID(wid),
        .O_M_W_DATA(wdata),
        .O_M_W_LAST(wlast),
        .O_M_W_STRB(wstrb),
        .O_M_W_VALID(bus_wvalid),
        .I_M_W_READY(bus_wready),
        .I_M_B_ID(4'd3),
        .I_M_B_VALID(bvalid),
        .O_M_B_READY(bready),
        .O_M_AR_ID(arid),
        .O_M_AR_ADDR({mux_araddr}),
        .O_M_AR_LEN(arlen),
        .O_M_AR_SIZE(arsize),
        .O_M_AR_BURST(arburst),
        .O_M_AR_LOCK(arlock),
        .O_M_AR_VALID(arvalid),
        .I_M_AR_READY(arready),
        .I_M_R_ID(4'd3),
        .I_M_R_DATA(rdata),
        .I_M_R_LAST(rlast),
        .I_M_R_RESP(rresp),
        .I_M_R_VALID(rvalid),
        .O_M_R_READY(rready),
        .I_S0_AW_ID('0),
        .I_S0_AW_ADDR('0),
        .I_S0_AW_LEN('0),
        .I_S0_AW_SIZE('0),
        .I_S0_AW_BURST('0),
        .I_S0_AW_LOCK('0),
        .I_S0_AW_VALID('0),
        .O_S0_AW_READY(),
        .I_S0_W_ID('0),
        .I_S0_W_DATA('0),
        .I_S0_W_LAST('0),
        .I_S0_W_STRB('0),
        .I_S0_W_VALID('0),
        .O_S0_W_READY(),
        .O_S0_B_ID(),
        .O_S0_B_VALID(),
        .I_S0_B_READY(1'b1),
        .I_S0_AR_ID('0),
        .I_S0_AR_ADDR(32'h01620000),
        .I_S0_AR_LEN(8'(RLEN-1)),
        .I_S0_AR_SIZE(3'd4),
        .I_S0_AR_BURST(2'd1),
        .I_S0_AR_LOCK('0),
        .I_S0_AR_VALID(compete),
        .O_S0_AR_READY(compete_ready),
        .O_S0_R_ID(),
        .O_S0_R_DATA(),
        .O_S0_R_LAST(),
        .O_S0_R_RESP(),
        .O_S0_R_VALID(),
        .I_S0_R_READY(1'b1),
        .I_S1_AW_ID('0),
        .I_S1_AW_ADDR('0),
        .I_S1_AW_LEN('0),
        .I_S1_AW_SIZE('0),
        .I_S1_AW_BURST('0),
        .I_S1_AW_LOCK('0),
        .I_S1_AW_VALID('0),
        .O_S1_AW_READY(),
        .I_S1_W_ID('0),
        .I_S1_W_DATA('0),
        .I_S1_W_LAST('0),
        .I_S1_W_STRB('0),
        .I_S1_W_VALID('0),
        .O_S1_W_READY(),
        .O_S1_B_ID(),
        .O_S1_B_VALID(),
        .I_S1_B_READY('0),
        .I_S1_AR_ID('0),
        .I_S1_AR_ADDR(32'h0167_5400),
        .I_S1_AR_LEN(8'd15),
        .I_S1_AR_SIZE(3'd4),
        .I_S1_AR_BURST(2'd1),
        .I_S1_AR_LOCK('0),
        .I_S1_AR_VALID(s1_ar_valid),
        .O_S1_AR_READY(s1_ar_ready),
        .O_S1_R_ID(),
        .O_S1_R_DATA(),
        .O_S1_R_LAST(),
        .O_S1_R_RESP(),
        .O_S1_R_VALID(),
        .I_S1_R_READY(s1_r_ready),
        .I_S2_AW_ID('0),
        .I_S2_AW_ADDR('0),
        .I_S2_AW_LEN('0),
        .I_S2_AW_SIZE('0),
        .I_S2_AW_BURST('0),
        .I_S2_AW_LOCK('0),
        .I_S2_AW_VALID('0),
        .O_S2_AW_READY(),
        .I_S2_W_ID('0),
        .I_S2_W_DATA('0),
        .I_S2_W_LAST('0),
        .I_S2_W_STRB('0),
        .I_S2_W_VALID('0),
        .O_S2_W_READY(),
        .O_S2_B_ID(),
        .O_S2_B_VALID(),
        .I_S2_B_READY('0),
        .I_S2_AR_ID('0),
        .I_S2_AR_ADDR(32'h0167_5400),
        .I_S2_AR_LEN(8'd15),
        .I_S2_AR_SIZE(3'd4),
        .I_S2_AR_BURST(2'd1),
        .I_S2_AR_LOCK('0),
        .I_S2_AR_VALID(s2_ar_valid),
        .O_S2_AR_READY(s2_ar_ready),
        .O_S2_R_ID(),
        .O_S2_R_DATA(),
        .O_S2_R_LAST(),
        .O_S2_R_RESP(),
        .O_S2_R_VALID(),
        .I_S2_R_READY(s2_r_ready),
        .I_S3_AW_ID(c_awid),
        .I_S3_AW_ADDR({4'd0,c_awaddr}),
        .I_S3_AW_LEN(c_awlen),
        .I_S3_AW_SIZE(c_awsize),
        .I_S3_AW_BURST(c_awburst),
        .I_S3_AW_LOCK(c_awlock),
        .I_S3_AW_VALID(c_awvalid),
        .O_S3_AW_READY(c_awready),
        .I_S3_W_ID(c_wid),
        .I_S3_W_DATA(c_wdata),
        .I_S3_W_LAST(c_wlast),
        .I_S3_W_STRB(c_wstrb),
        .I_S3_W_VALID(c_wvalid),
        .O_S3_W_READY(c_wready),
        .O_S3_B_ID(),
        .O_S3_B_VALID(c_bvalid),
        .I_S3_B_READY(c_bready),
        .I_S3_AR_ID(c_arid),
        .I_S3_AR_ADDR({4'd0,c_araddr}),
        .I_S3_AR_LEN(c_arlen),
        .I_S3_AR_SIZE(c_arsize),
        .I_S3_AR_BURST(c_arburst),
        .I_S3_AR_LOCK(c_arlock),
        .I_S3_AR_VALID(c_arvalid),
        .O_S3_AR_READY(c_arready),
        .O_S3_R_ID(),
        .O_S3_R_DATA(c_rdata),
        .O_S3_R_LAST(c_rlast),
        .O_S3_R_RESP(c_rresp),
        .O_S3_R_VALID(c_rvalid),
        .I_S3_R_READY(c_rready)
    );
`else
    assign arid=c_arid;
    assign araddr=c_araddr;
    assign arlen=c_arlen;
    assign arsize=c_arsize;
    assign arburst=c_arburst;
    assign arlock=c_arlock;
    assign arvalid=c_arvalid;
    assign c_arready=arready;
    assign awid=c_awid;
    assign awaddr=c_awaddr;
    assign awlen=c_awlen;
    assign awsize=c_awsize;
    assign awburst=c_awburst;
    assign awlock=c_awlock;
    assign awvalid=c_awvalid;
    assign c_awready=awready;
    assign wid=c_wid;
    assign wdata=c_wdata;
    assign wstrb=c_wstrb;
    assign wlast=c_wlast;
    assign wvalid=c_wvalid;
    assign c_wready=wready;
    assign c_rdata=rdata;
    assign c_rresp=rresp;
    assign c_rvalid=rvalid;
    assign rready=c_rready;
    assign c_bresp=bresp;
    assign c_bvalid=bvalid;
    assign bready=c_bready;
    assign c_rlast=rlast;
`endif
    reg expect_fault=0;
    reg motion=0;
    wire [15:0] live_count, kill_count, cand_count;
    dma_bucket_coprocessor #(.TABLE_SLOTS(SLOTS),.EB_CAPACITY(ECAP),.BURST_READ_LEN(RLEN)) dut (
        .clk(clk),.rst_n(rst_n),.start(start),.clear_ledger(clear_ledger),
        .buffer_sel(buffer_sel),.eb_count(eb_count),.pb_count(pb_count),.player_xy(player_xy),
        .motion_en(motion),.bound_x(32'h03DC_00B6),.bound_y(32'h02FF_0001),
        .eb_live(live_count),.eb_kill(kill_count),.eb_cand(cand_count),
        .busy(busy),.done(done),.fault(fault),.cycles(cycles),.drop_count(drop_count),
        .m_axi_arid(c_arid),.m_axi_araddr(c_araddr),.m_axi_arlen(c_arlen),
        .m_axi_arsize(c_arsize),.m_axi_arburst(c_arburst),.m_axi_arlock(c_arlock),
        .m_axi_arvalid(c_arvalid),.m_axi_arready(c_arready),.m_axi_rid(4'd3),
        .m_axi_rdata(c_rdata),.m_axi_rresp(c_rresp),.m_axi_rlast(c_rlast),
        .m_axi_rvalid(c_rvalid),.m_axi_rready(c_rready),
        .m_axi_awid(c_awid),.m_axi_awaddr(c_awaddr),.m_axi_awlen(c_awlen),
        .m_axi_awsize(c_awsize),.m_axi_awburst(c_awburst),.m_axi_awlock(c_awlock),
        .m_axi_awvalid(c_awvalid),.m_axi_awready(c_awready),.m_axi_wid(c_wid),
        .m_axi_wdata(c_wdata),.m_axi_wstrb(c_wstrb),.m_axi_wlast(c_wlast),
        .m_axi_wvalid(c_wvalid),.m_axi_wready(c_wready),.m_axi_bid(4'd3),
        .m_axi_bresp(c_bresp),.m_axi_bvalid(c_bvalid),.m_axi_bready(c_bready)
    );
    reg [63:0] pb[0:511], eb[0:ECAP-1];
    reg [63:0] expected_eb[0:ECAP-1];
    reg [15:0] candidates[0:511], expected_cand[0:511];
    localparam CAND_BASE=28'h1675400+ECAP*8+(ECAP-512)*2;
    integer expected_live, expected_kill, expected_nc;
    reg [31:0] mem[0:WORDS*2-1], expected[0:WORDS-1];
    reg [7:0] ledger[0:192*UBYTES-1];
    integer counts[0:95], drops;
    integer tick=0, aqw=0, aqr=0, wqw=0, wqr=0, replies=0, delay_r=0;
    integer beat_left=0;
    reg beating=0;
    reg [27:0] aq[0:65535], read_addr, beat_addr;
    reg [7:0] alen_q[0:65535];
    reg [143:0] wq[0:65535];
    reg wlast_q[0:65535];
    reg [31:0] rng=32'h17cafe01;
    integer read_remaining=0;
    assign arready=(delay_r==0 && !rvalid && read_remaining==0 && rng[0]);
    assign awready=rng[3] && tick%11!=0;
    assign wready=rng[7] && tick%13!=0;
    integer i,j,idx;
    reg old_awstall=0,old_wstall=0,old_arstall=0;
    reg [27:0] held_aw,held_ar;
    reg [7:0] held_awlen;
    reg [143:0] held_w;
    reg held_wlast;
    always @(posedge clk) if(rst_n) begin
        tick=tick+1;
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if(old_awstall && (!awvalid || awaddr!==held_aw || awlen!==held_awlen)) $fatal(1,"AW changed while stalled");
        if(old_arstall && (!arvalid || araddr!==held_ar)) $fatal(1,"AR changed while stalled");
        if(old_wstall && (!wvalid || {wstrb,wdata}!==held_w || wlast!==held_wlast)) $fatal(1,"W changed while stalled");
        old_awstall=awvalid&&!awready; held_aw=awaddr; held_awlen=awlen;
        old_arstall=arvalid&&!arready; held_ar=araddr;
        old_wstall=wvalid&&!wready; held_w={wstrb,wdata}; held_wlast=wlast;
        if(rvalid && rready) begin
            rvalid<=0;
            read_remaining=read_remaining-1;
            if(read_remaining>0) begin
                read_addr=read_addr+16;
                delay_r=2+(rng[7:0]%4);
            end
        end
        if(delay_r>0) begin
            delay_r=delay_r-1;
            if(delay_r==0) begin
                if(read_addr>=28'h1675400 && read_addr<28'h1675400+ECAP*8) begin
                    idx=(read_addr-28'h1675400)/8;
                    rdata<={eb[idx+1],eb[idx]};
                end else if(read_addr>=28'h1620000 && read_addr<28'h1621000) begin
                    idx=(read_addr-28'h1620000)/8;
                    rdata<={pb[idx+1],pb[idx]};
                end else $fatal(1,"invalid pool read %h",read_addr);
                rvalid<=1;rlast<=read_remaining==1;
            end
        end
        if(arvalid && arready) begin
            if(arlen!=RLEN-1 || arsize!=4 || araddr[3:0]!=0) $fatal(1,"AR format");
            if(araddr[11:0]+(arlen+1)*16>4096) $fatal(1,"4KiB boundary");
            read_addr=araddr; delay_r=3+(rng[15:8]%27);read_remaining=RLEN;
        end
        if(awvalid && awready) begin
            if(awsize!=4 || awaddr[3:0]!=0 || awlen>8'd15) $fatal(1,"AW format len=%0d",awlen);
            if(awaddr[11:0]+(awlen+1)*16>4096) $fatal(1,"write 4KiB boundary");
            aq[aqw%65536]=awaddr; alen_q[aqw%65536]=awlen; aqw=aqw+1;
        end
        if(wvalid && wready) begin
            wq[wqw%65536]={wstrb,wdata}; wlast_q[wqw%65536]=wlast; wqw=wqw+1;
        end
        // One AW owns (awlen+1) W beats and one B response. Bucket and ledger
        // writes stay awlen 0; motion writeback is a chunk burst.
        if(!beating && aqr<aqw && wqr<wqw) begin
            beating=1; beat_addr=aq[aqr%65536]; beat_left=alen_q[aqr%65536]+1;
        end
        if(beating && wqr<wqw) begin
            if((beat_left==1)!=wlast_q[wqr%65536])
                $fatal(1,"WLAST mismatch at %h left=%0d wlast=%b",beat_addr,beat_left,wlast_q[wqr%65536]);
            if(beat_addr>=28'h4800000 && beat_addr<28'h4800000+WORDS*8) begin
                idx=(beat_addr-28'h4800000)/4;
                for(j=0;j<16;j=j+1) if(wq[wqr%65536][128+j])
                    mem[idx+j/4][(j%4)*8+:8]=wq[wqr%65536][j*8+:8];
            end else if(beat_addr>=28'h48c1000 && beat_addr<28'h48c1000+192*UBYTES) begin
                idx=beat_addr-28'h48c1000;
                for(j=0;j<16;j=j+1) if(wq[wqr%65536][128+j])
                    ledger[idx+j]=wq[wqr%65536][j*8+:8];
            end else if(beat_addr>=28'h1675400 && beat_addr<28'h1675400+ECAP*8) begin
                idx=(beat_addr-28'h1675400)/8;
                for(j=0;j<16;j=j+1) if(wq[wqr%65536][128+j])
                    eb[idx+j/8][(j%8)*8+:8]=wq[wqr%65536][j*8+:8];
            end else if(beat_addr>=CAND_BASE && beat_addr<CAND_BASE+1024) begin
                idx=(beat_addr-CAND_BASE)/2;
                for(j=0;j<16;j=j+1) if(wq[wqr%65536][128+j])
                    candidates[idx+j/2][(j%2)*8+:8]=wq[wqr%65536][j*8+:8];
            end else $fatal(1,"invalid write %h",beat_addr);
            wqr=wqr+1; beat_addr=beat_addr+16; beat_left=beat_left-1;
            if(beat_left==0) begin beating=0; aqr=aqr+1; replies=replies+1; end
        end
        if(bvalid && bready) begin bvalid<=0; replies=replies-1; end
        // Responses deliberately much slower than independent AW/W channels.
`ifdef BUCKET_TEST_BOARD
        if(!bvalid && replies>0 && tick%1051==0) bvalid<=1;
`else
        if(!bvalid && replies>0 && tick%41==0) bvalid<=1;
`endif
        if(dut.wr_pend>8) $fatal(1,"outstanding credit overflow");
        if(tick>TICK_LIMIT) begin
            $display("state=%d idx=%d pend=%d AR=%b/%b cAR=%b/%b R=%b/%b cR=%b/%b AW=%b/%b W=%b/%b B=%b/%b aq=%d/%d wq=%d/%d replies=%d",
                dut.state,dut.bullet_idx,dut.wr_pend,arvalid,arready,c_arvalid,c_arready,
                rvalid,rready,c_rvalid,c_rready,awvalid,awready,wvalid,wready,bvalid,bready,aqw,aqr,wqw,wqr,replies);
            $fatal(1,"timeout");
        end
    end
    function integer heading(input integer dx,dy);
        integer ax,ay,q;
        begin
            ax=dx<0?-dx:dx;ay=dy<0?-dy:dy;
            if(dy==0) heading=dx==0?4:dx<0?8:0;
            else begin
                q=ay*5<=ax?0:ay*3<=ax*2?1:ay*2<=ax*3?2:ay<=ax*5?3:4;
                if(dx<0) q=8-q;
                heading=(dy<0?-q:q)&15;
            end
        end
    endfunction
    function integer bounds(input integer s);
        case(s)
            2,6:bounds=710;3,4,5:bounds=742;
            10,14:bounds=677;11,12,13:bounds=676;
            16,18:bounds=832;17:bounds=481;
            19,20,21,22,23,24,25,26:bounds=768;default:bounds=647;
            27:bounds=295;28:bounds=389;
            29,30,31,32,33,34,35,36:bounds=832;
        endcase
    endfunction
    task reference_bullet(input reg [63:0] b,input integer player);
        integer x,y,vx,vy,f,c,s,w,row,bx,t,lo,hi,g,word;
        begin
            x=$signed(b[15:0]);y=$signed(b[31:16]);vx=$signed(b[39:32]);vy=$signed(b[47:40]);
            f=b[55:48];c=b[63:56];
            if((f&1)!=0) begin
                if(player) begin s=(f&2)!=0?18:16;w=s==18?13:7;row=y;bx=x;end
                else if((f&128)!=0) begin s=(c&128)!=0?28:27;w=16;row=y-8;bx=x-8;end
                else if((f&8)!=0) begin s=19+(heading(vx,vy)>>1);w=24;row=y-12;bx=x-12;end
                else if((f&32)!=0) begin s=29+(heading(vx,vy)>>1);w=26;row=y-13;bx=x-13;end
                else if((f&64)!=0) begin s=17;w=16;row=y-8;bx=x-8;end
                else if((c&192)==64) begin s=29+(((f&4)!=0 || (vx==0&&vy==0) ? heading(683-x,512-y) : heading(vx,vy))>>1);w=26;row=y-13;bx=x-13;end
                else begin
                    if((f&4)!=0) s=heading(683-x,512-y);
                    else if((c&128)!=0) s=(c>>3)&15;
                    else s=(vx==0&&vy==0)?heading(683-x,512-y):heading(vx,vy);
                    w=26;row=y-13;bx=x-13;
                end
                t=bounds(s);lo=row+(t&31);hi=row+(t>>5);
                if(lo<0)lo=0;if(hi>768)hi=768;
                if(lo<hi) for(g=lo/8;g<=(hi-1)/8;g=g+1) begin
                    word=((c&7)<<29)|(w<<24)|(s<<17)|(((g*8-row+8)&63)<<11)|(bx&2047);
                    if(counts[g]<SLOTS)begin expected[g*SLOTS+counts[g]]=word;counts[g]=counts[g]+1;end
                    else drops=drops+1;
                end
            end
        end
    endtask
    task run_frame(input integer target,np,ne);
        integer k,n,x,y;
        begin
            for(k=0;k<WORDS;k=k+1)expected[k]=0;
            for(k=0;k<96;k=k+1)counts[k]=0;
            drops=0;
            expected_live=0;expected_kill=0;expected_nc=0;
            for(k=0;k<ECAP;k=k+1) begin
                expected_eb[k]=eb[k];
                if(motion && ((k<ne && k<ECAP-128)||k>=ECAP-128) && eb[k][48]) begin
                    if(k<ECAP-128 && !(eb[k][51] || eb[k][53] || eb[k][55])) begin
                        x=$signed(eb[k][15:0])+$signed(eb[k][39:32]);
                        y=$signed(eb[k][31:16])+$signed(eb[k][47:40]);
                        if(x<182||x>1169||y<1||y>767) begin
                            expected_eb[k][48]=0;expected_kill=expected_kill+1;
                        end else begin
                            expected_eb[k][15:0]=x;expected_eb[k][31:16]=y;
                            if(x>=668 && x<=698 && y>=497 && y<=527) begin
                                if(expected_nc<512) expected_cand[expected_nc]=k;
                                expected_nc=expected_nc+1;
                            end
                        end
                    end
                    if(expected_eb[k][48]) expected_live=expected_live+1;
                end
            end
            for(k=0;k<np&&k<512;k=k+1)reference_bullet(pb[k],1);
            for(k=0;k<ne&&k<ECAP-128;k=k+1)reference_bullet(expected_eb[k],0);
            for(k=ECAP-128;k<ECAP;k=k+1)reference_bullet(expected_eb[k],0);
            @(negedge clk);buffer_sel=target;pb_count=np;eb_count=ne;start=1;
            player_xy={16'd512,16'd683};
            @(negedge clk);start=0;
            player_xy={16'd12,16'd34};pb_count=0;eb_count=0;
            wait(done);@(negedge clk);
            if(busy||aqw!=aqr||wqw!=wqr||replies!=0) $fatal(1,"premature done");
            if(fault!=expect_fault||drop_count!=drops) $fatal(1,"fault/drop mismatch fault=%0d cycles=%0d drops=%0d expected=%0d",fault,cycles,drop_count,drops);
`ifdef BUCKET_TEST_SNAPSHOT
            if(fault && dut.debug_snapshot[31:29]==0) $fatal(1,"fault snapshot missing");
`endif
`ifdef BUCKET_TEST_BOARD
            if(cycles>2000000) $fatal(1,"1088-load job exceeded 20 ms budget: %0d",cycles);
`endif
            if(motion) begin
                if(live_count!=expected_live||kill_count!=expected_kill||cand_count!=expected_nc)
                    $fatal(1,"motion counts live=%0d/%0d kill=%0d/%0d cand=%0d/%0d",live_count,expected_live,kill_count,expected_kill,cand_count,expected_nc);
                for(k=0;k<ECAP;k=k+1) if(eb[k]!==expected_eb[k])
                    $fatal(1,"motion record %0d actual=%h expected=%h",k,eb[k],expected_eb[k]);
                for(k=0;k<expected_nc && k<512;k=k+1) if(candidates[k]!==expected_cand[k])
                    $fatal(1,"candidate %0d mismatch",k);
            end
            for(k=0;k<WORDS;k=k+1) if(mem[target*WORDS+k]!==expected[k])
                $fatal(1,"table %d word %d actual %h expected %h",target,k,mem[target*WORDS+k],expected[k]);
            for(k=0;k<96;k=k+1) begin
                n=ledger[(target*96+k)*UBYTES];
                if(UBYTES==2) n=n+256*ledger[(target*96+k)*UBYTES+1];
                if(n!==counts[k]) $fatal(1,"ledger mismatch");
            end
            $display("PASS buffer=%0d pb=%0d eb=%0d drops=%0d cycles=%0d",target,np,ne,drops,cycles);
`ifdef BUCKET_TEST_BUS_LOADED
            $display("     competing bus reads granted so far: cpu=%0d bitblt=%0d",s1_grants,s2_grants);
`endif
        end
    endtask
    function [63:0] bullet(input integer x,y,vx,vy,f,c);
        bullet={c[7:0],f[7:0],vy[7:0],vx[7:0],y[15:0],x[15:0]};
    endfunction
`ifdef BUCKET_TEST_BUS_LOADED
    // The job must not need millions of cycles.  5,000,000 is above the
    // coprocessor's own 4,000,000-cycle watchdog, so a job that reaches it has
    // already set fault and is dragging the frame down exactly as the board's
    // T = 10,027,312 line shows.
    always @(posedge clk) if (rst_n && busy && cycles > 5000000) begin
        $display("FAIL bucket job did not finish inside 5,000,000 cycles: state=%0d bullet=%0d/%0d busy=%b fault=%b cycles=%0d drop=%0d",
                 dut.state, dut.bullet_idx, dut.bullet_limit, busy, fault, cycles, drop_count);
        $display("     wr_pend=%0d aw=%b/%b w=%b/%b b=%b/%b aq=%0d/%0d wq=%0d/%0d replies=%0d",
                 dut.wr_pend, c_awvalid, c_awready, c_wvalid, c_wready,
                 c_bvalid, c_bready, aqw, aqr, wqw, wqr, replies);
        $display("     competing bus reads granted: cpu=%0d bitblt=%0d", s1_grants, s2_grants);
        $fatal(1, "bucket job starved on the bus");
    end
`endif
    initial begin
        for(i=0;i<512;i=i+1)pb[i]=0;
        for(i=0;i<ECAP;i=i+1)eb[i]=0;
        for(i=0;i<WORDS*2;i=i+1)mem[i]=0;
        for(i=0;i<192*UBYTES;i=i+1)ledger[i]=0;
        repeat(4)@(negedge clk);rst_n=1;
`ifdef BUCKET_TEST_20000
        motion=1;
        // One bullet on each of the 96 groups, walked across X. vy=±1 keeps
        // the next frame inside the playfield. 20000 is a multiple of 32, so
        // the last read chunk is full and the 15-bit index is past 16383.
        for(i=0;i<20000;i=i+1)
`ifdef BUCKET_TEST_GLOW
            eb[i]=bullet(300+(i%800), 4+((i%96)*8), 1, (i[0]?1:-1), 1, 64|i[2:0]);
`else
            eb[i]=bullet(300+(i%800), 4+((i%96)*8), 1, (i[0]?1:-1), 1, i[2:0]);
`endif
        run_frame(0,0,20000);
        if(drops!=0) $fatal(1,"20000 stratified field dropped %0d",drops);
        // The direct slave is the frame-budget measurement. The mux and the
        // board guard add a competing master, so they only have to finish.
`ifndef BUCKET_TEST_MUX
`ifdef BUCKET_TEST_GLOW
        // The full 26-row glow writes more bucket entries than the rice mask.
        // Bound this distinct workload to 10 ms at 100 MHz, leaving 3.33 ms
        // of a 75 Hz frame for other work (not a board-level FPS assertion).
        if(cycles>1000000) $fatal(1,"20000 glow job exceeded 10 ms: %0d",cycles);
`else
        if(cycles>750000) $fatal(1,"20000 motion job exceeded 7.5 ms: %0d",cycles);
`endif
`endif
        run_frame(1,0,20000);
        if(drops!=0) $fatal(1,"20000 second buffer dropped %0d",drops);
`ifndef BUCKET_TEST_MUX
`ifdef BUCKET_TEST_GLOW
        if(cycles>1000000) $fatal(1,"20000 glow job exceeded 10 ms: %0d",cycles);
`else
        if(cycles>750000) $fatal(1,"20000 motion job exceeded 7.5 ms: %0d",cycles);
`endif
`endif
`ifdef BUCKET_TEST_GLOW
        $display("PASS 20000 GLOW MOTION: both buffers, drops=0, cycles=%0d",cycles);
`else
        $display("PASS 20000 MOTION: both buffers, drops=0, cycles=%0d",cycles);
`endif
        $finish;
`elsif BUCKET_TEST_BOARD
        motion=1;
`ifdef BUCKET_TEST_BUS_LOADED
`ifdef BUCKET_TEST_LOAD_8000
        for(i=0;i<8000;i=i+1)eb[i]=bullet(400+i%100,32+(i%8)*80,1,1,1,i%8);
        run_frame(0,0,8000);
        run_frame(1,0,7991);
`else
        for(i=0;i<1300;i=i+1)eb[i]=bullet(400+i%100,32+(i%8)*80,1,1,1,i%8);
        run_frame(0,0,1300);
        run_frame(1,0,1291);
`endif
`else
        for(i=0;i<1088;i=i+1)eb[i]=bullet(400+i%100,32+(i%8)*80,1,1,1,i%8);
        run_frame(0,0,1088);
        run_frame(1,0,1079);
`endif
`ifdef BUCKET_TEST_BUS_LOADED
        for(i=0;i<ECAP;i=i+1)eb[i]=0;
        run_frame(0,0,0);run_frame(1,0,0);
        $display("PASS BUS-LOADED CONTENTION: %0d load under CPU+BitBlt read pressure",
`ifdef BUCKET_TEST_LOAD_8000
                 8000);
`else
                 1300);
`endif
        $finish;
`else
        for(i=0;i<ECAP;i=i+1)eb[i]=0;
        run_frame(0,0,0);run_frame(1,0,0);
        $display("PASS BOARD CONTENTION: 1088 load, serialized slow B, video priority, live tables and stale clears");
        $finish;
`endif
`else
        run_frame(0,0,0);
        // All eight HTML spark orientations, including slots > 31.
        for(i=0;i<8;i=i+1) eb[i]=bullet(500+i*30,300,
            i==0?90:i==1?64:i==2?0:i==3?-64:i==4?-90:i==5?-64:i==6?0:64,
            i==0?0:i==1?64:i==2?90:i==3?64:i==4?0:i==5?-64:i==6?-90:-64,33,i);
        run_frame(0,0,8);run_frame(1,0,8);
        for(i=0;i<8;i=i+1) eb[i]=0;
        eb[0]=bullet(500,300,98,0,129,6);
        eb[1]=bullet(600,400,62,0,129,133);
        run_frame(0,0,2); run_frame(1,0,2);
        eb[0]=0;eb[1]=0;
        $display("PASS skill laser warning/fire tiles, both buffers");
        for(i=0;i<512;i=i+1)pb[i]=bullet(300+i%800,(i*23)%820-26,0,-5,i%2?3:1,i%8);
        for(i=0;i<ECAP;i=i+1)eb[i]=bullet(181+i%1000,(i*37)%820-26,i%15-7,i%13-6,
            i%17==0?0:i%23==0?9:i%19==0?65:i%29==0?5:1,(i%2?128:0)|((i%16)<<3)|(i%8));
        eb[0]=bullet(-32768,-32768,0,0,1,0);
        eb[1]=bullet(32767,32767,0,0,1,0);
        run_frame(0,511,4001);
        run_frame(1,512,ECAP);
        run_frame(0,1,3);
        for(i=0;i<ECAP;i=i+1)eb[i]=0;
        run_frame(1,0,0);run_frame(0,0,0);
        for(i=0;i<4000;i=i+1)eb[i]=bullet(500,200,2,0,1,3);
        run_frame(0,0,4000);
        rresp=2;expect_fault=1;run_frame(1,0,1);
`ifdef BUCKET_TEST_SNAPSHOT
        if(dut.debug_snapshot[31:29]!=2) $fatal(1,"RRESP cause was not captured");
`endif
        rresp=0;expect_fault=0;run_frame(1,0,1);
        bresp=2;expect_fault=1;run_frame(1,0,1);
`ifdef BUCKET_TEST_SNAPSHOT
        if(dut.debug_snapshot[31:29]!=2) $fatal(1,"first error snapshot was overwritten");
`endif
        bresp=0;expect_fault=0;run_frame(1,0,1);
        // clear is a CPU/DMA ownership operation, not a DDR memset command.
        @(negedge clk);clear_ledger=1;
        for(i=0;i<WORDS*2;i=i+1)mem[i]=0;
        for(i=0;i<192*UBYTES;i=i+1)ledger[i]=0;
        @(negedge clk);clear_ledger=0;
`ifdef BUCKET_TEST_SNAPSHOT
        if(dut.debug_snapshot!=0) $fatal(1,"snapshot did not clear with ledger");
        bresp=2;expect_fault=1;
`endif
        run_frame(0,1,1);
`ifdef BUCKET_TEST_SNAPSHOT
        if(dut.debug_snapshot[31:29]!=4) $fatal(1,"BRESP cause was not captured");
        bresp=0;expect_fault=0;
`endif
        run_frame(1,0,0);
        motion=1;
        // Integer-speed glow uses the same atlas as Q4 skills, but remains
        // DMA-owned. All eight orientations must retain colour[6] on writeback.
        for(i=0;i<8;i=i+1)eb[i]=bullet(500+i*30,300,2-i%5,i%3-1,1,64|i);
        run_frame(0,0,8);run_frame(1,0,8);
        for(i=0;i<8;i=i+1) begin
            if(eb[i][15:0]!=500+i*30+2*(2-i%5) ||
               eb[i][31:16]!=300+2*(i%3-1) || eb[i][63:56]!=(64|i))
                $fatal(1,"integer glow motion/colour mismatch at %0d",i);
            eb[i]=0;
        end
        $display("PASS integer glow sparks: atlas selection and DMA motion, both buffers");
        // CPU already advanced Q4 shots and timed lasers. DMA must bucket
        // them without interpreting fractional velocity or lifetime as pixels.
        eb[0]=bullet(500,300,24,-8,33,0);
        eb[1]=bullet(600,400,97,0,129,6);
        eb[ECAP-128]=bullet(700,500,3,2,65,0);
        eb[ECAP-1]=bullet(800,600,-3,2,65,0);
        run_frame(0,0,2);run_frame(1,0,2);
        if(eb[0]!=bullet(500,300,24,-8,33,0) ||
           eb[1]!=bullet(600,400,97,0,129,6) ||
           eb[ECAP-128]!=bullet(700,500,3,2,65,0) ||
           eb[ECAP-1]!=bullet(800,600,-3,2,65,0))
            $fatal(1,"DMA moved CPU-owned shots or reserved orb slots");
        $display("PASS motion ownership: Q4, timer lasers and both ends of 128-orb tail");
        for(i=0;i<ECAP;i=i+1) eb[i]=bullet(182+i%988,1+(i*37)%767,i%15-7,i%13-6,
            i%17==0?0:i%23==0?9:i%19==0?65:1,i%8);
        // Full scan, odd count, untouched tail, candidate saturation and empty pool.
        run_frame(0,512,ECAP);run_frame(1,3,4001);
        for(i=0;i<ECAP;i=i+1) eb[i]=i<600?bullet(683,512,0,0,1,0):0;
        run_frame(0,0,600);
        for(i=0;i<ECAP;i=i+1)eb[i]=0;
        run_frame(1,0,0);
        $display("ALL BUCKET AXI TESTS PASSED");$finish;
`endif
    end
endmodule
