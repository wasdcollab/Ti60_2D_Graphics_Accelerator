`timescale 1ns/1ps
// =============================================================================
// video_fx_ring -- procedural impact rings on the scanout (zero DDR traffic)
// -----------------------------------------------------------------------------
// What this replaces
//   burst_render() in sw/app/main.c used to blit a 112x112 pre-baked frame
//   through the BitBlt engine for every impact.  That is a read-modify-write
//   pass over DDR (src read + dst read + dst write, ~9.4k bus cycles for a
//   108x108 ring) plus a damage_restore of the same rectangle on the next
//   frame, for an effect that is nothing but a circle.  Here the circle is
//   computed from the pixel position: no DDR read, no DDR write, no engine
//   command, and the radius is continuous instead of quantised to 24 frames.
//
// Geometry
//   Four slots, each a ring or a disc:
//       covered  = r_in^2 <= (x-cx)^2 + (y-cy)^2 <= r_out^2
//   r_in = 0 makes it a disc (the bright core of an impact).  Each edge is
//   feathered by 2 px at alpha/2 so the ring does not alias into a hard
//   staircase edge; (r+-2)^2 is expanded as r^2 +- 4r + 4, so the feather costs
//   an adder, not another multiplier.
//
//   Slots are prioritised: slot 0 wins over slot 1 and so on.  The compositor
//   blends the single winning pixel once, which is what keeps this layer at one
//   128-bit blend instead of four.
//
// Timing
//   Two pipeline stages from (x,y) to (visible,rgb):
//       A: dx^2 + dy^2                (two 13x13 signed multiplies)
//       B: four compares, the feather, the priority pick, then the output reg
//   That is exactly the compositor's own latency from (cur_pixel, x) to s2_*,
//   so the ring pixel arrives on the same cycle as the stage-2 background it
//   is blended onto - no delay line, no shift of the picture.
//
// Alignment with the frame
//   p_a/p_b/p_c are latched by display_engine_top at v_cnt==V_ACT, h_cnt==0,
//   the same VSync-atomic point every other layer's parameters use, so a ring
//   never appears half-drawn or jumps by a frame.
//
// Field packing (4 slots x 32 bits in each of the three buses)
//   p_a[i] : {en, add, r_out[8:0], cy[9:0], cx[10:0]}
//   p_b[i] : {15'd0, r_in[8:0], alpha[7:0]}
//   p_c[i] : {8'd0, rgb[23:0]}
// =============================================================================
module video_fx_ring (
    input  wire         pixel_clk,
    input  wire         pixel_rst_n,
    input  wire [11:0]  x,
    input  wire [10:0]  y,
    input  wire         de,

    input  wire [127:0] p_a,
    input  wire [127:0] p_b,
    input  wire [127:0] p_c,

    // Occlusion box, same convention as video_laser/video_weather:
    //   mask_x: [10:0] x0, [21:11] x1, [31] enable
    input  wire [31:0]  mask_x,
    input  wire [31:0]  mask_y,

    output reg          visible,
    output reg          add,
    output reg  [7:0]   alpha,
    output reg  [23:0]  rgb
);

    wire [11:0] box_x0 = {1'b0, mask_x[10:0]};
    wire [11:0] box_x1 = {1'b0, mask_x[21:11]};
    wire [11:0] box_y0 = {1'b0, mask_y[10:0]};
    wire [11:0] box_y1 = {1'b0, mask_y[21:11]};

    // The occlusion box and DE belong to the pixel whose verdict is being
    // registered, not to the pixel being sampled this cycle: both are delayed
    // by the same stage as the geometry.
    reg [11:0] x_d1;
    reg [10:0] y_d1;
    reg        de_d1;

    always @(posedge pixel_clk) begin
        x_d1  <= x;
        y_d1  <= y;
        de_d1 <= de;
    end

    wire in_box = mask_x[31] && (x_d1 >= box_x0) && (x_d1 <= box_x1) &&
                  (y_d1 >= box_y0) && (y_d1 <= box_y1);

    // -------------------------------------------------------------------------
    // stage A: squared distance for every slot
    // -------------------------------------------------------------------------
    // d2 and its slot's thresholds are registered together, so stage B is a
    // pure compare tree.
    reg  [23:0] sa_d2   [0:3];
    reg  [17:0] sa_ro2  [0:3];
    reg  [17:0] sa_ro2p [0:3];
    reg  [17:0] sa_ri2  [0:3];
    reg  [17:0] sa_ri2m [0:3];
    reg  [ 7:0] sa_alpha[0:3];
    reg         sa_add  [0:3];
    reg         sa_en   [0:3];
    reg  [23:0] sa_rgb  [0:3];

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_slot
            wire        en  = p_a[i*32 + 31];
            wire        ad  = p_a[i*32 + 30];
            wire [8:0]  ro  = p_a[i*32 + 21 +: 9];
            wire [9:0]  cy  = p_a[i*32 + 11 +: 10];
            wire [10:0] cx  = p_a[i*32 +  0 +: 11];
            wire [8:0]  ri  = p_b[i*32 + 16 +: 9];
            wire [7:0]  al  = p_b[i*32 +  0 +: 8];

            // 13-bit signed difference: x reaches 1455 and cx 2047, so the
            // range is -2047..1455 and the square stays under 2^22.
            wire signed [12:0] dx = $signed({1'b0, x}) - $signed({2'b00, cx});
            wire signed [12:0] dy = $signed({2'b00, y}) - $signed({3'b000, cy});
            wire signed [25:0] dx2 = dx * dx;
            wire signed [25:0] dy2 = dy * dy;

            // (r+2)^2 = r^2 + 4r + 4 and (r-2)^2 = r^2 - 4r + 4 : no extra
            // multiplier for the feather, and the inner one is clamped so a
            // 0- or 1-pixel inner radius cannot wrap.
            wire [17:0] ro2  = ro * ro;
            wire [17:0] ri2  = ri * ri;
            wire [17:0] ro2p = ro2 + {9'd0, ro, 2'b00} + 18'd4;
            wire [17:0] ri2m = (ri > 9'd2) ? (ri2 - {9'd0, ri, 2'b00} + 18'd4)
                                           : 18'd0;

            always @(posedge pixel_clk) begin
                sa_d2[i]    <= dx2[23:0] + dy2[23:0];
                sa_ro2[i]   <= ro2;
                sa_ro2p[i]  <= ro2p;
                sa_ri2[i]   <= ri2;
                sa_ri2m[i]  <= ri2m;
                sa_alpha[i] <= al;
                sa_add[i]   <= ad;
                sa_en[i]    <= en;
                sa_rgb[i]   <= p_c[i*32 + 0 +: 24];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // stage B: verdict per slot, then the priority pick
    // -------------------------------------------------------------------------
    wire [3:0] cov, solid;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_verdict
            // inside the outer feather's outer edge
            wire inside_outer = (sa_d2[i] <= {6'd0, sa_ro2p[i]});
            // inside the solid band
            wire in_band      = (sa_d2[i] <= {6'd0, sa_ro2[i]}) &&
                                (sa_d2[i] >= {6'd0, sa_ri2[i]});
            // inner feather: just outside the band on the inside, only when
            // the slot really has a hole (a disc's "inner edge" is its centre)
            wire in_inner     = (sa_ri2[i] != 18'd0) &&
                                (sa_d2[i] <  {6'd0, sa_ri2[i]}) &&
                                (sa_d2[i] >= {6'd0, sa_ri2m[i]});
            assign solid[i] = sa_en[i] && in_band;
            assign cov[i]   = sa_en[i] && (inside_outer || in_inner);
        end
    endgenerate

    // slot 0 has the highest priority; a slot only wins when no lower-numbered
    // slot covers the pixel as well.
    wire [3:0] win = { cov[3] & ~(cov[2] | cov[1] | cov[0]),
                       cov[2] & ~(cov[1] | cov[0]),
                       cov[1] & ~cov[0],
                       cov[0] };

    wire [1:0] win_idx = win[0] ? 2'd0 :
                         win[1] ? 2'd1 :
                         win[2] ? 2'd2 : 2'd3;

    wire [7:0] win_alpha = solid[win_idx] ? sa_alpha[win_idx]
                                          : {1'b0, sa_alpha[win_idx][7:1]};
    wire       win_add   = sa_add[win_idx];
    wire [23:0] win_rgb  = sa_rgb[win_idx];

    wire any = |win;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            visible <= 1'b0;
            add     <= 1'b0;
            alpha   <= 8'd0;
            rgb     <= 24'd0;
        end else if (de_d1 && !in_box && any) begin
            visible <= 1'b1;
            add     <= win_add;
            alpha   <= win_alpha;
            rgb     <= win_rgb;
        end else begin
            visible <= 1'b0;
            add     <= 1'b0;
            alpha   <= 8'd0;
            rgb     <= 24'd0;
        end
    end

endmodule
