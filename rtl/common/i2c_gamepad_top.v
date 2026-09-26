// rtl/common/i2c_gamepad_top.v
// Autonomous I2C Gamepad Master for Mini-Joystick (0x5A) & Dual Board Key Debouncer
`timescale 1ns/1ps

module i2c_gamepad_top #(
    parameter CLK_FREQ_HZ = 100_000_000,
    parameter I2C_FREQ_HZ = 100_000
)(
    input  wire        clk,
    input  wire        rst_n,

    // Board Pushbutton Inputs (Active-low from physical buttons)
    input  wire        key_sw0_in,      // SW0 (KEY0, C4, Bank TL, 3.3V)
    input  wire        key_sw2_in,      // SW2 (KEY2, N14, Bank BR, 3.3V)

    // I2C Open-Drain Physical Pins (40-Pin Header: Pin 37 SCL, Pin 39 SDA)
    input  wire        i2c_scl_in,
    output wire        i2c_scl_out,
    output reg         i2c_scl_oe,      // 1: Drive low (0), 0: High-Z (release for pullup)
    input  wire        i2c_sda_in,
    output wire        i2c_sda_out,
    output reg         i2c_sda_oe,      // 1: Drive low (0), 0: High-Z (release for pullup)

    // Configuration from APB Registers
    input  wire [6:0]  i2c_slave_addr,  // Default 7'h5A (Mini-Joystick)

    // Debounced Button Outputs (Active-high: 1 = pressed)
    output wire        sw0_pressed,
    output wire        sw2_pressed,
    output reg         sw0_pulse,
    output reg         sw2_pulse,

    // Latched Gamepad Readouts
    output reg  [7:0]  joy_x,           // 0..255, center ~128
    output reg  [7:0]  joy_y,           // 0..255, center ~128
    output reg  [4:0]  buttons,         // [0]=A [1]=B [2]=X(C) [3]=Y(D) [4]=OK (1 = pressed)
    output reg         gamepad_online   // 1: I2C ACK received and communicating
);

    // Open-drain outputs: drive 0 when OE=1, float when OE=0
    assign i2c_scl_out = 1'b0;
    assign i2c_sda_out = 1'b0;

    // =========================================================================
    // 1. Board Keys 10ms Debouncing & Pulse Generation
    // =========================================================================
    localparam DEBOUNCE_CYCLES = CLK_FREQ_HZ / 100; // 10ms @ 100MHz = 1,000,000 ticks

    reg [1:0] sw0_sync, sw2_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw0_sync <= 2'b11;
            sw2_sync <= 2'b11;
        end else begin
            sw0_sync <= {sw0_sync[0], key_sw0_in};
            sw2_sync <= {sw2_sync[0], key_sw2_in};
        end
    end

    reg [19:0] cnt_sw0, cnt_sw2;
    reg sw0_state, sw2_state;
    reg sw0_state_d, sw2_state_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_sw0    <= 20'd0;
            sw0_state  <= 1'b1;
            cnt_sw2    <= 20'd0;
            sw2_state  <= 1'b1;
            sw0_state_d<= 1'b1;
            sw2_state_d<= 1'b1;
            sw0_pulse  <= 1'b0;
            sw2_pulse  <= 1'b0;
        end else begin
            if (sw0_sync[1] != sw0_state) begin
                if (cnt_sw0 >= DEBOUNCE_CYCLES) begin
                    sw0_state <= sw0_sync[1];
                    cnt_sw0   <= 20'd0;
                end else begin
                    cnt_sw0   <= cnt_sw0 + 20'd1;
                end
            end else begin
                cnt_sw0 <= 20'd0;
            end

            if (sw2_sync[1] != sw2_state) begin
                if (cnt_sw2 >= DEBOUNCE_CYCLES) begin
                    sw2_state <= sw2_sync[1];
                    cnt_sw2   <= 20'd0;
                end else begin
                    cnt_sw2   <= cnt_sw2 + 20'd1;
                end
            end else begin
                cnt_sw2 <= 20'd0;
            end

            sw0_state_d <= sw0_state;
            sw2_state_d <= sw2_state;
            sw0_pulse   <= (sw0_state_d == 1'b1 && sw0_state == 1'b0);
            sw2_pulse   <= (sw2_state_d == 1'b1 && sw2_state == 1'b0);
        end
    end

    assign sw0_pressed = ~sw0_state;
    assign sw2_pressed = ~sw2_state;

    // =========================================================================
    // 2. Input Metastability Synchronizers for SCL & SDA
    // =========================================================================
    reg [2:0] scl_sync, sda_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_sync <= 3'b111;
            sda_sync <= 3'b111;
        end else begin
            scl_sync <= {scl_sync[1:0], i2c_scl_in};
            sda_sync <= {sda_sync[1:0], i2c_sda_in};
        end
    end
    wire scl_filtered = scl_sync[2];
    wire sda_filtered = sda_sync[2];

    // =========================================================================
    // 3. Autonomous I2C Polling State Machine for Mini-Joystick (Addr 0x5A)
    //    Sequence per polling period (50Hz / 20ms):
    //      Step 0: Read Reg 0x10 -> joy_x (0..255)
    //      Step 1: Read Reg 0x11 -> joy_y (0..255)
    //      Step 2: Read Reg 0x22 -> btn_a (0..6=pressed, 8=unpressed)
    //      Step 3: Read Reg 0x23 -> btn_b (0..6=pressed, 8=unpressed)
    //      Step 4: Read Reg 0x21 -> btn_x/C (0..6=pressed, 8=unpressed)
    //      Step 5: Read Reg 0x24 -> btn_y/D (0..6=pressed, 8=unpressed)
    //      Step 6: Read Reg 0x20 -> btn_ok  (joystick centre press)
    // =========================================================================
    localparam SCL_HALF    = CLK_FREQ_HZ / (I2C_FREQ_HZ * 2); // 500 clock ticks @ 100kHz
    localparam POLL_PERIOD = CLK_FREQ_HZ / 50;                // 20ms poll interval (50Hz)

    reg [23:0] poll_timer;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            poll_timer <= 24'd0;
        else if (poll_timer >= POLL_PERIOD - 1)
            poll_timer <= 24'd0;
        else
            poll_timer <= poll_timer + 24'd1;
    end

    reg [15:0] scl_cnt;
    wire scl_tick = (scl_cnt >= SCL_HALF - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            scl_cnt <= 16'd0;
        else if (scl_cnt >= SCL_HALF - 1)
            scl_cnt <= 16'd0;
        else
            scl_cnt <= scl_cnt + 16'd1;
    end

    // FSM States
    localparam ST_IDLE    = 4'd0;
    localparam ST_W_START = 4'd1;
    localparam ST_W_ADDR  = 4'd2;
    localparam ST_W_REG   = 4'd3;
    localparam ST_W_STOP  = 4'd4;
    localparam ST_R_START = 4'd5;
    localparam ST_R_ADDR  = 4'd6;
    localparam ST_R_DATA  = 4'd7;
    localparam ST_R_STOP  = 4'd8;

    reg [3:0] main_state;
    reg [4:0] sub;
    reg [2:0] reg_step;
    reg [7:0] tx_data;
    reg [7:0] rx_data;
    reg       err_flag;

    reg [7:0] tmp_joy_x;
    reg [7:0] tmp_joy_y;
    reg [7:0] tmp_btn_a_val;
    reg [7:0] tmp_btn_b_val;
    reg [7:0] tmp_btn_x_val;
    reg [7:0] tmp_btn_y_val;
    reg [7:0] tmp_btn_ok_val;

    // poll_timer wraps for only one core-clock cycle, while the I2C FSM advances
    // only on scl_tick.  Latch the request so the FSM cannot miss that pulse.
    // Start with one request pending to perform the first read immediately after
    // reset instead of waiting a full polling period.
    reg poll_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            poll_pending <= 1'b1;
        end else begin
            if (poll_timer >= POLL_PERIOD - 1)
                poll_pending <= 1'b1;
            else if (scl_tick && main_state == ST_IDLE && poll_pending)
                poll_pending <= 1'b0;
        end
    end

    reg [7:0] cur_reg_addr;
    always @(*) begin
        case (reg_step)
            3'd0: cur_reg_addr = 8'h10; // Left Joy X
            3'd1: cur_reg_addr = 8'h11; // Left Joy Y
            3'd2: cur_reg_addr = 8'h22; // Button A
            3'd3: cur_reg_addr = 8'h23; // Button B
            3'd4: cur_reg_addr = 8'h21; // Button C (mapped to X)
            3'd5: cur_reg_addr = 8'h24; // Button D (mapped to Y)
            3'd6: cur_reg_addr = 8'h20; // Button OK (joystick centre press)
            default: cur_reg_addr = 8'h10;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            main_state     <= ST_IDLE;
            sub            <= 5'd0;
            reg_step       <= 3'd0;
            tx_data        <= 8'd0;
            rx_data        <= 8'd0;
            err_flag       <= 1'b0;
            i2c_scl_oe     <= 1'b0;
            i2c_sda_oe     <= 1'b0;
            joy_x          <= 8'd128;
            joy_y          <= 8'd128;
            buttons        <= 4'd0;
            tmp_joy_x      <= 8'd128;
            tmp_joy_y      <= 8'd128;
            tmp_btn_a_val  <= 8'd8;
            tmp_btn_b_val  <= 8'd8;
            tmp_btn_x_val  <= 8'd8;
            tmp_btn_y_val  <= 8'd8;
            tmp_btn_ok_val <= 8'd8;
            gamepad_online <= 1'b0;
        end else if (scl_tick) begin
            case (main_state)
                ST_IDLE: begin
                    i2c_scl_oe <= 1'b0; // Release SCL (High)
                    i2c_sda_oe <= 1'b0; // Release SDA (High)
                    if (poll_pending) begin
                        reg_step   <= 3'd0;
                        err_flag   <= 1'b0;
                        main_state <= ST_W_START;
                        sub        <= 5'd0;
                    end
                end

                // =============================================================
                // PHASE 1: Write Sub-Address (START -> 0xB4 -> RegAddr -> STOP)
                // =============================================================
                ST_W_START: begin
                    if (sub == 5'd0) begin
                        i2c_scl_oe <= 1'b0; // SCL High
                        i2c_sda_oe <= 1'b0; // SDA High
                        sub        <= 5'd1;
                    end else if (sub == 5'd1) begin
                        i2c_scl_oe <= 1'b0; // SCL High
                        i2c_sda_oe <= 1'b1; // SDA Low -> START condition!
                        sub        <= 5'd2;
                    end else begin
                        i2c_scl_oe <= 1'b1; // SCL Low
                        i2c_sda_oe <= 1'b1; // SDA Low
                        tx_data    <= {i2c_slave_addr, 1'b0}; // 0xB4 (Write)
                        main_state <= ST_W_ADDR;
                        sub        <= 5'd0;
                    end
                end

                ST_W_ADDR: begin
                    if (!sub[0] && sub < 5'd16) begin
                        // Even sub: SCL Low, set data bit
                        i2c_scl_oe <= 1'b1;
                        i2c_sda_oe <= ~tx_data[7 - (sub >> 1)];
                        sub        <= sub + 5'd1;
                    end else if (sub[0] && sub < 5'd16) begin
                        // Odd sub: SCL High (slave samples)
                        i2c_scl_oe <= 1'b0;
                        sub        <= sub + 5'd1;
                    end else if (sub == 5'd16) begin
                        // SCL Low, release SDA for slave ACK
                        i2c_scl_oe <= 1'b1;
                        i2c_sda_oe <= 1'b0;
                        sub        <= 5'd17;
                    end else if (sub == 5'd17) begin
                        // SCL High, sample slave ACK
                        i2c_scl_oe <= 1'b0;
                        if (sda_filtered == 1'b0) begin
                            sub <= 5'd18; // ACK received!
                        end else begin
                            err_flag   <= 1'b1; // NACK received!
                            main_state <= ST_W_STOP;
                            sub        <= 5'd0;
                        end
                    end else begin
                        // sub == 18: SCL Low, load register address
                        i2c_scl_oe <= 1'b1;
                        tx_data    <= cur_reg_addr;
                        main_state <= ST_W_REG;
                        sub        <= 5'd0;
                    end
                end

                ST_W_REG: begin
                    if (!sub[0] && sub < 5'd16) begin
                        i2c_scl_oe <= 1'b1;
                        i2c_sda_oe <= ~tx_data[7 - (sub >> 1)];
                        sub        <= sub + 5'd1;
                    end else if (sub[0] && sub < 5'd16) begin
                        i2c_scl_oe <= 1'b0;
                        sub        <= sub + 5'd1;
                    end else if (sub == 5'd16) begin
                        i2c_scl_oe <= 1'b1;
                        i2c_sda_oe <= 1'b0;
                        sub        <= 5'd17;
                    end else if (sub == 5'd17) begin
                        i2c_scl_oe <= 1'b0;
                        if (sda_filtered == 1'b0) begin
                            sub <= 5'd18; // ACK received!
                        end else begin
                            err_flag   <= 1'b1;
                            main_state <= ST_W_STOP;
                            sub        <= 5'd0;
                        end
                    end else begin
                        // sub == 18: SCL Low, prepare STOP
                        i2c_scl_oe <= 1'b1;
                        main_state <= ST_W_STOP;
                        sub        <= 5'd0;
                    end
                end

                ST_W_STOP: begin
                    if (sub == 5'd0) begin
                        i2c_scl_oe <= 1'b1; // SCL Low
                        i2c_sda_oe <= 1'b1; // SDA Low
                        sub        <= 5'd1;
                    end else if (sub == 5'd1) begin
                        i2c_scl_oe <= 1'b0; // SCL High
                        i2c_sda_oe <= 1'b1; // SDA Low
                        sub        <= 5'd2;
                    end else if (sub == 5'd2) begin
                        i2c_scl_oe <= 1'b0; // SCL High
                        i2c_sda_oe <= 1'b0; // SDA High -> STOP condition!
                        sub        <= 5'd3;
                    end else if (sub < 5'd8) begin
                        // Hold bus idle for 5 ticks (~25us) for MCU processing
                        i2c_scl_oe <= 1'b0;
                        i2c_sda_oe <= 1'b0;
                        sub        <= sub + 5'd1;
                    end else begin
                        if (err_flag) begin
                            gamepad_online <= 1'b0;
                            main_state <= ST_IDLE;
                        end else begin
                            main_state <= ST_R_START;
                            sub        <= 5'd0;
                        end
                    end
                end

                // =============================================================
                // PHASE 2: Read Data Byte (START -> 0xB5 -> Read -> NACK -> STOP)
                // =============================================================
                ST_R_START: begin
                    if (sub == 5'd0) begin
                        i2c_scl_oe <= 1'b0; // SCL High
                        i2c_sda_oe <= 1'b0; // SDA High
                        sub        <= 5'd1;
                    end else if (sub == 5'd1) begin
                        i2c_scl_oe <= 1'b0; // SCL High
                        i2c_sda_oe <= 1'b1; // SDA Low -> START condition!
                        sub        <= 5'd2;
                    end else begin
                        i2c_scl_oe <= 1'b1; // SCL Low
                        i2c_sda_oe <= 1'b1; // SDA Low
                        tx_data    <= {i2c_slave_addr, 1'b1}; // 0xB5 (Read)
                        main_state <= ST_R_ADDR;
                        sub        <= 5'd0;
                    end
                end

                ST_R_ADDR: begin
                    if (!sub[0] && sub < 5'd16) begin
                        i2c_scl_oe <= 1'b1;
                        i2c_sda_oe <= ~tx_data[7 - (sub >> 1)];
                        sub        <= sub + 5'd1;
                    end else if (sub[0] && sub < 5'd16) begin
                        i2c_scl_oe <= 1'b0;
                        sub        <= sub + 5'd1;
                    end else if (sub == 5'd16) begin
                        i2c_scl_oe <= 1'b1;
                        i2c_sda_oe <= 1'b0;
                        sub        <= 5'd17;
                    end else if (sub == 5'd17) begin
                        i2c_scl_oe <= 1'b0;
                        if (sda_filtered == 1'b0) begin
                            sub <= 5'd18; // ACK received!
                        end else begin
                            err_flag   <= 1'b1;
                            main_state <= ST_R_STOP;
                            sub        <= 5'd0;
                        end
                    end else begin
                        // sub == 18: SCL Low, prepare to read data byte
                        i2c_scl_oe <= 1'b1;
                        rx_data    <= 8'd0;
                        main_state <= ST_R_DATA;
                        sub        <= 5'd0;
                    end
                end

                ST_R_DATA: begin
                    if (!sub[0] && sub < 5'd16) begin
                        // SCL Low, master releases SDA so slave can drive
                        i2c_scl_oe <= 1'b1;
                        i2c_sda_oe <= 1'b0;
                        sub        <= sub + 5'd1;
                    end else if (sub[0] && sub < 5'd16) begin
                        // SCL High, sample slave data bit
                        i2c_scl_oe <= 1'b0;
                        rx_data    <= {rx_data[6:0], sda_filtered};
                        sub        <= sub + 5'd1;
                    end else if (sub == 5'd16) begin
                        // Master NACK: SCL Low, SDA High (OE=0)
                        i2c_scl_oe <= 1'b1;
                        i2c_sda_oe <= 1'b0;
                        sub        <= 5'd17;
                    end else if (sub == 5'd17) begin
                        // SCL High, slave samples Master NACK
                        i2c_scl_oe <= 1'b0;
                        sub        <= 5'd18;
                    end else begin
                        // sub == 18: SCL Low, latch data into temporary register
                        i2c_scl_oe <= 1'b1;
                        case (reg_step)
                            3'd0: tmp_joy_x     <= rx_data;
                            3'd1: tmp_joy_y     <= rx_data;
                            3'd2: tmp_btn_a_val <= rx_data;
                            3'd3: tmp_btn_b_val <= rx_data;
                            3'd4: tmp_btn_x_val <= rx_data;
                            3'd5: tmp_btn_y_val <= rx_data;
                            3'd6: tmp_btn_ok_val <= rx_data;
                            default: ;
                        endcase
                        main_state <= ST_R_STOP;
                        sub        <= 5'd0;
                    end
                end

                ST_R_STOP: begin
                    if (sub == 5'd0) begin
                        i2c_scl_oe <= 1'b1; // SCL Low
                        i2c_sda_oe <= 1'b1; // SDA Low
                        sub        <= 5'd1;
                    end else if (sub == 5'd1) begin
                        i2c_scl_oe <= 1'b0; // SCL High
                        i2c_sda_oe <= 1'b1; // SDA Low
                        sub        <= 5'd2;
                    end else if (sub == 5'd2) begin
                        i2c_scl_oe <= 0;    // SCL High
                        i2c_sda_oe <= 0;    // SDA High -> STOP condition!
                        sub        <= 5'd3;
                    end else if (sub < 5'd8) begin
                        // Hold bus idle for 5 ticks (~25us) between registers
                        i2c_scl_oe <= 1'b0;
                        i2c_sda_oe <= 1'b0;
                        sub        <= sub + 5'd1;
                    end else begin
                        if (err_flag) begin
                            gamepad_online <= 1'b0;
                            main_state     <= ST_IDLE;
                        end else if (reg_step == 3'd6) begin
                            // Successfully polled all 7 registers!
                            gamepad_online <= 1'b1;
                            joy_x          <= tmp_joy_x;
                            joy_y          <= tmp_joy_y;
                            buttons[0]     <= (tmp_btn_a_val != 8'd8 && tmp_btn_a_val != 8'hFF && tmp_btn_a_val <= 8'd6);
                            buttons[1]     <= (tmp_btn_b_val != 8'd8 && tmp_btn_b_val != 8'hFF && tmp_btn_b_val <= 8'd6);
                            buttons[2]     <= (tmp_btn_x_val != 8'd8 && tmp_btn_x_val != 8'hFF && tmp_btn_x_val <= 8'd6);
                            buttons[3]     <= (tmp_btn_y_val != 8'd8 && tmp_btn_y_val != 8'hFF && tmp_btn_y_val <= 8'd6);
                            buttons[4]     <= (tmp_btn_ok_val != 8'd8 && tmp_btn_ok_val != 8'hFF && tmp_btn_ok_val <= 8'd6);
                            main_state     <= ST_IDLE;
                        end else begin
                            reg_step   <= reg_step + 3'd1;
                            main_state <= ST_W_START;
                            sub        <= 5'd0;
                        end
                    end
                end

                default: main_state <= ST_IDLE;
            endcase
        end
    end

endmodule
