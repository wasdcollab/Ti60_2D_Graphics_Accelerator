// =============================================================================
// tb_step3_bitblt_copy.sv
// -----------------------------------------------------------------------------
// Vector driven, byte-exact regression for the BitBlt engine v2.
//
// The vector file (tests/bitblt_copy_vectors.txt) is shared with the Python
// reference model in simulator/rv32i_soc_vm.py, so both implementations are
// driven by exactly the same stimulus and their per-vector FNV hashes can be
// diffed.
//
// Vector line:  op src_off dst_off width height src_stride dst_stride color
//               op 0 = OP_FILL, op 1 = OP_COPY
//
// Per vector the bench checks:
//   * every destination byte of the rectangle equals the golden model
//       - FILL : the colour register
//       - COPY : the byte snapshot of the source taken before the command
//   * the number of bytes actually written equals 4*width*height
//     (no stray and no missing bytes anywhere in DDR)
//   * AXI4 protocol: 16-byte ARSIZE/AWSIZE, 16-byte aligned addresses,
//     INCR bursts, never crossing a 4 KiB boundary, AWLEN/ARLEN <= MAX_BURST-1,
//     WLAST exactly on the final beat, payload stable while stalled
//   * the read channel really does use long bursts - reported at the end
//
// Override the burst length with:  xvlog -d BITBLT_MAX_BURST=16 ...
// =============================================================================
`timescale 1ns/1ps

// Burst-length configuration.  The runner writes bitblt_burst_cfg.vh into the
// simulation directory (see tests/run_bitblt_copy_rtl.ps1) so the same bench
// can be elaborated for 64-beat and for the conservative 16-beat setting.
`include "bitblt_burst_cfg.vh"
`ifndef BITBLT_MAX_BURST
 `define BITBLT_MAX_BURST 64
