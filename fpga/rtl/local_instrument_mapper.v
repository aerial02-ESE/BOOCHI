`timescale 1ns / 1ps
`include "src/control_event64_defs.vh"

// Source 0 = ESP32 SMK-25, 1 = direct USB0 88-key, 2 = ESP32 BLE phone.
// KEY1 selects unified piano/organ/drum, or source-assigned mode 3. Note Off keeps the instrument
// captured by Note On, including when KEY1 changed while a key was held.
// Three sources x 16 channels have separate key/owner bits at each pitch.
// The owner is two bits per source/channel slot: piano=0, bass/organ=1, drum=2.
module local_instrument_mapper #(
    parameter [3:0] SMK25_SOURCE = 4'd0,
    parameter [3:0] KEYBED_SOURCE = 4'd1,
    parameter [3:0] PHONE_SOURCE = 4'd2,
    parameter [3:0] SCORE_SOURCE = 4'd3
) (
    input wire clk,
    input wire rst_n,
    input wire panic,
    input wire [3:0] mode,
    input wire in_valid,
    output wire in_ready,
    input wire [63:0] in_data,
    output wire out_valid,
    input wire out_ready,
    output wire [63:0] out_data,
    output reg [127:0] pressed_notes,
    output reg [127:0] human_pressed_notes,
    // Physical USB88 keys A0..D3, independent of SMK25/phone/score/sustain.
    output wire [29:0] usb88_low_pressed,
    output reg [87:0] usb88_pressed,
    output wire [3:0] display_mode
);
    localparam CLEAR=0, IDLE=1, READ=2, MAP=3, RETRIGGER=4, SEND=5, READ_WAIT=6;
    assign usb88_low_pressed=usb88_pressed[29:0];
    reg [2:0] state;
    reg [6:0] clear_note;
    reg clear_mapping;
    reg [63:0] down_ram [0:127];
    reg [3:0] owner_ram [0:8191];
    reg [3:0] owner_read;
    reg [12:0] owner_read_address;
    // Direct USB keyboard mapping is changed by the phone via ESP32/UART.
    // Keep the destination captured at Note On so a later map edit cannot
    // strand a held note when its physical key is released.
    reg [6:0] keybed_map_ram [0:127];
    reg [6:0] keybed_active_ram [0:127];
    reg [6:0] map_read, active_read;
    reg [63:0] down_read;
    reg [63:0] down_next;
    reg [63:0] pending, mapped, release_event;
    reg [3:0] chosen_mode;
    reg chosen_split;
    reg app_active, app_split;
    reg [3:0] app_mode;
    assign display_mode = app_active ? app_mode : mode;
    reg update_note, clear_after_send;
    wire [6:0] note = pending[38:32];
    wire [5:0] owner_slot = {pending[53:52], pending[51:48]};
    wire [63:0] slot_mask = 64'h1 << owner_slot;
    wire [5:0] kind = pending[61:56];
    wire is_on = kind == `CE64_TYPE_NOTE_ON && pending[31:16] != 0;
    wire is_off = kind == `CE64_TYPE_NOTE_OFF ||
                  (kind == `CE64_TYPE_NOTE_ON && pending[31:16] == 0);
    wire [3:0] event_source = pending[55:52];
    wire keybed_note = event_source == KEYBED_SOURCE;
    wire [6:0] output_note = keybed_note ? (is_off ? active_read : map_read) : note;
    wire keybed_map_command = kind == `CE64_TYPE_PARAM_CTRL &&
                               event_source == PHONE_SOURCE && pending[39] &&
                               pending[15:8] == 8'd1 && pending[31:16] <= 16'd127;
    wire timbre_command = kind == `CE64_TYPE_PARAM_CTRL &&
                          pending[55:48] == 8'h2f && pending[39:32] == 8'h20 &&
                          pending[31:16] <= 16'd11 &&
                          (pending[15:8] == 0 ||
                           (pending[15:8] == 1 && pending[31:16] != 16'd3));
    // The audio engine has 16 channel slots. Reserve channel 14 for the
    // directly attached 88-key device and 15 for the phone; SMK-25 normally
    // uses channel 0 for keys and 9 for pads. The owner RAM above retains the
    // full source/channel pair even though the synth sees the reserved slot.
    wire [3:0] synth_channel = (event_source == KEYBED_SOURCE) ? 4'd14 :
                               (event_source == PHONE_SOURCE) ? 4'd15 :
                               pending[51:48];
    wire valid_note = (event_source == SMK25_SOURCE ||
                       event_source == KEYBED_SOURCE ||
                       event_source == PHONE_SOURCE ||
                       event_source == SCORE_SOURCE) && !pending[39];
    // SMK-25 pads: zero-based channel 9 (MIDI channel 10), notes 36..43.
    // They are always drums, independent of the KEY1 mode. Only the SMK-25
    // source can be a pad; other live sources follow KEY1.
    wire is_pad_on = is_on && event_source == SMK25_SOURCE &&
                     pending[51:48] == 4'd9 && note >= 7'd36 && note <= 7'd43;
    // Mode 3 reproduces project 14: SMK25 keys=organ, USB88/phone=piano.
    // Never forward the UI mode number 3 as an unsupported instrument ID.
    wire [3:0] assigned_mode = (event_source == SMK25_SOURCE) ? 2'd1 : 2'd0;
    wire [3:0] live_mode = (chosen_mode == 4'd3) ? assigned_mode : ((chosen_mode >= 4) ? chosen_mode - 1'b1 : chosen_mode);
    wire [3:0] effective_mode = is_pad_on ? 2'd2 :
                                (event_source == SCORE_SOURCE ? pending[47:44] :
                                 (chosen_split && note < 7'd72 ? 4'd0 : live_mode));
    wire [3:0] owner_mode_read = owner_read;
    wire accepted = out_valid && out_ready;

    assign in_ready = state == IDLE && !panic;
    assign out_valid = (state == SEND || state == RETRIGGER) && !panic;
    assign out_data = state == RETRIGGER ? release_event : mapped;

    // Synchronous read/write, no asynchronous reset on the memory arrays.
    always @(posedge clk) begin
        down_read <= down_ram[note];
        // Independent registered read address infers semi-dual-port RAM.
        // READ_WAIT accounts for its extra address register. This avoids the
        // unsupported SP read-before-write mode in Gowin 1.9.12.03 for GW5AT.
        owner_read_address <= {note,owner_slot};
        owner_read <= owner_ram[owner_read_address];
        map_read <= keybed_map_ram[note];
        active_read <= keybed_active_ram[note];
        if (state == CLEAR) begin
            down_ram[clear_note] <= 0;
            // A panic clears active keys but keeps the user's mapping.
            if (clear_mapping) keybed_map_ram[clear_note] <= clear_note;
        end else if (state == MAP && keybed_map_command) begin
            keybed_map_ram[note] <= pending[22:16];
        end else if (state == SEND && accepted && update_note) begin
            down_ram[note] <= down_next;
            owner_ram[{note,owner_slot}] <= is_on ? effective_mode : 4'd0;
            if (keybed_note && is_on) keybed_active_ram[note] <= map_read;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= CLEAR;
            clear_note <= 0;
            clear_mapping <= 1'b1;
            pressed_notes <= 0;
            human_pressed_notes <= 0;
            usb88_pressed <= 0;
            pending <= 0;
            mapped <= 0;
            release_event <= 0;
            chosen_mode <= 0;
            chosen_split <= 0;
            app_active <= 0;
            app_split <= 0;
            app_mode <= 0;
            down_next <= 0;
            update_note <= 0;
            clear_after_send <= 0;
        end else if (panic) begin
            state <= CLEAR;
            clear_note <= 0;
            clear_mapping <= 1'b0;
            pressed_notes <= 0;
            human_pressed_notes <= 0;
            usb88_pressed <= 0;
            update_note <= 0;
            clear_after_send <= 0;
        end else begin
            case (state)
                CLEAR: begin
                    if (clear_note == 127) begin
                        state <= IDLE;
                        clear_mapping <= 1'b0;
                    end else
                        clear_note <= clear_note + 1'b1;
                end
                IDLE: if (in_valid) begin
                    pending <= in_data;
                    chosen_mode <= app_active && (!app_split || in_data[55:52] == KEYBED_SOURCE)
                                   ? app_mode : mode;
                    chosen_split <= app_active && app_split && in_data[55:52] == KEYBED_SOURCE;
                    update_note <= 0;
                    clear_after_send <= 0;
                    state <= READ;
                end
                READ: state <= READ_WAIT;
                READ_WAIT: state <= MAP;
                MAP: begin
                    mapped <= pending;
                    mapped[51:48] <= synth_channel;
                    mapped[39:32] <= {1'b0, output_note};
                    state <= SEND;
                    if (timbre_command) begin
                        app_mode <= pending[19:16];
                        app_split <= pending[8];
                        app_active <= 1;
                        state <= IDLE;
                    end else if (keybed_map_command) begin
                        state <= IDLE;
                    end else if (is_on || is_off) begin
                        if (!valid_note) begin
                            state <= IDLE;
                        end else if (is_on) begin
                            mapped[47:44] <= effective_mode;
                            down_next <= down_read | slot_mask;
                            update_note <= 1;
                            // Repeated On after a local timbre change releases
                            // the previous engine before starting the new one.
                            if (down_read[owner_slot] &&
                                (owner_mode_read != effective_mode ||
                                 (keybed_note && active_read != map_read))) begin
                                release_event <= pending;
                                release_event[61:56] <= `CE64_TYPE_NOTE_OFF;
                                release_event[51:48] <= synth_channel;
                                release_event[47:44] <= owner_mode_read;
                                release_event[39:32] <= {1'b0, keybed_note ? active_read : note};
                                release_event[31:16] <= 0;
                                state <= RETRIGGER;
                            end
                        end else if (down_read[owner_slot]) begin
                            mapped[61:56] <= `CE64_TYPE_NOTE_OFF;
                            mapped[47:44] <= owner_mode_read;
                            down_next <= down_read & ~slot_mask;
                            update_note <= 1;
                        end else begin
                            state <= IDLE; // stale/unmatched Off
                        end
                    end else if (kind == `CE64_TYPE_PROGRAM) begin
                        state <= IDLE; // Timbre selection uses KEY1 or the explicit App command.
                    end else if (kind == `CE64_TYPE_ALL_NOTES_OFF) begin
                        clear_after_send <= 1;
                    end
                end
                RETRIGGER: if (accepted) state <= SEND;
                SEND: if (accepted) begin
                    if (update_note) begin
                        pressed_notes[note] <= |down_next;
                        human_pressed_notes[note] <= |down_next[47:0];
                        if (keybed_note && note >= 21 && note <= 108)
                            usb88_pressed[note-21] <= |down_next[31:16];
                    end
                    if (clear_after_send) begin
                        pressed_notes <= 0;
                        human_pressed_notes <= 0;
                        usb88_pressed <= 0;
                        clear_note <= 0;
                        state <= CLEAR;
                    end else
                        state <= IDLE;
                end
                default: begin state <= CLEAR; clear_note <= 0; end
            endcase
        end
    end
endmodule
