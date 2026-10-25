`timescale 1ns/1ps
// Two complete groups in BRAM, never a wide vector of sprite registers.
// A group is published only after its final AXI beat has reached the RAM.
module dma_scanline_prefetch #(
    parameter integer SLOTS = 1024,
    parameter integer V_TOTAL = 782
) (
    input wire axi_clk, axi_rst_n, cal_done,
    input wire [27:0] bucket_base, active_base,
    input wire frame_clear_axi, at_line_start, fb_busy,
    output reg bk_pend, bk_act,
    output reg [27:0] bk_araddr,
    output wire [7:0] bk_arlen,
    output reg bk_arvalid,
    input wire bk_arready,
    input wire [127:0] bk_rdata,
    input wire bk_rlast, bk_rvalid,
    output wire bk_rready,
    input wire pixel_clk, pixel_rst_n,
    input wire [11:0] h_cnt,
    input wire [10:0] v_cnt,
    input wire [$clog2(SLOTS)-1:0] entry_addr,
    input wire entry_group,
    output wire [31:0] entry_data,
    output wire entry_ready,
    output reg [11:0] missed_lines
);
    localparam integer BEAT_BITS = $clog2(SLOTS/4);
    localparam integer STRIDE = SLOTS*4;
    localparam integer TABLE_BYTES = 96*STRIDE;
    reg req_toggle;
    reg [6:0] req_group;
    // Group zero must be fetched AFTER the vertical-blank framebuffer flip,
    // not during group 95 of the old frame.
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin req_toggle <= 0; req_group <= 0; end
        else if (h_cnt == 0) begin
            if (v_cnt < 760 && v_cnt[2:0] == 0) begin
                req_toggle <= ~req_toggle;
                req_group <= v_cnt[9:3] + 7'd1;
            end else if (v_cnt == 769) begin
                req_toggle <= ~req_toggle;
                req_group <= 0;
            end
        end
    end
    reg [2:0] req_sync;
    always @(posedge axi_clk or negedge axi_rst_n)
        if (!axi_rst_n) req_sync <= 0;
        else req_sync <= {req_sync[1:0],req_toggle};
    wire request = req_sync[2] ^ req_sync[1];
    reg [6:0] pending_group, group_r;
    reg [27:0] base_r;
    reg [BEAT_BITS-1:0] beat;
    reg reading, discard;
    reg [1:0] published;
    reg [6:0] tags [0:1];
    assign bk_arlen = 15;
    assign bk_rready = reading;
    wire accepted = reading && bk_rvalid;
    wire store = accepted && !discard && !frame_clear_axi;
    always @(posedge axi_clk or negedge axi_rst_n) begin
        if (!axi_rst_n) begin
            bk_pend <= 0; bk_act <= 0; bk_arvalid <= 0;
            bk_araddr <= 0; pending_group <= 0; group_r <= 0;
            base_r <= 0; beat <= 0; reading <= 0; discard <= 0;
            published <= 0; tags[0] <= 0; tags[1] <= 0;
        end else begin
            if (request) begin bk_pend <= 1; pending_group <= req_group; end
            if (!bk_act && bk_pend && cal_done && bucket_base != 0 &&
                !frame_clear_axi && !fb_busy && at_line_start) begin
                bk_pend <= request;
                group_r <= pending_group;
                base_r <= bucket_base + (active_base[22] ? TABLE_BYTES : 0);
                bk_araddr <= bucket_base + (active_base[22] ? TABLE_BYTES : 0)
                             + pending_group*STRIDE;
                beat <= 0; discard <= 0; bk_act <= 1; bk_arvalid <= 1;
            end
            if (bk_arvalid && bk_arready) begin bk_arvalid <= 0; reading <= 1; end
            if (accepted) begin
                beat <= beat + 1'b1;
                if (bk_rlast) begin
                    reading <= 0;
                    if (beat == SLOTS/4-1) begin
                        bk_act <= 0;
                        if (!discard && !frame_clear_axi) begin
                            tags[group_r[0]] <= group_r;
                            published[group_r[0]] <= ~published[group_r[0]];
                        end
                    end else begin
                        bk_araddr <= base_r + group_r*STRIDE + (beat+1'b1)*16;
                        bk_arvalid <= 1;
                    end
                end
            end
            // Do not revoke VALID or RREADY on a page flip. Drain old traffic.
            if (frame_clear_axi) begin discard <= 1; bk_pend <= 0; end
        end
    end
    wire [127:0] ram_q;
    reg [1:0] lane_d;
    always @(posedge pixel_clk) lane_d <= entry_addr[1:0];
    simple_dual_port_ram #(.DATA_WIDTH(128),.ADDR_WIDTH(BEAT_BITS+1),.OUTPUT_REG("TRUE"))
    u_groups (
        .wclk(axi_clk),.we(store),.waddr({group_r[0],beat}),.wdata(bk_rdata),
        .rclk(pixel_clk),.re(1'b1),.raddr({entry_group,entry_addr[$clog2(SLOTS)-1:2]}),
        .rdata(ram_q)
    );
    assign entry_data = ram_q[32*lane_d +: 32];
    reg [1:0] pub_s1,pub_s2,pub_seen,valid;
    reg [6:0] pixel_tag [0:1];
    wire [10:0] target_y = v_cnt == V_TOTAL-1 ? 11'd0 : v_cnt+11'd1;
    assign entry_ready = valid[entry_group] && pixel_tag[entry_group] == target_y[9:3];
    integer k;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            pub_s1 <= 0; pub_s2 <= 0; pub_seen <= 0; valid <= 0;
            pixel_tag[0] <= 0; pixel_tag[1] <= 0; missed_lines <= 0;
        end else begin
            pub_s1 <= published; pub_s2 <= pub_s1; pub_seen <= pub_s2;
            for (k=0;k<2;k=k+1) if (pub_s2[k] != pub_seen[k]) begin
                pixel_tag[k] <= tags[k]; valid[k] <= 1;
            end
            if (h_cnt == 0 && v_cnt == 768) valid <= 0;
            if (h_cnt == 0 && v_cnt == 769) missed_lines <= 0;
            else if (h_cnt == 64 && target_y < 768 && !entry_ready &&
                     missed_lines != 4095) missed_lines <= missed_lines+1'b1;
        end
    end
endmodule
