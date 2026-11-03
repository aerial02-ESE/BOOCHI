/*
 * 统一控制事件路由器（64-bit ControlEvent → 分引擎事件流）。
 *
 * 职责：把一路 64-bit ControlEvent 按 instrument 字段分发到钢琴/贝斯/鼓音符流，
 * 并把其余已定义控制事件送到统一控制流；未知类型或未实现音色被丢弃并计数。
 *
 * 用途：这是 ESP32/UART/SPI 事件进入音频引擎的唯一入口（docs §8.3、C05/C08）。
 * 单槽 pending 设计：直到目标流接受才释放，保证 Note On/Off 不丢失、不重复。
 */
`include "src/control_event64_defs.vh"

module control_event_router #(
    parameter integer EVENT_WIDTH = `CE64_WIDTH,
    parameter integer COUNT_WIDTH = 32
) (
    input  wire                   clk,
    input  wire                   rst_n,
    // 输入事件流（来自 UART/SPI/曲谱源）。
    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire [EVENT_WIDTH-1:0] in_event,
    // 钢琴音符流（instrument = 0）。
    output reg                    piano_valid,
    input  wire                   piano_ready,
    output reg                    piano_note_on,
    output reg  [6:0]             piano_note,
    output reg  [6:0]             piano_velocity,
    output reg  [3:0]             piano_channel,
    // 贝斯音符流（instrument = 1）。
    output reg                    bass_valid,
    input  wire                   bass_ready,
    output reg                    bass_note_on,
    output reg  [6:0]             bass_note,
    output reg  [6:0]             bass_velocity,
    output reg  [3:0]             bass_channel,
    // 鼓音符流（instrument = 2）。
    output reg                    drum_valid,
    input  wire                   drum_ready,
    output reg                    drum_note_on,
    output reg  [6:0]             drum_note,
    output reg  [6:0]             drum_velocity,
    output reg  [3:0]             drum_channel,
    output reg bank_valid,
    input wire bank_ready,
    output reg bank_note_on,
    output reg [6:0] bank_note, bank_velocity,
    output reg [3:0] bank_channel,
    output reg [2:0] bank_patch,
    // 完整控制流（Pitch/Mod/Pressure/Program/Sustain/Effect/Transport/Param/Panic）。
    output reg                    expr_valid,
    input  wire                   expr_ready,
    output reg  [5:0]             expr_type,
    output reg  [15:0]            expr_value,
    output reg  [3:0]             expr_instrument,
    output reg  [3:0]             expr_source,
    output reg  [3:0]             expr_channel,
    output reg  [3:0]             expr_flags,
    output reg  [7:0]             expr_id,
    output reg  [7:0]             expr_aux,
    // 诊断（饱和计数）。
    output reg  [COUNT_WIDTH-1:0] unknown_type_count,
    output reg  [COUNT_WIDTH-1:0] unknown_instrument_count
);
    localparam [2:0] DEST_NONE  = 3'd0;
    localparam [2:0] DEST_PIANO = 3'd1;
    localparam [2:0] DEST_BASS  = 3'd2;
    localparam [2:0] DEST_DRUM  = 3'd3;
    localparam [2:0] DEST_EXPR  = 3'd4;

    localparam [2:0] DEST_BANK = 3'd5;
    reg [2:0] dest;

    assign in_ready = (dest == DEST_NONE);

    // 输入字段（组合解码）。
    wire [5:0] ev_type = in_event[`CE64_TYPE_MSB:`CE64_TYPE_LSB];
    wire [3:0] ev_inst = in_event[`CE64_INSTR_MSB:`CE64_INSTR_LSB];
    wire [3:0] ev_source = in_event[`CE64_SOURCE_MSB:`CE64_SOURCE_LSB];
    wire [3:0] ev_channel = in_event[`CE64_CHANNEL_MSB:`CE64_CHANNEL_LSB];
    wire [3:0] ev_flags = in_event[`CE64_FLAGS_MSB:`CE64_FLAGS_LSB];
    wire [7:0] ev_id   = in_event[`CE64_ID_MSB:`CE64_ID_LSB];
    wire [15:0] ev_val = in_event[`CE64_VALUE_MSB:`CE64_VALUE_LSB];
    wire [7:0] ev_aux = in_event[`CE64_AUX_MSB:`CE64_AUX_LSB];

    wire ev_is_note = (ev_type == `CE64_TYPE_NOTE_ON) || (ev_type == `CE64_TYPE_NOTE_OFF);
    wire ev_is_expr = (ev_type == `CE64_TYPE_PITCH_BEND) || (ev_type == `CE64_TYPE_MODULATION) ||
                      (ev_type == `CE64_TYPE_PRESSURE)   || (ev_type == `CE64_TYPE_PROGRAM) ||
                      (ev_type == `CE64_TYPE_SUSTAIN)    || (ev_type == `CE64_TYPE_EFFECT_CTRL) ||
                      (ev_type == `CE64_TYPE_ALL_NOTES_OFF) || (ev_type == `CE64_TYPE_TRANSPORT) ||
                      (ev_type == `CE64_TYPE_PARAM_CTRL);

    function [COUNT_WIDTH-1:0] sat_inc;
        input [COUNT_WIDTH-1:0] value;
        begin
            sat_inc = (value == {COUNT_WIDTH{1'b1}}) ? value : value + 1'b1;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_valid <= 0; bank_note_on <= 0; bank_note <= 0; bank_velocity <= 0; bank_channel <= 0; bank_patch <= 0;
            dest <= DEST_NONE;
            piano_valid <= 1'b0; bass_valid <= 1'b0; drum_valid <= 1'b0; expr_valid <= 1'b0;
            piano_note_on <= 1'b0; piano_note <= 7'd0; piano_velocity <= 7'd0;
            piano_channel <= 4'd0;
            bass_note_on <= 1'b0; bass_note <= 7'd0; bass_velocity <= 7'd0;
            bass_channel <= 4'd0;
            drum_note_on <= 1'b0; drum_note <= 7'd0; drum_velocity <= 7'd0;
            drum_channel <= 4'd0;
            expr_type <= 6'd0; expr_value <= 16'd0; expr_instrument <= 4'd0;
            expr_source <= 4'd0; expr_channel <= 4'd0; expr_flags <= 4'd0;
            expr_id <= 8'd0; expr_aux <= 8'd0;
            unknown_type_count <= {COUNT_WIDTH{1'b0}};
            unknown_instrument_count <= {COUNT_WIDTH{1'b0}};
        end else begin
            // 目标流接受后释放槽位。
            if ((dest == DEST_PIANO && piano_ready) ||
                (dest == DEST_BASS  && bass_ready)  ||
                (dest == DEST_DRUM  && drum_ready)  ||
                (dest == DEST_EXPR  && expr_ready) ||
                (dest == DEST_BANK && bank_ready))
                dest <= DEST_NONE;

            // 槽位空闲时接收并解码新事件。
            if (dest == DEST_NONE && in_valid) begin
                if (ev_is_note) begin
                    if (ev_inst == `CE64_INST_PIANO) begin
                        piano_valid    <= 1'b1;
                        piano_note_on  <= (ev_type == `CE64_TYPE_NOTE_ON);
                        piano_note     <= ev_id[6:0];
                        piano_velocity <= ev_val[15:9];
                        piano_channel  <= ev_channel;
                        dest           <= DEST_PIANO;
                    end else if (ev_inst == `CE64_INST_BASS) begin
                        bass_valid    <= 1'b1;
                        bass_note_on  <= (ev_type == `CE64_TYPE_NOTE_ON);
                        bass_note     <= ev_id[6:0];
                        bass_velocity <= ev_val[15:9];
                        bass_channel  <= ev_channel;
                        dest          <= DEST_BASS;
                    end else if (ev_inst == `CE64_INST_DRUM) begin
                        drum_valid    <= 1'b1;
                        drum_note_on  <= (ev_type == `CE64_TYPE_NOTE_ON);
                        drum_note     <= ev_id[6:0];
                        drum_velocity <= ev_val[15:9];
                        drum_channel  <= ev_channel;
                        dest          <= DEST_DRUM;
                    end else if (ev_inst >= 3 && ev_inst <= 10) begin
                        bank_valid <= 1; bank_note_on <= (ev_type == `CE64_TYPE_NOTE_ON) && ev_val != 0;
                        bank_note <= ev_id[6:0]; bank_velocity <= ev_val[15:9];
                        bank_channel <= ev_channel; bank_patch <= ev_inst - 4'd3;
                        dest <= DEST_BANK;
                    end else begin
                        // 未实现的音色：拒绝并计数，不静默变成钢琴（docs §7.3）。
                        unknown_instrument_count <= sat_inc(unknown_instrument_count);
                    end
                end else if (ev_is_expr) begin
                    expr_valid      <= 1'b1;
                    expr_type       <= ev_type;
                    expr_value      <= ev_val;
                    expr_instrument <= ev_inst;
                    expr_source     <= ev_source;
                    expr_channel    <= ev_channel;
                    expr_flags      <= ev_flags;
                    expr_id         <= ev_id;
                    expr_aux        <= ev_aux;
                    dest            <= DEST_EXPR;
                end else if (ev_type == `CE64_TYPE_NOP) begin
                    // NOP：消费但不产生动作。
                end else begin
                    unknown_type_count <= sat_inc(unknown_type_count);
                end
            end

            // 握手完成后撤销 valid（目标流已消费）。
            if (dest == DEST_PIANO && piano_ready) piano_valid <= 1'b0;
            if (dest == DEST_BASS  && bass_ready)  bass_valid  <= 1'b0;
            if (dest == DEST_DRUM  && drum_ready)  drum_valid  <= 1'b0;
            if (dest == DEST_EXPR  && expr_ready)  expr_valid  <= 1'b0;
            if (dest == DEST_BANK && bank_ready) bank_valid <= 0;
        end
    end
endmodule
