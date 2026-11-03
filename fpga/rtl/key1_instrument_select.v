`timescale 1ns / 1ps

// Debounce BOTH edges. Holding KEY1 advances the instrument mode once.
// 0..3 preserve piano/organ/drum/split; 4..11 select the eight new patches.
module key1_instrument_select #(
    parameter integer DEBOUNCE_CYCLES = 500000
) (
    input wire clk,
    input wire rst_n,
    input wire key1_n,
    output reg [3:0] mode
);
    // Width follows DEBOUNCE_CYCLES; a fixed 20-bit counter could never reach
    // a longer programmed terminal count and the key would stop working.
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

    reg key_meta, key_sync, stable_n;
    reg [CNT_W-1:0] count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta <= 1'b1;
            key_sync <= 1'b1;
            stable_n <= 1'b1;
            count <= 0;
            mode <= 2'd0;
        end else begin
            key_meta <= key1_n;
            key_sync <= key_meta;
            if (key_sync == stable_n)
                count <= 0;
            else if (count == DEBOUNCE_CYCLES - 1) begin
                count <= 0;
                stable_n <= key_sync;
                if (!key_sync)
                    mode <= (mode == 4'd11) ? 4'd0 : mode + 1'b1;
            end else
                count <= count + 1'b1;
        end
    end
endmodule
