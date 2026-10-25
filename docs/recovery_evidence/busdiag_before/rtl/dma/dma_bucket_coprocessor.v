`timescale 1ns/1ps
// =============================================================================
// dma_bucket_coprocessor.v
// -----------------------------------------------------------------------------
// Hardware Bucket Table Acceleration Coprocessor for Ti60 2D Graphics Engine.
//
// Responsibilities:
// - Offloads the CPU software bucket builder (performance must be measured).
// - Reads flat pbullets and ebullets arrays with AXI Burst-16 (16 beats = 32
//   sprites) when BURST_READ_LEN = 16, which is what rtl/ti60_top.v instantiates;
//   BURST_READ_LEN = 1 keeps the old one-beat-per-request path for A/B runs.
// - Computes tile slot, directional heading (aim_index), bounding rows, and Y groups.
// - Registers each sprite in EVERY 8-row group its occupied rows touch
//   (SINGLE_GROUP_REG = 0, what rtl/ti60_top.v instantiates with the scanline
//   rasterizer).  video_bullet_scanline.v paints a line from that group's table
//   alone, so there is no on-chip active pool to carry a sprite down; the 2.8x
//   per-group write inflation is the price of a 1024-slot lossless table, and it
//   buys DROP = 0 at the full 8160-sprite pool.  SINGLE_GROUP_REG = 1 remains
//   for the retired active-pool path (one entry, in the top group).
// - Directly writes 32-bit packed bucket entries into DDR3 MM_BUCKET_TABLE.
// - Automatically clears old unused table slots from the previous frame.
// - At most eight writes outstanding; completion waits for every response.
// - CPU must flush bullet data before start and not touch tables while busy.
// - clear_ledger is idle-only, after the CPU zeroes and flushes BOTH tables.
//
// Phase 2 - motion offload (start.motion_en = 1, enemy pool only):
//   stage 1 (ST_MOVE)  : X' = X + Vx, Y' = Y + Vy          (one adder per axis)
//   stage 2 (ST_CHECK) : playfield bounds -> kill, danger-box -> candidate
//   stage 3 (ST_EVAL)  : slot / bounding rows / group range from the NEW position
//   A moved record is written back to DDR (x,y: 4 bytes; a kill: the flags byte
//   only).  Lances (EF_LANCE) are left to the CPU: they bounce, they are few.
//   Two index lists come back through the write channel, 8 x uint16 per beat:
//     free list      MM_EBULLET_LIST            every inactive or just-killed
//                                               front-run slot, ascending
//     candidate list MM_EBULLET_LIST+FREE_CAP*2 every moved bullet that ended
//                                               inside the 129x129 danger box
//   so the CPU never scans for a free slot and never tests a bullet that is
//   nowhere near the player.  Lists are capped; the counters are not.
//   The motion ALU is pipelined (a new bullet may enter ST_MOVE every cycle);
//   the end-to-end rate of this FSM is lower and is set by the AXI read round
//   trip and the per-group bucket writes - see the testbench cycle report.
// =============================================================================

module dma_bucket_coprocessor #(
    parameter AXI_ADDR_WIDTH   = 28,
    parameter AXI_DATA_WIDTH   = 128,
    parameter EB_CAPACITY      = 6144,
    parameter BURST_READ_LEN   = 1,
    parameter SINGLE_GROUP_REG = 0,
    parameter TABLE_SLOTS = 128
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // APB / Control Interface
    input  wire                       start,          // 1-cycle pulse to start
    input  wire                       clear_ledger,   // 1-cycle pulse to reset old_first/old_end/used_count
    input  wire                       buffer_sel,     // 0: FB0 table (0x04800000), 1: FB1 table (0x0480C000)
    input  wire [13:0]                eb_count,       // enemy bullet front-run bound (up to 8192)
    input  wire [9:0]                 pb_count,       // player bullet bound (up to 512)
    input  wire [31:0]                player_xy,      // {player_y[15:0], player_x[15:0]}
    input  wire                       motion_en,      // with start: move/cull enemy bullets in DDR
    input  wire [31:0]                bound_x,        // {w[15:0], x0[15:0]}: alive iff 0 <= X'-x0 < w
    input  wire [31:0]                bound_y,        // {h[15:0], y0[15:0]}: alive iff 0 <= Y'-y0 < h
    output reg                        busy,
    output reg                        done,
    output reg  [15:0]                drop_count,
    output reg                        fault,
    output reg  [31:0]                cycles,
    output reg  [15:0]                eb_live,        // enemy bullets alive after the job (lances, orbs included)
    output reg  [15:0]                eb_kill,        // culled by this job
    output reg  [15:0]                eb_free,        // free-list length (CPU reads min(eb_free, FREE_CAP))
    output reg  [15:0]                eb_cand,        // candidate count (CPU reads min(eb_cand, CAND_CAP))

    // AXI4 Read Master (for reading ebullets and pbullets)
    output reg  [3:0]                 m_axi_arid,
    output reg  [AXI_ADDR_WIDTH-1:0]  m_axi_araddr,
    output reg  [7:0]                 m_axi_arlen,
    output wire [2:0]                 m_axi_arsize,
    output wire [1:0]                 m_axi_arburst,
    output wire [1:0]                 m_axi_arlock,
    output reg                        m_axi_arvalid,
    input  wire                       m_axi_arready,

    input  wire [3:0]                 m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_rdata,
    input  wire [1:0]                 m_axi_rresp,
    input  wire                       m_axi_rlast,
    input  wire                       m_axi_rvalid,
    output reg                        m_axi_rready,

    // AXI4 Write Master (for writing bucket entries and zeroing tail)
    output reg  [3:0]                 m_axi_awid,
    output reg  [AXI_ADDR_WIDTH-1:0]  m_axi_awaddr,
    output wire [7:0]                 m_axi_awlen,
    output wire [2:0]                 m_axi_awsize,
    output wire [1:0]                 m_axi_awburst,
    output wire [1:0]                 m_axi_awlock,
    output reg                        m_axi_awvalid,
    input  wire                       m_axi_awready,

    output reg  [3:0]                 m_axi_wid,
    output reg  [AXI_DATA_WIDTH-1:0]  m_axi_wdata,
    output reg  [15:0]                m_axi_wstrb,
    output wire                       m_axi_wlast,
    output reg                        m_axi_wvalid,
    input  wire                       m_axi_wready,

    input  wire [3:0]                 m_axi_bid,
    input  wire [1:0]                 m_axi_bresp,
    input  wire                       m_axi_bvalid,
    output wire                       m_axi_bready
);

    assign m_axi_bready = 1'b1;

    // Fixed DDR3 Memory Map Constants
    localparam [27:0] MM_PBULLET_BASE   = 28'h1620000;  // 0x01620000
    localparam [27:0] MM_EBULLET_BASE   = 28'h1675400;  // 0x01675400
    localparam [27:0] MM_BUCKET_TABLE_0 = 28'h4800000;  // 0x04800000
    localparam [27:0] MM_BUCKET_TABLE_1 = MM_BUCKET_TABLE_0 + 96*TABLE_SLOTS*4;
    localparam [27:0] MM_BUCKET_USED_0  = 28'h48C1000;  // 0x048C1000
    localparam integer COUNT_BITS = $clog2(TABLE_SLOTS+1);
    localparam integer USED_BYTES = TABLE_SLOTS > 255 ? 2 : 1;
    localparam [27:0] MM_BUCKET_USED_1 = MM_BUCKET_USED_0 + 96*USED_BYTES;

    // Index lists written back by the motion pass.  MM_EBULLET_LIST is the
    // region directly after the enemy pool (MM_EBULLET_ACTIVE_BASE in memory_map.h);
    // the free list grows up from its start, the candidate list lives in its last CAND_CAP entries.
    localparam [27:0] MM_EBULLET_LIST   = (EB_CAPACITY == 8192) ? 28'h1685400 : 28'h1681400;
    localparam [13:0] CAND_CAP          = 14'd512;
    localparam [13:0] FREE_CAP          = (EB_CAPACITY == 8192) ? 14'd7680 : 14'd5632;
    localparam [27:0] MM_EB_CAND_LIST   = (EB_CAPACITY == 8192) ? 28'h1689000 : 28'h1684000;
    localparam [13:0] EB_FRONT_RUN      = (EB_CAPACITY == 8192) ? 14'd8160 : 14'd6112;
    localparam [13:0] EB_TOTAL_LIMIT    = (EB_CAPACITY == 8192) ? 14'd8192 : 14'd6144;

    localparam [4:0]  BTILE_SLOT_PBULLET = 5'd16;
    localparam [4:0]  BTILE_SLOT_ORB     = 5'd17;
    localparam [4:0]  BTILE_SLOT_MISSILE = 5'd18;

    localparam [4:0]  MM_PBULLET_TILE_W   = 5'd7;
    localparam [4:0]  MM_MISSILE_TILE_W   = 5'd13;
    localparam [4:0]  MM_ORB_TILE_W       = 5'd16;
    localparam [4:0]  MM_EBULLET_DIRTILE_W= 5'd26;

    localparam signed [11:0] BUCKET_SCREEN_ROWS = 12'sd768;

    // AXI master static configurations
    assign m_axi_arsize  = 3'd4;   // 16 bytes = 128-bit
    assign m_axi_arburst = 2'b01;  // INCR
    assign m_axi_arlock  = 2'b00;

    assign m_axi_awsize  = 3'd4;   // 16 bytes = 128-bit
    assign m_axi_awburst = 2'b01;  // INCR
    assign m_axi_awlock  = 2'b00;
    assign m_axi_awlen   = 8'd0;   // Single beat writes
    assign m_axi_wlast   = 1'b1;

    // Tile bounding rows lookup table
    function [9:0] get_tile_rows;
        input [4:0] slot;
        begin
            case (slot)
                5'd0:  get_tile_rows = 10'd647;
                5'd1:  get_tile_rows = 10'd647;
                5'd2:  get_tile_rows = 10'd710;
                5'd3:  get_tile_rows = 10'd742;
                5'd4:  get_tile_rows = 10'd742;
                5'd5:  get_tile_rows = 10'd742;
                5'd6:  get_tile_rows = 10'd710;
                5'd7:  get_tile_rows = 10'd647;
                5'd8:  get_tile_rows = 10'd647;
                5'd9:  get_tile_rows = 10'd647;
                5'd10: get_tile_rows = 10'd677;
                5'd11: get_tile_rows = 10'd676;
                5'd12: get_tile_rows = 10'd676;
                5'd13: get_tile_rows = 10'd676;
                5'd14: get_tile_rows = 10'd677;
                5'd15: get_tile_rows = 10'd647;
                5'd16: get_tile_rows = 10'd832;
                5'd17: get_tile_rows = 10'd481;
                5'd18: get_tile_rows = 10'd832;
                5'd19, 5'd20, 5'd21, 5'd22, 5'd23, 5'd24, 5'd25, 5'd26:
                    get_tile_rows = 10'd768;
                default: get_tile_rows = 10'd0;
            endcase
        end
    endfunction

    // 16-direction angle calculation (exact match to main.c aim_index for 16-bit deltas)
    function [3:0] aim_index;
        input signed [17:0] dx;
        input signed [17:0] dy;
        reg [17:0] ax, ay;
        reg [4:0] q;
        reg signed [5:0] q_signed;
        begin
            ax = dx[17] ? -dx : dx;
            ay = dy[17] ? -dy : dy;
            if (dy == 16'sd0) begin
                aim_index = (dx == 16'sd0) ? 4'd4 : (dx[17] ? 4'd8 : 4'd0);
            end else begin
                if (({2'b00, ay, 2'b00} + {4'd0, ay}) <= {4'd0, ax})
                    q = 5'd0;
                else if (({3'b000, ay, 1'b0} + {4'd0, ay}) <= {3'b000, ax, 1'b0})
                    q = 5'd1;
                else if ({3'b000, ay, 1'b0} <= ({3'b000, ax, 1'b0} + {4'd0, ax}))
                    q = 5'd2;
                else if ({4'd0, ay} <= ({2'b00, ax, 2'b00} + {4'd0, ax}))
                    q = 5'd3;
                else
                    q = 5'd4;

                if (dx[17])
                    q = 5'd8 - q;
                q_signed = dy[17] ? -$signed({1'b0, q}) : $signed({1'b0, q});
                aim_index = q_signed[3:0];
            end
        end
    endfunction

    localparam [5:0] ST_IDLE=0, ST_INIT=1, ST_POOL=2, ST_READ_AR=3,
        ST_READ_R=4, ST_LOAD=5, ST_LOAD_WAIT=6, ST_DISPATCH=7,
        ST_MOVE=8, ST_CHECK=9, ST_CANDIDATE=10, ST_EVAL=11,
        ST_WRITE_GROUPS=12, ST_REC_WR=13, ST_NEXT=14,
        ST_CLEAR_SETUP=15, ST_CLEAR_LOAD=16, ST_CLEAR_WAIT=17,
        ST_CLEAR_WRITE=18, ST_WRITE_USED=19, ST_DRAIN=20, ST_DONE=21,
        ST_PACK_WAIT=22, ST_PACK0=23, ST_PACK1=24, ST_PACK2=25, ST_PACK_SEND=26;
    reg [5:0] state;
    reg [COUNT_BITS-1:0] cur_count[0:95];
    reg [COUNT_BITS-1:0] used_count[0:255];
    reg [COUNT_BITS-1:0] used_count_q;
    reg [95:0] ledger_valid[0:1];
    reg buffer_r, motion_r, is_player, orb_tail;
    reg [13:0] enemy_limit, player_limit, bullet_idx, bullet_limit;
    reg [31:0] player_r, bound_x_r, bound_y_r;
    reg [27:0] table_base, read_address;
    reg [3:0] read_index, beat_index;
    reg [127:0] read_word, changed_word;
    reg [63:0] bullet_buf;
    reg second_bullet, changed;
    reg [6:0] init_group, group_index, group_last, clear_group;
    reg [COUNT_BITS-1:0] clear_index, clear_limit;
    reg [31:0] entry_word;
    reg [13:0] record_index;
    reg signed [17:0] moved_x, moved_y;
    reg [4:0] wr_pend;
    reg abort_job;
    wire aw_fire=m_axi_awvalid && m_axi_awready;
    wire b_fire=m_axi_bvalid && m_axi_bready;
    wire write_free=!m_axi_awvalid && !m_axi_wvalid && wr_pend<5'd8;
    wire [7:0] ledger_address={buffer_r,clear_group};
    wire ledger_write=state==ST_CLEAR_WRITE && write_free &&
                      clear_index>=clear_limit;
    always @(posedge clk) begin
        used_count_q<=used_count[ledger_address];
        if(ledger_write) used_count[ledger_address]<=cur_count[clear_group];
    end
    reg [127:0] burst_data;
    wire burst_write=state==ST_READ_R && m_axi_rvalid && m_axi_rready;
    wire [2047:0] burst_words;
    genvar burst_bank;
    generate for(burst_bank=0;burst_bank<16;burst_bank=burst_bank+1) begin : g_burst
        reg [127:0] value;
        always @(posedge clk) if(burst_write && read_index==burst_bank)
            value<=m_axi_rdata;
        assign burst_words[burst_bank*128+:128]=value;
    end endgenerate
    always @(posedge clk) burst_data<=burst_words[beat_index*128+:128];
    wire signed [17:0] position_x={{2{bullet_buf[15]}},bullet_buf[15:0]};
    wire signed [17:0] position_y={{2{bullet_buf[31]}},bullet_buf[31:16]};
    wire signed [17:0] velocity_x={{10{bullet_buf[39]}},bullet_buf[39:32]};
    wire signed [17:0] velocity_y={{10{bullet_buf[47]}},bullet_buf[47:40]};
    wire signed [17:0] player_x={{2{player_r[15]}},player_r[15:0]};
    wire signed [17:0] player_y={{2{player_r[31]}},player_r[31:16]};
    wire signed [17:0] moved_dx=moved_x-player_x;
    wire signed [17:0] moved_dy=moved_y-player_y;
    wire signed [17:0] bounds_dx=moved_x-$signed({2'b00,bound_x_r[15:0]});
    wire signed [17:0] bounds_dy=moved_y-$signed({2'b00,bound_y_r[15:0]});
    wire outside_bounds=bounds_dx<0 || bounds_dx>=$signed({2'b00,bound_x_r[31:16]}) ||
                        bounds_dy<0 || bounds_dy>=$signed({2'b00,bound_y_r[31:16]});
    wire candidate=moved_dx>=-18'sd15 && moved_dx<=18'sd15 &&
                   moved_dy>=-18'sd15 && moved_dy<=18'sd15;
    wire aim_player=!bullet_buf[51] && (bullet_buf[50] || bullet_buf[47:32]==16'd0);
    wire [3:0] direction=aim_index(aim_player ? player_x-position_x : velocity_x,
                                   aim_player ? player_y-position_y : velocity_y);
    reg [4:0] tile_slot, tile_width;
    reg signed [17:0] tile_x, tile_y, row_first, row_end;
    reg [9:0] tile_bounds;
    always @* begin
        tile_slot=is_player ? (bullet_buf[49] ? 5'd18 : 5'd16) :
                  bullet_buf[51] ? 5'd19+{2'b00,direction[3:1]} :
                  bullet_buf[54] ? 5'd17 :
                  bullet_buf[50] ? {1'b0,direction} :
                  bullet_buf[63] ? {1'b0,bullet_buf[62:59]} : {1'b0,direction};
        tile_width=is_player ? (bullet_buf[49] ? 5'd13 : 5'd7) :
                   bullet_buf[51] ? 5'd24 : bullet_buf[54] ? 5'd16 : 5'd26;
        tile_x=position_x-(is_player ? 18'sd0 :
                          bullet_buf[51] ? 18'sd12 : bullet_buf[54] ? 18'sd8 : 18'sd13);
        tile_y=position_y-(is_player ? 18'sd0 :
                          bullet_buf[51] ? 18'sd12 : bullet_buf[54] ? 18'sd8 : 18'sd13);
        tile_bounds=get_tile_rows(tile_slot);
        row_first=tile_y+$signed({13'd0,tile_bounds[4:0]});
        row_end=tile_y+$signed({13'd0,tile_bounds[9:5]});
        if(row_first<0) row_first=0;
        if(row_end>18'sd768) row_end=18'sd768;
    end
    reg [5:0] tile_row;
    reg [10:0] tile_left;
    reg [4:0] tile_slot_r, tile_width_r;
    reg [2:0] hue_r;
    wire [5:0] packed_row={group_index,3'b000}-tile_row+6'd8;
    wire [31:0] packed_entry={hue_r,tile_width_r,2'b00,tile_slot_r,packed_row,tile_left};
    wire [COUNT_BITS-1:0] group_count=cur_count[group_index];
    wire cache_write=state==ST_WRITE_GROUPS && group_count<TABLE_SLOTS && group_count[1:0]!=3;
    wire [8:0] cache_waddr=group_index*9'd3+{7'd0,group_count[1:0]};
    reg [8:0] cache_raddr;
    wire [31:0] cache_q;
    simple_dual_port_ram #(.DATA_WIDTH(32),.ADDR_WIDTH(9),.OUTPUT_REG("TRUE"))
    partial_entries(.wclk(clk),.we(cache_write),.waddr(cache_waddr),.wdata(packed_entry),
        .rclk(clk),.re(1'b1),.raddr(cache_raddr),.rdata(cache_q));
    reg [127:0] write_pack,used_pack;
    reg [27:0] pack_address;
    reg [2:0] pack_count;
    reg pack_tail;
    wire [COUNT_BITS:0] rounded_count={1'b0,cur_count[clear_group]}+
                                      {{(COUNT_BITS-1){1'b0}},2'b11};
    wire used_last=USED_BYTES==2 ? clear_group[2:0]==3'd7 : clear_group[3:0]==4'd15;
    wire [127:0] used_next=USED_BYTES==2 ?
        {{{(16-COUNT_BITS){1'b0}},cur_count[clear_group]},used_pack[127:16]} :
        {cur_count[clear_group][7:0],used_pack[127:8]};
    integer group_number;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=ST_IDLE;busy<=0;done<=0;fault<=0;cycles<=0;
            drop_count<=0;eb_live<=0;eb_kill<=0;eb_free<=0;eb_cand<=0;
            m_axi_arid<=4'd3;m_axi_araddr<=0;m_axi_arlen<=0;
            m_axi_arvalid<=0;m_axi_rready<=0;
            m_axi_awid<=4'd3;m_axi_awaddr<=0;m_axi_awvalid<=0;
            m_axi_wid<=4'd3;m_axi_wdata<=0;m_axi_wstrb<=0;m_axi_wvalid<=0;
            wr_pend<=0;
            ledger_valid[0]<=0;ledger_valid[1]<=0;
            buffer_r<=0;motion_r<=0;is_player<=0;orb_tail<=0;
            enemy_limit<=0;player_limit<=0;bullet_idx<=0;bullet_limit<=0;
            player_r<=0;bound_x_r<=0;bound_y_r<=0;table_base<=0;read_address<=0;
            read_index<=0;beat_index<=0;read_word<=0;changed_word<=0;
            bullet_buf<=0;second_bullet<=0;changed<=0;
            init_group<=0;group_index<=0;group_last<=0;clear_group<=0;
            clear_index<=0;clear_limit<=0;record_index<=0;
            moved_x<=0;moved_y<=0;tile_row<=0;tile_left<=0;
            tile_slot_r<=0;tile_width_r<=0;hue_r<=0;entry_word<=0;
            abort_job<=0;
            cache_raddr<=0;write_pack<=0;used_pack<=0;pack_address<=0;pack_count<=0;pack_tail<=0;
        end else begin
            done<=0;
            if(m_axi_awvalid && m_axi_awready) m_axi_awvalid<=0;
            if(m_axi_wvalid && m_axi_wready) m_axi_wvalid<=0;
            if(m_axi_arvalid && m_axi_arready) m_axi_arvalid<=0;
            case({aw_fire,b_fire})
                2'b10:wr_pend<=wr_pend+5'd1;
                2'b01:wr_pend<=wr_pend-5'd1;
                default: ;
            endcase
            if(b_fire && m_axi_bresp!=0) fault<=1;
            if(busy) begin
                if(cycles!=32'hffffffff) cycles<=cycles+32'd1;
                if(cycles==32'd4000000) begin abort_job<=1;fault<=1;end
            end
            if(ledger_write) ledger_valid[buffer_r][clear_group]<=1;
            case(state)
                ST_IDLE:begin
                    busy<=0;
                    if(clear_ledger) begin ledger_valid[0]<=0;ledger_valid[1]<=0;end
                    else if(start) begin
                        busy<=1;fault<=0;cycles<=0;abort_job<=0;
                        drop_count<=0;eb_live<=0;eb_kill<=0;eb_free<=0;eb_cand<=0;
                        buffer_r<=buffer_sel;motion_r<=motion_en;player_r<=player_xy;
                        bound_x_r<=bound_x;bound_y_r<=bound_y;
                        enemy_limit<=eb_count>EB_FRONT_RUN ? EB_FRONT_RUN : eb_count;
                        player_limit<=pb_count>10'd512 ? 14'd512 : {4'd0,pb_count};
                        table_base<=buffer_sel ? MM_BUCKET_TABLE_1 : MM_BUCKET_TABLE_0;
                        is_player<=pb_count!=0;orb_tail<=0;bullet_idx<=0;
                        init_group<=0;state<=ST_INIT;
                    end
                end
                ST_INIT:begin
                    cur_count[init_group]<=0;
                    if(init_group==7'd95) state<=ST_POOL;
                    else init_group<=init_group+7'd1;
                end
                ST_POOL:begin
                    bullet_limit<=is_player ? player_limit : enemy_limit;
                    if((is_player && player_limit==0) || (!is_player && enemy_limit==0)) begin
                        is_player<=0;orb_tail<=1;
                        bullet_idx<=EB_FRONT_RUN;bullet_limit<=EB_TOTAL_LIMIT;
                    end
                    state<=ST_READ_AR;
                end
                ST_READ_AR:begin
                    if(abort_job) state<=ST_DRAIN;
                    else if(bullet_idx>=bullet_limit) begin
                        if(is_player) begin
                            is_player<=0;bullet_idx<=0;bullet_limit<=enemy_limit;
                        end else if(!orb_tail) begin
                            orb_tail<=1;bullet_idx<=EB_FRONT_RUN;bullet_limit<=EB_TOTAL_LIMIT;
                        end else begin clear_group<=0;state<=ST_CLEAR_SETUP;end
                    end else begin
                        m_axi_araddr<=(is_player ? MM_PBULLET_BASE : MM_EBULLET_BASE)+{11'd0,bullet_idx,3'b000};
                        read_address<=(is_player ? MM_PBULLET_BASE : MM_EBULLET_BASE)+{11'd0,bullet_idx,3'b000};
                        m_axi_arlen<=BURST_READ_LEN==16 ? 8'd15 : 8'd0;
                        m_axi_arvalid<=1;m_axi_rready<=1;read_index<=0;beat_index<=0;
                        state<=ST_READ_R;
                    end
                end
                ST_READ_R:begin
                    if(m_axi_rvalid && m_axi_rready) begin
                        if(m_axi_rresp!=0 ||
                           m_axi_rlast!=(read_index==(BURST_READ_LEN==16 ? 4'd15 : 4'd0))) fault<=1;
                        if(m_axi_rlast) begin
                            m_axi_rready<=0;state<=abort_job ? ST_DRAIN : ST_LOAD;
                        end else read_index<=read_index+4'd1;
                    end
                end
                ST_LOAD:state<=ST_LOAD_WAIT;
                ST_LOAD_WAIT:begin
                    read_word<=burst_data;changed_word<=burst_data;
                    changed<=0;second_bullet<=0;state<=ST_DISPATCH;
                end
                ST_DISPATCH:begin
                    bullet_buf<=second_bullet ? read_word[127:64] : read_word[63:0];
                    record_index<=bullet_idx;bullet_idx<=bullet_idx+14'd1;
                    state<=ST_MOVE;
                end
                ST_MOVE:begin
                    if(motion_r && !is_player && !orb_tail && bullet_buf[48] && !bullet_buf[51]) begin
                        moved_x<=position_x+velocity_x;moved_y<=position_y+velocity_y;
                        state<=ST_CHECK;
                    end else begin
                        if(!is_player && bullet_buf[48]) eb_live<=eb_live+16'd1;
                        state<=ST_EVAL;
                    end
                end
                ST_CHECK:begin
                    changed<=1;
                    if(outside_bounds) begin
                        bullet_buf[48]<=0;eb_kill<=eb_kill+16'd1;
                        if(second_bullet) changed_word[112]<=0;
                        else changed_word[48]<=0;
                        state<=ST_EVAL;
                    end else begin
                        eb_live<=eb_live+16'd1;
                        bullet_buf[15:0]<=moved_x[15:0];bullet_buf[31:16]<=moved_y[15:0];
                        if(second_bullet) changed_word[95:64]<={moved_y[15:0],moved_x[15:0]};
                        else changed_word[31:0]<={moved_y[15:0],moved_x[15:0]};
                        state<=candidate && eb_cand<CAND_CAP ? ST_CANDIDATE : ST_EVAL;
                        if(candidate && eb_cand>=CAND_CAP && eb_cand!=16'hffff)
                            eb_cand<=eb_cand+16'd1;
                    end
                end
                ST_CANDIDATE:begin
                    if(write_free) begin
                        m_axi_awaddr<=MM_EB_CAND_LIST+{11'd0,eb_cand[15:3],4'b0000};
                        m_axi_awvalid<=1;m_axi_wdata<={8{{2'b00,record_index}}};
                        m_axi_wstrb<=16'h0003<<{eb_cand[2:0],1'b0};m_axi_wvalid<=1;
                        eb_cand<=eb_cand+16'd1;state<=ST_EVAL;
                    end
                end
                ST_EVAL:begin
                    if(!bullet_buf[48] || row_first>=row_end) state<=ST_NEXT;
                    else begin
                        tile_row<=tile_y[5:0];tile_left<=tile_x[10:0];
                        tile_slot_r<=tile_slot;tile_width_r<=tile_width;hue_r<=bullet_buf[58:56];
                        group_index<=row_first[9:3];
                        group_last<=SINGLE_GROUP_REG ? row_first[9:3] : (row_end-18'sd1)>>3;
                        state<=ST_WRITE_GROUPS;
                    end
                end
                ST_WRITE_GROUPS:begin
                    if(group_count>=TABLE_SLOTS) begin
                        if(drop_count!=16'hffff) drop_count<=drop_count+16'd1;
                        if(group_index==group_last) state<=ST_NEXT;
                        else group_index<=group_index+7'd1;
                    end else begin
                        cur_count[group_index]<=group_count+1'b1;
                        if(group_count[1:0]==3) begin
                            pack_address<=table_base+group_index*(TABLE_SLOTS*4)+((group_count>>2)<<4);
                            write_pack[127:96]<=packed_entry;pack_count<=4;pack_tail<=0;
                            cache_raddr<=group_index*9'd3;state<=ST_PACK_WAIT;
                        end else if(group_index==group_last) state<=ST_NEXT;
                        else group_index<=group_index+7'd1;
                    end
                end
                ST_PACK_WAIT:begin cache_raddr<=cache_raddr+9'd1;state<=ST_PACK0;end
                ST_PACK0:begin
                    write_pack[31:0]<=cache_q;cache_raddr<=cache_raddr+9'd1;state<=ST_PACK1;
                end
                ST_PACK1:begin write_pack[63:32]<=pack_count>1 ? cache_q : 32'd0;state<=ST_PACK2;end
                ST_PACK2:begin write_pack[95:64]<=pack_count>2 ? cache_q : 32'd0;state<=ST_PACK_SEND;end
                ST_PACK_SEND:if(write_free) begin
                    m_axi_awaddr<=pack_address;m_axi_awvalid<=1;
                    m_axi_wdata<=write_pack;m_axi_wstrb<=16'hffff;m_axi_wvalid<=1;
                    if(pack_tail) state<=ST_CLEAR_LOAD;
                    else if(group_index==group_last) state<=ST_NEXT;
                    else begin group_index<=group_index+7'd1;state<=ST_WRITE_GROUPS;end
                end
                ST_NEXT:begin
                    if(!second_bullet && bullet_idx<bullet_limit) begin
                        second_bullet<=1;state<=ST_DISPATCH;
                    end else state<=changed ? ST_REC_WR : ST_LOAD;
                    if(second_bullet || bullet_idx>=bullet_limit) begin
                        if(!changed) begin
                            if(bullet_idx>=bullet_limit || beat_index==(BURST_READ_LEN==16 ? 4'd15 : 4'd0))
                                state<=ST_READ_AR;
                            else begin beat_index<=beat_index+4'd1;read_address<=read_address+28'd16;state<=ST_LOAD;end
                        end
                    end
                end
                ST_REC_WR:begin
                    if(write_free) begin
                        m_axi_awaddr<=read_address;m_axi_awvalid<=1;
                        m_axi_wdata<=changed_word;m_axi_wstrb<=16'hffff;m_axi_wvalid<=1;
                        if(bullet_idx>=bullet_limit || beat_index==(BURST_READ_LEN==16 ? 4'd15 : 4'd0))
                            state<=ST_READ_AR;
                        else begin beat_index<=beat_index+4'd1;read_address<=read_address+28'd16;state<=ST_LOAD;end
                    end
                end
                ST_CLEAR_SETUP:begin
                    clear_index<={rounded_count[COUNT_BITS-1:2],2'b00};
                    if(cur_count[clear_group][1:0]!=0) begin
                        pack_count<={1'b0,cur_count[clear_group][1:0]};pack_tail<=1;
                        write_pack[127:96]<=0;cache_raddr<=clear_group*9'd3;
                        pack_address<=table_base+clear_group*(TABLE_SLOTS*4)+((cur_count[clear_group]>>2)<<4);
                        state<=ST_PACK_WAIT;
                    end else state<=ST_CLEAR_LOAD;
                end
                ST_CLEAR_LOAD:state<=ST_CLEAR_WAIT;
                ST_CLEAR_WAIT:begin
                    clear_limit<=ledger_valid[buffer_r][clear_group] ? used_count_q : {COUNT_BITS{1'b0}};
                    state<=ST_CLEAR_WRITE;
                end
                ST_CLEAR_WRITE:begin
                    if(write_free) begin
                        if(clear_index<clear_limit) begin
                            m_axi_awaddr<=table_base+clear_group*(TABLE_SLOTS*4)+((clear_index>>2)<<4);
                            m_axi_awvalid<=1;m_axi_wdata<=0;
                            m_axi_wstrb<=16'hffff;m_axi_wvalid<=1;
                            clear_index<=clear_index+4;
                        end else state<=ST_WRITE_USED;
                    end
                end
                ST_WRITE_USED:begin
                    if(!used_last || write_free) begin
                        used_pack<=used_next;
                        if(used_last) begin
                            m_axi_awaddr<=(buffer_r ? MM_BUCKET_USED_1 : MM_BUCKET_USED_0)
                                          +((clear_group*USED_BYTES>>4)<<4);
                            m_axi_awvalid<=1;m_axi_wdata<=used_next;
                            m_axi_wstrb<=16'hffff;m_axi_wvalid<=1;
                        end
                        if(clear_group==7'd95) state<=ST_DRAIN;
                        else begin clear_group<=clear_group+7'd1;state<=ST_CLEAR_SETUP;end
                    end
                end
                ST_DRAIN:if(wr_pend==0 && !m_axi_awvalid && !m_axi_wvalid) state<=ST_DONE;
                ST_DONE:begin done<=1;busy<=0;state<=ST_IDLE;end
                default:begin fault<=1;state<=ST_DRAIN;end
            endcase
        end
    end
endmodule
