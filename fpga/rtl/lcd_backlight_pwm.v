`timescale 1ns / 1ps

// Logic-level enable/PWM only. It must drive the EN/PWM input of an external
// constant-current backlight driver, never the LCD LED+/- pins directly.
module lcd_backlight_pwm #(
    parameter [21:0] STARTUP_CYCLES = 22'd2500000,
    parameter [15:0] PWM_PERIOD     = 16'd50000,
    parameter [15:0] PWM_ON_CYCLES  = 16'd40000
) (
    input  wire clk_50m,
    input  wire rst_n,
    output reg  pwm_out
);

    reg [21:0] startup_count;
    reg [15:0] pwm_count;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            startup_count <= 22'd0;
            pwm_count     <= 16'd0;
            pwm_out       <= 1'b0;
        end else if (startup_count < STARTUP_CYCLES) begin
            startup_count <= startup_count + 1'b1;
            pwm_count     <= 16'd0;
            pwm_out       <= 1'b0;
        end else begin
            if (pwm_count == PWM_PERIOD - 1'b1) begin
                pwm_count <= 16'd0;
            end else begin
                pwm_count <= pwm_count + 1'b1;
            end
            pwm_out <= (pwm_count < PWM_ON_CYCLES);
        end
    end

endmodule
