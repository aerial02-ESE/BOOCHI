/*
 * ESP32 ControlEvent -> FPGA 双音色合成 -> Delay -> PT8211 的无显示完整音频链。
 *
 * 事件只接受冻结的 64-bit ControlEvent。instrument=0/1 分别进入钢琴/贝斯；
 * SMK25 的 Sustain 默认统一控制所有钢琴/管风琴通道；其他来源的踏板消息被消费并忽略。
 * Pitch/Mod 仍按通道处理。ALL_NOTES_OFF 或链路超时会脉冲复位
 * 合成/包络/效果状态，防止控制器断开后卡音，PT8211 串行器保持连续运行。
 */
`include "src/control_event64_defs.vh"

module esp32_audio_engine #(
    parameter integer SYS_CLK_FREQ_HZ = 50_000_000,
    parameter integer AUDIO_CLK_FREQ_HZ = 50_000_000,
    parameter integer SAMPLE_RATE_HZ = 48_828,
    parameter integer SAMPLE_PERIOD_CYCLES = 1024,
    parameter integer BANK_VOICES = 32,
    parameter integer PIANO_VOICES = 32,
    parameter integer BASS_VOICES = 32,
    parameter integer DRUM_VOICES = 32,
    parameter integer PCM_WIDTH = 24,
    parameter integer CDC_DEPTH = 16,
    parameter integer COUNT_WIDTH = 32,
    parameter integer PT_BCLK_DIV = 16,
    // Full-scale 24-bit PCM maps to 16-bit DAC without an extra 12 dB gain.
    parameter integer PT_QUANT_SHIFT = 8,
    parameter integer DELAY_ENABLE = 0,
    parameter integer DELAY_SAMPLES = 3072,
    parameter [7:0] DELAY_WET_GAIN = 8'd16,
    parameter [7:0] DELAY_FB_GAIN = 8'd32,
    parameter [7:0] DRUM_GAIN = 8'hc0,
    // 鼓核输出是 16-bit 量级，钢琴/管风琴是 24-bit 量级；右移 5 位（原为 8）
    // 把单次鼓击抬到与单个钢琴音大致相同的峰值，否则鼓在混音里低约 18 dB。
    parameter integer DRUM_MIX_SHIFT = 5,
    parameter PIANO_PHASE_FILE = "src/note_phase_rom_48828.mem",
    parameter BASS_PHASE_FILE = "src/note_phase_rom_48828.mem",
    parameter PIANO_WAVE_FILE = "src/piano_refined_18bit.mem",
    parameter ORGAN_WAVE_FILE = "src/organ_waveform_rom.mem",
    parameter integer GLOBAL_SUSTAIN_ENABLE = 1,
    parameter [3:0] GLOBAL_SUSTAIN_SOURCE = 4'd0
) (
    input  wire                         sys_clk,
    input  wire                         audio_clk,
    input  wire                         rst_n,
    input  wire                         event_valid,
    output wire                         event_ready,
    input  wire [63:0]                  event_data,
    input  wire                         link_timeout_pulse,
    output wire                         pt_bck,
    output wire                         pt_ws,
    output wire                         pt_din,
    output wire                         pa_en,
    output wire [31:0]                  active_voice_count,
    output wire [31:0]                  deadline_miss_count,
    output wire [COUNT_WIDTH-1:0]       audio_overflow_count,
    output wire [COUNT_WIDTH-1:0]       audio_underflow_count,
    output wire [COUNT_WIDTH-1:0]       unknown_type_count,
    output wire [COUNT_WIDTH-1:0]       unknown_instrument_count,
    // Post-effect PCM tap for the local LCD visualizer. Existing users may
    // leave these ports unconnected; audio behaviour is unchanged.
    output wire                          visual_audio_valid,
    output wire signed [PCM_WIDTH-1:0]  visual_audio_sample,
    // Stereo post-effect tap for the TAS5805 I2S path. Existing users may
    // leave these unconnected; the PT8211 path is unchanged.
    output wire                          post_valid,
    output wire signed [PCM_WIDTH-1:0]  post_left,
    output wire signed [PCM_WIDTH-1:0]  post_right,
    // Knob/parameter feedback for the local LCD: one-cycle pulse, label 1=reverb,
    // 2=chorus, value 0..99.
    output reg                           ui_event,
    output reg  [1:0]                    ui_label,
    output reg  [6:0]                    ui_value
);
    wire router_piano_valid, router_piano_ready, router_piano_on;
    wire [6:0] router_piano_note, router_piano_velocity;
    wire [3:0] router_piano_channel;
    wire router_bass_valid, router_bass_ready, router_bass_on;
    wire [6:0] router_bass_note, router_bass_velocity;
    wire [3:0] router_bass_channel;
    wire router_drum_valid, router_drum_ready, router_drum_on;
    wire [6:0] router_drum_note, router_drum_velocity;
    wire [3:0] router_drum_channel;
    wire bank_valid, bank_ready, bank_on;
    wire [6:0] bank_note, bank_velocity;
    wire [3:0] bank_channel;
    wire [2:0] bank_patch;
    wire [3:0] bank_query_channel;
    wire [6:0] bank_query_note;
    wire [15:0] bank_pitch, bank_pressure;
    wire [7:0] bank_mod;
    wire signed [15:0] bank_bend;
    wire signed [PCM_WIDTH-1:0] bank_sample;
    wire bank_sample_valid;
    wire [31:0] bank_active, bank_deadline;
    wire expr_valid;
    wire [5:0] expr_type;
    wire [15:0] expr_value;
    wire [3:0] expr_instrument;
    wire [3:0] expr_source, expr_channel, expr_flags;
    wire [7:0] expr_id, expr_aux;
    wire expr_ready;
    wire expr_fire = expr_valid && expr_ready;
    // Source 0 is the SMK25 forwarded by ESP32. Only this source owns the
    // global pedal; another keyboard/app cannot cancel it with a local CC64.
    wire sustain_is_owner = (GLOBAL_SUSTAIN_ENABLE == 0) ||
                            (expr_source == GLOBAL_SUSTAIN_SOURCE);

    control_event_router #(.COUNT_WIDTH(COUNT_WIDTH)) router (
        .clk(sys_clk), .rst_n(rst_n),
        .in_valid(event_valid), .in_ready(event_ready), .in_event(event_data),
        .piano_valid(router_piano_valid), .piano_ready(router_piano_ready),
        .piano_note_on(router_piano_on), .piano_note(router_piano_note),
        .piano_velocity(router_piano_velocity), .piano_channel(router_piano_channel),
        .bass_valid(router_bass_valid), .bass_ready(router_bass_ready),
        .bass_note_on(router_bass_on), .bass_note(router_bass_note),
        .bass_velocity(router_bass_velocity), .bass_channel(router_bass_channel),
        .drum_valid(router_drum_valid), .drum_ready(router_drum_ready),
        .drum_note_on(router_drum_on), .drum_note(router_drum_note),
        .drum_velocity(router_drum_velocity), .drum_channel(router_drum_channel),
        .bank_valid(bank_valid), .bank_ready(bank_ready), .bank_note_on(bank_on),
        .bank_note(bank_note), .bank_velocity(bank_velocity), .bank_channel(bank_channel), .bank_patch(bank_patch),
        .expr_valid(expr_valid), .expr_ready(expr_ready),
        .expr_type(expr_type), .expr_value(expr_value),
        .expr_instrument(expr_instrument),
        .expr_source(expr_source), .expr_channel(expr_channel), .expr_flags(expr_flags),
        .expr_id(expr_id), .expr_aux(expr_aux),
        .unknown_type_count(unknown_type_count),
        .unknown_instrument_count(unknown_instrument_count)
    );

    reg panic_pulse;
    reg transport_playing;
    reg [31:0] transport_position;
    reg effect_bypass;
    reg [12:0] effect_delay_samples;
    reg [7:0] effect_feedback_gain;
    reg [7:0] effect_wet_gain;
    reg [15:0] piano_a, piano_d, piano_s, piano_r;
    reg [15:0] organ_a, organ_d, organ_s, organ_r;
    reg [7:0] master_gain;
    reg [7:0] piano_gain;
    reg [7:0] bass_gain;
    reg [7:0] chorus_wet;
    reg [7:0] reverb_wet;
    reg [6:0] pedal_position;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            panic_pulse <= 1'b0;
            transport_playing <= 1'b0;
            transport_position <= 32'd0;
            effect_bypass <= (DELAY_ENABLE == 0);
            effect_delay_samples <= DELAY_SAMPLES[12:0];
            effect_feedback_gain <= DELAY_FB_GAIN;
            effect_wet_gain <= DELAY_WET_GAIN;
            piano_a <= 16'd256; piano_d <= 16'd8; piano_s <= 16'd24576; piano_r <= 16'd8;
            organ_a <= 16'd256; organ_d <= 16'd16; organ_s <= 16'hffff; organ_r <= 16'd8;
            master_gain <= 8'hff;
            piano_gain <= 8'hff;
            bass_gain <= 8'hff;
            chorus_wet <= 8'h00;
            reverb_wet <= 8'h00;
            pedal_position <= 7'd0;
            ui_event <= 1'b0;
            ui_label <= 2'd0;
            ui_value <= 7'd0;
        end else begin
            panic_pulse <= link_timeout_pulse;
            ui_event <= 1'b0;
            if (expr_fire) begin
                case (expr_type)
                    `CE64_TYPE_ALL_NOTES_OFF: panic_pulse <= 1'b1;
                    `CE64_TYPE_SUSTAIN: if (sustain_is_owner)
                        pedal_position <= expr_value[15:9];
                    `CE64_TYPE_EFFECT_CTRL: if (expr_id == 8'd0) begin
                        case (expr_aux)
                            8'd0: effect_bypass <= (expr_value == 0);
                            8'd1: effect_delay_samples <= (expr_value[15:3] == 0) ? 13'd1 :
                                                                  expr_value[15:3];
                            // 反馈硬限到 0.75，避免面板/应用异常值把 Delay 推入自激。
                            8'd2: effect_feedback_gain <= (expr_value[15:8] > 8'd192) ?
                                                         8'd192 : expr_value[15:8];
                            8'd3: effect_wet_gain <= expr_value[15:8];
                            8'd4: begin
                                reverb_wet <= expr_value[15:8];
                                ui_label <= 2'd1;
                                ui_value <= (expr_value[15:8] * 100) >> 8;
                                ui_event <= 1'b1;
                            end
                            8'd5: begin
                                chorus_wet <= expr_value[15:8];
                                ui_label <= 2'd2;
                                ui_value <= (expr_value[15:8] * 100) >> 8;
                                ui_event <= 1'b1;
                            end
                            default: begin end
                        endcase
                    end
                    `CE64_TYPE_PARAM_CTRL: begin
                        // App-only runtime ADSR; aux selects piano(0)/organ(1).
                        // Zero slope is clamped, so an invalid command cannot strand a voice.
                        if (expr_source == 4'd2 && expr_id >= 8'h10 && expr_id <= 8'h13 && expr_aux <= 1) begin
                            case ({expr_aux[0], expr_id[1:0]})
                                3'd0: piano_a <= expr_value == 0 ? 16'd1 : expr_value;
                                3'd1: piano_d <= expr_value == 0 ? 16'd1 : expr_value;
                                3'd2: piano_s <= expr_value;
                                3'd3: piano_r <= expr_value == 0 ? 16'd1 : expr_value;
                                3'd4: organ_a <= expr_value == 0 ? 16'd1 : expr_value;
                                3'd5: organ_d <= expr_value == 0 ? 16'd1 : expr_value;
                                3'd6: organ_s <= expr_value;
                                3'd7: organ_r <= expr_value == 0 ? 16'd1 : expr_value;
                            endcase
                        end
                        case (expr_id)
                            8'd0: master_gain <= expr_value[15:8];
                            8'd1: piano_gain <= expr_value[15:8];
                            8'd2: bass_gain <= expr_value[15:8];
                            default: begin end
                        endcase
                    end
                    `CE64_TYPE_TRANSPORT: begin
                        case (expr_id)
                            8'd0: begin transport_playing <= 1'b0; transport_position <= 32'd0; panic_pulse <= 1'b1; end
                            8'd1: transport_playing <= 1'b1;
                            8'd2: transport_playing <= 1'b0;
                            8'd3: transport_position <= {16'd0, expr_value};
                            default: begin end
                        endcase
                    end
                    default: begin end
                endcase
            end
            if (panic_pulse || link_timeout_pulse)
                pedal_position <= 7'd0;
        end
    end

    wire engine_rst_n = rst_n && !panic_pulse;

    wire piano_event_valid, piano_event_ready, piano_event_on;
    wire [6:0] piano_event_note, piano_event_velocity;
    wire [3:0] piano_event_channel;
    wire bass_event_valid, bass_event_ready, bass_event_on;
    wire [6:0] bass_event_note, bass_event_velocity;
    wire [3:0] bass_event_channel;
    wire piano_sustain_ready, bass_sustain_ready;
    wire sustain_commit = expr_valid && (expr_type == `CE64_TYPE_SUSTAIN) &&
                          sustain_is_owner && piano_sustain_ready && bass_sustain_ready;
    assign expr_ready = ((expr_type == `CE64_TYPE_SUSTAIN) && sustain_is_owner) ?
                        (piano_sustain_ready && bass_sustain_ready) : 1'b1;

    sustain_event_processor_multi #(
        .FULL_SUSTAIN_THRESHOLD(64), .GLOBAL_SUSTAIN(GLOBAL_SUSTAIN_ENABLE)
    ) piano_sustain (
        .clk(sys_clk), .rst_n(rst_n), .panic(panic_pulse),
        .input_valid(router_piano_valid), .input_ready(router_piano_ready),
        .input_note_on(router_piano_on), .input_note(router_piano_note),
        .input_channel(router_piano_channel), .input_velocity(router_piano_velocity),
        .sustain_valid(sustain_commit), .sustain_ready(piano_sustain_ready),
        .sustain_channel(expr_channel), .sustain_position(expr_value[15:9]),
        .output_valid(piano_event_valid), .output_ready(piano_event_ready),
        .output_note_on(piano_event_on), .output_note(piano_event_note),
        .output_channel(piano_event_channel), .output_velocity(piano_event_velocity)
    );

    sustain_event_processor_multi #(
        .FULL_SUSTAIN_THRESHOLD(64), .GLOBAL_SUSTAIN(GLOBAL_SUSTAIN_ENABLE)
    ) bass_sustain (
        .clk(sys_clk), .rst_n(rst_n), .panic(panic_pulse),
        .input_valid(router_bass_valid), .input_ready(router_bass_ready),
        .input_note_on(router_bass_on), .input_note(router_bass_note),
        .input_channel(router_bass_channel), .input_velocity(router_bass_velocity),
        .sustain_valid(sustain_commit), .sustain_ready(bass_sustain_ready),
        .sustain_channel(expr_channel), .sustain_position(expr_value[15:9]),
        .output_valid(bass_event_valid), .output_ready(bass_event_ready),
        .output_note_on(bass_event_on), .output_note(bass_event_note),
        .output_channel(bass_event_channel), .output_velocity(bass_event_velocity)
    );

    wire [3:0] piano_query_channel, bass_query_channel;
    wire [6:0] piano_query_note, bass_query_note;
    wire [15:0] piano_pitch_value, bass_pitch_value;
    wire [7:0] piano_modulation_depth, bass_modulation_depth;
    wire [15:0] piano_pressure, bass_pressure;
    wire note_state_fire = (router_piano_valid && router_piano_ready) ||
                           (router_bass_valid && router_bass_ready) || (bank_valid && bank_ready);
    wire [3:0] note_state_channel = router_piano_valid ? router_piano_channel : (router_bass_valid ? router_bass_channel : bank_channel);
    wire [6:0] note_state_note = router_piano_valid ? router_piano_note : (router_bass_valid ? router_bass_note : bank_note);
    channel_expression_state expression_state (
        .clk(sys_clk), .rst_n(rst_n), .panic(panic_pulse),
        .expr_fire(expr_fire), .expr_type(expr_type), .expr_channel(expr_channel),
        .expr_flags(expr_flags), .expr_id(expr_id), .expr_value(expr_value),
        .note_fire(note_state_fire), .note_channel(note_state_channel), .note_number(note_state_note),
        .query0_channel(piano_query_channel), .query0_note(piano_query_note),
        .query0_pitch(piano_pitch_value), .query0_mod(piano_modulation_depth),
        .query0_pressure(piano_pressure),
        .query1_channel(bass_query_channel), .query1_note(bass_query_note),
        .query1_pitch(bass_pitch_value), .query1_mod(bass_modulation_depth),
        .query1_pressure(bass_pressure),
        .query2_channel(bank_query_channel), .query2_note(bank_query_note),
        .query2_pitch(bank_pitch), .query2_mod(bank_mod), .query2_pressure(bank_pressure),
        .selected_program(), .selected_program_channel(expr_channel)
    );
    wire signed [15:0] piano_pitch_delta, bass_pitch_delta;
    pitch_bend_map piano_pitch_map (.value(piano_pitch_value), .delta_q15(piano_pitch_delta));
    pitch_bend_map bass_pitch_map (.value(bass_pitch_value), .delta_q15(bass_pitch_delta));

    wire signed [PCM_WIDTH-1:0] piano_sample, bass_sample, drum_sample;
    wire piano_sample_valid, bass_sample_valid, drum_sample_valid;
    wire [31:0] piano_active, bass_active, drum_active;
    wire [31:0] piano_deadline, bass_deadline, drum_deadline;

    music_synth_core #(
        .CLK_FREQ_HZ(SYS_CLK_FREQ_HZ), .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),
        .SAMPLE_PERIOD_CYCLES(SAMPLE_PERIOD_CYCLES), .VOICE_NUM(PIANO_VOICES),
        .AUDIO_WIDTH(PCM_WIDTH), .OUTPUT_SHIFT(6), .WAVE_LAYERS(32), .WAVE_ADDR_WIDTH(8),
        .WAVE_STORAGE_WIDTH(18), .PIANO_REFINED(1),
        .WAVE_MEMORY_FILE(PIANO_WAVE_FILE), .NOTE_PHASE_FILE(PIANO_PHASE_FILE),
        .RUNTIME_ADSR_ENABLE(1), .ATTACK_STEP(16'd256), .DECAY_STEP(16'd8),
        .SUSTAIN_LEVEL(16'd24576), .RELEASE_STEP(16'd8),
        // 保持音的自然衰减：步长 1 对应高音约 3.5 s、中音约 7.5 s。原来的步长 4
        // 让高音不到 1 s 就消失，踏板无法累积出 32 声部，也让钢琴听起来发干。
        .NATURAL_DECAY_STEP(16'd1)
    ) piano (
        .event_patch(3'd0), .pedal_position(7'd0), .adsr_attack(piano_a), .adsr_decay(piano_d), .adsr_sustain(piano_s), .adsr_release(piano_r),
        .clk(sys_clk), .rst_n(engine_rst_n),
        .event_valid(piano_event_valid), .event_ready(piano_event_ready),
        .event_note_on(piano_event_on), .event_note(piano_event_note),
        .event_channel(piano_event_channel), .event_velocity(piano_event_velocity),
        .audio_sample(piano_sample), .audio_valid(piano_sample_valid),
        .active_voice_count(piano_active), .deadline_miss_count(piano_deadline),
        .bend(piano_pitch_delta), .mod_depth(piano_modulation_depth),
        .pressure(piano_pressure), .expression_query_channel(piano_query_channel),
        .expression_query_note(piano_query_note)
    );

    music_synth_core #(
        .CLK_FREQ_HZ(SYS_CLK_FREQ_HZ), .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),
        .SAMPLE_PERIOD_CYCLES(SAMPLE_PERIOD_CYCLES), .VOICE_NUM(BASS_VOICES),
        .AUDIO_WIDTH(PCM_WIDTH), .OUTPUT_SHIFT(5), .WAVE_LAYERS(2),
        .WAVE_MEMORY_FILE(ORGAN_WAVE_FILE), .NOTE_PHASE_FILE(BASS_PHASE_FILE),
        .RUNTIME_ADSR_ENABLE(1), .ATTACK_STEP(16'd256), .DECAY_STEP(16'd16),
        .SUSTAIN_LEVEL(16'hffff), .RELEASE_STEP(16'd8),
        .NATURAL_DECAY_ENABLE(0), .NATURAL_DECAY_STEP(16'd0)
    ) organ (
        .event_patch(3'd0), .pedal_position(7'd0), .adsr_attack(organ_a), .adsr_decay(organ_d), .adsr_sustain(organ_s), .adsr_release(organ_r),
        .clk(sys_clk), .rst_n(engine_rst_n),
        .event_valid(bass_event_valid), .event_ready(bass_event_ready),
        .event_note_on(bass_event_on), .event_note(bass_event_note),
        .event_channel(bass_event_channel), .event_velocity(bass_event_velocity),
        .audio_sample(bass_sample), .audio_valid(bass_sample_valid),
        .active_voice_count(bass_active), .deadline_miss_count(bass_deadline),
        .bend(bass_pitch_delta), .mod_depth(bass_modulation_depth),
        .pressure(bass_pressure), .expression_query_channel(bass_query_channel),
        .expression_query_note(bass_query_note)
    );

    // ---- Piano hybrid voicing: hammer noise -> body resonance -> pedal chain ----
    // A short broadband burst on every piano Note On, velocity scaled. It is
    // global (one burst per event) rather than per-voice to keep resources low.
    reg [15:0] hammer_lfsr;
    reg [23:0] hammer_env;
    reg signed [15:0] hammer_lp;
    reg signed [PCM_WIDTH-1:0] hammer_sample;
    wire signed [15:0] hammer_noise = $signed(hammer_lfsr);
    wire signed [15:0] hammer_hp = hammer_noise - hammer_lp;
    wire [23:0] hammer_env_dec = (hammer_env >> 7) + 1'b1;
    wire signed [32:0] hammer_product = hammer_hp * $signed({1'b0, hammer_env[23:8]});
    wire signed [PCM_WIDTH-1:0] hammer_scaled = hammer_product >>> 15;

    always @(posedge sys_clk or negedge engine_rst_n) begin
        if (!engine_rst_n) begin
            hammer_lfsr <= 16'h1ace;
            hammer_env <= 24'd0;
            hammer_lp <= 16'sd0;
            hammer_sample <= {PCM_WIDTH{1'b0}};
        end else begin
            if (piano_event_valid && piano_event_ready && piano_event_on) begin
                hammer_env <= {1'b0, piano_event_velocity, 16'b0};
                hammer_lfsr <= 16'h1ace;
                hammer_lp <= 16'sd0;
            end else if (piano_sample_valid) begin
                hammer_lfsr <= {hammer_lfsr[14:0],
                                hammer_lfsr[15] ^ hammer_lfsr[13] ^
                                hammer_lfsr[12] ^ hammer_lfsr[10]};
                hammer_lp <= hammer_lp + ((hammer_noise - hammer_lp) >>> 5);
                hammer_env <= (hammer_env > hammer_env_dec) ?
                              hammer_env - hammer_env_dec : 24'd0;
                hammer_sample <= hammer_scaled;
            end
        end
    end

    localparam signed [PCM_WIDTH-1:0] PIANO_PCM_MAX = {1'b0, {(PCM_WIDTH-1){1'b1}}};
    localparam signed [PCM_WIDTH-1:0] PIANO_PCM_MIN = {1'b1, {(PCM_WIDTH-1){1'b0}}};
    wire signed [PCM_WIDTH:0] piano_hammer_sum = piano_sample + hammer_sample;
    wire signed [PCM_WIDTH-1:0] piano_hammer_sample =
        (piano_hammer_sum > PIANO_PCM_MAX) ? PIANO_PCM_MAX :
        (piano_hammer_sum < PIANO_PCM_MIN) ? PIANO_PCM_MIN :
        piano_hammer_sum[PCM_WIDTH-1:0];

    wire body_valid;
    wire signed [PCM_WIDTH-1:0] body_sample;
    body_resonance #(
        .MODES(3), .MODE_INDEX_WIDTH(2), .DATA_WIDTH(PCM_WIDTH),
        .WET_SHIFT(5)
    ) piano_body (
        .clk(sys_clk), .rst_n(engine_rst_n),
        .in_valid(piano_sample_valid), .in_sample(piano_hammer_sample),
        .out_valid(body_valid), .out_sample(body_sample)
    );

    wire piano_fx_valid;
    wire signed [PCM_WIDTH-1:0] piano_fx_sample;
    piano_effects_chain #(
        .DATA_WIDTH(PCM_WIDTH),
        .DELAY_SAMPLES(2), .ENABLE(0),
        .WET_SHIFT(2), .FEEDBACK_SHIFT(2),
        .PEDAL_POSITION_WIDTH(7),
        .STRING_RESONANCE_ENABLE(1),
        .STRING_RESONANCE_DELAY_SAMPLES(997),
        .STRING_RESONANCE_WET_SHIFT(4),
        .STRING_RESONANCE_FEEDBACK_SHIFT(2),
        .PEDAL_NOISE_ENABLE(1),
        .PEDAL_NOISE_GAIN_SHIFT(4),
        .PEDAL_NOISE_DECAY_SHIFT(8)
    ) piano_pedal (
        .clk(sys_clk), .rst_n(engine_rst_n),
        .input_valid(body_valid), .input_sample(body_sample),
        .pedal_position(pedal_position),
        .output_valid(piano_fx_valid), .output_sample(piano_fx_sample)
    );

    // Diagnostics must include all three engines; the former expression
    // silently omitted active drum voices.
    assign active_voice_count = piano_active + bass_active + drum_active + bank_active;
    assign deadline_miss_count = piano_deadline + bass_deadline + drum_deadline + bank_deadline;

    drum_synth_core #(
        .CLK_FREQ_HZ(SYS_CLK_FREQ_HZ), .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),
        .SAMPLE_PERIOD_CYCLES(SAMPLE_PERIOD_CYCLES), .VOICES(DRUM_VOICES),
        .PCM_WIDTH(PCM_WIDTH), .COUNT_WIDTH(COUNT_WIDTH),
        .SINE_FILE("src/drum_sine_rom.mem")
    ) drums (
        .clk(sys_clk), .rst_n(engine_rst_n),
        .event_valid(router_drum_valid), .event_ready(router_drum_ready),
        .event_note_on(router_drum_on), .event_note(router_drum_note),
        .event_velocity(router_drum_velocity), .event_channel(router_drum_channel),
        .audio_sample(drum_sample), .audio_valid(drum_sample_valid),
        .active_voice_count(drum_active), .deadline_miss_count(drum_deadline)
    );

    pitch_bend_map bank_pitch_map(.value(bank_pitch), .delta_q15(bank_bend));
    music_synth_core #(
        .PATCH_BANK_ENABLE(1), .WAVE_STORAGE_WIDTH(16), .VOICE_NUM(BANK_VOICES),
        .CLK_FREQ_HZ(SYS_CLK_FREQ_HZ), .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),
        .SAMPLE_PERIOD_CYCLES(SAMPLE_PERIOD_CYCLES), .AUDIO_WIDTH(PCM_WIDTH),
        .WAVE_ADDR_WIDTH(7), .WAVE_LAYERS(32), .OUTPUT_SHIFT(5),
        .NOTE_PHASE_FILE(PIANO_PHASE_FILE), .WAVE_MEMORY_FILE("src/instrument_bank.mem")
    ) bank (
        .clk(sys_clk), .rst_n(engine_rst_n), .event_valid(bank_valid), .event_ready(bank_ready),
        .event_note_on(bank_on), .event_note(bank_note), .event_channel(bank_channel),
        .event_velocity(bank_velocity), .event_patch(bank_patch), .pedal_position(pedal_position),
        .adsr_attack(16'd0), .adsr_decay(16'd0), .adsr_sustain(16'd0), .adsr_release(16'd0),
        .audio_sample(bank_sample), .audio_valid(bank_sample_valid),
        .active_voice_count(bank_active), .deadline_miss_count(bank_deadline),
        .bend(bank_bend), .mod_depth(bank_mod), .pressure(bank_pressure),
        .expression_query_channel(bank_query_channel), .expression_query_note(bank_query_note)
    );

    reg bank_held;
    reg signed [PCM_WIDTH-1:0] bank_hold;
    reg signed [PCM_WIDTH:0] bank_scaled_q;
    wire bank_seen = bank_held || bank_sample_valid;
    wire signed [PCM_WIDTH-1:0] bank_now = bank_sample_valid ? bank_sample : bank_hold;
    wire signed [PCM_WIDTH+8:0] bank_gain_product = $signed(bank_now) * $signed({1'b0,piano_gain});
    wire signed [PCM_WIDTH+9:0] bank_pan_product = bank_scaled_q * 9'sd180;
    wire signed [PCM_WIDTH+9:0] bank_pan_shifted = bank_pan_product >>> 8;

    reg piano_held, bass_held, drum_held;
    reg signed [PCM_WIDTH-1:0] piano_hold, bass_hold, drum_hold;
    reg mix_gain_valid, mix_pan_valid, mix_valid;
    reg signed [PCM_WIDTH:0] piano_scaled_q, bass_scaled_q, drum_scaled_q;
    reg signed [PCM_WIDTH+2:0] pan_left_q, pan_right_q;
    reg [7:0] master_gain_q;
    reg signed [PCM_WIDTH-1:0] mix_left_sample, mix_right_sample;
    wire piano_seen = piano_held || piano_fx_valid;
    wire bass_seen = bass_held || bass_sample_valid;
    wire drum_seen = drum_held || drum_sample_valid;
    wire signed [PCM_WIDTH-1:0] piano_now = piano_fx_valid ? piano_fx_sample : piano_hold;
    wire signed [PCM_WIDTH-1:0] bass_now = bass_sample_valid ? bass_sample : bass_hold;
    wire signed [PCM_WIDTH-1:0] drum_now = drum_sample_valid ? drum_sample : drum_hold;
    wire signed [PCM_WIDTH+8:0] piano_gain_product = $signed(piano_now) * $signed({1'b0, piano_gain});
    wire signed [PCM_WIDTH+8:0] bass_gain_product = $signed(bass_now) * $signed({1'b0, bass_gain});
    wire signed [PCM_WIDTH+8:0] drum_gain_product = $signed(drum_now) * $signed({1'b0, DRUM_GAIN});

    // Fixed, subtle stereo placement. Values are Q0.8 (256 = unity).
    localparam [7:0] PIANO_PAN_L = 8'd176; // 0.688
    localparam [7:0] PIANO_PAN_R = 8'd184; // 0.719
    localparam [7:0] BASS_PAN_L  = 8'd184; // 0.719
    localparam [7:0] BASS_PAN_R  = 8'd176; // 0.688
    localparam [7:0] DRUM_PAN_L  = 8'd180; // 0.703
    localparam [7:0] DRUM_PAN_R  = 8'd180; // 0.703

    // Stage 2 operates only on the registered gain results.  The extra width
    // on the pan products is intentional: a 25-bit signed sample times a
    // 9-bit unsigned gain requires 34 result bits.
    wire signed [PCM_WIDTH+9:0] piano_l_prod = piano_scaled_q * $signed({1'b0, PIANO_PAN_L});
    wire signed [PCM_WIDTH+9:0] piano_r_prod = piano_scaled_q * $signed({1'b0, PIANO_PAN_R});
    wire signed [PCM_WIDTH+9:0] bass_l_prod  = bass_scaled_q  * $signed({1'b0, BASS_PAN_L});
    wire signed [PCM_WIDTH+9:0] bass_r_prod  = bass_scaled_q  * $signed({1'b0, BASS_PAN_R});
    wire signed [PCM_WIDTH+9:0] drum_l_prod  = drum_scaled_q  * $signed({1'b0, DRUM_PAN_L});
    wire signed [PCM_WIDTH+9:0] drum_r_prod  = drum_scaled_q  * $signed({1'b0, DRUM_PAN_R});
    wire signed [PCM_WIDTH+9:0] piano_l_shifted = piano_l_prod >>> 8;
    wire signed [PCM_WIDTH+9:0] piano_r_shifted = piano_r_prod >>> 8;
    wire signed [PCM_WIDTH+9:0] bass_l_shifted = bass_l_prod >>> 8;
    wire signed [PCM_WIDTH+9:0] bass_r_shifted = bass_r_prod >>> 8;
    wire signed [PCM_WIDTH+9:0] drum_l_shifted = drum_l_prod >>> 8;
    wire signed [PCM_WIDTH+9:0] drum_r_shifted = drum_r_prod >>> 8;
    wire signed [PCM_WIDTH+2:0] pan_left_next =
        $signed(piano_l_shifted[PCM_WIDTH+2:0]) +
        $signed(bass_l_shifted[PCM_WIDTH+2:0]) +
        $signed(drum_l_shifted[PCM_WIDTH+2:0]) + $signed(bank_pan_shifted[PCM_WIDTH+2:0]);
    wire signed [PCM_WIDTH+2:0] pan_right_next =
        $signed(piano_r_shifted[PCM_WIDTH+2:0]) +
        $signed(bass_r_shifted[PCM_WIDTH+2:0]) +
        $signed(drum_r_shifted[PCM_WIDTH+2:0]) + $signed(bank_pan_shifted[PCM_WIDTH+2:0]);

    // Stage 3 applies the registered master gain and saturates before
    // truncation so large signals cannot wrap around.
    wire signed [PCM_WIDTH+11:0] master_left_product  = pan_left_q  * $signed({1'b0, master_gain_q});
    wire signed [PCM_WIDTH+11:0] master_right_product = pan_right_q * $signed({1'b0, master_gain_q});
    wire signed [PCM_WIDTH+11:0] mix_wide_left  = master_left_product  >>> 8;
    wire signed [PCM_WIDTH+11:0] mix_wide_right = master_right_product >>> 8;
    localparam signed [PCM_WIDTH-1:0] MIX_MAX = {1'b0, {(PCM_WIDTH-1){1'b1}}};
    localparam signed [PCM_WIDTH-1:0] MIX_MIN = {1'b1, {(PCM_WIDTH-1){1'b0}}};

    // 鼓的增益结果先钳到 24-bit 范围内，避免高力度多鼓叠加时 25-bit 寄存器回绕。
    wire signed [PCM_WIDTH+8:0] drum_mix_wide = drum_gain_product >>> DRUM_MIX_SHIFT;
    wire signed [PCM_WIDTH:0] drum_mix_sat =
        (drum_mix_wide > $signed({1'b0, MIX_MAX})) ? {1'b0, MIX_MAX} :
        (drum_mix_wide < $signed({1'b1, MIX_MIN})) ? {1'b1, MIX_MIN} :
        drum_mix_wide[PCM_WIDTH:0];

    always @(posedge sys_clk or negedge engine_rst_n) begin
        if (!engine_rst_n) begin
            bank_held <= 0; bank_hold <= 0; bank_scaled_q <= 0;
            piano_held <= 1'b0;
            bass_held <= 1'b0;
            drum_held <= 1'b0;
            piano_hold <= {PCM_WIDTH{1'b0}};
            bass_hold <= {PCM_WIDTH{1'b0}};
            drum_hold <= {PCM_WIDTH{1'b0}};
            mix_gain_valid <= 1'b0;
            mix_pan_valid <= 1'b0;
            mix_valid <= 1'b0;
            piano_scaled_q <= {(PCM_WIDTH+1){1'b0}};
            bass_scaled_q <= {(PCM_WIDTH+1){1'b0}};
            drum_scaled_q <= {(PCM_WIDTH+1){1'b0}};
            pan_left_q <= {(PCM_WIDTH+3){1'b0}};
            pan_right_q <= {(PCM_WIDTH+3){1'b0}};
            master_gain_q <= 8'd0;
            mix_left_sample <= {PCM_WIDTH{1'b0}};
            mix_right_sample <= {PCM_WIDTH{1'b0}};
        end else begin
            mix_gain_valid <= 1'b0;
            mix_pan_valid <= mix_gain_valid;
            mix_valid <= 1'b0;
            if (bank_sample_valid) bank_hold <= bank_sample;
            if (piano_fx_valid) piano_hold <= piano_fx_sample;
            if (bass_sample_valid) bass_hold <= bass_sample;
            if (drum_sample_valid) drum_hold <= drum_sample;
            if (piano_seen && bass_seen && drum_seen && bank_seen) begin
                bank_scaled_q <= bank_gain_product >>> 8;
                bank_held <= 0;
                piano_scaled_q <= piano_gain_product >>> 8;
                bass_scaled_q <= bass_gain_product >>> 8;
                drum_scaled_q <= drum_mix_sat;
                mix_gain_valid <= 1'b1;
                piano_held <= 1'b0;
                bass_held <= 1'b0;
                drum_held <= 1'b0;
            end else begin
                bank_held <= bank_seen;
                piano_held <= piano_seen;
                bass_held <= bass_seen;
                drum_held <= drum_seen;
            end

            if (mix_gain_valid) begin
                pan_left_q <= pan_left_next;
                pan_right_q <= pan_right_next;
                master_gain_q <= master_gain;
            end

            if (mix_pan_valid) begin
                mix_left_sample  <= (mix_wide_left > $signed({1'b0, MIX_MAX})) ? MIX_MAX :
                                    (mix_wide_left < $signed({1'b1, MIX_MIN})) ? MIX_MIN :
                                    mix_wide_left[PCM_WIDTH-1:0];
                mix_right_sample <= (mix_wide_right > $signed({1'b0, MIX_MAX})) ? MIX_MAX :
                                    (mix_wide_right < $signed({1'b1, MIX_MIN})) ? MIX_MIN :
                                    mix_wide_right[PCM_WIDTH-1:0];
                mix_valid <= 1'b1;
            end
        end
    end

    wire ch_valid;
    wire signed [PCM_WIDTH-1:0] ch_left, ch_right;
    chorus_effect #(
        .DATA_WIDTH(PCM_WIDTH), .MAX_DELAY(2048), .ADDR_WIDTH(11),
        .GAIN_SHIFT(8), .LFO_INC(172)
    ) chorus (
        .clk(sys_clk), .rst_n(engine_rst_n), .in_valid(mix_valid),
        .in_left(mix_left_sample), .in_right(mix_right_sample),
        .wet_gain(chorus_wet),
        .out_valid(ch_valid), .out_left(ch_left), .out_right(ch_right)
    );

    wire fx_l_valid, fx_r_valid;
    wire signed [PCM_WIDTH-1:0] fx_left, fx_right;
    delay_effect #(
        .DATA_WIDTH(PCM_WIDTH), .MAX_DELAY(8192), .ADDR_WIDTH(13), .GAIN_SHIFT(8)
    ) effects_left (
        .clk(sys_clk), .rst_n(engine_rst_n),
        .in_valid(ch_valid), .in_sample(ch_left),
        .bypass(effect_bypass), .delay_samples(effect_delay_samples),
        .feedback_gain(effect_feedback_gain), .wet_gain(effect_wet_gain),
        .out_valid(fx_l_valid), .out_sample(fx_left)
    );

    delay_effect #(
        .DATA_WIDTH(PCM_WIDTH), .MAX_DELAY(8192), .ADDR_WIDTH(13), .GAIN_SHIFT(8)
    ) effects_right (
        .clk(sys_clk), .rst_n(engine_rst_n),
        .in_valid(ch_valid), .in_sample(ch_right),
        .bypass(effect_bypass), .delay_samples(effect_delay_samples),
        .feedback_gain(effect_feedback_gain), .wet_gain(effect_wet_gain),
        .out_valid(fx_r_valid), .out_sample(fx_right)
    );

    wire fx_valid = fx_l_valid && fx_r_valid;
    wire rv_valid;
    wire signed [PCM_WIDTH-1:0] rv_left, rv_right;
    reverb_effect #(
        .DATA_WIDTH(PCM_WIDTH), .GAIN_SHIFT(8)
    ) reverb (
        .clk(sys_clk), .rst_n(engine_rst_n), .in_valid(fx_valid),
        .in_left(fx_left), .in_right(fx_right),
        .wet_gain(reverb_wet),
        .out_valid(rv_valid), .out_left(rv_left), .out_right(rv_right)
    );

    // A 16-sample right-channel delay is part of the actual stereo output.
    // The XY display below taps these same post-effect samples. A mono input
    // therefore creates a frequency-dependent phase difference, not a drawn
    // decorative ellipse; silent input still plots only the origin.
    reg signed [PCM_WIDTH-1:0] stereo_right_delay [0:15];
    integer stereo_i;
    always @(posedge sys_clk or negedge engine_rst_n) begin
        if (!engine_rst_n) begin
            for (stereo_i = 0; stereo_i < 16; stereo_i = stereo_i + 1)
                stereo_right_delay[stereo_i] <= 0;
        end else if (rv_valid) begin
            stereo_right_delay[0] <= rv_right;
            for (stereo_i = 1; stereo_i < 16; stereo_i = stereo_i + 1)
                stereo_right_delay[stereo_i] <= stereo_right_delay[stereo_i-1];
        end
    end

    wire final_valid = rv_valid;
    wire signed [PCM_WIDTH-1:0] final_left = rv_left;
    wire signed [PCM_WIDTH-1:0] final_right = stereo_right_delay[15];
    wire signed [PCM_WIDTH:0] visual_sum = final_left + final_right;
    assign visual_audio_valid = final_valid;
    assign visual_audio_sample = visual_sum >>> 1;
    assign post_valid = final_valid;
    assign post_left  = final_left;
    assign post_right = final_right;

    wire cdc_read_request, cdc_read_valid;
    wire [2*PCM_WIDTH-1:0] cdc_read_data;
    wire [2*PCM_WIDTH-1:0] cdc_write_data = {final_left, final_right};
    audio_cdc_fifo #(
        .DATA_WIDTH(2*PCM_WIDTH), .DEPTH(CDC_DEPTH), .COUNT_WIDTH(COUNT_WIDTH)
    ) cdc (
        .wr_clk(sys_clk), .wr_rst_n(rst_n), .wr_valid(final_valid),
        .wr_ready(), .wr_data(cdc_write_data), .overflow_count(audio_overflow_count),
        .rd_clk(audio_clk), .rd_rst_n(rst_n), .rd_request(cdc_read_request),
        .rd_valid(cdc_read_valid), .rd_data(cdc_read_data),
        .underflow_count(audio_underflow_count)
    );

    wire signed [PCM_WIDTH-1:0] cdc_left  = cdc_read_data[2*PCM_WIDTH-1:PCM_WIDTH];
    wire signed [PCM_WIDTH-1:0] cdc_right = cdc_read_data[PCM_WIDTH-1:0];

    pt8211_output_chain #(
        .PCM_WIDTH(PCM_WIDTH), .BCLK_DIV(PT_BCLK_DIV),
        .QUANT_SHIFT(PT_QUANT_SHIFT), .STARTUP_FRAMES(32),
        .COUNT_WIDTH(COUNT_WIDTH)
    ) output_chain (
        .audio_clk(audio_clk), .rst_n(rst_n),
        .pcm_valid(cdc_read_valid), .pcm_left(cdc_left), .pcm_right(cdc_right),
        .pcm_ready(cdc_read_request), .render_tick(),
        .pt_bck(pt_bck), .pt_ws(pt_ws), .pt_din(pt_din), .pa_en(pa_en),
        .overwrite_count(), .underflow_count()
    );
endmodule
