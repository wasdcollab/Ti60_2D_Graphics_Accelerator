`timescale 1ns/1ps
// =============================================================================
// bitblt_alpha_blend
// -----------------------------------------------------------------------------
// Hardware alpha blending stage of the BitBlt engine (OP_ALPHA = 2).
//
// WHAT IT IS NOT
//   It is not a pre-blended constant pushed into a sprite: the destination
//   background is read back from DDR for every single beat (real
//   read-modify-write), blended, and written again.
//
// PIXEL FORMAT (ARGB8888, little endian byte lanes)
//   32-bit pixel = {A[31:24], R[23:16], G[15:8], B[7:0]}, four pixels per
//   128-bit AXI beat, lane 0 = lowest address.
//
// MATH  (bit exact with simulator/blit_ref.py and tests/*.sv)
//   effective alpha : ae = (a * GLOBAL_ALPHA + 127) / 255     (GLOBAL_ALPHA = 255 -> ae = a)
//   colour channels : out = (src * ae + dst * (255 - ae) + 127) / 255
//   alpha byte      : taken from the destination unchanged (the framebuffer
//                     alpha is not used by the scanout, and leaving it alone
//                     keeps the surface opaque).
//
//   The divide is exact on this range with the add-shift identity
//       n / 255 == (n + 1 + (n >> 8)) >> 8        for 0 <= n <= 65152
//   which was verified exhaustively.  The numerator is at most
//   255*255 + 127 = 65152, and rewriting it as
//       n = 255*dst + 127 + ae*(src - dst)
//   keeps it to ONE signed 9x8 multiply per channel instead of two 8x8
//   multiplies (255*dst is a shift-subtract).  The sum is computed in 18-bit
//   two's complement arithmetic; because the true value is always >= 127 the
//   wrapped result is the correct non-negative numerator.
//
// COLOUR KEY PRIORITY
//   With Color Keying enabled a source pixel equal to COLORKEY is skipped
//   entirely (all four of its byte strobes are cleared) and is NEVER blended,
//   even when its alpha byte is non zero.
//
// PIPELINE (throughput one beat per clock, latency four clocks)
//   P0 latch source / destination / keep-mask
//   P1 effective alpha        (one 8x8 multiply + the 255-divide)
//   P2 products + bases       (one 9x8 signed multiply per colour channel)
//   P3 divide + pack          (two 18-bit adds, no multiply)
//   hold                      (one beat of elasticity towards the write master)
//
// BACK PRESSURE / NO LOST PIXEL
//   A source and a destination beat are accepted together, and only when the
//   whole pipeline can advance (the hold register is free or its beat is being
//   taken by the write master).  src_ack / dst_ack pulse exactly once per
//   accepted beat, which is what the alignment shifter and the destination
//   FIFO use to advance their own pointers.
// =============================================================================
module bitblt_alpha_blend (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clr,            // command boundary: flush the pipeline

    input  wire         enable,         // 1 while an OP_ALPHA or OP_ADD command is running
    input  wire         is_add,         // 1 for OP_ADD (saturated add), 0 for OP_ALPHA
    input  wire [7:0]   global_alpha,   // 8'hFF = use the source alpha unchanged
    input  wire         colorkey_en,
    input  wire [31:0]  colorkey_val,

    // source pixel stream (already byte-realigned onto the destination lanes)
    input  wire [127:0] src_data,
    input  wire         src_valid,
    output wire         src_ack,

    // destination background stream (exactly the lanes that are being written)
    input  wire [127:0] dst_data,
    input  wire         dst_valid,
    output wire         dst_ack,

    // blended beat towards the AXI write master
    output reg  [127:0] out_data,
    output reg  [15:0]  out_mask,       // per pixel nibble, 0 = keep the background
    output wire         out_valid,
    input  wire         out_ack
);

    // ---------------------------------------------------------------------
    // arithmetic primitives
    // ---------------------------------------------------------------------
    // exact n/255 for 0 <= n <= 65152 (which is the whole range this engine can
    // produce); t itself never exceeds 65407 so it stays 16 bits wide.
    function [7:0] div255;
        input [17:0] n;
        reg   [17:0] t;
        begin
            t      = n + 18'd1 + {10'd0, n[17:8]};
            div255 = t[15:8];
        end
    endfunction

    // (a * g + 127) / 255   ; g = 255 -> a
    function [7:0] scale_alpha;
        input [7:0] a;
        input [7:0] g;
        begin
            scale_alpha = div255(({10'd0, a} * {10'd0, g}) + 18'd127);
        end
    endfunction

    // ---------------------------------------------------------------------
    // colour key: per pixel keep flag, decided on the raw source beat
    // ---------------------------------------------------------------------
    wire [3:0] key_hit = {
        colorkey_en && (src_data[127:96] == colorkey_val),
        colorkey_en && (src_data[95:64]  == colorkey_val),
        colorkey_en && (src_data[63:32]  == colorkey_val),
        colorkey_en && (src_data[31:0]   == colorkey_val)
    };
    wire [3:0] keep_in = ~key_hit;

    // ---------------------------------------------------------------------
    // pipe stage 0
    // ---------------------------------------------------------------------
    reg [127:0] p0_src, p0_dst;
    reg [3:0]   p0_keep;
    reg         p0_is_add;
    reg         p0_v;

    // ---------------------------------------------------------------------
    // pipe stage 1 : effective alpha per pixel
    // ---------------------------------------------------------------------
    wire [7:0] eff0 = scale_alpha(p0_src[31:24],   global_alpha);
    wire [7:0] eff1 = scale_alpha(p0_src[63:56],   global_alpha);
    wire [7:0] eff2 = scale_alpha(p0_src[95:88],   global_alpha);
    wire [7:0] eff3 = scale_alpha(p0_src[127:120], global_alpha);

    reg [127:0] p1_src, p1_dst;
    reg [31:0]  p1_eff;
    reg [3:0]   p1_keep;
    reg         p1_is_add;
    reg         p1_v;

    // ---------------------------------------------------------------------
    // pipe stage 2 : one signed 9x8 product and one 255*dst+127 base per
    // colour channel (B/G/R byte lanes 0/1/2 of every pixel)
    // ---------------------------------------------------------------------
    reg [215:0] p2_prod;        // 12 x 18-bit two's complement
    reg [215:0] p2_base;        // 12 x 18-bit unsigned
    reg [127:0] p2_src, p2_dst;
    reg [3:0]   p2_keep;
    reg         p2_is_add;
    reg         p2_v;

    reg         h_valid;        // one beat of elasticity towards the write master

    // the pipeline advances whenever the hold register is free or its beat was
    // just taken; that is also the condition for accepting a new beat pair.
    wire advance = !h_valid || out_ack;

    genvar k;
    generate
        for (k = 0; k < 12; k = k + 1) begin : g_ch
            wire [1:0]  lane = k / 3;                    // pixel lane 0..3
            wire [1:0]  chan = k % 3;                    // 0 = B, 1 = G, 2 = R
            wire [6:0]  off  = (lane * 32) + (chan * 8); // bit offset in the beat
            wire signed [8:0]  dif = $signed({1'b0, p1_src[off +: 8]}) -
                                     $signed({1'b0, p1_dst[off +: 8]});
            wire signed [8:0]  am  = $signed({1'b0, p1_eff[(lane * 8) +: 8]});
            wire signed [17:0] prd = dif * am;           // |.| <= 65025
            wire        [17:0] bas = ({10'd0, p1_dst[off +: 8]} * 18'd255) + 18'd127;

            always @(posedge clk) begin
                if (advance) begin
                    p2_prod[(k * 18) +: 18] <= prd[17:0];
                    p2_base[(k * 18) +: 18] <= bas;
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------------------
    // pipe stage 3 : numerator, exact 255-divide, and packing.
    // The twelve colour channels are unrolled (k = lane*3 + chan, chan 0 = B,
    // 1 = G, 2 = R) because a part select needs a constant index here - the
    // vendor tools reject a genvar-derived *wire* used as an lvalue index.
    // ---------------------------------------------------------------------
    wire [17:0] n00 = p2_prod[18*0  +: 18] + p2_base[18*0  +: 18];   // lane 0 B
    wire [17:0] n01 = p2_prod[18*1  +: 18] + p2_base[18*1  +: 18];   // lane 0 G
    wire [17:0] n02 = p2_prod[18*2  +: 18] + p2_base[18*2  +: 18];   // lane 0 R
    wire [17:0] n10 = p2_prod[18*3  +: 18] + p2_base[18*3  +: 18];   // lane 1 B
    wire [17:0] n11 = p2_prod[18*4  +: 18] + p2_base[18*4  +: 18];   // lane 1 G
    wire [17:0] n12 = p2_prod[18*5  +: 18] + p2_base[18*5  +: 18];   // lane 1 R
    wire [17:0] n20 = p2_prod[18*6  +: 18] + p2_base[18*6  +: 18];   // lane 2 B
    wire [17:0] n21 = p2_prod[18*7  +: 18] + p2_base[18*7  +: 18];   // lane 2 G
    wire [17:0] n22 = p2_prod[18*8  +: 18] + p2_base[18*8  +: 18];   // lane 2 R
    wire [17:0] n30 = p2_prod[18*9  +: 18] + p2_base[18*9  +: 18];   // lane 3 B
    wire [17:0] n31 = p2_prod[18*10 +: 18] + p2_base[18*10 +: 18];   // lane 3 G
    wire [17:0] n32 = p2_prod[18*11 +: 18] + p2_base[18*11 +: 18];   // lane 3 R

    // ---------------------------------------------------------------------
    // Saturated addition primitive for OP_ADD (scheme A)
    // ---------------------------------------------------------------------
    function [7:0] sat_add;
        input [7:0] a;
        input [7:0] b;
        reg   [8:0] sum;
        begin
            sum = {1'b0, a} + {1'b0, b};
            sat_add = sum[8] ? 8'hFF : sum[7:0];
        end
    endfunction

    // colour bytes come from the blend, the alpha byte is passed through from
    // the destination background
    wire [127:0] pack_data = {
        p2_dst[127:120], div255(n32), div255(n31), div255(n30),
        p2_dst[95:88],   div255(n22), div255(n21), div255(n20),
        p2_dst[63:56],   div255(n12), div255(n11), div255(n10),
        p2_dst[31:24],   div255(n02), div255(n01), div255(n00)
    };

    wire [127:0] add_pack_data = {
        p2_dst[127:120],
        sat_add(p2_dst[119:112], p2_src[119:112]),
        sat_add(p2_dst[111:104], p2_src[111:104]),
        sat_add(p2_dst[103:96],  p2_src[103:96]),

        p2_dst[95:88],
        sat_add(p2_dst[87:80],   p2_src[87:80]),
        sat_add(p2_dst[79:72],   p2_src[79:72]),
        sat_add(p2_dst[71:64],   p2_src[71:64]),

        p2_dst[63:56],
        sat_add(p2_dst[55:48],   p2_src[55:48]),
        sat_add(p2_dst[47:40],   p2_src[47:40]),
        sat_add(p2_dst[39:32],   p2_src[39:32]),

        p2_dst[31:24],
        sat_add(p2_dst[23:16],   p2_src[23:16]),
        sat_add(p2_dst[15:8],    p2_src[15:8]),
        sat_add(p2_dst[7:0],     p2_src[7:0])
    };

    wire [127:0] final_pack_data = p2_is_add ? add_pack_data : pack_data;

    wire [15:0] pack_mask = {
        {4{p2_keep[3]}}, {4{p2_keep[2]}}, {4{p2_keep[1]}}, {4{p2_keep[0]}}
    };

    reg [127:0] p3_data;
    reg [15:0]  p3_mask;
    reg         p3_v;

    // ---------------------------------------------------------------------
    // hold register + handshake
    // ---------------------------------------------------------------------
    wire accept = enable && src_valid && dst_valid && advance;

    assign src_ack   = accept;
    assign dst_ack   = accept;
    assign out_valid = h_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p0_v <= 1'b0; p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0; h_valid <= 1'b0;
            p0_is_add <= 1'b0; p1_is_add <= 1'b0; p2_is_add <= 1'b0;
            p0_src <= 128'd0; p0_dst <= 128'd0; p0_keep <= 4'd0;
            p1_src <= 128'd0; p1_dst <= 128'd0; p1_eff <= 32'd0; p1_keep <= 4'd0;
            p2_src <= 128'd0; p2_dst <= 128'd0; p2_keep <= 4'd0;
            p3_data <= 128'd0; p3_mask <= 16'd0;
            out_data <= 128'd0; out_mask <= 16'd0;
        end else if (clr) begin
            p0_v <= 1'b0; p1_v <= 1'b0; p2_v <= 1'b0; p3_v <= 1'b0; h_valid <= 1'b0;
            p0_is_add <= 1'b0; p1_is_add <= 1'b0; p2_is_add <= 1'b0;
            out_data <= 128'd0; out_mask <= 16'd0;
        end else if (advance) begin
            p0_v      <= accept;
            p0_is_add <= is_add;
            p0_src    <= src_data;
            p0_dst    <= dst_data;
            p0_keep   <= keep_in;

            p1_v      <= p0_v;
            p1_is_add <= p0_is_add;
            p1_src    <= p0_src;
            p1_dst    <= p0_dst;
            p1_eff    <= {eff3, eff2, eff1, eff0};
            p1_keep   <= p0_keep;

            p2_v      <= p1_v;
            p2_is_add <= p1_is_add;
            p2_src    <= p1_src;
            p2_dst    <= p1_dst;
            p2_keep   <= p1_keep;

            p3_v    <= p2_v;
            p3_data <= final_pack_data;
            p3_mask <= pack_mask;

            h_valid <= p3_v;
            if (p3_v) begin
                out_data <= p3_data;
                out_mask <= p3_mask;
            end
        end
    end

endmodule
