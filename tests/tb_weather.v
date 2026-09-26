// tb_weather.v -- verify video_weather against an independent reference model.
// The reference uses the same slot structure as the DUT (collect the NEXT line's
// dots at end of line, display the collected set during the line), so the whole
// frame is checked with eight comparisons per pixel instead of 170.
`timescale 1ns / 1ps

module tb_weather;

    reg         clk, rst_n;
    reg  [11:0] h_cnt;
    reg  [10:0] v_cnt;
    reg  [31:0] ctrl;
    // Pause-card occlusion box, in the register layout of APB 0x8C / 0xAC:
    //     mask_x = {enable, x1[10:0], x0[10:0]}
    //     mask_y = {10'd0, y1[10:0], y0[10:0]}
    reg  [31:0] mask_x, mask_y;
    wire        de_wire = (h_cnt < 1366) && (v_cnt < 768);

    wire        vis;
    wire [23:0] rgb;

    video_weather dut (
        .pixel_clk(clk), .pixel_rst_n(rst_n),
        .x(h_cnt), .y(v_cnt), .de(de_wire),
        .ctrl(ctrl),
        .mask_x(mask_x), .mask_y(mask_y),
        .visible(vis), .rgb(rgb)
    );

    // ---- independent reference: the firmware's dot table -----------------
    reg [31:0] rs;
    reg [10:0] ref_y [0:169];
    reg [4:0]  ref_x [0:169];
    reg [1:0]  ref_st [0:169];
    integer k;
    task ref_step;
        begin
            rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5);
        end
    endtask
    initial begin
        rs = 32'h54;
        for (k = 0; k < 170; k = k + 1) begin
            ref_step; ref_y[k] = 32 + ((rs >> 9) & 511);
            ref_step; ref_x[k] = rs & 31;
            ref_step; ref_st[k] = {rs[0], 1'b0};
            ref_step; ref_st[k] = {rs[0], ref_st[k][1]};
        end
    end

    // ---- reference collector: same pipeline as the DUT --------------------
    reg [4:0]  ex_x0 [0:7];
    reg [23:0] ex_col [0:7];
    reg        ex_v   [0:7];
    reg [3:0]  ex_cnt;
    reg [10:0] ey_next;
    reg [1:0]  stage;
    reg [23:0] bright, dim;
    integer m;

    always @(*) begin
        stage  = ctrl[14:13];
        bright = ((stage == 2'd0) || (stage == 2'd3)) ? 24'hEEF8FF :
                 (stage == 2'd1) ? 24'hFF9A3C : 24'hD8A8FF;
        dim    = ((stage == 2'd0) || (stage == 2'd3)) ? 24'hCEE4FF :
                 (stage == 2'd1) ? 24'h7F4D1E : 24'h6C547F;
    end

    always @(posedge clk or negedge rst_n) begin : ref_collect
        integer mm;
        reg [10:0] ey;
        reg [3:0]  ec;
        if (!rst_n) begin
            for (mm = 0; mm < 8; mm = mm + 1) begin
                ex_v[mm] <= 0; ex_x0[mm] <= 0; ex_col[mm] <= 0;
            end
        end else if (h_cnt == 12'd1455) begin
            // end of line: collect the dots of the NEXT line.  Blocking
            // temporaries: the NBA versions of these would lag one event.
            // v_cnt still holds the CURRENT line here; its NBA advances it on
            // this very clock, so "next line" is v_cnt + 1.
            ey = v_cnt + 11'd1;
            ec = 4'd0;
            for (mm = 0; mm < 8; mm = mm + 1) ex_v[mm] <= 1'b0;
            for (mm = 0; mm < 170; mm = mm + 1) begin
                if (ec < 4'd8 &&
                    (ey >= (ref_y[mm] + {3'd0, ctrl[7:0]})) &&
                    (ey <= (ref_y[mm] + {10'd0, ref_st[mm][1]} + {3'd0, ctrl[7:0]}))) begin
                    ex_x0[ec[2:0]]  <= ref_x[mm] - ctrl[12:8];
                    ex_col[ec[2:0]] <= ref_st[mm][0] ? dim : bright;
                    ex_v[ec[2:0]]   <= 1'b1;
                    ec = ec + 4'd1;
                end
            end
        end
    end

    // ---- per-pixel expectation -------------------------------------------
    wire [4:0] px5 = h_cnt[4:0];
    wire [7:0] ex_hit = {
        ex_v[7] && (ex_x0[7] == px5), ex_v[6] && (ex_x0[6] == px5),
        ex_v[5] && (ex_x0[5] == px5), ex_v[4] && (ex_x0[4] == px5),
        ex_v[3] && (ex_x0[3] == px5), ex_v[2] && (ex_x0[2] == px5),
        ex_v[1] && (ex_x0[1] == px5), ex_v[0] && (ex_x0[0] == px5)
    };
    wire [2:0] ex_first = ex_hit[0] ? 3'd0 : ex_hit[1] ? 3'd1 : ex_hit[2] ? 3'd2 :
                          ex_hit[3] ? 3'd3 : ex_hit[4] ? 3'd4 : ex_hit[5] ? 3'd5 :
                          ex_hit[6] ? 3'd6 : 3'd7;

    // ---- what the layer is ALLOWED to draw --------------------------------
    // Two gates sit between "this dot matched the scan line" and "this dot is on
    // screen": the playfield band (the layer is composited above the
    // framebuffer, so a dot in a HUD gutter would be a dot on the HUD) and, new
    // with the pause-card occlusion, the box the firmware publishes while the
    // menu is up.  Both are derived here from the parameters and from the
    // register layout - never read back out of the DUT.
    localparam [11:0] EXP_PLAY_LEFT  = 12'd181;
    localparam [11:0] EXP_PLAY_RIGHT = 12'd1185;
    wire exp_in_playfield = (h_cnt >= EXP_PLAY_LEFT) && (h_cnt <= EXP_PLAY_RIGHT);
    wire [11:0] exp_x0 = {1'b0, mask_x[10:0]};
    wire [11:0] exp_x1 = {1'b0, mask_x[21:11]};
    wire [11:0] exp_y0 = {1'b0, mask_y[10:0]};
    wire [11:0] exp_y1 = {1'b0, mask_y[21:11]};
    wire exp_in_box = mask_x[31] && (h_cnt >= exp_x0) && (h_cnt <= exp_x1) &&
                                    (v_cnt >= exp_y0) && (v_cnt <= exp_y1);
    wire exp_vis = ctrl[15] && exp_in_playfield && (|ex_hit) && !exp_in_box;

    // ---- clock + scan counters -------------------------------------------
    initial clk = 0;
    always #5.85 clk = ~clk;   // 85.47 MHz

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 12'd0;
            v_cnt <= 11'd0;
        end else begin
            if (h_cnt == 12'd1455) begin
                h_cnt <= 12'd0;
                v_cnt <= (v_cnt == 11'd781) ? 11'd0 : v_cnt + 11'd1;
            end else begin
                h_cnt <= h_cnt + 12'd1;
            end
        end
    end

    // ---- checker ----------------------------------------------------------
    // Two counters exist so that the occlusion pass cannot succeed vacuously: a
    // box that swallowed every dot, or missed every dot, would make "dut == exp"
    // true for the wrong reason.
    integer errors, checked, covered_dots, sky_dots;
    reg checking;
    always @(posedge clk) begin
        if (checking && de_wire) begin
            checked = checked + 1;
            if (ctrl[15] && (|ex_hit)) begin
                if (exp_in_box) covered_dots = covered_dots + 1;
                else            sky_dots     = sky_dots + 1;
            end
            if (vis !== exp_vis) begin
                if (errors < 12)
                    $display("MISMATCH vis @(%0d,%0d): dut=%b exp=%b",
                             h_cnt, v_cnt, vis, exp_vis);
                errors = errors + 1;
            end else if (vis && (rgb !== ex_col[ex_first])) begin
                if (errors < 12)
                    $display("MISMATCH rgb @(%0d,%0d): dut=%h exp=%h",
                             h_cnt, v_cnt, rgb, ex_col[ex_first]);
                errors = errors + 1;
            end
        end
    end

    task check_frame;
        integer guard;
        begin
            guard = 0;
            while (!((h_cnt == 12'd0) && (v_cnt == 11'd0))) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 1456 * 782) begin
                    $display("TIMEOUT waiting for frame start");
                    $finish;
                end
            end
            checking = 1;
            repeat (1456 * 782) @(posedge clk);
            checking = 0;
        end
    endtask

    initial begin
        errors = 0; checked = 0; checking = 0;
        covered_dots = 0; sky_dots = 0;
        rst_n = 0;
        ctrl = 32'h0000_0000;
        mask_x = 32'd0; mask_y = 32'd0;
        repeat (6) @(posedge clk);
        rst_n = 1;
        repeat (1456 * 40) @(posedge clk);   // settle generation + pipeline

        // ---- verify the generated table against the reference -----------
        for (k = 0; k < 170; k = k + 1) begin
            if (dut.dot_mem[k][4:0] !== ref_x[k] ||
                dut.dot_mem[k][15:5] !== ref_y[k] ||
                dut.dot_mem[k][17:16] !== ref_st[k]) begin
                if (errors < 10)
                    $display("GEN MISMATCH k=%0d dut={%0b,%0d,%0d} ref={%0b,%0d,%0d}",
                             k, dut.dot_mem[k][17:16], dut.dot_mem[k][15:5],
                             dut.dot_mem[k][4:0], ref_st[k], ref_y[k], ref_x[k]);
                errors = errors + 1;
            end
        end
        $display("gen table check done, errors=%0d", errors);

        // ---- dump slots at line 32: DUT cur vs reference ex ------------
        fork
            begin
                while (!((h_cnt == 12'd5) && (v_cnt == 11'd32))) @(posedge clk);
                for (k = 0; k < 8; k = k + 1)
                    $display("L32 DUT cur[%0d]: v=%b x0=%0d col=%h | EX[%0d]: v=%b x0=%0d",
                             k, dut.cur_v[k], dut.cur_x0[k], dut.cur_col[k],
                             k, ex_v[k], ex_x0[k]);
                // and during line 31, watch one full collect pass
            end
        join_none
        fork
            begin
                while (!((h_cnt == 12'd1454) && (v_cnt == 11'd31))) @(posedge clk);
                $display("L31 tail: DUT scan_idx=%0d cnt=%0d nxt_v0=%b | EX cnt was %0d",
                         dut.scan_idx, dut.slot_cnt, dut.nxt_v[0], ex_cnt);
            end
        join_none

        // ---- watch the collector during line 32 (y=32 is the first dot) --
        fork
            begin
                while (!((h_cnt == 12'd1) && (v_cnt == 11'd32))) @(posedge clk);
                repeat (30) begin
                    @(posedge clk);
                    $display("line32 t=%0t x=%0d scan=%0d div=%0d cnt=%0d hit=%b ynext=%0d ytop=%0d",
                             $time, h_cnt, dut.scan_idx, dut.scan_div, dut.slot_cnt,
                             dut.hit, dut.y_next, dut.y_top);
                end
            end
        join_none

        ctrl = 32'h0000_8000;   // enable, stage 0, scroll 0, slide 0
        covered_dots = 0; sky_dots = 0;
        check_frame;
        $display("pass1 errors=%0d sky_dots=%0d", errors, sky_dots);
        if (covered_dots != 0) begin
            $display("FAIL: a zero box occluded %0d dots", covered_dots);
            errors = errors + 1;
        end

        ctrl = 32'h0000_8405;   // enable, stage 1, scroll 5, slide 8
        covered_dots = 0; sky_dots = 0;
        check_frame;
        $display("pass2 errors=%0d sky_dots=%0d", errors, sky_dots);

        ctrl = 32'h0000_0000;   // disabled
        check_frame;
        $display("pass3 errors=%0d", errors);

        // ---- pass4: the pause card's box punches a hole in the layer -------
        // The box is main.c's settings card: 512x352 centred on 1366x768, i.e.
        // x 427..938, y 208..559.  Written the way the firmware writes it - y
        // first, then x, which carries the enable.
        mask_y = (32'd559 << 11) | 32'd208;
        mask_x = 32'h8000_0000 | (32'd938 << 11) | 32'd427;
        ctrl = 32'h0000_8000;
        covered_dots = 0; sky_dots = 0;
        check_frame;
        $display("pass4 (occluded) errors=%0d covered_dots=%0d sky_dots=%0d",
                 errors, covered_dots, sky_dots);
        if (covered_dots == 0) begin
            $display("VACUOUS: no dot ever fell inside the pause card");
            errors = errors + 1;
        end
        if (sky_dots == 0) begin
            $display("VACUOUS: no dot was left outside the pause card");
            errors = errors + 1;
        end

        // ---- pass5: box released, the sky is whole again -------------------
        mask_x = 32'd0; mask_y = 32'd0;
        covered_dots = 0; sky_dots = 0;
        check_frame;
        $display("pass5 (released) errors=%0d sky_dots=%0d", errors, sky_dots);
        if (covered_dots != 0) begin
            $display("FAIL: released box still occluded %0d dots", covered_dots);
            errors = errors + 1;
        end

        $display("checked=%0d pixels, errors=%0d", checked, errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

endmodule
