`timescale 1ns / 1ps
`include "src/control_event64_defs.vh"

// Parameterised two-axis sensor front end for the self-made controller.
// A future FSR + Hall/ToF/knob board presents two 12-bit samples and a
// sample strobe; this block turns significant changes into ControlEvents:
//   axis 0 -> PRESSURE   (strike force / aftertouch)
//   axis 1 -> MODULATION (position or modulation wheel)
// The sensor type is deliberately not fixed here, so the analog front end can
// change without touching the FPGA event path.
module sensor_pair_if #(
    parameter [11:0] MIN_DELTA = 12'd8,
    parameter [3:0]  SOURCE    = 4'd0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] sensor0,
    input  wire [11:0] sensor1,
    input  wire        sample_stb,
    output reg         out_valid,
    output reg  [63:0] out_data,
    input  wire        out_ready
);
    localparam [1:0] ST_IDLE = 2'd0,
                     ST_SEND0 = 2'd1,
                     ST_SEND1 = 2'd2;

    reg [1:0]  state;
    reg [11:0] sent0, sent1;
    reg [11:0] hold0, hold1;
    reg [11:0] send_val;
    reg        pending0, pending1;
    reg [7:0]  seq;

    wire [11:0] diff0 = (sensor0 > sent0) ? (sensor0 - sent0) : (sent0 - sensor0);
    wire [11:0] diff1 = (sensor1 > sent1) ? (sensor1 - sent1) : (sent1 - sensor1);
    wire [11:0] send_diff0 = (sensor0 > send_val) ?
                             (sensor0 - send_val) : (send_val - sensor0);
    wire [11:0] send_diff1 = (sensor1 > send_val) ?
                             (sensor1 - send_val) : (send_val - sensor1);

    function [63:0] make_event;
        input [5:0]  type;
        input [11:0] value;
        input [7:0]  sequence;
        begin
            make_event = {
                2'b01, type,
                SOURCE, 4'd0,
                4'd0, 4'd0,
                8'd0,
                value, 4'b0000,
                8'd0,
                sequence
            };
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            sent0    <= 12'd0;
            sent1    <= 12'd0;
            hold0    <= 12'd0;
            hold1    <= 12'd0;
            send_val <= 12'd0;
            pending0 <= 1'b0;
            pending1 <= 1'b0;
            seq      <= 8'd0;
            out_valid <= 1'b0;
            out_data  <= 64'd0;
        end else begin
            if (sample_stb) begin
                hold0 <= sensor0;
                hold1 <= sensor1;
                if (diff0 >= MIN_DELTA) pending0 <= 1'b1;
                if (diff1 >= MIN_DELTA) pending1 <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    out_valid <= 1'b0;
                    if (pending0) begin
                        out_data  <= make_event(`CE64_TYPE_PRESSURE, hold0, seq);
                        send_val  <= hold0;
                        out_valid <= 1'b1;
                        state     <= ST_SEND0;
                    end else if (pending1) begin
                        out_data  <= make_event(`CE64_TYPE_MODULATION, hold1, seq);
                        send_val  <= hold1;
                        out_valid <= 1'b1;
                        state     <= ST_SEND1;
                    end
                end
                ST_SEND0: begin
                    if (out_ready) begin
                        sent0    <= send_val;
                        // A fresh sample can arrive on the same edge that the
                        // previous event is accepted.  Preserve it when it is
                        // significant relative to the value just delivered.
                        pending0 <= sample_stb && (send_diff0 >= MIN_DELTA);
                        seq      <= seq + 1'b1;
                        out_valid <= 1'b0;
                        state    <= ST_IDLE;
                    end
                end
                ST_SEND1: begin
                    if (out_ready) begin
                        sent1    <= send_val;
                        pending1 <= sample_stb && (send_diff1 >= MIN_DELTA);
                        seq      <= seq + 1'b1;
                        out_valid <= 1'b0;
                        state    <= ST_IDLE;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
