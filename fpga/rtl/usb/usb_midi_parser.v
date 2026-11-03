`timescale 1ns / 1ps

// USB-MIDI event packet (4 bytes) -> ControlEvent v1 (64 bits).
//
// Ported from the ESP32 bridge (esp32/main/midi_bridge.c) so the FPGA can host
// the SMK-25 directly.  Packet layout: {cable[3:0],CIN[3:0]}, status, data0,
// data1.  Only cable 0 is accepted (the SMK-25 mirrors every message on
// cable 1; accepting both would duplicate every note).
//
// Mapping (confirmed against 03_??????/03_???USB??IDI???_2026-10-23.md):
//   Note On/Off      -> NOTE_ON/NOTE_OFF, velocity scaled 7->16 bit
//   channel 10 notes -> instrument 2 (DRUM); notes 36..43 are the 8 pads
//   poly pressure    -> PRESSURE with the per-note flag (ESP32 omitted it)
//   channel pressure -> PRESSURE id=0
//   pitch bend       -> PITCH_BEND, 14->16 bit (centre 8192 -> 0x8002)
//   CC1  -> MODULATION, CC64 -> SUSTAIN, CC120/123 -> ALL_NOTES_OFF
//   CC20 -> EFFECT_CTRL aux4 (reverb)      CC21 -> aux5 (chorus)
//   CC22 -> EFFECT_CTRL aux1 (delay time)  CC23 -> aux2 (feedback)
//   CC24 -> EFFECT_CTRL aux3 (wet)         CC25 -> PARAM_CTRL id0 (master)
//   CC26 -> PARAM_CTRL id1 (piano)         CC27 -> PARAM_CTRL id2 (organ/bass)
//   Program Change   -> PROGRAM (32..39 => instrument 1, else piano)
// Knob values are de-duplicated per controller like the ESP32 did for CC20/21.
// Function keys (PLAY/STOP/OCT/ARP/...) produced no MIDI in the captures; if a
// later firmware sends CC/PC for them they pass through the generic handlers.
`include "src/control_event64_defs.vh"

