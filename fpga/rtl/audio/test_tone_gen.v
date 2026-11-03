`timescale 1ns / 1ps
`include "src/control_event64_defs.vh"

// Power-on self test for the competition's "active independent oscillators"
// demonstration: emits 32 NOTE_ON events, one whole tone apart from MIDI 36
// (C2) to 98 (D7), and never releases them.  The events go through the normal
// mapper and audio engine, so the sample path is the same as a real keyboard.
module test_tone_gen #(
    parameter integer START_DELAY_CYCLES = 50_000_000,
    parameter integer EVENT_GAP_CYCLES   = 50_000,
    parameter [6:0]   VELOCITY           = 7'd64,
    parameter [3:0]   SOURCE             = 4'd0
) (
    input  wire        clk,
    input  wire        rst_n,
    output wire        out_valid,
    output wire [63:0] out_data,
    input  wire        out_ready,
    output reg         done
);
    localparam integer NOTE_COUNT = 32;
    localparam [1:0] ST_DELAY = 2'd0,
                     ST_SEND  = 2'd1,
                     ST_GAP   = 2'd2,
                     ST_DONE  = 2'd3;

    // 32 whole-tone MIDI notes, C2..D7.  Fundamentals stay strong in the
    // piano wavetable, so every voice produces a resolvable spectral peak.
    function [6:0] note_at;
        input [4:0] index;
        begin
            case (index)
                5'd0:  note_at = 7'd36;   // 65.41 Hz
                5'd1:  note_at = 7'd38;   // 73.42 Hz
                5'd2:  note_at = 7'd40;   // 82.41 Hz
                5'd3:  note_at = 7'd42;   // 92.50 Hz
                5'd4:  note_at = 7'd44;   // 103.83 Hz
                5'd5:  note_at = 7'd46;   // 116.54 Hz
                5'd6:  note_at = 7'd48;   // 130.81 Hz
                5'd7:  note_at = 7'd50;   // 146.83 Hz
                5'd8:  note_at = 7'd52;   // 164.81 Hz
                5'd9:  note_at = 7'd54;   // 185.00 Hz
                5'd10: note_at = 7'd56;   // 207.65 Hz
                5'd11: note_at = 7'd58;   // 233.08 Hz
                5'd12: note_at = 7'd60;   // 261.63 Hz
                5'd13: note_at = 7'd62;   // 293.66 Hz
                5'd14: note_at = 7'd64;   // 329.63 Hz
                5'd15: note_at = 7'd66;   // 369.99 Hz
                5'd16: note_at = 7'd68;   // 415.30 Hz
                5'd17: note_at = 7'd70;   // 466.16 Hz
                5'd18: note_at = 7'd72;   // 523.25 Hz
                5'd19: note_at = 7'd74;   // 587.33 Hz
                5'd20: note_at = 7'd76;   // 659.26 Hz
                5'd21: note_at = 7'd78;   // 739.99 Hz
                5'd22: note_at = 7'd80;   // 830.61 Hz
                5'd23: note_at = 7'd82;   // 932.33 Hz
                5'd24: note_at = 7'd84;   // 1046.50 Hz
                5'd25: note_at = 7'd86;   // 1174.66 Hz
                5'd26: note_at = 7'd88;   // 1318.51 Hz
                5'd27: note_at = 7'd90;   // 1479.98 Hz
                5'd28: note_at = 7'd92;   // 1661.22 Hz
                5'd29: note_at = 7'd94;   // 1864.66 Hz
                5'd30: note_at = 7'd96;   // 2093.00 Hz
                default: note_at = 7'd98; // 2349.32 Hz
            endcase
        end
    endfunction

    function [63:0] event_at;
        input [4:0] index;
        reg [6:0] note;
        begin
            note = note_at(index);
            event_at = {
                2'b01, `CE64_TYPE_NOTE_ON,  // B0: version 1, NOTE_ON
                SOURCE, 4'd0,               // B1: source, channel 0
                4'd0, 4'd0,                 // B2: piano, no flags
                1'b0, note,                 // B3: note id
                VELOCITY, 1'b0,             // B4: value[15:8]
                8'd0,                       // B5: value[7:0]
                8'd0,                       // B6: aux
                3'd0, index                 // B7: sequence
            };
        end
    endfunction

    reg [1:0]  state;
    reg [4:0]  index;
    reg [31:0] timer;
    reg [63:0] event_reg;

    assign out_valid = state == ST_SEND;
    assign out_data  = event_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_DELAY;
            index     <= 5'd0;
            timer     <= 32'd0;
            event_reg <= 64'd0;
            done      <= 1'b0;
        end else begin
            case (state)
                ST_DELAY: begin
                    if (timer >= START_DELAY_CYCLES - 1) begin
                        timer     <= 32'd0;
                        index     <= 5'd0;
                        event_reg <= event_at(5'd0);
                        state     <= ST_SEND;
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end
                ST_SEND: begin
                    if (out_ready) begin
                        if (index == NOTE_COUNT - 1) begin
                            done  <= 1'b1;
                            state <= ST_DONE;
                        end else begin
                            index     <= index + 1'b1;
                            event_reg <= event_at(index + 1'b1);
                            timer     <= 32'd0;
                            state     <= ST_GAP;
                        end
                    end
                end
                ST_GAP: begin
                    if (timer >= EVENT_GAP_CYCLES - 1) begin
                        timer <= 32'd0;
                        state <= ST_SEND;
                    end else begin
                        timer <= timer + 1'b1;
                    end
                end
                default: begin
                    done  <= 1'b1;
                    state <= ST_DONE;
                end
            endcase
        end
    end

endmodule
