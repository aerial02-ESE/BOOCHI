`timescale 1ns / 1ps

// Debounce an active-low key and emit one clock-wide pulse on each press.
// Both edges are debounced; the pulse is generated on the debounced falling
// edge, so holding the key produces exactly one event.
module key_pulse_debounce #(
    parameter integer DEBOUNCE_CYCLES = 500000
) (
    input wire clk,
    input wire rst_n,
    input wire key_n,
    output reg pulse
);
    function integer clog2;
        input integer value;
        integer temporary;
        begin
            temporary = value - 1;
            clog2 = 0;
            while (temporary > 0) begin
                temporary = temporary >> 1;
                clog2 = clog2 + 1;
            end
        end
    endfunction

    localparam integer CNT_W = (DEBOUNCE_CYCLES <= 1) ? 1 : clog2(DEBOUNCE_CYCLES);

    reg key_meta, key_sync, stable_n, prev_stable_n;
    reg [CNT_W-1:0] count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta      <= 1'b1;
            key_sync      <= 1'b1;
            stable_n      <= 1'b1;
            prev_stable_n <= 1'b1;
            count         <= {CNT_W{1'b0}};
            pulse         <= 1'b0;
        end else begin
            key_meta      <= key_n;
            key_sync      <= key_meta;
            prev_stable_n <= stable_n;
            pulse         <= (stable_n == 1'b0) && (prev_stable_n == 1'b1);

            if (key_sync == stable_n)
                count <= {CNT_W{1'b0}};
            else if (count == DEBOUNCE_CYCLES - 1) begin
                count    <= {CNT_W{1'b0}};
                stable_n <= key_sync;
            end else
                count <= count + 1'b1;
        end
    end
endmodule
