`timescale 1ns/1ps
// =============================================================================
// tb_compositor_align -- DE and the pixel must stay one stream
// -----------------------------------------------------------------------------
// Stage 2b (the impact-ring blend) added a register stage to the compositor.
// The picture cannot move relative to DE: that would shift the whole frame
// against the syncs and the HDMI receiver would re-lock one pixel over.  This
// bench drives a raster whose pixel value IS its x coordinate, with every
// layer switched off, and checks that each output pixel arrives inside the DE
// window that belongs to it - i.e. the first pixel of a line is the first DE
// cycle, and it carries x=0.
// =============================================================================
module tb_compositor_align;

    reg pixel_clk = 0, rst_n = 0;
    always #5.83 pixel_clk = ~pixel_clk;

    localparam H_ACT = 32, H_TOTAL = 48, V_ACT = 4, V_TOTAL = 6;

    reg [11:0] h = 0;
    reg [10:0] v = 0;
    reg        hs = 0, vs = 0, de = 0;
    reg [31:0] pix = 0;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            h <= 0; v <= 0; de <= 0; hs <= 0; vs <= 0;
        end else begin
            h <= (h == H_TOTAL - 1) ? 12'd0 : h + 12'd1;
            if (h == H_TOTAL - 1) v <= (v == V_TOTAL - 1) ? 11'd0 : v + 11'd1;
            de <= (h < H_ACT) && (v < V_ACT);
            hs <= (h >= H_ACT) && (h < H_ACT + 4);
            vs <= (v >= V_ACT) && (v < V_ACT + 2);
        end
    end

    // One register stage, the same one t_de_d1 gets: the pixel value is its own
    // x and y, so a one-pixel shift cannot hide in the comparison.
    reg [31:0] pixd = 0;
    always @(posedge pixel_clk) pixd <= {8'h00, h[7:0], v[7:0], 8'h00};

    wire [7:0] cr, cg, cb, ca;
    wire       chs, cvs, cde;

    video_pixel_compositor dut (
        .pixel_clk(pixel_clk), .pixel_rst_n(rst_n),
        .t_hsync_d1(hs), .t_vsync_d1(vs), .t_de_d1(de),
        .cur_pixel(pixd),
        .w_visible(1'b0), .w_rgb(24'd0),
        .u_visible(1'b0), .u_add_sel(1'b0), .u_rgb(24'd0), .u_alpha(8'd0),
        .l_visible(1'b0), .l_laser_add(1'b0), .l_laser_alpha(8'd0), .l_rgb(24'd0),
        .b_visible(1'b0), .b_beam_vis(1'b0), .b_hair_vis(1'b0),
        .b_beam_add(1'b0), .b_beam_alpha(8'd0), .b_rgb(24'd0),
        .f_visible(1'b0), .f_add(1'b0), .f_alpha(8'd0), .f_rgb(24'd0),
        .hud_visible(1'b0), .hud_rgb(24'd0), .hud_enable(1'b0),
        .comp_a(ca), .comp_r(cr), .comp_g(cg), .comp_b(cb),
        .comp_hs(chs), .comp_vs(cvs), .comp_de(cde));

    // ---- checks ------------------------------------------------------------
    integer errors = 0, pixels = 0, lines = 0;
    reg [7:0] want_x = 0;
    reg [7:0] want_y = 0;
    reg       in_frame = 0;

    always @(posedge pixel_clk) if (rst_n) begin
        // the compositor blanks its outputs outside DE, so DE gates the check
        if (cde) begin
            if (!in_frame) begin
                // first pixel of a line must be x = 0 (g carries the line number)
                if (cr !== 8'd0) begin
                    if (errors < 6)
                        $display("MISMATCH first pixel: got r=%0d g=%0d, want r=0", cr, cg);
                    errors = errors + 1;
                end
                in_frame = 1;
                want_y = cg;
                lines = lines + 1;
            end else if (cr !== (want_x + 8'd1) || cg !== want_y) begin
                if (errors < 6)
                    $display("MISMATCH at line %0d x %0d: got r=%0d g=%0d",
                             want_y, want_x, cr, cg);
                errors = errors + 1;
                want_x = cr;
            end else begin
                want_x = cr;
            end
            pixels = pixels + 1;
        end else begin
            if (in_frame) begin
                if (want_x !== H_ACT - 1) begin
                    if (errors < 6)
                        $display("MISMATCH line %0d ended at x=%0d, want %0d",
                                 want_y, want_x, H_ACT - 1);
                    errors = errors + 1;
                end
                want_x = 0;
                in_frame = 0;
            end
        end
    end

    initial begin
        repeat (4) @(negedge pixel_clk);
        rst_n = 1;
        repeat (V_TOTAL * H_TOTAL * 3) @(negedge pixel_clk);
        if (lines < V_ACT * 2) $fatal(1, "only %0d lines captured", lines);
        if (errors != 0) $fatal(1, "%0d alignment mismatches", errors);
        if (pixels != lines * H_ACT) $fatal(1, "DE width wrong: %0d px in %0d lines",
                                           pixels, lines);
        $display("PASS compositor alignment: %0d pixels over %0d lines, DE and RGB in step",
                 pixels, lines);
        $finish;
    end

endmodule
