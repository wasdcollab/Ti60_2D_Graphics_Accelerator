`timescale 1ns/1ps
// =============================================================================
// tb_fx_ring -- pixel-exact check of the procedural impact ring layer
// -----------------------------------------------------------------------------
// The layer produces visible/add/alpha/rgb two clocks after (x,y,de).  This
// testbench drives a raster in the timing generator's order, computes the
// expected answer for every pixel with the same integer geometry, and compares
// it against the DUT two clocks later - so an off-by-one in the pipeline, a
// wrong feather edge, or a priority inversion all show up as a mismatch.
//
// Cases
//   1  disc (r_in = 0), alpha blend
//   2  annulus with a hole
//   3  additive ring
//   4  two overlapping slots -> slot 0 must win
//   5  occlusion box (mask_x[31]) -> nothing inside the box
//   6  r_out = 0 / disabled slot -> never visible
// =============================================================================
module tb_fx_ring;

    reg clk = 0, rst_n = 0;
    always #5.83 clk = ~clk;          // ~85.7 MHz

    localparam H_TOTAL = 1456;
    localparam V_TOTAL = 782;

    reg [11:0] x = 0;
    reg [10:0] y = 0;
    reg        de = 0;

    reg [127:0] p_a = 0, p_b = 0, p_c = 0;
    reg [31:0]  mask_x = 0, mask_y = 0;

    wire        v, ad;
    wire [7:0]  al;
    wire [23:0] rgb;

    video_fx_ring dut (
        .pixel_clk(clk), .pixel_rst_n(rst_n),
        .x(x), .y(y), .de(de),
        .p_a(p_a), .p_b(p_b), .p_c(p_c),
        .mask_x(mask_x), .mask_y(mask_y),
        .visible(v), .add(ad), .alpha(al), .rgb(rgb));

    // ---- stimulus slots ----------------------------------------------------
    // slot fields: en, add, r_out, cy, cx / r_in, alpha / rgb
    task set_slot(input integer slot,
                  input         en, add,
                  input [8:0]   ro, ri,
                  input [10:0]  cx,
                  input [9:0]   cy,
                  input [7:0]   alpha,
                  input [23:0]  colour);
        begin
            p_a[slot*32 + 31]        = en;
            p_a[slot*32 + 30]        = add;
            p_a[slot*32 + 21 +: 9]   = ro;
            p_a[slot*32 + 11 +: 10]  = cy;
            p_a[slot*32 +  0 +: 11]  = cx;
            p_b[slot*32 + 16 +: 9]   = ri;
            p_b[slot*32 +  0 +: 8]   = alpha;
            p_c[slot*32 +  0 +: 24]  = colour;
        end
    endtask

    // ---- reference ---------------------------------------------------------
    // Same integer geometry as the RTL: r^2, the +-2 px feather expanded as
    // r^2 +- 4r + 4, and slot 0 winning ties.
    integer ref_vis, ref_add, ref_alpha, ref_rgb;
    integer i, dx, dy, d2, ro, ri, a, ro2, ro2p, ri2, ri2m;
    integer inband, inner;

    task reference(input integer px, py);
        begin
            ref_vis = 0; ref_add = 0; ref_alpha = 0; ref_rgb = 0;
            for (i = 0; i < 4; i = i + 1) begin
                if (p_a[i*32 + 31]) begin
                    dx  = px - p_a[i*32 + 0 +: 11];
                    dy  = py - p_a[i*32 + 11 +: 10];
                    d2  = dx*dx + dy*dy;
                    ro  = p_a[i*32 + 21 +: 9];
                    ri  = p_b[i*32 + 16 +: 9];
                    a   = p_b[i*32 + 0 +: 8];
                    ro2 = ro*ro;
                    ro2p = ro2 + 4*ro + 4;
                    ri2 = ri*ri;
                    ri2m = (ri > 2) ? (ri2 - 4*ri + 4) : 0;
                    inband = (d2 <= ro2) && (d2 >= ri2);
                    inner  = (ri2 != 0) && (d2 < ri2) && (d2 >= ri2m);
                    if (!ref_vis && (inband || (d2 <= ro2p) || inner)) begin
                        ref_vis   = 1;
                        ref_add   = p_a[i*32 + 30];
                        ref_alpha = inband ? a : (a >> 1);
                        ref_rgb   = p_c[i*32 + 0 +: 24];
                    end
                end
            end
            if (mask_x[31] &&
                px >= mask_x[10:0] && px <= mask_x[21:11] &&
                py >= mask_y[10:0] && py <= mask_y[21:11]) begin
                ref_vis = 0; ref_add = 0; ref_alpha = 0; ref_rgb = 0;
            end
        end
    endtask

    // ---- expected queue: one entry per driven pixel, checked 2 clocks later --
    reg [33:0] exp_q [0:7];
    integer    q_wr = 0, q_rd = 0;
    reg        drain = 0;
    integer    errors = 0, checked = 0, covered = 0;
    integer    minx = 9999, maxx = -1, miny = 9999, maxy = -1;

    // drive pixel (px,py) and enqueue the expectation
    task pixel(input integer px, py);
        begin
            @(posedge clk); #1;
            x = px; y = py; de = 1;
            reference(px, py);
            exp_q[q_wr % 8] = {ref_vis[0], ref_add[0], ref_alpha[7:0], ref_rgb[23:0]};
            q_wr = q_wr + 1;
            if (ref_vis) begin
                if (px < minx) minx = px;
                if (px > maxx) maxx = px;
                if (py < miny) miny = py;
                if (py > maxy) maxy = py;
            end
        end
    endtask

    // compare the DUT output against the head of the queue every clock
    always @(negedge clk) if (rst_n && ((q_wr - q_rd) > 2 || (drain && q_rd < q_wr))) begin
        if ({v, ad, al, rgb} !== exp_q[q_rd % 8]) begin
            if (errors < 8)
                $display("MISMATCH: got v=%b add=%b a=%0d rgb=%06h, want v=%b add=%b a=%0d rgb=%06h",
                         v, ad, al, rgb,
                         exp_q[q_rd % 8][33], exp_q[q_rd % 8][32],
                         exp_q[q_rd % 8][31:24], exp_q[q_rd % 8][23:0]);
            errors = errors + 1;
        end
        checked = checked + 1;
        if (v) covered = covered + 1;
        q_rd = q_rd + 1;
    end

    // blank pixel between cases: expected "not visible"
    task blank;
        begin
            @(posedge clk); #1;
            de = 0; x = 0; y = 0;
            exp_q[q_wr % 8] = {1'b0, 1'b0, 8'd0, 24'd0};
            q_wr = q_wr + 1;
        end
    endtask

    integer qx, qy;
    initial begin
        for (i = 0; i < 4; i = i + 1) set_slot(i, 0, 0, 0, 0, 0, 0, 0, 0);
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // ---- case 1: disc, 60x60 around (600,300), blend ----------------
        set_slot(0, 1, 0, 30, 0, 600, 300, 8'hC0, 24'hFF4060);
        for (qy = 260; qy < 341; qy = qy + 1)
            for (qx = 560; qx < 641; qx = qx + 1) pixel(qx, qy);
        blank;

        // ---- case 2: annulus 40..44 with a hole -------------------------
        set_slot(0, 1, 0, 44, 40, 600, 300, 8'hFF, 24'h40C0FF);
        for (qy = 250; qy < 351; qy = qy + 1)
            for (qx = 550; qx < 651; qx = qx + 1) pixel(qx, qy);
        blank;

        // ---- case 3: additive ring -------------------------------------
        set_slot(0, 1, 1, 20, 17, 300, 200, 8'h80, 24'hFFFF80);
        for (qy = 175; qy < 226; qy = qy + 1)
            for (qx = 275; qx < 326; qx = qx + 1) pixel(qx, qy);
        blank;

        // ---- case 4: two overlapping rings, slot 0 must win -------------
        set_slot(0, 1, 0, 30, 0, 600, 300, 8'hFF, 24'hFF0000);
        set_slot(1, 1, 1, 30, 0, 620, 300, 8'hFF, 24'h00FF00);
        for (qy = 260; qy < 341; qy = qy + 1)
            for (qx = 560; qx < 661; qx = qx + 1) pixel(qx, qy);
        blank;
        set_slot(1, 0, 0, 0, 0, 0, 0, 0, 0);

        // ---- case 5: occlusion box over the whole ring ------------------
        set_slot(0, 1, 0, 30, 0, 600, 300, 8'hFF, 24'hFFFFFF);
        mask_x = {1'b1, 10'd0, 11'd700};     // x0=0, x1=700
        mask_y = {11'd0, 10'd0, 11'd400};    // y0=0, y1=400
        for (qy = 290; qy < 311; qy = qy + 1)
            for (qx = 590; qx < 611; qx = qx + 1) pixel(qx, qy);
        blank;
        mask_x = 0; mask_y = 0;

        // ---- case 6: r_out = 0 and a disabled slot ----------------------
        set_slot(0, 1, 0, 0, 0, 600, 300, 8'hFF, 24'hFFFFFF);
        set_slot(1, 0, 0, 30, 0, 600, 300, 8'hFF, 24'hFFFFFF);
        for (qy = 295; qy < 306; qy = qy + 1)
            for (qx = 595; qx < 606; qx = qx + 1) pixel(qx, qy);
        blank;

        drain = 1;                     // let the queue empty, then judge
        repeat (6) @(negedge clk);
        if (checked != q_wr) $fatal(1, "queue mismatch %0d/%0d", checked, q_wr);
        if (errors != 0) $fatal(1, "%0d pixel mismatches", errors);
        if (covered < 5000) $fatal(1, "coverage suspiciously small: %0d", covered);
        $display("PASS fx ring: %0d pixels compared, %0d covered, bbox x %0d..%0d y %0d..%0d",
                 checked, covered, minx, maxx, miny, maxy);
        $finish;
    end

endmodule
