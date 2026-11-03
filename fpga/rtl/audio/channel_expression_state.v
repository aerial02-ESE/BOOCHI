/*
 * MIDI 通道表情状态。
 *
 * Pitch Bend、Modulation、Channel Pressure、Sustain、Program 按 16 个 MIDI
 * 通道独立保存。
 * 通道独立保存。Poly Pressure 使用小型关联表，避免综合出 16x128 的寄存器阵列。
 * 两个无时序查询口分别服务钢琴/贝斯共享运算通路的当前声部。
 */
`include "src/control_event64_defs.vh"

module channel_expression_state #(
    parameter integer POLY_SLOTS = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        panic,
    input  wire        expr_fire,
    input  wire [5:0]  expr_type,
    input  wire [3:0]  expr_channel,
    input  wire [3:0]  expr_flags,
    input  wire [7:0]  expr_id,
    input  wire [15:0] expr_value,
    input  wire        note_fire,
    input  wire [3:0]  note_channel,
    input  wire [6:0]  note_number,
    input  wire [3:0]  query0_channel,
    input  wire [6:0]  query0_note,
    output reg  [15:0] query0_pitch,
    output reg  [7:0]  query0_mod,
    output reg  [15:0] query0_pressure,
    input  wire [3:0]  query1_channel,
    input  wire [6:0]  query1_note,
    output reg  [15:0] query1_pitch,
    output reg  [7:0]  query1_mod,
    output reg  [15:0] query1_pressure,
    input wire [3:0] query2_channel,
    input wire [6:0] query2_note,
    output reg [15:0] query2_pitch, query2_pressure,
    output reg [7:0] query2_mod,
    output wire [6:0]  selected_program,
    input  wire [3:0]  selected_program_channel
);
    reg [15:0] pitch [0:15];
    reg [7:0] modulation [0:15];
    reg [15:0] channel_pressure [0:15];
    reg [6:0] program [0:15];

    reg poly_valid [0:POLY_SLOTS-1];
    reg [3:0] poly_channel [0:POLY_SLOTS-1];
    reg [6:0] poly_note [0:POLY_SLOTS-1];
    reg [15:0] poly_value [0:POLY_SLOTS-1];
    reg [$clog2(POLY_SLOTS)-1:0] poly_replace;

    integer i;
    integer free_slot;
    integer match_slot;
    always @* begin
        query0_pitch = pitch[query0_channel];
        query0_mod = modulation[query0_channel];
        query0_pressure = channel_pressure[query0_channel];
        query1_pitch = pitch[query1_channel];
        query1_mod = modulation[query1_channel];
        query1_pressure = channel_pressure[query1_channel];
        query2_pitch = pitch[query2_channel]; query2_mod = modulation[query2_channel];
        query2_pressure = channel_pressure[query2_channel];
        for (i = 0; i < POLY_SLOTS; i = i + 1) begin
            if (poly_valid[i] && poly_channel[i] == query0_channel && poly_note[i] == query0_note)
                query0_pressure = poly_value[i];
            if (poly_valid[i] && poly_channel[i] == query1_channel && poly_note[i] == query1_note)
                query1_pressure = poly_value[i];
            if (poly_valid[i] && poly_channel[i] == query2_channel && poly_note[i] == query2_note)
                query2_pressure = poly_value[i];
        end
    end

    assign selected_program = program[selected_program_channel];

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || panic) begin
            poly_replace <= 0;
            for (reset_index = 0; reset_index < 16; reset_index = reset_index + 1) begin
                pitch[reset_index] <= 16'h8000;
                modulation[reset_index] <= 8'd0;
                channel_pressure[reset_index] <= 16'd0;
                program[reset_index] <= 7'd0;
            end
            for (reset_index = 0; reset_index < POLY_SLOTS; reset_index = reset_index + 1) begin
                poly_valid[reset_index] <= 1'b0;
                poly_channel[reset_index] <= 4'd0;
                poly_note[reset_index] <= 7'd0;
                poly_value[reset_index] <= 16'd0;
            end
        end else begin
            if (note_fire) begin
                for (i = 0; i < POLY_SLOTS; i = i + 1)
                    if (poly_valid[i] && poly_channel[i] == note_channel && poly_note[i] == note_number)
                        poly_valid[i] <= 1'b0;
            end

            if (expr_fire) begin
                case (expr_type)
                    `CE64_TYPE_PITCH_BEND: pitch[expr_channel] <= expr_value;
                    `CE64_TYPE_MODULATION: modulation[expr_channel] <= expr_value[15:8];
                    `CE64_TYPE_PROGRAM: program[expr_channel] <= expr_id[6:0];
                    `CE64_TYPE_PRESSURE: begin
                        if (expr_flags[`CE64_FLAG_PER_NOTE]) begin
                            free_slot = -1;
                            match_slot = -1;
                            for (i = 0; i < POLY_SLOTS; i = i + 1) begin
                                if (!poly_valid[i] && free_slot < 0)
                                    free_slot = i;
                                if (poly_valid[i] && poly_channel[i] == expr_channel &&
                                    poly_note[i] == expr_id[6:0])
                                    match_slot = i;
                            end
                            if (match_slot >= 0) begin
                                poly_value[match_slot] <= expr_value;
                                poly_valid[match_slot] <= (expr_value != 0);
                            end else if (expr_value != 0) begin
                                if (free_slot >= 0) begin
                                    poly_valid[free_slot] <= 1'b1;
                                    poly_channel[free_slot] <= expr_channel;
                                    poly_note[free_slot] <= expr_id[6:0];
                                    poly_value[free_slot] <= expr_value;
                                end else begin
                                    poly_valid[poly_replace] <= 1'b1;
                                    poly_channel[poly_replace] <= expr_channel;
                                    poly_note[poly_replace] <= expr_id[6:0];
                                    poly_value[poly_replace] <= expr_value;
                                    poly_replace <= poly_replace + 1'b1;
                                end
                            end
                        end else begin
                            channel_pressure[expr_channel] <= expr_value;
                        end
                    end
                    default: begin end
                endcase
            end
        end
    end
endmodule