module usb_midi_parser #(
    parameter [3:0] SOURCE = `CE64_SRC_USB_MIDI,
    parameter [3:0] CABLE_ACCEPT = 4'd0,
    parameter integer SEQ_START = 0,
    // 1 = keep the ESP32's per-(channel,note) owner table so a Note Off
    // carries the instrument captured at Note On.  The FPGA's
    // local_instrument_mapper already keeps that ownership (and KEY1 owns the
    // timbre), so the integrated default is 0 and the table is not built.
    parameter integer TRACK_OWNER = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [31:0] in_packet,   // {data1, data0, status, cable/CIN}

    output reg         out_valid,
    input  wire        out_ready,
    output reg  [63:0] out_event,

    output reg  [31:0] ignored_packets,
    output reg  [31:0] unsupported_messages,
    output reg  [31:0] knob_events,
    output reg  [31:0] pad_events
);

    localparam [3:0] CMD_NOTE_OFF = 4'h8;
    localparam [3:0] CMD_NOTE_ON  = 4'h9;
    localparam [3:0] CMD_POLY     = 4'hA;
    localparam [3:0] CMD_CC       = 4'hB;
    localparam [3:0] CMD_PROGRAM  = 4'hC;
    localparam [3:0] CMD_CHAN_PRS = 4'hD;
    localparam [3:0] CMD_BEND     = 4'hE;

    wire [3:0] cable  = in_packet[7:4];
    reg [7:0] seq;
    integer i, j;
    wire [3:0] cin    = in_packet[3:0];
    wire [3:0] cmd    = in_packet[15:12];
    wire [3:0] chan   = in_packet[11:8];
    wire [7:0] d0b    = in_packet[23:16] & 8'h7F;
    wire [7:0] d1b    = in_packet[31:24] & 8'h7F;
    wire [6:0] d0     = d0b[6:0];
    wire [6:0] d1     = d1b[6:0];
    // Channel-voice USB-MIDI packets carry CIN == command nibble, and both
    // data bytes must be 7-bit (bit 7 clear).
    wire       data_ok  = (in_packet[31:24] < 8'h80) && (in_packet[23:16] < 8'h80);
    wire       status_ok = in_packet[15] && (cmd != 4'hF) && (cin == cmd) && data_ok;
    // CC20..CC27 map to knob slots 0..7.
    wire [2:0] knob_sel = d0[2:0] - 3'd4;

    // Per-channel program and per-(channel,note) owner instrument.
    // owner: 0 = free, 1 = piano, 2 = organ (instrument+1).
    reg [6:0]  program [0:15];
    reg [1:0]  owner   [0:15][0:127];
    reg [7:0]  last_knob [0:7];   // CC20..CC27

    wire [3:0] prog_inst = (program[chan] >= 7'd32 && program[chan] <= 7'd39) ? 4'd1 : 4'd0;
    wire [3:0] instr_now = (chan == 4'd9) ? 4'd2 : prog_inst;   // channel 10 pads are drums
    wire [1:0] owner_now = (TRACK_OWNER != 0) ? owner[chan][d0] : 2'd0;

    // ---- exact ESP32 7-bit / 14-bit scaling, without a divider/ROM ----
    // scale7(v) = round(v*65535/127) = 516*v + floor((3v+63)/127)
    wire [16:0] s7_base = ({10'd0, d1} << 9) + ({10'd0, d1} << 2);
    wire [15:0] s7 = s7_base[15:0] +
                     {15'd0, (d1 >= 7'd22)} +
                     {15'd0, (d1 >= 7'd64)} +
                     {15'd0, (d1 >= 7'd106)};
    // Channel Pressure carries its value in data0 instead of data1.
    wire [16:0] s7d0_base = ({10'd0, d0} << 9) + ({10'd0, d0} << 2);
    wire [15:0] s7d0 = s7d0_base[15:0] +
                       {15'd0, (d0 >= 7'd22)} +
                       {15'd0, (d0 >= 7'd64)} +
                       {15'd0, (d0 >= 7'd106)};
    // scale14(v) = round(v*65535/16383) = 4*v + floor((3v+8191)/16383)
    wire [13:0] b14 = {d1, d0};
    wire [15:0] s14 = {b14, 2'b00} +
                      {15'd0, (b14 >= 14'd2731)} +
                      {15'd0, (b14 >= 14'd8192)} +
                      {15'd0, (b14 >= 14'd13653)};

    // ---- combinational decode ----
    reg        emit;
    reg  [5:0] ev_type;
    reg  [3:0] ev_flags;
    reg  [7:0] ev_id;
    reg  [15:0] ev_value;
    reg  [7:0] ev_aux;

    reg        set_owner, clear_owner, set_prog, set_knob, all_off;
    reg  [6:0] new_prog;
    reg  [2:0] knob_idx;
    reg  [7:0] knob_val;
    reg        knob_dup;
    reg        is_pad;

    always @(*) begin
        emit = 1'b0; ev_type = `CE64_TYPE_NOP; ev_flags = 4'd0;
        ev_id = 8'd0; ev_value = 16'd0; ev_aux = 8'd0;
        set_owner = 1'b0; clear_owner = 1'b0; set_prog = 1'b0;
        set_knob = 1'b0; all_off = 1'b0; new_prog = 7'd0;
        knob_idx = 3'd0; knob_val = 8'd0; knob_dup = 1'b0; is_pad = 1'b0;

        if (in_valid && in_ready && cable == CABLE_ACCEPT && status_ok) begin
            case (cmd)
                CMD_NOTE_ON: begin
                    if (chan == 4'd9) is_pad = 1'b1;
                    if (d1 == 7'd0) begin
                        // Velocity-0 Note On is a Note Off (MIDI convention).
                        ev_type  = `CE64_TYPE_NOTE_OFF;
                        ev_id    = {1'b0, d0};
                        ev_value = 16'd0;
                        clear_owner = 1'b1;
                        emit = 1'b1;
                    end else begin
                        ev_type  = `CE64_TYPE_NOTE_ON;
                        ev_id    = {1'b0, d0};
                        ev_value = s7;
                        set_owner = 1'b1;
                        emit = 1'b1;
                    end
                end

                CMD_NOTE_OFF: begin
                    if (chan == 4'd9) is_pad = 1'b1;
                    ev_type  = `CE64_TYPE_NOTE_OFF;
                    ev_id    = {1'b0, d0};
                    ev_value = s7;
                    clear_owner = 1'b1;
                    emit = 1'b1;
                end

                CMD_POLY: begin
                    ev_type  = `CE64_TYPE_PRESSURE;
                    ev_flags = (4'd1 << `CE64_FLAG_PER_NOTE);
                    ev_id    = {1'b0, d0};
                    ev_value = s7;
                    emit = 1'b1;
                end

                CMD_CC: begin
                    case (d0)
                        7'd1: begin
                            ev_type = `CE64_TYPE_MODULATION; ev_id = 8'd1;
                            ev_value = s7; emit = 1'b1;
                        end
                        7'd64: begin
                            ev_type = `CE64_TYPE_SUSTAIN; ev_id = 8'd64;
                            ev_value = s7; emit = 1'b1;
                        end
                        7'd20, 7'd21, 7'd22, 7'd23,
                        7'd24, 7'd25, 7'd26, 7'd27: begin
                            knob_idx = knob_sel;
                            knob_val = d1b;
                            knob_dup = (last_knob[knob_sel] == d1b);
                            if (!knob_dup) begin
                                set_knob = 1'b1;
                                emit = 1'b1;
                                case (d0)
                                    7'd20: begin ev_type = `CE64_TYPE_EFFECT_CTRL; ev_aux = 8'd4; end
                                    7'd21: begin ev_type = `CE64_TYPE_EFFECT_CTRL; ev_aux = 8'd5; end
                                    7'd22: begin ev_type = `CE64_TYPE_EFFECT_CTRL; ev_aux = 8'd1; end
                                    7'd23: begin ev_type = `CE64_TYPE_EFFECT_CTRL; ev_aux = 8'd2; end
                                    7'd24: begin ev_type = `CE64_TYPE_EFFECT_CTRL; ev_aux = 8'd3; end
                                    7'd25: begin ev_type = `CE64_TYPE_PARAM_CTRL;  ev_id  = 8'd0; end
                                    7'd26: begin ev_type = `CE64_TYPE_PARAM_CTRL;  ev_id  = 8'd1; end
                                    default: begin ev_type = `CE64_TYPE_PARAM_CTRL; ev_id = 8'd2; end
                                endcase
                                ev_value = s7;
                            end
                        end
                        7'd120, 7'd123: begin
                            ev_type = `CE64_TYPE_ALL_NOTES_OFF;
                            all_off = 1'b1;
                            emit = 1'b1;
                        end
                        default: ;
                    endcase
                end

                CMD_PROGRAM: begin
                    new_prog = d0;
                    set_prog = 1'b1;
                    ev_type  = `CE64_TYPE_PROGRAM;
                    ev_id    = {1'b0, d0};
                    ev_value = 16'd0;
                    emit = 1'b1;
                end

                CMD_CHAN_PRS: begin
                    ev_type  = `CE64_TYPE_PRESSURE;
                    ev_id    = 8'd0;
                    ev_value = s7d0;
                    emit = 1'b1;
                end

                CMD_BEND: begin
                    ev_type  = `CE64_TYPE_PITCH_BEND;
                    ev_id    = 8'd0;
                    ev_value = s14;
                    emit = 1'b1;
                end

                default: ;   // 0xF and undefined commands are ignored
            endcase
        end
    end

    // Instrument carried by the event: a Program Change uses the new program;
    // a Note Off uses the Note-On owner; everything else uses the current one.
    wire [3:0] prog_inst_new = (d0 >= 7'd32 && d0 <= 7'd39) ? 4'd1 : 4'd0;
    wire [3:0] ev_inst = (cmd == CMD_PROGRAM) ? prog_inst_new :
                         ((cmd == CMD_NOTE_OFF ||
                           (cmd == CMD_NOTE_ON && d1 == 7'd0))
                          ? ((owner_now != 2'd0) ? {2'b00, owner_now - 2'd1} : instr_now)
                          : instr_now);

    wire [63:0] ev_word = {
        2'b01, ev_type, SOURCE, chan, ev_inst, ev_flags,
        ev_id, ev_value, ev_aux, seq
    };

    wire accept = in_valid && in_ready;
    wire valid_packet = accept && cable == CABLE_ACCEPT && status_ok;

    assign in_ready = !out_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_event <= 64'd0;
            seq <= SEQ_START[7:0];
            ignored_packets <= 32'd0;
            unsupported_messages <= 32'd0;
            knob_events <= 32'd0;
            pad_events <= 32'd0;
            for (i = 0; i < 16; i = i + 1) begin
                program[i] <= 7'd0;
                for (j = 0; j < 128; j = j + 1)
                    owner[i][j] <= 2'd0;
            end
            for (i = 0; i < 8; i = i + 1)
                last_knob[i] <= 8'hFF;
        end else begin
            if (out_valid && out_ready)
                out_valid <= 1'b0;

            if (accept) begin
                // Side effects happen once per accepted packet, whether or
                // not it produced an event.
                if (set_owner && TRACK_OWNER != 0)
                    owner[chan][d0] <= instr_now[1:0] + 2'd1;
                if (clear_owner && TRACK_OWNER != 0)
                    owner[chan][d0] <= 2'd0;
                if (set_prog) program[chan] <= new_prog;
                if (set_knob) last_knob[knob_idx] <= knob_val;
                if (all_off && TRACK_OWNER != 0)
                    for (i = 0; i < 16; i = i + 1)
                        for (j = 0; j < 128; j = j + 1)
                            owner[i][j] <= 2'd0;

                if (!valid_packet)
                    ignored_packets <= ignored_packets + 32'd1;
                else if (!emit)
                    unsupported_messages <= unsupported_messages + 32'd1;

                if (emit) begin
                    out_event <= ev_word;
                    out_valid <= 1'b1;
                    seq <= seq + 8'd1;
                    if (set_knob) knob_events <= knob_events + 32'd1;
                    if (is_pad)   pad_events  <= pad_events + 32'd1;
                end
            end
        end
    end

endmodule

