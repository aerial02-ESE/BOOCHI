/*
 * 16-channel sustain processor with ready/valid output semantics.
 * GLOBAL_SUSTAIN shares one pedal across all channels while keeping note
 * ownership separate. Pedal-up scans every channel and releases only keys
 * that have already been lifted.
 * Key/deferred state is stored as 128 note rows x 16 channels so the arrays
 * can infer synchronous RAM instead of asynchronously-reset flip-flops.
 */
module sustain_event_processor_multi #(
    parameter integer FULL_SUSTAIN_THRESHOLD = 64,
    parameter integer GLOBAL_SUSTAIN = 0
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       panic,
    input  wire       input_valid,
    output wire       input_ready,
    input  wire       input_note_on,
    input  wire [3:0] input_channel,
    input  wire [6:0] input_note,
    input  wire [6:0] input_velocity,
    input  wire       sustain_valid,
    output wire       sustain_ready,
    input  wire [3:0] sustain_channel,
    input  wire [6:0] sustain_position,
    output reg        output_valid,
    input  wire       output_ready,
    output reg        output_note_on,
    output reg  [3:0] output_channel,
    output reg  [6:0] output_note,
    output reg  [6:0] output_velocity
);
    localparam [3:0] ST_CLEAR         = 4'd0;
    localparam [3:0] ST_IDLE          = 4'd1;
    localparam [3:0] ST_NOTE_READ     = 4'd2;
    localparam [3:0] ST_NOTE_APPLY    = 4'd3;
    localparam [3:0] ST_EMIT          = 4'd4;
    localparam [3:0] ST_RETRIGGER_OFF = 4'd5;
    localparam [3:0] ST_RETRIGGER_ON  = 4'd6;
    localparam [3:0] ST_SCAN_READ     = 4'd7;
    localparam [3:0] ST_SCAN_CHECK    = 4'd8;
    localparam [3:0] ST_SCAN_EMIT     = 4'd9;

    reg [3:0] state;
    reg [15:0] key_down [0:127];
    reg [15:0] deferred [0:127];
    reg [6:0] pedal [0:15];
    reg [6:0] clear_note;
    reg [3:0] scan_channel;
    reg [6:0] scan_note;
    reg [15:0] key_row;
    reg [15:0] deferred_row;
    reg pending_note_on;
    reg [3:0] pending_channel;
    reg [6:0] pending_note;
    reg [6:0] pending_velocity;
    reg [3:0] retrigger_channel;
    reg [6:0] retrigger_note;
    reg [6:0] retrigger_velocity;
    wire [15:0] pending_mask = 16'h0001 << pending_channel;
    wire [15:0] scan_mask = 16'h0001 << scan_channel;
    wire scan_last_channel = (GLOBAL_SUSTAIN == 0) || (scan_channel == 4'd15);
    wire scan_complete = (scan_note == 7'd127) && scan_last_channel;
    wire [6:0] previous_pedal = (GLOBAL_SUSTAIN != 0) ? pedal[0] : pedal[sustain_channel];

    assign input_ready = (state == ST_IDLE) && !sustain_valid;
    assign sustain_ready = (state == ST_IDLE);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || panic) begin
            state <= ST_CLEAR;
            output_valid <= 1'b0;
            output_note_on <= 1'b0;
            output_channel <= 4'd0;
            output_note <= 7'd0;
            output_velocity <= 7'd0;
            clear_note <= 7'd0;
            scan_channel <= 4'd0;
            scan_note <= 7'd0;
            key_row <= 16'd0;
            deferred_row <= 16'd0;
            pending_note_on <= 1'b0;
            pending_channel <= 4'd0;
            pending_note <= 7'd0;
            pending_velocity <= 7'd0;
            retrigger_channel <= 4'd0;
            retrigger_note <= 7'd0;
            retrigger_velocity <= 7'd0;
            for (i = 0; i < 16; i = i + 1)
                pedal[i] <= 7'd0;
        end else begin
            case (state)
                ST_CLEAR: begin
                    output_valid <= 1'b0;
                    key_down[clear_note] <= 16'd0;
                    deferred[clear_note] <= 16'd0;
                    if (clear_note == 7'd127) begin
                        clear_note <= 7'd0;
                        state <= ST_IDLE;
                    end else begin
                        clear_note <= clear_note + 1'b1;
                    end
                end

                ST_IDLE: begin
                    output_valid <= 1'b0;
                    if (sustain_valid) begin
                        if (GLOBAL_SUSTAIN != 0) begin
                            for (i = 0; i < 16; i = i + 1)
                                pedal[i] <= sustain_position;
                        end else begin
                            pedal[sustain_channel] <= sustain_position;
                        end
                        if (previous_pedal >= FULL_SUSTAIN_THRESHOLD &&
                            sustain_position < FULL_SUSTAIN_THRESHOLD) begin
                            scan_channel <= (GLOBAL_SUSTAIN != 0) ? 4'd0 : sustain_channel;
                            scan_note <= 7'd0;
                            state <= ST_SCAN_READ;
                        end
                    end else if (input_valid) begin
                        pending_note_on <= input_note_on;
                        pending_channel <= input_channel;
                        pending_note <= input_note;
                        pending_velocity <= input_velocity;
                        state <= ST_NOTE_READ;
                    end
                end

                ST_NOTE_READ: begin
                    key_row <= key_down[pending_note];
                    deferred_row <= deferred[pending_note];
                    state <= ST_NOTE_APPLY;
                end

                ST_NOTE_APPLY: begin
                    if (pending_note_on) begin
                        key_down[pending_note] <= key_row | pending_mask;
                        output_channel <= pending_channel;
                        output_note <= pending_note;
                        if (deferred_row[pending_channel]) begin
                            deferred[pending_note] <= deferred_row & ~pending_mask;
                            retrigger_channel <= pending_channel;
                            retrigger_note <= pending_note;
                            retrigger_velocity <= pending_velocity;
                            output_note_on <= 1'b0;
                            output_velocity <= 7'd0;
                            output_valid <= 1'b1;
                            state <= ST_RETRIGGER_OFF;
                        end else begin
                            output_note_on <= 1'b1;
                            output_velocity <= pending_velocity;
                            output_valid <= 1'b1;
                            state <= ST_EMIT;
                        end
                    end else begin
                        key_down[pending_note] <= key_row & ~pending_mask;
                        if (pedal[pending_channel] >= FULL_SUSTAIN_THRESHOLD) begin
                            deferred[pending_note] <= deferred_row | pending_mask;
                            state <= ST_IDLE;
                        end else begin
                            deferred[pending_note] <= deferred_row & ~pending_mask;
                            output_note_on <= 1'b0;
                            output_channel <= pending_channel;
                            output_note <= pending_note;
                            // The synth uses Off velocity as pedal position,
                            // not as the keyboard's MIDI release velocity.
                            output_velocity <= pedal[pending_channel];
                            output_valid <= 1'b1;
                            state <= ST_EMIT;
                        end
                    end
                end

                ST_EMIT: begin
                    if (output_valid && output_ready) begin
                        output_valid <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                ST_RETRIGGER_OFF: begin
                    if (output_valid && output_ready) begin
                        output_note_on <= 1'b1;
                        output_channel <= retrigger_channel;
                        output_note <= retrigger_note;
                        output_velocity <= retrigger_velocity;
                        output_valid <= 1'b1;
                        state <= ST_RETRIGGER_ON;
                    end
                end

                ST_RETRIGGER_ON: begin
                    if (output_valid && output_ready) begin
                        output_valid <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                ST_SCAN_READ: begin
                    key_row <= key_down[scan_note];
                    deferred_row <= deferred[scan_note];
                    state <= ST_SCAN_CHECK;
                end

                ST_SCAN_CHECK: begin
                    if (deferred_row[scan_channel] && !key_row[scan_channel]) begin
                        deferred[scan_note] <= deferred_row & ~scan_mask;
                        output_note_on <= 1'b0;
                        output_channel <= scan_channel;
                        output_note <= scan_note;
                        output_velocity <= pedal[scan_channel];
                        output_valid <= 1'b1;
                        state <= ST_SCAN_EMIT;
                    end else if (scan_complete) begin
                        state <= ST_IDLE;
                    end else begin
                        if (scan_last_channel) begin
                            scan_note <= scan_note + 1'b1;
                            if (GLOBAL_SUSTAIN != 0) scan_channel <= 4'd0;
                        end else begin
                            scan_channel <= scan_channel + 1'b1;
                        end
                        state <= ST_SCAN_READ;
                    end
                end

                ST_SCAN_EMIT: begin
                    if (output_valid && output_ready) begin
                        output_valid <= 1'b0;
                        if (scan_complete) begin
                            state <= ST_IDLE;
                        end else begin
                            if (scan_last_channel) begin
                                scan_note <= scan_note + 1'b1;
                                if (GLOBAL_SUSTAIN != 0) scan_channel <= 4'd0;
                            end else begin
                                scan_channel <= scan_channel + 1'b1;
                            end
                            state <= ST_SCAN_READ;
                        end
                    end
                end

                default: begin
                    state <= ST_CLEAR;
                    clear_note <= 7'd0;
                    output_valid <= 1'b0;
                end
            endcase
        end
    end
endmodule
