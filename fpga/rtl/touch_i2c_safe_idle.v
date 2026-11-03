`timescale 1ns / 1ps

// Safe electrical placeholder for the panel's CTP connector.
// CTP controller identity, I2C address and register map are absent from the
// supplied panel specification, so this module releases SDA/SCL rather than
// sending invented traffic. It does perform a clean reset release.
module touch_i2c_safe_idle #(
    parameter [20:0] RESET_RELEASE_CYCLES = 21'd1000000
) (
    input  wire clk_50m,
    input  wire rst_n,
    input  wire ctp_int,
    output reg  ctp_rst_n,
    inout  wire ctp_sda,
    inout  wire ctp_scl
);

    reg [20:0] reset_count;

    assign ctp_sda = 1'bz;
    assign ctp_scl = 1'bz;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            reset_count <= 21'd0;
            ctp_rst_n   <= 1'b0;
        end else if (reset_count < RESET_RELEASE_CYCLES) begin
            reset_count <= reset_count + 1'b1;
            ctp_rst_n   <= 1'b0;
        end else begin
            ctp_rst_n <= 1'b1;
        end
    end

    // Keeps ctp_int in the synthesized hierarchy for board bring-up probing.
    wire keep_ctp_int = ctp_int;

endmodule
