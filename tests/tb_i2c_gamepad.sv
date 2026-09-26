`timescale 1ns/1ps

module tb_i2c_gamepad;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg key_sw0_in = 1'b1;
    reg key_sw2_in = 1'b1;

    wire i2c_scl_out;
    wire i2c_scl_oe;
    wire i2c_sda_out;
    wire i2c_sda_oe;
    wire sw0_pressed;
    wire sw2_pressed;
    wire sw0_pulse;
    wire sw2_pulse;
    wire [7:0] joy_x;
    wire [7:0] joy_y;
    wire [4:0] buttons;
    wire gamepad_online;

    // A minimal open-drain slave model.  Pulling SDA low acknowledges every
    // transfer and returns 8'h00; releasing it makes the address phase NACK.
    reg slave_pull_sda_low = 1'b1;
    wire i2c_scl_in = i2c_scl_oe ? 1'b0 : 1'b1;
    wire i2c_sda_in = (i2c_sda_oe || slave_pull_sda_low) ? 1'b0 : 1'b1;

    i2c_gamepad_top #(
        .CLK_FREQ_HZ(1_000_000),
        .I2C_FREQ_HZ(100_000)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .key_sw0_in(key_sw0_in),
        .key_sw2_in(key_sw2_in),
        .i2c_scl_in(i2c_scl_in),
        .i2c_scl_out(i2c_scl_out),
        .i2c_scl_oe(i2c_scl_oe),
        .i2c_sda_in(i2c_sda_in),
        .i2c_sda_out(i2c_sda_out),
        .i2c_sda_oe(i2c_sda_oe),
        .i2c_slave_addr(7'h5A),
        .sw0_pressed(sw0_pressed),
        .sw2_pressed(sw2_pressed),
        .sw0_pulse(sw0_pulse),
        .sw2_pulse(sw2_pulse),
        .joy_x(joy_x),
        .joy_y(joy_y),
        .buttons(buttons),
        .gamepad_online(gamepad_online)
    );

    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1'b1;

        // The reset-pending request must launch without waiting 20 ms.  Before
        // the fix, the one-cycle poll_timer pulse never coincided with scl_tick
        // and this timeout fired with the bus permanently idle.
        fork
            begin
                wait (gamepad_online === 1'b1);
            end
            begin
                repeat (5000) @(posedge clk);
                $fatal(1, "initial I2C poll never completed");
            end
        join_any
        disable fork;

        if (joy_x !== 8'h00 || joy_y !== 8'h00 || buttons !== 5'h1F)
            $fatal(1, "unexpected latched data x=%02h y=%02h buttons=%02h",
                   joy_x, joy_y, buttons);

        // Disconnect the slave.  A write-address NACK must clear online rather
        // than leaving a stale success flag from the preceding poll.
        slave_pull_sda_low = 1'b0;
        fork
            begin
                wait (gamepad_online === 1'b0);
            end
            begin
                repeat (25000) @(posedge clk);
                $fatal(1, "address NACK did not clear gamepad_online");
            end
        join_any
        disable fork;

        $display("PASS I2C gamepad RTL: 7-register poll (incl. OK), reset poll, NACK clears online");
        $finish;
    end
endmodule

