`timescale 1ns/1ps
// tb_video_write_guard.sv  -- CORRECTED (v2)
//
// v1 reported CASE B as "DEADLOCK CONFIRMED".  That was a testbench artifact:
// CASE A never returned a B response, so write_pending stayed 1 forever and
// CASE B started from that dirty state.
// v2 models the DDR B response and uses a sticky monitor bit, because an
// admitted AW handshakes on the posedge and m_awvalid drops immediately
// afterwards (write_pending = 1) -- sampling only on negedge misses it.
module tb_video_write_guard;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg  prior = 0;
    reg  s_awvalid = 0;
    wire m_awvalid;
    wire s_awready;
    reg  m_awready = 0;
    reg  s_wvalid = 0;
    wire m_wvalid;
    wire s_wready;
    reg  m_wready = 0;
    reg  bvalid = 0;
    reg  bready = 1;

    video_write_guard dut (
        .clk(clk), .rst_n(rst_n), .video_priority(prior),
        .s_awvalid(s_awvalid), .m_awready(m_awready),
        .m_awvalid(m_awvalid), .s_awready(s_awready),
        .s_wvalid(s_wvalid), .m_wready(m_wready),
        .m_wvalid(m_wvalid), .s_wready(s_wready),
        .bvalid(bvalid), .bready(bready)
    );

    // ---- DDR write-response model: B arrives 3 cycles after AW handshake ----
    reg b_busy = 0;
    initial begin
        bvalid = 0; b_busy = 0;
        forever begin
            @(posedge clk);
            if (!b_busy && rst_n && m_awvalid && m_awready) begin
                b_busy = 1;
                repeat (3) @(posedge clk);
                @(negedge clk); bvalid = 1;
                @(posedge clk);
                @(negedge clk); bvalid = 0;
                b_busy = 0;
            end
        end
    end

    // ---- sticky monitors (sampled on posedge, cleared by the test) ----
    reg aw_seen_bit;      // m_awvalid was asserted at some posedge
    integer accept_cnt;   // number of completed AW handshakes
    always @(posedge clk) if (rst_n) begin
        if (m_awvalid) aw_seen_bit <= 1;
        if (m_awvalid && m_awready) accept_cnt <= accept_cnt + 1;
    end

    integer i, pass = 0, fail = 0, ok_rounds = 0;

    task chk;
        input cond;
        input [511:0] msg;
        begin
            if (cond) begin $display("   PASS: %0s", msg); pass = pass + 1; end
            else      begin $display("   FAIL: %0s", msg); fail = fail + 1; end
        end
    endtask

    initial begin
        aw_seen_bit = 0; accept_cnt = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (4) @(negedge clk);

        // ---------- S1: baseline write completes, write_pending self-clears ----
        $display("--- S1: normal write with B response ---");
        prior = 0; m_awready = 1; s_awvalid = 1;
        accept_cnt = 0;
        repeat (10) @(negedge clk);
        chk(accept_cnt >= 1, "at least one AW accepted while priority low");
        s_awvalid = 0;
        repeat (12) @(negedge clk);
        chk(dut.write_pending == 0, "write_pending self-cleared after B");

        // ---------- S2: priority high, FRESH request -> gated, then admitted --
        $display("--- S2: priority already high, fresh write arrives ---");
        prior = 1; m_awready = 1; s_awvalid = 1;
        aw_seen_bit = 0; accept_cnt = 0;
        repeat (6) @(negedge clk);
        chk(aw_seen_bit == 0, "fresh AW correctly held off while priority high");
        prior = 0;
        repeat (4) @(negedge clk);
        chk(aw_seen_bit == 1, "request admitted shortly after priority drops");
        chk(accept_cnt == 1, "exactly one handshake");
        s_awvalid = 0;
        repeat (12) @(negedge clk);
        chk(dut.write_pending == 0, "write_pending cleared again");

        // ---------- S3: AW stalled, THEN priority rises -> must keep trying ----
        $display("--- S3: AW already stalled, then priority rises ---");
        prior = 0; m_awready = 0; s_awvalid = 1;
        repeat (2) @(negedge clk);
        prior = 1;
        aw_seen_bit = 0;
        for (i = 0; i < 6; i = i + 1) @(negedge clk);
        chk(aw_seen_bit == 1, "stalled AW keeps AWVALID asserted under high priority");
        m_awready = 1;
        @(negedge clk);
        s_awvalid = 0; prior = 0;
        repeat (12) @(negedge clk);

        // ---------- S4: long priority burst while requesting -> no deadlock ---
        $display("--- S4: priority held high 50 cycles with a pending request ---");
        prior = 0; m_awready = 1; repeat (4) @(negedge clk);
        chk(dut.write_pending == 0 && dut.aw_held == 0, "guard idle before S4");
        prior = 1; s_awvalid = 1;
        aw_seen_bit = 0; accept_cnt = 0;
        repeat (50) @(negedge clk);
        chk(aw_seen_bit == 0, "request still gated after 50 cycles of priority");
        prior = 0;
        repeat (4) @(negedge clk);
        chk(accept_cnt == 1, "LIVENESS: request admitted after priority drop");
        s_awvalid = 0;
        repeat (12) @(negedge clk);
        chk(dut.write_pending == 0, "guard returned to idle after S4");

        // ---------- S5: W channel hold semantics ------------------------------
        $display("--- S5: W must not pass before AW is accepted ---");
        prior = 1; m_awready = 1; s_awvalid = 1; s_wvalid = 1; m_wready = 1;
        repeat (3) @(negedge clk);
        chk(m_wvalid == 0, "W held while AW is gated");
        prior = 0;
        repeat (4) @(negedge clk);
        accept_cnt = 0;
        chk(m_wvalid == 1, "W released once AW is accepted");
        s_awvalid = 0; s_wvalid = 0;
        repeat (12) @(negedge clk);

        // ---------- S6: back-to-back writes across priority toggling ----------
        $display("--- S6: 8 back-to-back writes with priority toggling ---");
        accept_cnt = 0;
        m_awready = 1;
        for (i = 0; i < 8; i = i + 1) begin
            prior = 1; s_awvalid = 1; aw_seen_bit = 0;
            repeat (3) @(negedge clk);
            prior = 0;
            repeat (6) @(negedge clk);
            if (aw_seen_bit) ok_rounds = ok_rounds + 1;
            s_awvalid = 0;
            repeat (14) @(negedge clk);
        end
        chk(ok_rounds == 8, "all 8 writes completed through the guard");
        chk(dut.write_pending == 0 && dut.aw_held == 0, "guard idle at end");

        $display("");
        $display("WGRESULT pass=%0d fail=%0d", pass, fail);
        $display("WGDONE");
        $finish(fail ? 1 : 0);
    end

    initial begin
        #500000;
        $display("WGDONE timeout");
        $finish(1);
    end
endmodule
