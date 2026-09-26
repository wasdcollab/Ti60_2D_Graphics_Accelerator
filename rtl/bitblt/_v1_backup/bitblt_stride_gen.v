`timescale 1ns/1ps

module bitblt_stride_gen (
    input  wire        clk,
    input  wire        rst_n,
    
    // Command interface from APB regs
    input  wire        cmd_start,
    input  wire [1:0]  cmd_op_type,      // 0: OP_FILL, 1: OP_COPY
    input  wire [27:0] cmd_dst_addr,
    input  wire [27:0] cmd_src_addr,
    input  wire [10:0] cmd_rect_w,       // width in pixels (1-1024)
    input  wire [10:0] cmd_rect_h,       // height in rows (1-600)
    input  wire [31:0] cmd_color,
    input  wire [15:0] cmd_src_stride,
    input  wire [15:0] cmd_dst_stride,
    output wire        busy,
    
    // Read master control interface
    output reg         rd_req,
    output reg  [27:0] rd_addr,
    output reg  [7:0]  rd_len,
    input  wire        rd_done,
    output reg         fifo_clr,
    
    // Write master control interface
    output wire        data_from_fifo,
    output reg         burst_req,
    output reg  [27:0] burst_addr,       // 16-byte aligned byte address
    output reg  [7:0]  burst_len,        // AXI burst length (0-based: 0=1 beat, 15=16 beats)
    output reg [127:0] burst_data,       // replicated color {4{color}} (used when data_from_fifo==0)
    output reg  [15:0] burst_wstrb_first, // wstrb for first beat
    output reg  [15:0] burst_wstrb_last,  // wstrb for last beat
    input  wire        burst_done        // pulse when AXI write master completes one burst
);

    localparam S_IDLE       = 3'd0;
    localparam S_ROW_INIT   = 3'd1;
    localparam S_RD_BURST   = 3'd2;
    localparam S_RD_WAIT    = 3'd3;
    localparam S_WR_BURST   = 3'd4;
    localparam S_WR_WAIT    = 3'd5;
    localparam S_NEXT_BURST = 3'd6;
    localparam S_DONE       = 3'd7;
    
    reg [2:0] state;
    
    reg [1:0]  r_op_type;
    reg [10:0] r_rect_w;
    reg [10:0] r_rect_h;
    reg [15:0] r_src_stride;
    reg [15:0] r_dst_stride;
    
    reg [27:0] dst_line_start;
    reg [27:0] src_line_start;
    reg [10:0] row_count;
    
    reg [10:0] beats_remaining;
    reg [1:0]  first_pixel;
    reg [1:0]  end_pixel;
    reg        first_burst;
    reg [27:0] current_dst_burst_addr;
    reg [27:0] current_src_burst_addr;
    
    wire [11:0] command_pixels = {1'b0, cmd_rect_w} + {10'd0, cmd_dst_addr[3:2]};
    wire [11:0] row_pixels     = {1'b0, r_rect_w} + {10'd0, first_pixel};
    
    // Calculate beats remaining until 4-KiB boundary for destination and source
    wire [8:0] page_beats_dst = 9'd256 - {1'b0, current_dst_burst_addr[11:4]};
    wire [8:0] page_beats_src = 9'd256 - {1'b0, current_src_burst_addr[11:4]};
    wire [8:0] page_beats     = (r_op_type == 2'd0) ? page_beats_dst : 
                                ((page_beats_dst < page_beats_src) ? page_beats_dst : page_beats_src);
                                
    wire [10:0] limited_beats = (beats_remaining > 11'd16) ? 11'd16 : beats_remaining;
    wire [10:0] issue_beats   = (limited_beats > {2'd0, page_beats}) ? {2'd0, page_beats} : limited_beats;
    reg  [10:0] issued_beats;
    
    assign busy = (state != S_IDLE);
    assign data_from_fifo = (r_op_type != 2'd0);
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                  <= S_IDLE;
            rd_req                 <= 1'b0;
            rd_addr                <= 28'd0;
            rd_len                 <= 8'd0;
            fifo_clr               <= 1'b0;
            burst_req              <= 1'b0;
            burst_addr             <= 28'd0;
            burst_len              <= 8'd0;
            burst_data             <= 128'd0;
            burst_wstrb_first      <= 16'hFFFF;
            burst_wstrb_last       <= 16'hFFFF;
            
            r_op_type              <= 2'd0;
            r_rect_w               <= 11'd0;
            r_rect_h               <= 11'd0;
            r_src_stride           <= 16'd4096;
            r_dst_stride           <= 16'd4096;
            dst_line_start         <= 28'd0;
            src_line_start         <= 28'd0;
            row_count              <= 11'd0;
            beats_remaining        <= 11'd0;
            first_pixel            <= 2'd0;
            end_pixel              <= 2'd0;
            first_burst            <= 1'b0;
            issued_beats           <= 11'd0;
            current_dst_burst_addr <= 28'd0;
            current_src_burst_addr <= 28'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    burst_req <= 1'b0;
                    rd_req    <= 1'b0;
                    fifo_clr  <= 1'b0;
                    if (cmd_start) begin
                        r_op_type              <= cmd_op_type;
                        r_rect_w               <= cmd_rect_w;
                        r_rect_h               <= cmd_rect_h;
                        r_src_stride           <= (cmd_src_stride == 16'd0) ? 16'd4096 : cmd_src_stride;
                        r_dst_stride           <= (cmd_dst_stride == 16'd0) ? 16'd4096 : cmd_dst_stride;
                        dst_line_start         <= {cmd_dst_addr[27:4], 4'b0000};
                        src_line_start         <= {cmd_src_addr[27:4], 4'b0000};
                        first_pixel            <= cmd_dst_addr[3:2];
                        end_pixel              <= command_pixels[1:0];
                        row_count              <= 11'd0;
                        burst_data             <= {4{cmd_color}};
                        burst_wstrb_first      <= 16'hFFFF;
                        burst_wstrb_last       <= 16'hFFFF;
                        fifo_clr               <= 1'b1;
                        
                        if (cmd_rect_h > 0 && cmd_rect_w > 0) begin
                            state <= S_ROW_INIT;
                        end
                    end
                end
                
                S_ROW_INIT: begin
                    fifo_clr               <= 1'b0;
                    beats_remaining        <= (row_pixels + 12'd3) >> 2;
                    first_burst            <= 1'b1;
                    current_dst_burst_addr <= dst_line_start;
                    current_src_burst_addr <= src_line_start;
                    
                    if (r_op_type == 2'd0) begin
                        state <= S_WR_BURST;
                    end else begin
                        state <= S_RD_BURST;
                    end
                end
                
                S_RD_BURST: begin
                    rd_req  <= 1'b1;
                    rd_addr <= current_src_burst_addr;
                    rd_len  <= issue_beats - 1'b1;
                    state   <= S_RD_WAIT;
                end
                
                S_RD_WAIT: begin
                    rd_req <= 1'b0; // rd_req is a pulse
                    if (rd_done) begin
                        state <= S_WR_BURST;
                    end
                end
                
                S_WR_BURST: begin
                    burst_req    <= 1'b1;
                    burst_addr   <= current_dst_burst_addr;
                    issued_beats <= issue_beats;
                    burst_len    <= issue_beats - 1'b1;
                    burst_wstrb_first <= first_burst ? (16'hFFFF << {first_pixel, 2'b00}) : 16'hFFFF;
                    if ((beats_remaining == issue_beats) && (end_pixel != 0))
                        burst_wstrb_last <= 16'hFFFF >> (5'd16 - {1'b0, end_pixel, 2'b00});
                    else
                        burst_wstrb_last <= 16'hFFFF;
                    state <= S_WR_WAIT;
                end
                
                S_WR_WAIT: begin
                    burst_req <= 1'b0; // burst_req is a pulse
                    if (burst_done) begin
                        state <= S_NEXT_BURST;
                    end
                end
                
                S_NEXT_BURST: begin
                    if (beats_remaining > issued_beats) begin
                        beats_remaining        <= beats_remaining - issued_beats;
                        current_dst_burst_addr <= current_dst_burst_addr + {13'd0, issued_beats, 4'd0};
                        current_src_burst_addr <= current_src_burst_addr + {13'd0, issued_beats, 4'd0};
                        first_burst            <= 1'b0;
                        if (r_op_type == 2'd0)
                            state <= S_WR_BURST;
                        else
                            state <= S_RD_BURST;
                    end else begin
                        // end of row
                        if (row_count + 11'd1 == r_rect_h) begin
                            state <= S_DONE;
                        end else begin
                            row_count      <= row_count + 11'd1;
                            dst_line_start <= dst_line_start + {12'd0, r_dst_stride};
                            src_line_start <= src_line_start + {12'd0, r_src_stride};
                            state          <= S_ROW_INIT;
                        end
                    end
                end
                
                S_DONE: begin
                    state <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
