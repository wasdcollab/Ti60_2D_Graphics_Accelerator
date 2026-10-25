`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_dma_bucket_group -- the bucket prefetch's GROUP selection.
//
// The bucket table's row unit is a group of BUCKET_GROUP_ROWS scanlines, so the
// prefetch no longer asks for "scanline N+2": it asks for a GROUP, on each
// group's first scanline.  And the lift that runs in scanline v's blanking
// interval is consumed by scanline v+1 -- so the bucket it must present is
// (v+1)'s group, NOT v's.
//
// THAT LAST SENTENCE IS THE WHOLE POINT OF THIS BENCH.  Taking v's own group is
// right for seven scanlines out of every eight and wrong on the eighth: there the
// next scanline is handed the PREVIOUS group's bucket, its tile row reconstructs
// eight rows too high, and that scanline repeats what the scanline eight above it
// already showed.  On the board that reads as bands of the curtain sliding
// downwards.  Nothing else in the tree caught it - the firmware-side checker
// re-derives the table with the same formula the firmware uses, and
// tb_bullet_overlay drives the overlay directly with hand-built entries, so the
// group-to-scanline timing between the two had no test at all.
//
// The bench never predicts which group the DUT will ask for.  It tags whatever
// comes back with the group number the ADDRESS names, and then insists that the
// bucket presented for scanline `line` carries line's own group.  So it fails on
// the old wiring and passes on the fixed one, without being told either.
//
// Run:  tools\sim_dma_bucket_group.ps1
// -----------------------------------------------------------------------------
module tb_dma_bucket_group;

    localparam integer SLOTS      = 128;
    localparam integer GROUP_ROWS = 8;
    localparam integer GROUPS     = 768 / GROUP_ROWS;
    localparam [27:0]  BASE       = 28'h4800000;
    localparam [27:0]  PAGE       = 28'h0000C000;   // GROUPS * 512 B = 96 * 512

    reg aclk = 0, pclk = 0, rst = 0;
    always #5 aclk = ~aclk;
    always #6 pclk = ~pclk;

    reg  [11:0]  h = 1;
    reg  [10:0]  v = 0;
    reg  [27:0]  active = 28'h0800000;
    reg          arready = 0, rv = 0, last = 0;
    reg  [127:0] data = 0;
    wire         av, rr, act, pend, ready;
    wire [27:0]  addr;
    wire [7:0]   len;
    wire [4095:0] row;

    dma_bucket_prefetch #(
        .BUCKET_SLOTS       (SLOTS),
        .BUCKET_GROUP_ROWS  (GROUP_ROWS),
        .BUCKET_GROUP_SHIFT (3)
    ) dut (
        .axi_clk(aclk), .axi_rst_n(rst), .cal_done(1'b1),
        .bucket_base(BASE), .active_base(active),
        .frame_clear_axi(1'b0), .discard_frame(1'b0),
        .at_line_start(1'b1), .fb_busy(1'b0), .bk_pend(pend), .bk_act(act),
        .bk_araddr(addr), .bk_arlen(len), .bk_arvalid(av), .bk_arready(arready),
        .bk_rdata(data), .bk_rlast(last), .bk_rvalid(rv), .bk_rready(rr),
        .pixel_clk(pclk), .pixel_rst_n(rst), .h_cnt(h), .v_cnt(v),
        .bucket_row(row), .bucket_ready(ready)
    );

    integer checks = 0;
    integer fails  = 0;

    // Serve the two bursts the DUT is asking for.  Data is tagged with the group
    // number the ADDRESS names, so whatever was asked for is what lands in the
    // RAM and the lift check can tell which group it actually presented.
    task serve_bursts(input bit back);
        integer burst, beat, wordidx, want_g;
        reg [27:0] want;
        begin
            want_g = ((v >> 3) + 1) % GROUPS;
            for (burst = 0; burst < 2; burst = burst + 1) begin
                wait (av);
                want = BASE + (back ? PAGE : 28'h0) + want_g * 512 + burst * 256;
                repeat (3) begin
                    @(negedge aclk);
                    checks = checks + 1;
                    if (!av || addr !== want || len !== 8'd15) begin
                        fails = fails + 1;
                        $display("  FAIL AR: addr=%h want=%h len=%d av=%b (v=%0d back=%b)",
                                 addr, want, len, av, v, back);
                    end
                end
                if ({1'b0, addr[11:0]} + 13'd256 > 13'd4096) begin
                    fails = fails + 1;
                    $display("  FAIL burst crosses 4K: addr=%h", addr);
                end
                arready = 1;
                @(negedge aclk); arready = 0;
                for (beat = 0; beat < 16; beat = beat + 1) begin
                    repeat (2) @(negedge aclk);
                    if (!rr) begin fails = fails + 1; $display("  FAIL lost R owner"); end
                    for (wordidx = 0; wordidx < 4; wordidx = wordidx + 1)
                        data[wordidx*32 +: 32] = want_g*1000 + burst*64 + beat*4 + wordidx;
                    rv = 1; last = (beat == 15);
                    @(negedge aclk); rv = 0; last = 0;
                end
            end
            @(negedge aclk);
            checks = checks + 1;
            if (act) begin fails = fails + 1; $display("  FAIL transaction did not retire"); end
        end
    endtask

    // Stand on the first scanline of group `at_group` and serve what the DUT asks
    // for.  It must be a group boundary or the request never fires.
    task fetch_at(input integer at_group, input bit back);
        begin
            @(negedge pclk); v = at_group * GROUP_ROWS; h = 0;
            @(negedge pclk); h = 1;
            serve_bursts(back);
        end
    endtask

    // Drive scanline `line` end to end and grade the bucket it is handed.
    task exercise(input integer line, input bit back);
        integer g, slot;
        begin
            active = back ? 28'h0e00000 : 28'h0800000;
            g = line >> 3;

            // Group g is fetched on the previous group's first scanline ...
            fetch_at((g + GROUPS - 1) % GROUPS, back);
            // ... and group g+1 on g's own, which is what puts DIFFERENT data in
            // the other half.  Without this second fetch both halves would agree
            // and a wrong-half read would go unnoticed.
            fetch_at(g, back);

            // The lift runs in scanline line-1's blanking interval and feeds
            // scanline `line`, so it must present line's group.  h has to sweep
            // 1366..1397 - the lift window is h_cnt in [H_ACT, H_ACT+32) - or
            // nothing ever lifts and bucket_ready stays low.
            //
            // Scanline 0 has no scanline -1: its bucket is lifted in the frame's
            // LAST blanking line (v = V_TOTAL-1), which is the second arm of the
            // rtl's own condition.  Driving v = -1 here would wrap to 2047 in an
            // 11-bit reg and no lift would happen at all.
            @(negedge pclk);
            v = (line == 0) ? 11'd781 : (line - 1);
            h = 1366;
            for (slot = 0; slot < 32; slot = slot + 1) begin
                @(negedge pclk);
                h = h + 1;
            end

            // The lift is registered, so bk_flat_ok rises one pixel clock after
            // the last word is written - i.e. on the clock AFTER h reaches 1398.
            // Wait one more before grading.
            @(negedge pclk);

            checks = checks + 1;
            if (!ready) begin
                fails = fails + 1;
                $display("  FAIL line %0d: bucket never became ready (h=%0d v=%0d lift_d=%b lidx_d=%0d)",
                         line, h, v, dut.bk_lift_d, dut.bk_lidx_d);
            end else begin
                for (slot = 0; slot < SLOTS; slot = slot + 1)
                    if (row[slot*32 +: 32] !== g*1000 + slot) begin
                        fails = fails + 1;
                        $display("  FAIL line %0d (page %0d) slot %0d: presented group %0d, want %0d",
                                 line, back, slot, row[slot*32 +: 32] / 1000, g);
                        slot = SLOTS;
                    end
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge aclk); rst = 1;
        // Every residue inside a group, on both pages.  The LAST scanline of a
        // group is the one that catches a bucket presented for the wrong group;
        // the first scanline of the frame is the wrap case.
        exercise(7,   0);
        exercise(8,   0);
        exercise(15,  0);
        exercise(16,  0);
        exercise(23,  1);
        exercise(24,  1);
        exercise(760, 1);
        exercise(767, 1);
        exercise(0,   0);
        if (fails == 0)
            $display("PASS tb_dma_bucket_group: %0d checks; every scanline presented its own group (%0d groups of %0d rows)",
                     checks, GROUPS, GROUP_ROWS);
        else
            $display("FAIL tb_dma_bucket_group: %0d failures in %0d checks", fails, checks);
        $finish(fails ? 1 : 0);
    end

    initial begin #2000000; $display("FAIL tb_dma_bucket_group: timeout"); $finish(1); end

endmodule