`endif

module tb_step3_bitblt_copy;

    localparam integer MAXB = `BITBLT_MAX_BURST;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    // ---------------- APB ----------------
    reg  [15:0] pa = 0;
    reg         ps = 0, pe = 0, pw = 0;
    reg  [31:0] pd = 0;
    wire [31:0] pr;
    wire        pre, per;

    // ---------------- AXI4 master side ----------------
    wire [3:0]  arid, awid, wid, bid;
    wire [27:0] araddr, awaddr;
    wire [7:0]  arlen, awlen;
    wire [2:0]  arsize, awsize;
    wire [1:0]  arburst, arlock, awburst, awlock;
    wire        arvalid, arready;
    wire [127:0] rdata;
    wire [1:0]  rresp = 2'b00;
    wire        rlast, rvalid, rready;
    wire [127:0] wdata;
    wire [15:0] wstrb;
    wire        wlast, wvalid, wready;
    wire        awvalid, awready, bvalid, bready;

    wire [27:0] next_base, right_next_base;
    wire [7:0]  cpu_fps, fpga_fps;
    wire [6:0]  i2c_addr;
    wire        hud_dis;

    localparam [3:0] RID = 4'd2;

    // FIFO depth is derived from the burst length on purpose.  bitblt_stride_gen
    // sizes its beat credit on the invariant
    //
    //     FIFO_DEPTH > 2*MAX_BURST_BEATS + 4
    //
    // and a bench that widens the burst without widening the FIFO tests nothing
    // useful - it deadlocks the read iterator, because rd_room_ok can never be
    // satisfied.  That is exactly what the first 192-beat run did: the
    // generator reserved 129 beats and issued none of them.  (The board's own
    // configuration in ti60_top.v already satisfies this: 512 > 2*192 + 4.)
    bitblt_top #(
        .MAX_BURST_BEATS (MAXB),
        .READ_FIFO_DEPTH (2*MAXB + 8),
        .READ_FIFO_AW    (10),
        .DST_FIFO_DEPTH  (2*MAXB + 8),
        .DST_FIFO_AW     (10)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .apb_paddr(pa), .apb_psel(ps), .apb_penable(pe), .apb_pwrite(pw),
        .apb_pwdata(pd), .apb_prdata(pr), .apb_pready(pre), .apb_pslverr(per),

        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(RID), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready),

        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wid(wid), .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bvalid(bvalid), .m_axi_bready(bready),

        .vdma_next_base(next_base), .vdma_active_base(28'h0100_0000),
        .vdma_right_next_base(right_next_base),
        .vdma_right_active_base(28'h0100_0000),
        .cpu_fps_bcd(cpu_fps), .fpga_fps_bcd(fpga_fps),
        .scan_diagnostics(32'd0), .vsync_flag(1'b0),

        .gamepad_joy_x(8'd128), .gamepad_joy_y(8'd128), .gamepad_buttons(5'd0),
        .gamepad_online(1'b0),
        .key_sw0_level(1'b0), .key_sw2_level(1'b0),
        .key_sw0_pulse(1'b0), .key_sw2_pulse(1'b0),
        .i2c_slave_addr(i2c_addr), .force_hud_disable(hud_dis)
    );

    // =====================================================================
    // DDR model: 64 KiB at SRC_BASE and 64 KiB at DST_BASE, byte addressable.
    // =====================================================================
    localparam [27:0] SRC_BASE = 28'h0160_0000;
    localparam [27:0] DST_BASE = 28'h0130_0000;
`ifdef BITBLT_LARGE_TEST
    localparam integer MEMSZ   = 4096 * 601 + 16;
`else
    localparam integer MEMSZ   = 65536;
`endif

    reg [7:0] src_mem  [0:MEMSZ-1];
    reg [7:0] dst_mem  [0:MEMSZ-1];
    reg [7:0] src_snap [0:MEMSZ-1];
    reg [7:0] dst_snap [0:MEMSZ-1];
    reg       written  [0:MEMSZ-1];

    // ---------------- deterministic stall pattern ----------------
    integer stall_ctr = 0;
    reg arready_r = 0, awready_r = 0, wready_r = 0;

    // ---------------- responders (single posedge block) ----------------
    reg         rd_active = 0;
    reg [27:0]  rd_cur    = 0;
    reg [7:0]   rd_left   = 0;
    reg [7:0]   rd_idx    = 0;
    reg [127:0] rdata_r   = 0;
    reg         rvalid_r  = 0;

    reg         wr_active = 0;
    reg [27:0]  wr_cur    = 0;
    reg [7:0]   wr_len    = 0;
    reg [7:0]   wr_beat   = 0;
    reg         bvalid_r  = 0;
    reg [7:0]   b_delay   = 0;

    integer bytes_written = 0;
    integer stray_writes  = 0;
    integer max_ar_len_seen = 0;
    integer max_aw_len_seen = 0;

    reg [27:0]  aw_saved = 0;   reg [7:0] awlen_saved = 0;  reg aw_stalled = 0;
    reg [127:0] w_saved = 0;    reg [15:0] wstrb_saved = 0; reg wlast_saved = 0;
    reg         w_stalled = 0;

    wire aw_hs = awvalid && awready;
    wire w_hs  = wvalid  && wready;
    wire ar_hs = arvalid && arready;
    wire b_hs  = bvalid  && bready;

    assign arready = arready_r;
    assign awready = awready_r;
    assign wready  = wready_r;
    assign bvalid  = bvalid_r;
    assign rvalid  = rvalid_r;
    assign rlast   = rvalid_r && (rd_left == 8'd1);
    assign rdata   = rdata_r;

    wire [27:0] rd_byte_addr = rd_cur + {16'd0, rd_idx, 4'd0};

    always @(negedge clk) begin
        stall_ctr  <= stall_ctr + 1;
        arready_r  <= (rd_active === 1'b0) && ((stall_ctr % 4) != 0);
        awready_r  <= (wr_active === 1'b0) && (bvalid_r === 1'b0) && (b_delay == 0) &&
                      ((stall_ctr % 6) >= 2);
        wready_r   <= (wr_active === 1'b1) && ((stall_ctr % 5) != 3);
    end

    // The engine can read from BOTH modelled regions: the source surface for
    // OP_COPY and, for OP_ALPHA, the live destination background.  Background
    // reads are served from dst_mem itself, so a buggy engine that blends
    // against already-blended data is caught instead of being hidden.
`ifdef BITBLT_PORTABLE_TB
    // Avoid a millions-of-elements inferred sensitivity list in Icarus.
    // Refresh on both clock edges and on address changes: R data is settled
    // before each posedge handshake, including after test-source rewrites.
    always @(rd_byte_addr or clk) begin
`else
    always @* begin
`endif
        for (int b = 0; b < 16; b = b + 1) begin
            integer idx, didx;
            idx  = (rd_byte_addr - SRC_BASE) + b;
            didx = (rd_byte_addr - DST_BASE) + b;
            if (rd_byte_addr >= SRC_BASE && rd_byte_addr < SRC_BASE + MEMSZ)
                rdata_r[b*8 +: 8] = (idx  >= 0 && idx  < MEMSZ) ? src_mem[idx]  : 8'h00;
            else if (rd_byte_addr >= DST_BASE && rd_byte_addr < DST_BASE + MEMSZ)
                rdata_r[b*8 +: 8] = (didx >= 0 && didx < MEMSZ) ? dst_mem[didx] : 8'h00;
            else
                rdata_r[b*8 +: 8] = 8'h00;
        end
    end

    always @(posedge clk) if (rst_n) begin
        // ------------------------------------------------ read responder
        if (ar_hs) begin
            if (arsize !== 3'b100)    $fatal(1, "ARSIZE != 16 bytes");
            if (arburst !== 2'b01)    $fatal(1, "ARBURST != INCR");
            if (araddr[3:0] !== 4'd0) $fatal(1, "ARADDR misaligned %h", araddr);
            if (arlen > (MAXB - 1))   $fatal(1, "ARLEN %0d exceeds MAX_BURST %0d", arlen, MAXB);
            if (araddr[11:0] + (arlen + 1) * 16 > 4096) $fatal(1, "read burst crosses 4 KiB");
            if (!((araddr >= SRC_BASE && araddr + (arlen+1)*16 <= SRC_BASE + MEMSZ) ||
                  (araddr >= DST_BASE && araddr + (arlen+1)*16 <= DST_BASE + MEMSZ)))
                                      $fatal(1, "read burst outside model %h", araddr);
            rd_active <= 1'b1;
            rd_cur    <= araddr;
            rd_left   <= arlen + 8'd1;
            rd_idx    <= 8'd0;
            if ((arlen + 1) > max_ar_len_seen) max_ar_len_seen = arlen + 1;
        end

        if (rd_active) begin
            if (!rvalid_r && ((stall_ctr % 5) != 0))
                rvalid_r <= 1'b1;
            if (rvalid_r && rready) begin
                rvalid_r <= 1'b0;
                rd_idx   <= rd_idx + 8'd1;
                rd_left  <= rd_left - 8'd1;
                if (rd_left == 8'd1) rd_active <= 1'b0;
            end
        end else begin
            rvalid_r <= 1'b0;
        end

        // ------------------------------------------------ write responder
        if (aw_stalled && (!awvalid || awaddr !== aw_saved || awlen !== awlen_saved))
            $fatal(1, "AW changed while stalled");
        aw_stalled  <= awvalid && !awready;
        aw_saved    <= awaddr;
        awlen_saved <= awlen;

        if (aw_hs) begin
            if (awsize !== 3'b100)    $fatal(1, "AWSIZE != 16 bytes");
            if (awburst !== 2'b01)    $fatal(1, "AWBURST != INCR");
            if (awaddr[3:0] !== 4'd0) $fatal(1, "AWADDR misaligned %h", awaddr);
            if (awlen > (MAXB - 1))   $fatal(1, "AWLEN %0d exceeds MAX_BURST %0d", awlen, MAXB);
            if (awaddr[11:0] + (awlen + 1) * 16 > 4096) $fatal(1, "write burst crosses 4 KiB");
            if (awaddr < DST_BASE || awaddr + (awlen+1)*16 > DST_BASE + MEMSZ)
                                      $fatal(1, "write burst outside model %h", awaddr);
            wr_active <= 1'b1;
            wr_cur    <= awaddr;
            wr_len    <= awlen;
            wr_beat   <= 8'd0;
            if ((awlen + 1) > max_aw_len_seen) max_aw_len_seen = awlen + 1;
        end

        if (w_stalled && (!wvalid || wdata !== w_saved || wstrb !== wstrb_saved ||
                          wlast !== wlast_saved))
            $fatal(1, "W changed while stalled");
        w_stalled   <= wvalid && !wready;
        w_saved     <= wdata;
        wstrb_saved <= wstrb;
        wlast_saved <= wlast;

        if (w_hs) begin
            if (!wr_active) $fatal(1, "W beat without AW");
            if (wlast !== (wr_beat == wr_len))
                $fatal(1, "bad WLAST at beat %0d/%0d", wr_beat, wr_len);
            for (int k = 0; k < 16; k = k + 1) begin
                if (wstrb[k]) begin
                    integer ba;
                    ba = (wr_cur - DST_BASE) + wr_beat*16 + k;
                    if (ba < 0 || ba >= MEMSZ) $fatal(1, "write outside model %0d", ba);
                    if (written[ba]) stray_writes = stray_writes + 1;
                    written[ba] = 1'b1;
                    dst_mem[ba] <= wdata[k*8 +: 8];
                    bytes_written = bytes_written + 1;
                end
            end
            if (wlast) begin
                wr_active <= 1'b0;
                b_delay   <= 8'd12;
            end else begin
                wr_beat <= wr_beat + 8'd1;
            end
        end

        if (b_delay > 0) begin
            b_delay <= b_delay - 8'd1;
            if (b_delay == 8'd1) bvalid_r <= 1'b1;
        end
        if (b_hs) bvalid_r <= 1'b0;
    end

    // =====================================================================
    // APB helpers
    // =====================================================================
    task apb_write(input [15:0] off, input [31:0] value);
        begin
            @(negedge clk); pa = off; pd = value; ps = 1; pw = 1; pe = 0;
            @(negedge clk); pe = 1;
            @(negedge clk); ps = 0; pe = 0; pw = 0;
        end
    endtask

    task apb_read(input [15:0] off, output [31:0] value);
        begin
            @(negedge clk); pa = off; ps = 1; pw = 0; pe = 0;
            @(negedge clk); pe = 1; #1; value = pr;
            @(negedge clk); ps = 0; pe = 0;
        end
    endtask

    // =====================================================================
    // Vector driven execution
    // =====================================================================
    reg [31:0] status;
    integer    fd, rc;
    integer    v_op, v_soff, v_doff, v_w, v_h, v_ss, v_ds;
    reg [31:0] v_color;
    integer    vec_idx = 0;
    integer    guard = 0;

    // OP_ALPHA vector stimulus
    integer    v_profile, v_ga, v_ck_en;
    reg [31:0] v_ck_val;
    integer    n_alpha = 0;

    localparam [63:0] FNV_OFF = 64'hcbf29ce484222325;
    localparam [63:0] FNV_PRM = 64'h00000100000001b3;

    integer i;
    integer idx, ly, lx, da, sa, exp_bytes, got_bytes;
    reg [7:0] exp_b;
    reg [63:0] hash;

    integer n_read;

    task run_vector;
        begin
            for (idx = 0; idx < MEMSZ; idx = idx + 1) begin
                src_snap[idx] = src_mem[idx];
                dst_mem[idx]  = 8'h00;
                written[idx]  = 1'b0;
            end
            bytes_written = 0;
            stray_writes  = 0;

            if (v_op == 1) begin
                apb_write(16'h18, 32'd1);                       // OP_COPY
                apb_write(16'h1C, SRC_BASE + v_soff);
                apb_write(16'h30, v_ss);
            end else begin
                apb_write(16'h18, 32'd0);                       // OP_FILL
                apb_write(16'h10, v_color);
            end
            apb_write(16'h04, DST_BASE + v_doff);
            apb_write(16'h08, v_w);
            apb_write(16'h0C, v_h);
            apb_write(16'h48, v_ds);
            apb_write(16'h14, 32'd1);                           // START

            apb_read(16'h00, status);
            if (status[2] || status[3])
                $fatal(1, "vector %0d rejected, status=%h", vec_idx, status);
            guard = 0;
            while (!status[1] && guard < 500000) begin
                apb_read(16'h00, status);
                guard = guard + 1;
            end
            if (!status[1]) begin
                $display("COPY timeout diagnostic: row=%0d rows_done=%0d reserved=%0d writes_done=%0d pending=%0d rd_left=%0d wr_left=%0d",
                    dut.u_stride_gen.row_idx, dut.u_stride_gen.rows_done,
                    dut.u_stride_gen.rd_reserved, dut.u_stride_gen.wr_done_cnt,
                    dut.u_stride_gen.rd_pending, dut.u_stride_gen.rd_left,
                    dut.u_stride_gen.wr_left);
                $fatal(1, "vector %0d: DONE timeout", vec_idx);
            end
            if (status[2] || status[3])
                $fatal(1, "vector %0d: error bits set, status=%h", vec_idx, status);
            repeat (20) @(negedge clk);

            hash = FNV_OFF;
            exp_bytes = 0;
            for (ly = 0; ly < v_h; ly = ly + 1) begin
                for (lx = 0; lx < v_w * 4; lx = lx + 1) begin
                    da = v_doff + ly*v_ds + lx;
                    sa = v_soff + ly*v_ss + lx;
                    exp_b = (v_op == 1) ? src_snap[sa] : v_color[((lx % 4) * 8) +: 8];
                    if (dst_mem[da] !== exp_b)
                        $fatal(1, "v%0d (so=%0d do=%0d w=%0d h=%0d ss=%0d ds=%0d) byte %0d got %02h exp %02h",
                               vec_idx, v_soff, v_doff, v_w, v_h, v_ss, v_ds, da, dst_mem[da], exp_b);
                    hash = (hash ^ {56'd0, exp_b}) * FNV_PRM;
                    exp_bytes = exp_bytes + 1;
                end
            end
            got_bytes = bytes_written;
            if (got_bytes != exp_bytes)
                $fatal(1, "vector %0d: wrote %0d bytes, expected %0d (dupes=%0d)",
                       vec_idx, got_bytes, exp_bytes, stray_writes);
            $display("VEC %0d ok op=%0d soff=%0d doff=%0d w=%0d h=%0d ss=%0d ds=%0d hash=%016h",
                     vec_idx, v_op, v_soff, v_doff, v_w, v_h, v_ss, v_ds, hash);
            vec_idx = vec_idx + 1;
        end
    endtask

    task run_colorkey_vector;
        reg [31:0] pix;
        integer opaque_pixels;
        begin
            v_soff = 4; v_doff = 12; v_w = 37; v_h = 3;
            v_ss = 4096; v_ds = 4096;
            bytes_written = 0;
            stray_writes = 0;
            opaque_pixels = 0;
            for (idx = 0; idx < MEMSZ; idx = idx + 1) begin
                dst_mem[idx] = 8'h5A;
                written[idx] = 1'b0;
            end
            for (ly = 0; ly < v_h; ly = ly + 1) begin
                for (lx = 0; lx < v_w; lx = lx + 1) begin
                    pix = (((lx + ly) % 3) == 0)
                          ? 32'h00FF00FF : (32'h00300000 | (ly << 8) | lx);
                    sa = v_soff + ly*v_ss + lx*4;
                    src_mem[sa+0] = pix[7:0];
                    src_mem[sa+1] = pix[15:8];
                    src_mem[sa+2] = pix[23:16];
                    src_mem[sa+3] = pix[31:24];
                    if (pix != 32'h00FF00FF) opaque_pixels = opaque_pixels + 1;
                end
            end

            apb_write(16'h18, 32'd1);
            apb_write(16'h1C, SRC_BASE + v_soff);
            apb_write(16'h04, DST_BASE + v_doff);
            apb_write(16'h08, v_w);
            apb_write(16'h0C, v_h);
            apb_write(16'h30, v_ss);
            apb_write(16'h48, v_ds);
            apb_write(16'h60, 32'h00FF00FF);
            apb_write(16'h64, 32'd1);
            apb_write(16'h14, 32'd1);
            guard = 0;
            status = 0;
            while (!status[1] && guard < 500000) begin
                apb_read(16'h00, status);
                guard = guard + 1;
            end
            if (!status[1] || status[2] || status[3])
                $fatal(1, "Color Key command failed status=%h", status);
            repeat (20) @(negedge clk);

            for (ly = 0; ly < v_h; ly = ly + 1) begin
                for (lx = 0; lx < v_w; lx = lx + 1) begin
                    sa = v_soff + ly*v_ss + lx*4;
                    da = v_doff + ly*v_ds + lx*4;
                    pix = {src_mem[sa+3], src_mem[sa+2], src_mem[sa+1], src_mem[sa+0]};
                    for (int k = 0; k < 4; k = k + 1) begin
                        if (pix == 32'h00FF00FF) begin
                            if (dst_mem[da+k] !== 8'h5A || written[da+k])
                                $fatal(1, "Color Key pixel wrote byte row=%0d x=%0d lane=%0d", ly, lx, k);
                        end else if (dst_mem[da+k] !== src_mem[sa+k] || !written[da+k]) begin
                            $fatal(1, "opaque pixel mismatch row=%0d x=%0d lane=%0d", ly, lx, k);
                        end
                    end
                end
            end
            if (bytes_written != opaque_pixels * 4 || stray_writes != 0)
                $fatal(1, "Color Key byte count got=%0d expected=%0d dupes=%0d",
                       bytes_written, opaque_pixels*4, stray_writes);
            apb_write(16'h64, 32'd0);
            $display("COLORKEY ok: %0d opaque pixels, %0d transparent pixels",
                     opaque_pixels, v_w*v_h-opaque_pixels);
        end
    endtask

    // =====================================================================
    // OP_ALPHA (hardware alpha blending) vectors
    // ---------------------------------------------------------------------
    // Stimulus line: profile soff doff w h ss ds global_alpha ck_en ck_val
    //
    //   profile 0 : pseudo random alpha and colour
    //   profile 1 : alpha swept over {0,255,1,127,128,254}, random colour
    //   profile 2 : alpha swept, colour channels swept over {0,255,1,254}
    //   profile 3 : every third pixel is exactly the colour key
    //
    // The destination background is a deterministic byte pattern, snapshotted
    // before the command: the reference result is blended from the SNAPSHOT, so
    // an engine that read back its own writes would fail.
    // =====================================================================
    function [7:0] fdiv255;
        input [17:0] n;
        reg   [17:0] t;
        begin t = n + 18'd1 + {10'd0, n[17:8]}; fdiv255 = t[15:8]; end
    endfunction

    function [7:0] fscale_a;
        input [7:0] a;
        input [7:0] g;
        begin fscale_a = fdiv255(({10'd0, a} * {10'd0, g}) + 18'd127); end
    endfunction

    function [7:0] fblend;
        input [7:0] s;
        input [7:0] d;
        input [7:0] a;
        reg signed [8:0]  dif;
        reg signed [17:0] prd;
        reg        [17:0] bas, num;
        begin
            dif = $signed({1'b0, s}) - $signed({1'b0, d});
            prd = dif * $signed({1'b0, a});
            bas = ({10'd0, d} * 18'd255) + 18'd127;
            num = prd[17:0] + bas;
            fblend = fdiv255(num);
        end
    endfunction

    function [7:0] aseq;                       // alpha boundary sweep
        input integer i;
        begin
            case (i % 6)
                0: aseq = 8'd0;   1: aseq = 8'd255; 2: aseq = 8'd1;
                3: aseq = 8'd127; 4: aseq = 8'd128; 5: aseq = 8'd254;
                default: aseq = 8'd0;
            endcase
        end
    endfunction

    function [7:0] cseq;                       // colour boundary sweep
        input integer i;
        begin
            case (i % 4)
                0: cseq = 8'd0; 1: cseq = 8'd255; 2: cseq = 8'd1; 3: cseq = 8'd254;
                default: cseq = 8'd0;
            endcase
        end
    endfunction

    function [31:0] alpha_src_pixel;
        input integer x;
        input integer y;
        reg [7:0] a, r, g, b;
        begin
            a = ((17*x + 29*y + 71) & 255);
            r = ((53*x + 97*y + 13) & 255);
            g = ((11*x + 41*y + 199) & 255);
            b = ((131*x + 7*y + 3) & 255);
            if (v_profile == 1) begin
                a = aseq(x + y);
            end else if (v_profile == 2) begin
                a = aseq(x + y);
                r = cseq(x);
                g = cseq(x + y + 1);
                b = cseq(x + 2*y + 2);
            end else if (v_profile == 3) begin
                a = aseq(x + y);
                if (((x + y) % 3) == 0) begin
                    a = v_ck_val[31:24];
                    r = v_ck_val[23:16];
                    g = v_ck_val[15:8];
                    b = v_ck_val[7:0];
                end
            end
            alpha_src_pixel = {a, r, g, b};
        end
    endfunction

    // A byte inside any row rectangle of the command is legitimately written by
    // that row.  With a tight stride the last beat of one row and the first beat
    // of the next can share the same 16-byte beat, so the head/tail masking
    // check below must not treat those bytes as stray.
    function alpha_byte_in_rect;
        input integer b;
        integer yy;
        begin
            alpha_byte_in_rect = 0;
            for (yy = 0; yy < v_h; yy = yy + 1)
                if (b >= v_doff + yy*v_ds && b < v_doff + yy*v_ds + 4*v_w)
                    alpha_byte_in_rect = 1;
        end
    endfunction

    task run_alpha_vector;
        integer   ck_pixels, exp_written, k, b;
        reg [31:0] spix;
        reg [7:0]  ae, exp_b;
        begin
            ck_pixels = 0;

            // ---- deterministic background, snapshotted ----
            for (idx = 0; idx < MEMSZ; idx = idx + 1) begin
                dst_mem[idx]  = ((idx * 29) ^ (idx >> 4) ^ 8'h5A) & 8'hFF;
                dst_snap[idx] = dst_mem[idx];
                written[idx]  = 1'b0;
            end
            bytes_written = 0;
            stray_writes  = 0;

            // ---- source sprite ----
            for (ly = 0; ly < v_h; ly = ly + 1) begin
                for (lx = 0; lx < v_w; lx = lx + 1) begin
                    spix = alpha_src_pixel(lx, ly);
                    sa   = v_soff + ly*v_ss + lx*4;
                    src_mem[sa+0] = spix[7:0];
                    src_mem[sa+1] = spix[15:8];
                    src_mem[sa+2] = spix[23:16];
                    src_mem[sa+3] = spix[31:24];
                    if (v_ck_en && (spix == v_ck_val)) ck_pixels = ck_pixels + 1;
                end
            end

            // ---- command ----
            apb_write(16'h18, 32'd2);                    // OP_ALPHA
            apb_write(16'h68, 32'd1);                    // ALPHA_CTRL enable
            apb_write(16'h6C, v_ga);
            apb_write(16'h60, v_ck_val);
            apb_write(16'h64, v_ck_en);
            apb_write(16'h1C, SRC_BASE + v_soff);
            apb_write(16'h04, DST_BASE + v_doff);
            apb_write(16'h08, v_w);
            apb_write(16'h0C, v_h);
            apb_write(16'h30, v_ss);
            apb_write(16'h48, v_ds);
            apb_write(16'h14, 32'd1);                    // START

            apb_read(16'h00, status);
            guard = 0;
            while (!status[1] && guard < 2000000) begin
                apb_read(16'h00, status);
                guard = guard + 1;
            end
            if (!status[1]) $fatal(1, "alpha v%0d: DONE timeout", vec_idx);
            if (status[2] || status[3])
                $fatal(1, "alpha v%0d: error bits set, status=%h", vec_idx, status);
            repeat (20) @(negedge clk);

            // ---- head / tail bytes of the first and last beat must stay put
            //      unless another row of the same command owns them ----
            for (ly = 0; ly < v_h; ly = ly + 1) begin
                integer row_start, row_end;
                row_start = v_doff + ly*v_ds;
                row_end   = row_start + 4*v_w;
                for (b = (row_start & ~15); b < row_start; b = b + 1)
                    if (!alpha_byte_in_rect(b) &&
                        (dst_mem[b] !== dst_snap[b] || written[b]))
                        $fatal(1, "alpha v%0d: head byte %0d was written", vec_idx, b);
                for (b = row_end; b < ((row_end + 15) & ~15); b = b + 1)
                    if (b < MEMSZ && !alpha_byte_in_rect(b) &&
                        (dst_mem[b] !== dst_snap[b] || written[b]))
                        $fatal(1, "alpha v%0d: tail byte %0d was written", vec_idx, b);
            end

            // ---- per pixel reference check ----
            hash = FNV_OFF;
            for (ly = 0; ly < v_h; ly = ly + 1) begin
                for (lx = 0; lx < v_w; lx = lx + 1) begin
                    sa   = v_soff + ly*v_ss + lx*4;
                    da   = v_doff + ly*v_ds + lx*4;
                    spix = {src_mem[sa+3], src_mem[sa+2], src_mem[sa+1], src_mem[sa+0]};
                    if (v_ck_en && (spix == v_ck_val)) begin
                        for (k = 0; k < 4; k = k + 1)
                            if (dst_mem[da+k] !== dst_snap[da+k] || written[da+k])
                                $fatal(1, "alpha v%0d: colour-keyed pixel written row=%0d x=%0d lane=%0d",
                                       vec_idx, ly, lx, k);
                    end else begin
                        ae = fscale_a(spix[31:24], v_ga[7:0]);
                        for (k = 0; k < 4; k = k + 1) begin
                            exp_b = (k == 3) ? dst_snap[da+3]
                                             : fblend(src_mem[sa+k], dst_snap[da+k], ae);
                            if (dst_mem[da+k] !== exp_b)
                                $fatal(1, "alpha v%0d (p=%0d so=%0d do=%0d w=%0d h=%0d ss=%0d ds=%0d ga=%0d ck=%0d) byte %0d got %02h exp %02h",
                                       vec_idx, v_profile, v_soff, v_doff, v_w, v_h, v_ss, v_ds,
                                       v_ga, v_ck_en, da+k, dst_mem[da+k], exp_b);
                            if (!written[da+k])
                                $fatal(1, "alpha v%0d: byte %0d missing", vec_idx, da+k);
                        end
                    end
                    for (k = 0; k < 4; k = k + 1)
                        hash = (hash ^ {56'd0, dst_mem[da+k]}) * FNV_PRM;
                end
            end

            exp_written = 4 * (v_w*v_h - ck_pixels);
            if (bytes_written != exp_written || stray_writes != 0)
                $fatal(1, "alpha v%0d: wrote %0d bytes, expected %0d (dupes=%0d)",
                       vec_idx, bytes_written, exp_written, stray_writes);

            $display("AVEC %0d ok p=%0d soff=%0d doff=%0d w=%0d h=%0d ss=%0d ds=%0d ga=%0d ck=%0d key=%08h hash=%016h",
                     n_alpha, v_profile, v_soff, v_doff, v_w, v_h, v_ss, v_ds,
                     v_ga, v_ck_en, v_ck_val, hash);
            n_alpha = n_alpha + 1;
            vec_idx = vec_idx + 1;
        end
    endtask

    task expect_cfg_error(input [1:0] op, input [10:0] w, input [10:0] h,
                          input [15:0] ss, input [15:0] ds);
        begin
            apb_write(16'h18, op);
            apb_write(16'h08, w);
            apb_write(16'h0C, h);
            apb_write(16'h30, ss);
            apb_write(16'h48, ds);
            apb_write(16'h14, 32'd1);
            apb_read(16'h00, status);
            if (status[0] || !status[1] || !status[2] || status[3])
                $fatal(1, "bad command was not rejected cleanly: op=%0d w=%0d h=%0d ss=%0d ds=%0d status=%h",
                       op, w, h, ss, ds, status);
            repeat (4) @(negedge clk);
            if (arvalid || awvalid || wvalid)
                $fatal(1, "rejected command touched AXI");
        end
    endtask

    initial begin
        for (i = 0; i < MEMSZ; i = i + 1)
            src_mem[i] = ((i * 37) ^ (i >> 5) ^ 8'hA5) & 8'hFF;

        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (5) @(negedge clk);

`ifdef BITBLT_LARGE_TEST
        // Previously the 64 KiB model limited the height sweep to 17 rows.
        // Full surfaces expose per-row look-ahead credit leakage.
        v_op=1; v_soff=0; v_doff=0; v_w=1024; v_h=124;
        v_ss=4096; v_ds=4096; v_color=0; run_vector();
        v_h=125; run_vector();
        v_h=600; run_vector();
        // Independent strides, unaligned row heads and the actual pause size.
        v_soff=4; v_doff=12; v_w=512; v_h=352;
        v_ss=2048; v_ds=4096; run_vector();
        // Alpha shares the source look-ahead stream; background credits must
        // NOT subtract rows, because that stream has no extra beat per row.
        v_profile=3; v_ga=137; v_ck_en=1; v_ck_val=32'h00FF00FF;
        v_soff=4; v_doff=12; v_w=512; v_h=352;
        v_ss=2064; v_ds=4096; run_alpha_vector();
        $display("PASS BitBlt LARGE: 124 / 125 / 600 rows, pause COPY and ALPHA+ColorKey, MAX_BURST=%0d",MAXB);
        $finish;
`endif

        fd = $fopen("../../tests/bitblt_copy_vectors.txt", "r");
        if (fd == 0) $fatal(1, "cannot open vector file");

        rc = $fscanf(fd, "%d %d %d %d %d %d %d %h",
                     v_op, v_soff, v_doff, v_w, v_h, v_ss, v_ds, v_color);
        while (rc == 8) begin
            run_vector();
            rc = $fscanf(fd, "%d %d %d %d %d %d %d %h",
                         v_op, v_soff, v_doff, v_w, v_h, v_ss, v_ds, v_color);
        end
        $fclose(fd);

        run_colorkey_vector();

        // ---------------- OP_ALPHA vectors ----------------
        fd = $fopen("../../tests/bitblt_alpha_vectors.txt", "r");
        if (fd == 0) $fatal(1, "cannot open alpha vector file");
        rc = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %h",
                     v_profile, v_soff, v_doff, v_w, v_h, v_ss, v_ds, v_ga,
                     v_ck_en, v_ck_val);
        while (rc == 10) begin
            run_alpha_vector();
            rc = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %h",
                         v_profile, v_soff, v_doff, v_w, v_h, v_ss, v_ds, v_ga,
                         v_ck_en, v_ck_val);
        end
        $fclose(fd);

        // APB guard rails: an illegal command, dimensions that exceed the
        // 1024x600 surface, and non-beat-aligned strides must complete with
        // CFGERR and must not issue an AXI transaction.
        // OP_ADD (2'd3) was the 'unknown opcode' here until Phase 2 made it
        // a legal command; the illegal-opcode rail moved to OP_ALPHA with
        // ALPHA_CTRL[0] clear, which is what 'no blending enabled' means.
        apb_write(16'h68, 32'd0);
        expect_cfg_error(2'd2, 11'd16,   11'd16, 16'd64,   16'd4096);
        apb_write(16'h68, 32'd1);
        expect_cfg_error(2'd0, 11'd1367, 11'd16, 16'd4096, 16'd4096);
        expect_cfg_error(2'd0, 11'd16,   11'd769,16'd4096, 16'd4096);
        expect_cfg_error(2'd1, 11'd16,   11'd16, 16'd4095, 16'd4096);
        apb_write(16'h60, 32'h00FF00FF);
        apb_write(16'h64, 32'd1);
        apb_write(16'h1C, SRC_BASE + 1);
        apb_write(16'h04, DST_BASE);
        expect_cfg_error(2'd1, 11'd16, 11'd16, 16'd4096, 16'd4096);
        apb_write(16'h64, 32'd0);

        // OP_ALPHA guard rails: blending disabled, and addresses that are not
        // on a 32-bit pixel boundary (the per-pixel strobe mask needs whole
        // pixels).  Neither may touch AXI.
        apb_write(16'h68, 32'd0);
        apb_write(16'h1C, SRC_BASE);
        apb_write(16'h04, DST_BASE);
        expect_cfg_error(2'd2, 11'd16, 11'd16, 16'd4096, 16'd4096);
        apb_write(16'h68, 32'd1);
        apb_write(16'h1C, SRC_BASE + 2);
        expect_cfg_error(2'd2, 11'd16, 11'd16, 16'd4096, 16'd4096);
        apb_write(16'h1C, SRC_BASE);
        apb_write(16'h04, DST_BASE + 2);
        expect_cfg_error(2'd2, 11'd16, 11'd16, 16'd4096, 16'd4096);
        apb_write(16'h68, 32'd0);

        $display("PASS BitBlt COPY: %0d vectors, longest AR=%0d beats, longest AW=%0d beats, MAX_BURST=%0d",
                 vec_idx - n_alpha, max_ar_len_seen, max_aw_len_seen, MAXB);
        $display("PASS BitBlt ALPHA: %0d vectors, longest AR=%0d beats, longest AW=%0d beats, MAX_BURST=%0d",
                 n_alpha, max_ar_len_seen, max_aw_len_seen, MAXB);
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "global timeout after %0d vectors", vec_idx);
    end

endmodule
