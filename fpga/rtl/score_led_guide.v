`timescale 1ns / 1ps
`include "src/control_event64_defs.vh"

// Timed score LED hints from ESP32. Separate per-instrument ownership prevents
// an organ Note Off from extinguishing an overlapping piano note at the same
// pitch. All event handling is synchronous; the WS2812 driver runs separately.
module score_led_guide (
    input wire clk,
    input wire rst_n,
    input wire event_valid,
    input wire [63:0] event_data,
    output wire [127:0] guide_notes,
    output wire [127:0] expected_notes
);
    reg [127:0] guide0, guide1, guide2;
    reg [127:0] expected0, expected1, expected2;
    wire is_hint = event_data[63:62] == `CE64_VERSION_V1 &&
                   event_data[61:56] == `CE64_TYPE_SCORE_LED &&
                   event_data[55:52] == 4'd3;
    wire [7:0] operation = event_data[15:8];
    wire [7:0] note = event_data[39:32];
    wire [3:0] instrument = event_data[47:44];

    assign guide_notes = guide0 | guide1 | guide2;
    assign expected_notes = expected0 | expected1 | expected2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            guide0 <= 0; guide1 <= 0; guide2 <= 0;
            expected0 <= 0; expected1 <= 0; expected2 <= 0;
        end else if (event_valid && is_hint) begin
            if (operation == 0) begin
                guide0 <= 0; guide1 <= 0; guide2 <= 0;
                expected0 <= 0; expected1 <= 0; expected2 <= 0;
            end else if (note < 128 && instrument < 3) begin
                case (instrument)
                    0: case (operation)
                        1: guide0[note[6:0]] <= 1'b1;
                        2: begin guide0[note[6:0]] <= 1'b0;
                                 expected0[note[6:0]] <= 1'b1; end
                        3: expected0[note[6:0]] <= 1'b0;
                        default: begin end
                    endcase
                    1: case (operation)
                        1: guide1[note[6:0]] <= 1'b1;
                        2: begin guide1[note[6:0]] <= 1'b0;
                                 expected1[note[6:0]] <= 1'b1; end
                        3: expected1[note[6:0]] <= 1'b0;
                        default: begin end
                    endcase
                    2: case (operation)
                        1: guide2[note[6:0]] <= 1'b1;
                        2: begin guide2[note[6:0]] <= 1'b0;
                                 expected2[note[6:0]] <= 1'b1; end
                        3: expected2[note[6:0]] <= 1'b0;
                        default: begin end
                    endcase
                    default: begin end
                endcase
            end
        end
    end
endmodule
