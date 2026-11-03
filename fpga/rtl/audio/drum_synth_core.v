/*
 * 8-voice synthesized drum engine.
 *
 * One-shot percussion voices, time-multiplexed over the 1024-cycle sample
 * period. Each voice has its own phase accumulator, pitch sweep, envelope,
 * noise LFSR and one-pole filter state. The shared datapath reads one small
 * sine ROM and one multiplier per voice slot.
 *
 * Drum types (selected from the MIDI note):
 *   0 kick, 1 snare, 2 closed hat, 3 open hat,
 *   4 low tom, 5 mid tom, 6 high tom, 7 clap.
 * Notes 36..43 map directly to types 0..7; other notes use note[2:0].
 */
`timescale 1ns / 1ps

module drum_synth_core #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer SAMPLE_RATE_HZ = 48_828,
    parameter integer SAMPLE_PERIOD_CYCLES = 1024,
    parameter integer VOICES = 8,
    parameter integer PCM_WIDTH = 24,
    parameter integer COUNT_WIDTH = 32,
    parameter SINE_FILE = "src/drum_sine_rom.mem"
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         event_valid,
    output wire                         event_ready,
    input  wire                         event_note_on,
    input  wire [6:0]                   event_note,
    input  wire [6:0]                   event_velocity,
    input  wire [3:0]                   event_channel,
    output reg  signed [PCM_WIDTH-1:0]  audio_sample,
    output reg                          audio_valid,
    output reg  [31:0]                  active_voice_count,
    output reg  [31:0]                  deadline_miss_count
);
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_LOAD = 2'd1;
    localparam [1:0] S_MAC  = 2'd2;
    localparam [1:0] S_OUT  = 2'd3;

    localparam integer MIX_WIDTH = PCM_WIDTH + 4;

    reg [1:0] state;
    localparam integer INDEX_WIDTH = (VOICES <= 1) ? 1 : $clog2(VOICES);
    reg [INDEX_WIDTH-1:0] voice_idx;
    reg signed [MIX_WIDTH-1:0] mix_acc;

    reg [VOICES-1:0] voice_active;
    reg [2:0] voice_type [0:VOICES-1];
    reg [23:0] voice_phase [0:VOICES-1];
    reg [23:0] voice_pitch_inc [0:VOICES-1];
    reg [15:0] voice_env [0:VOICES-1];
    reg signed [15:0] voice_noise [0:VOICES-1];
    reg signed [15:0] voice_lp [0:VOICES-1];

    // Work registers for the current voice slot.
    reg work_active;
    reg [2:0] work_type;
    reg [23:0] work_phase;
    reg [23:0] work_pitch_inc;
    reg [15:0] work_env;
    reg signed [15:0] work_noise;
    reg signed [15:0] work_lp;

    // Pending event slot.
    reg pending_valid;
    reg [6:0] pending_note;
    reg [6:0] pending_velocity;

    wire sample_tick;
    sample_tick_gen #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),
        .SAMPLE_PERIOD_CYCLES(SAMPLE_PERIOD_CYCLES)
    ) sample_clock (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick)
    );

    reg signed [15:0] sine_rom [0:255];
    initial $readmemh(SINE_FILE, sine_rom);

    assign event_ready = !pending_valid;

    function [2:0] drum_type_for_note;
        input [6:0] note;
        begin
            case (note)
                7'd36: drum_type_for_note = 3'd0;
                7'd37: drum_type_for_note = 3'd1;
                7'd38: drum_type_for_note = 3'd2;
                7'd39: drum_type_for_note = 3'd3;
                7'd40: drum_type_for_note = 3'd4;
                7'd41: drum_type_for_note = 3'd5;
                7'd42: drum_type_for_note = 3'd6;
                7'd43: drum_type_for_note = 3'd7;
                default: drum_type_for_note = note[2:0];
            endcase
        end
    endfunction

    // 24-bit phase increment for the base pitch (48.828 kHz).
    function [23:0] base_inc;
        input [2:0] t;
        begin
            case (t)
                3'd0: base_inc = 24'd17179; // kick ~50 Hz
                3'd1: base_inc = 24'd65280; // snare tone ~190 Hz
                3'd2: base_inc = 24'd0;
                3'd3: base_inc = 24'd0;
                3'd4: base_inc = 24'd27486; // low tom ~80 Hz
                3'd5: base_inc = 24'd37794; // mid tom ~110 Hz
                3'd6: base_inc = 24'd48101; // high tom ~140 Hz
                default: base_inc = 24'd0;
            endcase
        end
    endfunction

    function [23:0] pitch_init;
        input [2:0] t;
        begin
            case (t)
                3'd0: pitch_init = 24'd50000; // kick sweep
                3'd4: pitch_init = 24'd30000;
                3'd5: pitch_init = 24'd25000;
                3'd6: pitch_init = 24'd20000;
                default: pitch_init = 24'd0;
            endcase
        end
    endfunction

    function [3:0] decay_shift;
        input [2:0] t;
        begin
            case (t)
                3'd0: decay_shift = 4'd12;
                3'd1: decay_shift = 4'd10;
                3'd2: decay_shift = 4'd7;
                3'd3: decay_shift = 4'd10;
                3'd4: decay_shift = 4'd11;
                3'd5: decay_shift = 4'd11;
                3'd6: decay_shift = 4'd11;
                default: decay_shift = 4'd9;
            endcase
        end
    endfunction

    function [2:0] filter_shift;
        input [2:0] t;
        begin
            case (t)
                3'd1: filter_shift = 3'd4; // snare
                3'd2: filter_shift = 3'd3; // closed hat
                3'd3: filter_shift = 3'd3; // open hat
                3'd7: filter_shift = 3'd5; // clap
                default: filter_shift = 3'd4;
            endcase
        end
    endfunction

    function signed [PCM_WIDTH-1:0] saturate;
        input signed [MIX_WIDTH-1:0] value;
        localparam signed [PCM_WIDTH-1:0] MAXV = {1'b0, {(PCM_WIDTH-1){1'b1}}};
        localparam signed [PCM_WIDTH-1:0] MINV = {1'b1, {(PCM_WIDTH-1){1'b0}}};
        begin
            if (value > MAXV)
                saturate = MAXV;
            else if (value < MINV)
                saturate = MINV;
            else
                saturate = value[PCM_WIDTH-1:0];
        end
    endfunction

    // Combinational voice allocation: first inactive slot, otherwise steal 0.
    reg [INDEX_WIDTH-1:0] alloc_idx;
    reg alloc_found;
    integer ai;
    always @* begin
        alloc_found = 1'b0;
        alloc_idx = 3'd0;
        for (ai = 0; ai < VOICES; ai = ai + 1) begin
            if (!voice_active[ai] && !alloc_found) begin
                alloc_found = 1'b1;
                alloc_idx = ai[INDEX_WIDTH-1:0];
            end
        end
    end

    wire signed [15:0] sine = sine_rom[work_phase[23:16]];
    wire signed [15:0] hp = work_noise - work_lp;
    wire [15:0] lp_next = work_lp + ((work_noise - work_lp) >>> filter_shift(work_type));
    wire [15:0] noise_next = {work_noise[14:0],
                              work_noise[15] ^ work_noise[13] ^
                              work_noise[12] ^ work_noise[10]};
    wire [23:0] inc_eff = base_inc(work_type) + work_pitch_inc;
    wire [23:0] phase_next = work_phase + inc_eff;
    wire [23:0] pitch_next = (work_pitch_inc > (work_pitch_inc >> 5)) ?
                             work_pitch_inc - (work_pitch_inc >> 5) : 24'd0;
    wire [15:0] env_dec = (work_env >> decay_shift(work_type)) + 1'b1;
    wire [15:0] env_next = (work_env > env_dec) ? work_env - env_dec : 16'd0;

    wire signed [15:0] voice_sig =
        (work_type == 3'd0 || work_type == 3'd4 ||
         work_type == 3'd5 || work_type == 3'd6) ? sine :
        (work_type == 3'd1) ? ((sine >>> 1) + (hp >>> 1)) :
        (work_type == 3'd2 || work_type == 3'd3) ? hp :
        work_noise;
    wire signed [32:0] product = voice_sig * $signed({1'b0, work_env});
    wire signed [MIX_WIDTH-1:0] scaled = product >>> 16;

    // Active voice count, combinational.
    reg [31:0] active_comb;
    integer ci;
    always @* begin
        active_comb = 32'd0;
        for (ci = 0; ci < VOICES; ci = ci + 1)
            active_comb = active_comb + {31'd0, voice_active[ci]};
    end

    integer ri;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            voice_idx <= 3'd0;
            mix_acc <= {MIX_WIDTH{1'b0}};
            pending_valid <= 1'b0;
            pending_note <= 7'd0;
            pending_velocity <= 7'd0;
            work_active <= 1'b0;
            work_type <= 3'd0;
            work_phase <= 24'd0;
            work_pitch_inc <= 24'd0;
            work_env <= 16'd0;
            work_noise <= 16'd0;
            work_lp <= 16'd0;
            audio_sample <= {PCM_WIDTH{1'b0}};
            audio_valid <= 1'b0;
            active_voice_count <= 32'd0;
            deadline_miss_count <= 32'd0;
            voice_active <= {VOICES{1'b0}};
            for (ri = 0; ri < VOICES; ri = ri + 1) begin
                voice_type[ri] <= 3'd0;
                voice_phase[ri] <= 24'd0;
                voice_pitch_inc[ri] <= 24'd0;
                voice_env[ri] <= 16'd0;
                voice_noise[ri] <= 16'd0;
                voice_lp[ri] <= 16'd0;
            end
        end else begin
            audio_valid <= 1'b0;

            if (event_valid && event_ready && event_note_on && event_velocity != 0) begin
                pending_valid <= 1'b1;
                pending_note <= event_note;
                pending_velocity <= event_velocity;
            end

            if (sample_tick && state != S_IDLE)
                deadline_miss_count <= deadline_miss_count + 1'b1;

            case (state)
                S_IDLE: begin
                    if (pending_valid) begin
                        voice_active[alloc_idx] <= 1'b1;
                        voice_type[alloc_idx] <= drum_type_for_note(pending_note);
                        voice_phase[alloc_idx] <= 24'd0;
                        voice_pitch_inc[alloc_idx] <= pitch_init(drum_type_for_note(pending_note));
                        voice_env[alloc_idx] <= {pending_velocity, 9'b0};
                        voice_noise[alloc_idx] <= 16'hace1 ^ alloc_idx;
                        voice_lp[alloc_idx] <= 16'd0;
                        pending_valid <= 1'b0;
                    end
                    if (sample_tick) begin
                        mix_acc <= {MIX_WIDTH{1'b0}};
                        voice_idx <= 3'd0;
                        state <= S_LOAD;
                    end
                end
                S_LOAD: begin
                    work_active <= voice_active[voice_idx];
                    work_type <= voice_type[voice_idx];
                    work_phase <= voice_phase[voice_idx];
                    work_pitch_inc <= voice_pitch_inc[voice_idx];
                    work_env <= voice_env[voice_idx];
                    work_noise <= voice_noise[voice_idx];
                    work_lp <= voice_lp[voice_idx];
                    state <= S_MAC;
                end
                S_MAC: begin
                    if (work_active) begin
                        mix_acc <= mix_acc + scaled;
                        voice_phase[voice_idx] <= phase_next;
                        voice_pitch_inc[voice_idx] <= pitch_next;
                        voice_env[voice_idx] <= env_next;
                        voice_noise[voice_idx] <= noise_next;
                        voice_lp[voice_idx] <= lp_next;
                        voice_active[voice_idx] <= (env_next != 0);
                    end
                    if (voice_idx == VOICES - 1)
                        state <= S_OUT;
                    else begin
                        voice_idx <= voice_idx + 1'b1;
                        state <= S_LOAD;
                    end
                end
                S_OUT: begin
                    audio_sample <= saturate(mix_acc);
                    audio_valid <= 1'b1;
                    active_voice_count <= active_comb;
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule
