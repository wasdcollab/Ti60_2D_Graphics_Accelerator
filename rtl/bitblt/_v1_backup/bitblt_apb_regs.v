`timescale 1ns/1ps

module bitblt_apb_regs #(parameter CLOCK_HZ = 100000000) (
    input  wire        clk,
    input  wire        rst_n,
    // APB Slave Interface
    input  wire [15:0] apb_paddr,
    input  wire        apb_psel,
    input  wire        apb_penable,
    input  wire        apb_pwrite,
    input  wire [31:0] apb_pwdata,
    output reg  [31:0] apb_prdata,
    output wire        apb_pready,
    output wire        apb_pslverr,
    
    // Command interface to stride_gen
    output reg         cmd_start,
    output reg  [1:0]  cmd_op_type,      // 0: OP_FILL, 1: OP_COPY
    output reg  [27:0] cmd_dst_addr,
    output reg  [27:0] cmd_src_addr,
    output reg  [10:0] cmd_rect_w,
    output reg  [10:0] cmd_rect_h,
    output reg  [31:0] cmd_color,
    output reg  [15:0] cmd_src_stride,
    output reg  [15:0] cmd_dst_stride,
    input  wire        cmd_busy,
    
    // Double-buffer control
    output reg  [27:0] vdma_next_base,
    input  wire [27:0] vdma_active_base,
    input  wire [27:0] vdma_right_active_base,
    output reg  [27:0] vdma_right_next_base,
    output reg  [7:0]  cpu_fps_bcd,
    output reg  [7:0]  fpga_fps_bcd,
    input  wire [31:0] scan_diagnostics,
    input  wire        vsync_flag,

    // Gamepad & Board Keys Interface
    input  wire [7:0]  gamepad_joy_x,
    input  wire [7:0]  gamepad_joy_y,
    input  wire [3:0]  gamepad_buttons,
    input  wire        gamepad_online,
    input  wire        key_sw0_level,
    input  wire        key_sw2_level,
    input  wire        key_sw0_pulse,
    input  wire        key_sw2_pulse,
    output wire [6:0]  i2c_slave_addr,
    output wire        force_hud_disable
);

    // Capture VSync as a sticky event so firmware cannot miss the short
    // vertical blanking pulse while polling over APB. A read of REG_VSYNC_STS
    // acknowledges the event.
    reg vsync_seen;
    reg busy_d;
    reg done_seen;
    reg [31:0] reg_i2c_cfg;
    reg sw0_latched, sw2_latched;
    reg [31:0] second_ticks, cpu_frames, fpga_frames;
    reg [7:0] cpu_count, fpga_count;
    reg [27:0] left_previous, right_previous;
    wire left_swap = vdma_active_base != left_previous;
    wire right_swap = vdma_right_active_base != right_previous;
    
    function [7:0] increment_bcd;
        input [7:0] value;
        begin
            if (value == 8'h99) increment_bcd = value;
            else if (value[3:0] == 9) increment_bcd = {value[7:4] + 4'd1, 4'd0};
            else increment_bcd = value + 8'd1;
        end
    endfunction

    // Count actual newly presented half-frames
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            second_ticks <= 0;
            cpu_frames <= 0; fpga_frames <= 0;
            cpu_count <= 0; fpga_count <= 0;
            cpu_fps_bcd <= 0; fpga_fps_bcd <= 0;
            left_previous <= 28'h01000000;
            right_previous <= 28'h01000000;
        end else begin
            left_previous <= vdma_active_base;
            right_previous <= vdma_right_active_base;
            if (left_swap) cpu_frames <= cpu_frames + 1'b1;
            if (right_swap) fpga_frames <= fpga_frames + 1'b1;
            if (second_ticks == CLOCK_HZ - 1) begin
                second_ticks <= 0;
                cpu_fps_bcd <= left_swap ? increment_bcd(cpu_count) : cpu_count;
                fpga_fps_bcd <= right_swap ? increment_bcd(fpga_count) : fpga_count;
                cpu_count <= 0; fpga_count <= 0;
            end else begin
                second_ticks <= second_ticks + 1'b1;
                if (left_swap) cpu_count <= increment_bcd(cpu_count);
                if (right_swap) fpga_count <= increment_bcd(fpga_count);
            end
        end
    end

    assign apb_pready = 1'b1;
    assign apb_pslverr = 1'b0;
    
    wire apb_write = apb_psel & apb_penable & apb_pwrite;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_start            <= 1'b0;
            cmd_op_type          <= 2'd0;
            cmd_dst_addr         <= 28'd0;
            cmd_src_addr         <= 28'd0;
            cmd_rect_w           <= 11'd0;
            cmd_rect_h           <= 11'd0;
            cmd_color            <= 32'd0;
            cmd_src_stride       <= 16'd4096;
            cmd_dst_stride       <= 16'd4096;
            vdma_next_base       <= 28'h0100_0000;
            vdma_right_next_base <= 28'h0100_0000;
            vsync_seen           <= 1'b0;
            busy_d               <= 1'b0;
            done_seen            <= 1'b0;
            reg_i2c_cfg          <= 32'h0001_005A; // [6:0]=7'h5A (Mini-Joystick), [16]=1 (auto_poll)
            sw0_latched          <= 1'b0;
            sw2_latched          <= 1'b0;
        end else begin
            busy_d <= cmd_busy;
            if (busy_d && !cmd_busy)
                done_seen <= 1'b1;
            cmd_start <= 1'b0; // default to 0 for pulse
            if (vsync_flag)
                vsync_seen <= 1'b1;
            if (apb_psel && apb_penable && !apb_pwrite && (apb_paddr[7:0] == 8'h24))
                vsync_seen <= 1'b0;

            // Latch button press events; clear when 0x58 is read
            if (key_sw0_pulse) sw0_latched <= 1'b1;
            if (key_sw2_pulse) sw2_latched <= 1'b1;
            if (apb_psel && apb_penable && !apb_pwrite && (apb_paddr[7:0] == 8'h58)) begin
                sw0_latched <= 1'b0;
                sw2_latched <= 1'b0;
            end

            if (apb_write) begin
                case (apb_paddr[7:0])
                    8'h04: cmd_dst_addr <= apb_pwdata[27:0];
                    8'h08: cmd_rect_w <= apb_pwdata[10:0];
                    8'h0C: cmd_rect_h <= apb_pwdata[10:0];
                    8'h10: cmd_color <= apb_pwdata;
                    8'h14: begin
                        if (apb_pwdata[0] && !cmd_busy && !cmd_start) begin
                            cmd_start <= 1'b1;
                            done_seen <= (cmd_rect_w == 0 || cmd_rect_h == 0);
                        end
                    end
                    8'h18: cmd_op_type <= apb_pwdata[1:0];
                    8'h1C: cmd_src_addr <= apb_pwdata[27:0];
                    8'h20: vdma_next_base <= apb_pwdata[27:0];
                    8'h30: cmd_src_stride <= apb_pwdata[15:0];
                    8'h40: vdma_right_next_base <= apb_pwdata[27:0];
                    8'h48: cmd_dst_stride <= apb_pwdata[15:0];
                    8'h5C: reg_i2c_cfg <= apb_pwdata;
                    default: ;
                endcase
            end
        end
    end

    assign i2c_slave_addr = reg_i2c_cfg[6:0];
    assign force_hud_disable = reg_i2c_cfg[20];
    
    always @(*) begin
        apb_prdata = 32'd0;
        if (apb_psel && !apb_pwrite) begin
            case (apb_paddr[7:0])
                8'h00: apb_prdata = {30'd0, done_seen, (cmd_busy | cmd_start)};
                8'h04: apb_prdata = {4'd0, cmd_dst_addr};
                8'h08: apb_prdata = {21'd0, cmd_rect_w};
                8'h0C: apb_prdata = {21'd0, cmd_rect_h};
                8'h10: apb_prdata = cmd_color;
                8'h18: apb_prdata = {30'd0, cmd_op_type};
                8'h1C: apb_prdata = {4'd0, cmd_src_addr};
                8'h20: apb_prdata = {4'd0, vdma_next_base};
                8'h24: apb_prdata = {31'd0, vsync_seen};
                8'h28: apb_prdata = {4'd0, vdma_active_base};
                8'h2C: apb_prdata = {4'd0, vdma_right_active_base};
                8'h30: apb_prdata = {16'd0, cmd_src_stride};
                8'h34: apb_prdata = {16'd0, fpga_fps_bcd, cpu_fps_bcd};
                8'h38: apb_prdata = cpu_frames;
                8'h3C: apb_prdata = fpga_frames;
                8'h40: apb_prdata = {4'd0, vdma_right_next_base};
                8'h44: apb_prdata = scan_diagnostics;
                8'h48: apb_prdata = {16'd0, cmd_dst_stride};
                8'h50: apb_prdata = {16'd0, gamepad_joy_y, gamepad_joy_x};
                8'h54: apb_prdata = {15'd0, gamepad_online, 12'd0, gamepad_buttons};
                8'h58: apb_prdata = {22'd0, sw2_latched, sw0_latched, 6'd0, key_sw2_level, key_sw0_level};
                8'h5C: apb_prdata = reg_i2c_cfg;
                default: apb_prdata = 32'd0;
            endcase
        end
    end

endmodule
