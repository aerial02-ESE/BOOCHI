`timescale 1ns / 1ps
`include "src/control_event64_defs.vh"

// UART-only preview stream. Sixteen pitch cells are kept in registers, so no
// extra BSRAM is consumed by the already nearly full music design.
// B3 = C-major numbered pitch (octave[7:4], sharp[3], degree[2:0]).
// B4 low nibble = duration class, simultaneous-onset, long-onset-gap.
// B5 = slot 0..15 for LOAD. B6 = 0 CLEAR, 1 LOAD, 2 ADVANCE.
module score_viewer (
    input wire clk,
    input wire rst_n,
    input wire event_valid,
    input wire [63:0] event_data,
    output reg [127:0] pitch_codes,
    output reg [31:0] instruments,
    output reg [63:0] rhythms,
    output reg [15:0] occupied
);
    wire is_preview = event_data[63:62] == `CE64_VERSION_V1 &&
                      event_data[61:56] == `CE64_TYPE_SCORE_VIEW &&
                      event_data[55:52] == 4'd3;
    wire [7:0] operation = event_data[15:8];
    wire [7:0] slot = event_data[23:16];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pitch_codes <= 128'd0;
            instruments <= 32'd0;
            rhythms <= 64'd0;
            occupied <= 16'd0;
        end else if (event_valid && is_preview) begin
            case (operation)
                8'd0: begin
                    pitch_codes <= 128'd0;
                    instruments <= 32'd0;
                    rhythms <= 64'd0;
                    occupied <= 16'd0;
                end
                8'd1: if (slot < 16 &&
                         event_data[34:32] >= 1 && event_data[34:32] <= 7 &&
                         event_data[47:44] <= 2) begin
                    pitch_codes[slot[3:0]*8 +: 8] <= event_data[39:32];
                    instruments[slot[3:0]*2 +: 2] <= event_data[45:44];
                    rhythms[slot[3:0]*4 +: 4] <= event_data[27:24];
                    occupied[slot[3:0]] <= 1'b1;
                end
                8'd2: begin
                    pitch_codes <= {8'd0, pitch_codes[127:8]};
                    instruments <= {2'd0, instruments[31:2]};
                    rhythms <= {4'd0, rhythms[63:4]};
                    occupied <= {1'b0, occupied[15:1]};
                end
                default: begin end
            endcase
        end
    end
endmodule
