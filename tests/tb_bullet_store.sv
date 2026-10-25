`timescale 1ns/1ps
// =============================================================================
// tb_bullet_store -- the tile store's write port, through the APB.
//
// WHY THIS BENCH EXISTS.  The first cut of the store's APB port advanced the
// write pointer in the same clock that latched the data and the strobe.  All
// three are registers, so they took effect together on the NEXT clock - which
// meant the store was handed address A+1 while the firmware meant A, and the
// whole 30 KB shifted right by one byte.  Address 0 stayed zero, every tile lost
// its first column, and the board came up with a screenful of torn bullet tiles.
//
// tests/tb_bullet_overlay.sv could not see it: that bench drives the store
// through bitblt_top's parallel port, downstream of the bug.  A bench that only
// looks at the far end of a pipe cannot tell a shifted pipe from a clean one, so
// this one drives the APB itself and watches the cells.
//
// Run:  tools\sim_bullet_store.ps1
// =============================================================================
module tb_bullet_store;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;

    reg  [15:0] paddr = 16'd0;
    reg         psel = 1'b0, penable = 1'b0, pwrite = 1'b0;
    reg  [31:0] pwdata = 32'd0;
    wire [31:0] prdata;

    wire        btile_we, bpal_we;
    wire [13:0] btile_addr;
    wire [7:0]  btile_data, bpal_addr;
    wire [31:0] bpal_data;

    bitblt_apb_regs dut (
        .clk(clk), .rst_n(rst_n),
        .apb_paddr(paddr), .apb_psel(psel), .apb_penable(penable),
        .apb_pwrite(pwrite), .apb_pwdata(pwdata), .apb_prdata(prdata),
        .btile_we(btile_we), .btile_addr(btile_addr), .btile_data(btile_data),
        .bpal_we(bpal_we), .bpal_addr(bpal_addr), .bpal_data(bpal_data)
    );

    // What the scanout's store would do with what the port offers it.
    reg [7:0]  store [0:16383];
    reg [31:0] pal   [0:255];
    integer i;
    always @(posedge clk) begin
        if (btile_we) store[btile_addr] <= btile_data;
        if (bpal_we)  pal[bpal_addr]    <= bpal_data;
    end

    task apb_write(input [7:0] a, input [31:0] d);
        begin
            @(posedge clk);
            paddr = {8'd0, a}; pwdata = d; psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
            @(posedge clk);
            penable = 1'b1;
            @(posedge clk);
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
        end
    endtask

    integer checks = 0;
    integer fails  = 0;
    integer n;
    reg [7:0]  want8;
    reg [23:0] want24;

    initial begin
        for (i = 0; i < 32768; i = i + 1) store[i] = 8'hEE;
        for (i = 0; i < 256;   i = i + 1) pal[i]   = 24'hEEEEEE;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- the tile store --------------------------------------------
        for (n = 0; n < 512; n = n + 1)
            apb_write(8'hF8, (n ^ 8'hA5) & 8'hFF);
        repeat (4) @(posedge clk);

        for (n = 0; n < 512; n = n + 1) begin
            want8 = (n ^ 8'hA5) & 8'hFF;
            checks = checks + 1;
            if (store[n] !== want8) begin
                fails = fails + 1;
                if (fails <= 8)
                    $display("  FAIL store[%0d] = %02x, firmware wrote %02x",
                             n, store[n], want8);
            end
        end
        checks = checks + 1;
        if (store[512] !== 8'hEE) begin
            fails = fails + 1;
            $display("  FAIL store[512] was written: %02x (nothing addressed it)",
                     store[512]);
        end

        // ---- and the palette ------------------------------------------
        for (n = 0; n < 64; n = n + 1)
            apb_write(8'hFC, {8'h00, n[7:0], n[7:0] + 8'h01});
        repeat (4) @(posedge clk);

        for (n = 0; n < 64; n = n + 1) begin
            want24 = {8'h00, n[7:0], n[7:0] + 8'h01};
            checks = checks + 1;
            if (pal[n] !== want24) begin
                fails = fails + 1;
                if (fails <= 12)
                    $display("  FAIL pal[%0d] = %06x, firmware wrote %06x",
                             n, pal[n], want24);
            end
        end
        checks = checks + 1;
        if (pal[64] !== 24'hEEEEEE) begin
            fails = fails + 1;
            $display("  FAIL pal[64] was written: %06x", pal[64]);
        end

        $display("");
        $display("CHECKED %0d  FAILED %0d", checks, fails);
        if (fails == 0)
            $display("PASS tb_bullet_store RTL: every byte lands in the cell the firmware addressed");
        else
            $display("FAIL tb_bullet_store RTL: %0d cells wrong", fails);
        $finish(fails ? 1 : 0);
    end
endmodule