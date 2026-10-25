// =============================================================================
// video_weather.v -- hardware synthesis of the weather particle layer.
//
// The firmware used to erase and repaint ~14,600 scattered DDR pixels every
// frame straight from the CPU (stage_strip_render(), measured 3.28 ms of pure
// cache misses per frame).  This module regenerates the identical 170-dot
// pattern from the same xorshift32 sequence and overlays it on the scanout
// stream, so the CPU, the BitBlt engine and the DDR never see it.
//
// Dot table -- bit-exact with sw/app/main.c strip_dots_build():
//     s = 0x54; per dot: four xorshift32 steps
//     y = 32 + ((s >> 9) & 511);  x = s & 31;  h = 1 + (s & 1);
//     style = ((h - 1) << 1) | (s & 1)
//
// Placement -- bit-exact with stage_strip_render():
//     x0 = (x - scroll) & 31, pixels at x0 + k*32 for k in 0..42
//     rows  y + dy + slide, dy in 0..h-1
//     colour = style[0] ? dim : bright, per stage (card falls back to ice)
//
// Layer order: weather draws ABOVE the framebuffer (i.e. above sprites and
// bullets) and BELOW the HUD - the price of zero-cost synthesis.  The dots
// are 1-2 px and dim, and a snowflake riding a bullet is the accepted look.
//
// Pause-card occlusion (Phase 2, task 04).  The pause menu is painted into the
// framebuffer, i.e. UNDER this layer, so a flake that lands on the card lands on
// its lettering.  Switching the whole layer off while paused fixes the text and
// empties the sky, which is not the scene we want: the world is frozen, not
// featureless.  So the scanout is handed the card's bounding box instead and
// simply stops compositing the dots that fall inside it - two extra words per
// frame and four comparators, and the snow keeps falling everywhere around the
// menu.  A zero box (the reset value) leaves the layer exactly as it was.
//
// One 16-bit control word per frame, written by the firmware:
//     [15]    enable
//     [14:13] stage     0 ice, 1 lava, 2 dream, 3 card -> ice colours
//     [12:8]  scroll    phase 0..31, already direction-adjusted by firmware
//     [7:0]   slide     whole-layer vertical offset (boss shake), 0 or 8
// =============================================================================
`timescale 1ns / 1ps

module video_weather #(
    // The playfield band, in screen pixels.  The overlay is composited ABOVE the
    // framebuffer (HUD > weather > framebuffer), so outside this band the only
    // thing a dot can land on is a HUD gutter - it can never be scenery.  Fixed
    // parameters rather than a register because the band is a property of the
    // game's layout, not something to tune at run time, and the 16-bit control
    // word has no spare bits.  The values are main.c's GAME_LEFT / GAME_RIGHT;
    // tools/check_hud_layout.py re-derives them from those definitions and fails
    // the build if the two ever drift apart.
    parameter [11:0] PLAY_LEFT  = 12'd181,
    parameter [11:0] PLAY_RIGHT = 12'd1185
)(
    input  wire         pixel_clk,
    input  wire         pixel_rst_n,

    // scan position in the d1 domain (aligned with cur_pixel)
    input  wire [11:0]  x,
    input  wire [10:0]  y,
    input  wire         de,

    // control word, pre-synchronised to pixel_clk by the caller
    input  wire [31:0]  ctrl,

    // Pause-card occlusion box, pre-synchronised to pixel_clk by the caller and
    // latched on the same frame edge as ctrl, so box and layer can never be a
    // frame apart.
    //     mask_x: [10:0] x0, [21:11] x1, [31] enable (zero = layer untouched)
    //     mask_y: [10:0] y0, [21:11] y1
    input  wire [31:0]  mask_x,
    input  wire [31:0]  mask_y,

    output wire         visible,
    output wire [23:0]  rgb
);

    // ---- dot-table generator: strip_dots_build() in hardware ------------
    reg [31:0] xs;
    reg [8:0]  gen_idx;
    reg [1:0]  gen_step;
    reg [10:0] gen_y;
    reg [4:0]  gen_x;
    reg        gen_h1;
    reg [17:0] dot_mem [0:169];   // {style[0], style[1], y[10:0], x[4:0]}
    integer    gi;

    wire [31:0] xs1 = xs ^ (xs << 13);
    wire [31:0] xs2 = xs1 ^ (xs1 >> 17);
    wire [31:0] xs3 = xs2 ^ (xs2 << 5);

    // ---- per-line matcher -------------------------------------------------
    // Double buffered: cur_* is what the CURRENT scan line displays (collected
    // during the previous line), nxt_* is collected during the current line
    // for the next one.  A single buffer would wipe the line's own dots the
    // moment its x==0 tick fired.
    reg [7:0]  scan_idx;
    reg [2:0]  scan_div;
    reg [3:0]  slot_cnt;
    reg [4:0]  cur_x0 [0:7];
    reg [23:0] cur_col [0:7];
    reg        cur_v   [0:7];
    reg [4:0]  nxt_x0 [0:7];
    reg [23:0] nxt_col [0:7];
    reg        nxt_v   [0:7];
    integer    si;

    wire [10:0] y_next = y + 11'd1;
    wire [10:0] mem_y  = dot_mem[scan_idx][15:5];
    wire [4:0]  mem_x  = dot_mem[scan_idx][4:0];
    wire [1:0]  mem_st = dot_mem[scan_idx][17:16];
    wire [10:0] y_top  = mem_y + {3'd0, ctrl[7:0]};
    wire        hit    = (y_next >= y_top) && (y_next <= y_top + {10'd0, mem_st[1]});
    // Line head: wipe the collector and start scanning for the NEXT line's
    // dots.  Line tail: hand the collected set over to the display.  Handing
    // over at the head instead (as the first version did) makes the very
    // first pixel of a line still see the previous line's set for half a
    // clock, because the handover is a non-blocking assignment.
    wire        line_head = (x == 12'd0);
    wire        line_tail = (x == 12'd1455);

    // ---- colour per stage, bright/dim ------------------------------------
    wire [1:0]  st      = ctrl[14:13];
    wire        st_ice  = (st == 2'd0) || (st == 2'd3);
    wire [23:0] bright  = st_ice ? 24'hEEF8FF : (st == 2'd1) ? 24'hFF9A3C : 24'hD8A8FF;
    wire [23:0] dim     = st_ice ? 24'hCEE4FF : (st == 2'd1) ? 24'h7F4D1E : 24'h6C547F;
    wire [23:0] dot_col = mem_st[0] ? dim : bright;

    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            xs       <= 32'h00000054;
            gen_idx  <= 9'd0;
            gen_step <= 2'd0;
            gen_y    <= 11'd0;
            gen_x    <= 5'd0;
            gen_h1   <= 1'b0;
            for (gi = 0; gi < 170; gi = gi + 1) dot_mem[gi] <= 18'd0;
            scan_idx <= 8'd0;
            scan_div <= 3'd0;
            slot_cnt <= 4'd0;
            for (si = 0; si < 8; si = si + 1) begin
                cur_v[si]   <= 1'b0;
                cur_x0[si]  <= 5'd0;
                cur_col[si] <= 24'd0;
                nxt_v[si]   <= 1'b0;
                nxt_x0[si]  <= 5'd0;
                nxt_col[si] <= 24'd0;
            end
        end else begin
            // ---- table generation: 4 clocks per dot, 680 in total --------
            if (gen_idx < 9'd170) begin
                case (gen_step)
                2'd0: begin gen_y  <= 11'd32 + {2'd0, xs3[17:9]}; xs <= xs3; gen_step <= 2'd1; end
                2'd1: begin gen_x  <= xs3[4:0];                    xs <= xs3; gen_step <= 2'd2; end
                2'd2: begin gen_h1 <= xs3[0];                      xs <= xs3; gen_step <= 2'd3; end
                default: begin
                    dot_mem[gen_idx] <= {xs3[0], gen_h1, gen_y, gen_x};
                    xs       <= xs3;
                    gen_idx  <= gen_idx + 9'd1;
                    gen_step <= 2'd0;
                end
                endcase
            end

            // ---- per-line collection: one table entry per 8 clocks -------
            if (line_head) begin
                // wipe the collector, then scan the table during this line
                for (si = 0; si < 8; si = si + 1) nxt_v[si] <= 1'b0;
                scan_idx <= 8'd0;
                scan_div <= 3'd0;
                slot_cnt <= 4'd0;
            end else if (line_tail) begin
                // hand over at the END of the line: the whole next line then
                // displays one consistent set, including its very first pixel
                for (si = 0; si < 8; si = si + 1) begin
                    cur_v[si]   <= nxt_v[si];
                    cur_x0[si]  <= nxt_x0[si];
                    cur_col[si] <= nxt_col[si];
                end
            end else if (scan_div == 3'd7) begin
                scan_div <= 3'd0;
                if (scan_idx < 8'd170) begin
                    if (hit && (slot_cnt < 4'd8)) begin
                        nxt_v[slot_cnt[2:0]]   <= 1'b1;
                        nxt_x0[slot_cnt[2:0]]  <= mem_x - ctrl[12:8];
                        nxt_col[slot_cnt[2:0]] <= dot_col;
                        slot_cnt <= slot_cnt + 4'd1;
                    end
                    scan_idx <= scan_idx + 8'd1;
                end
            end else begin
                scan_div <= scan_div + 3'd1;
            end
        end
    end

    // ---- per-pixel hit: the dot repeats every 32 pixels ------------------
    wire [4:0] px5 = x[4:0];
    wire [7:0] hitmask = {
        cur_v[7] && (cur_x0[7] == px5),
        cur_v[6] && (cur_x0[6] == px5),
        cur_v[5] && (cur_x0[5] == px5),
        cur_v[4] && (cur_x0[4] == px5),
        cur_v[3] && (cur_x0[3] == px5),
        cur_v[2] && (cur_x0[2] == px5),
        cur_v[1] && (cur_x0[1] == px5),
        cur_v[0] && (cur_x0[0] == px5)
    };
    wire [2:0] first_hit =
        hitmask[0] ? 3'd0 : hitmask[1] ? 3'd1 : hitmask[2] ? 3'd2 : hitmask[3] ? 3'd3 :
        hitmask[4] ? 3'd4 : hitmask[5] ? 3'd5 : hitmask[6] ? 3'd6 : 3'd7;

    // Confine the layer to the playfield: it is drawn above the framebuffer, so
    // a dot in a gutter is a dot on top of the HUD.  Two comparators and an AND,
    // evaluated in the same cycle the pixel is already being composited - no
    // line buffer, no extra pipeline stage, nothing added to the frame time.
    wire in_playfield = (x >= PLAY_LEFT) && (x <= PLAY_RIGHT);

    // Pause-card occlusion.  The box is inclusive on both edges and is compared
    // against the same scan position the dots are matched on, so it needs no
    // line buffer and adds no pipeline stage - it is one more AND term on a
    // decision that is already combinational in this cycle.
    wire [11:0] box_x0 = {1'b0, mask_x[10:0]};
    wire [11:0] box_x1 = {1'b0, mask_x[21:11]};
    wire [11:0] box_y0 = {1'b0, mask_y[10:0]};
    wire [11:0] box_y1 = {1'b0, mask_y[21:11]};
    wire        in_box = mask_x[31] && (x >= box_x0) && (x <= box_x1) &&
                                       (y >= box_y0) && (y <= box_y1);

    assign visible = ctrl[15] && de && in_playfield && (|hitmask) && !in_box;
    assign rgb     = cur_col[first_hit];

endmodule
