/*
 * 参数化复音合成核心顶层。
 * 输入端用单入口 ready/valid 接收抽象 Note On/Note Off；内部为每个逻辑声部保存独立的
 * 音符、相位、力度、包络和年龄，但所有声部共享同一套波表、乘法与混音物理运算通路，
 * 由调度器逐声部时分复用。一次完整遍历结束后输出一拍 signed audio_sample/audio_valid。
 *
 * clk 驱动全部时序逻辑；rst_n 为上升沿同步、低有效复位。事件与采样输出都只在 clk
 * 上升沿建立协议意义：事件在 event_valid && event_ready 时接收，audio_sample 仅在
 * audio_valid=1 的周期有效。模块不包含板级外设、音频串行接口或 Gowin 软 IP。
 */
module music_synth_core #(
    // 单位 Hz，合法范围 >SAMPLE_RATE_HZ；增大可提高每样本调度预算，ROM 内容不依赖它。
    parameter integer PATCH_BANK_ENABLE = 0,
    // Piano-only: four pitch bands, eight velocity layers and phase interpolation.
    // ROM stays 8192 x 18 bits; other instruments retain their established path.
    parameter integer PIANO_REFINED = 0,
    parameter integer CLK_FREQ_HZ = 100000000,
    // 单位 Hz，合法范围 1..CLK_FREQ_HZ-1；决定采样时序和 DDS 换算，修改后须重生成相位增量 ROM。
    parameter integer SAMPLE_RATE_HZ = 48000,
    // 0=分数采样率；>0=固定系统时钟周期，供同源 DAC 帧同步模式使用。
    parameter integer SAMPLE_PERIOD_CYCLES = 0,
    // 单位个，合法范围 >=1；状态资源和遍历时间近似线性增加，混音保护位按 ceil(log2) 增加；不需重生成 ROM。
    parameter integer VOICE_NUM = 32,
    // 单位 bit，合法范围 >WAVE_ADDR_WIDTH；决定调音精度和相位资源，修改后须重生成相位增量 ROM。
    parameter integer PHASE_WIDTH = 32,
    // 相位增量表初始化文件；内容必须与 SAMPLE_RATE_HZ 一致，默认 48 kHz 表。
    parameter NOTE_PHASE_FILE = "src/note_phase_rom.mem",
    // 单位 bit，合法范围 1..min(30, PHASE_WIDTH-1)；表深为 2**该值，修改后须重生成复合波表 ROM。
    parameter integer WAVE_ADDR_WIDTH = 10,
    // 单位 bit，合法范围 >=2；决定波形/输出精度和乘法规模，修改后须重生成复合波表 ROM。
    parameter integer AUDIO_WIDTH = 24,
    parameter integer WAVE_STORAGE_WIDTH = AUDIO_WIDTH,
    // 单位 bit，合法范围 >=1；决定无符号力度范围与乘法规模，默认 7 bit 对应 0..127；不影响 ROM。
    parameter integer VELOCITY_WIDTH = 7,
    // 单位 bit，合法范围 >=1；决定包络分辨率及包络乘法规模，修改时需同步调整 ADSR 参数但不改 ROM。
    parameter integer ENV_WIDTH = 16,
    // 单位 bit，合法范围 >=AUDIO_WIDTH；请求的最小混音余量，增大会增加加法/限幅资源，不影响 ROM。
    parameter integer MIX_ACC_WIDTH = 32,
    // 单位 bit，合法范围 0..内部混音位宽-1；越大输出增益越低、削顶余量越多，不影响 ROM。
    parameter integer OUTPUT_SHIFT = 5,
    // 单位 包络码值/采样，合法范围 1..2**ENV_WIDTH-1；越大 Attack 越短，不影响 ROM。
    parameter [ENV_WIDTH-1:0] ATTACK_STEP =
        ({{(ENV_WIDTH-1){1'b0}}, 1'b1} << ((ENV_WIDTH > 6) ? (ENV_WIDTH - 6) : 0)),
    // 单位 包络码值/采样，合法范围 1..2**ENV_WIDTH-1；越大 Decay 越短，不影响 ROM。
    parameter [ENV_WIDTH-1:0] DECAY_STEP =
        ({{(ENV_WIDTH-1){1'b0}}, 1'b1} << ((ENV_WIDTH > 10) ? (ENV_WIDTH - 10) : 0)),
    // 单位 包络码值，合法范围 0..2**ENV_WIDTH-1；决定持续音量，不影响 ROM。
    parameter [ENV_WIDTH-1:0] SUSTAIN_LEVEL =
        ({ENV_WIDTH{1'b1}} - ({ENV_WIDTH{1'b1}} >> 2) -
         ({ENV_WIDTH{1'b1}} >> 4) - 1'b1),
    // 单位 包络码值/采样，合法范围 1..2**ENV_WIDTH-1；越大 Release 越短，不影响 ROM。
    parameter [ENV_WIDTH-1:0] RELEASE_STEP =
        ({{(ENV_WIDTH-1){1'b0}}, 1'b1} << ((ENV_WIDTH > 10) ? (ENV_WIDTH - 10) : 0)),
    // 1=按键保持期间仍按音区相关周期缓慢衰减到静音，避免固定 Sustain 形成风琴感。
    parameter integer NATURAL_DECAY_ENABLE = 1,
    // 每次自然衰减事件减少的包络码值；默认 1，与音区相关分频共同决定数秒到数十秒尾音。
    parameter [ENV_WIDTH-1:0] NATURAL_DECAY_STEP = {{(ENV_WIDTH-1){1'b0}}, 1'b1},
    // 每声部自然衰减分频计数器位宽；默认 6 bit 足以表达 4/8/16/32 个采样周期。
    parameter integer NATURAL_DECAY_COUNTER_WIDTH = 6,
    // 波表层数与该表的初始化文件：钢琴 8 层（Piano ROM），贝斯 2 层（Bass ROM）。
    parameter integer WAVE_LAYERS = 8,
    parameter         WAVE_MEMORY_FILE = "src/piano_waveform_rom.mem",
    // ---- 连续亮度包络的调试旋钮（详见 docs/tuning-parameters.md）----
    // 低音(<48)/高音(>=84)键区的起音亮度加成；调大 → 两端更亮更硬。
    parameter integer BRIGHT_KEY_BIAS = 8,
    // 亮度衰减地板 = 起音亮度 - (起音亮度 >> BRIGHT_FLOOR_SHIFT)（即降到起音亮度的
    // 约 (1 - 2^-SHIFT) 倍），并有最小下限 BRIGHT_FLOOR_MIN。
    // 这样强音的持续音色本来就比弱音亮；调大 SHIFT → 地板更接近起音（衰减更少）。
    parameter integer BRIGHT_FLOOR_SHIFT = 2,
    parameter integer BRIGHT_FLOOR_MIN = 8,
    // 亮度每减 1 所需的采样数 = BASE + (127 - 亮度) * SLOPE；
    // 调大 BASE → 整体变暗更慢；调大 SLOPE → 弱音比强音衰减得慢更多。
    parameter integer RUNTIME_ADSR_ENABLE = 0,
    parameter integer BRIGHT_PERIOD_BASE = 128,
    parameter integer BRIGHT_PERIOD_SLOPE = 2
) (
    // 合成核心逻辑时钟；所有事件握手、调度和 PCM 输出都属于该时钟域。
    input wire [2:0] event_patch,
    input wire [6:0] pedal_position,
    input wire [ENV_WIDTH-1:0] adsr_attack, adsr_decay, adsr_sustain, adsr_release,
    input  wire                            clk,
    // 同步低有效复位；为 0 时清空事件槽、全部声部、调度状态和诊断计数。
    input  wire                            rst_n,
    // 上游事件有效；必须与其余 event_* 字段保持到 event_ready 握手。
    input  wire                            event_valid,
    // 当前事件类型：1=Note On，0=Note Off。
    input  wire                            event_note_on,
    // 当前事件的 7-bit MIDI 音符号，合法编码为 0..127。
    input  wire [6:0]                      event_note,
    // MIDI 通道参与 Note Off 归属匹配，防止同音异通道互相释放。
    input  wire [3:0]                      event_channel,
    // Note On 时为无符号力度；Note Off 时为 0..满量程半踏板位置，决定释放步长。
    input  wire [VELOCITY_WIDTH-1:0]       event_velocity,
    // 单项事件槽可接收指示；event_valid && event_ready 时在本拍接收完整事件。
    output wire                            event_ready,
    // 一次完整声部遍历结束后的有符号单声道 PCM；仅 audio_valid=1 时有效。
    output reg signed [AUDIO_WIDTH-1:0]    audio_sample,
    // PCM 输出单周期有效脉冲；下游不可回压，必须立即接收或自行记录丢样。
    output reg                             audio_valid,
    // 当前仍占用的逻辑声部数量，包含按键已释放但包络尚未结束的声部。
    output reg [31:0]                      active_voice_count,
    // 新采样节拍到达时上一帧调度仍未完成的累计次数；32-bit 饱和计数。
    output reg [31:0]                      deadline_miss_count,
    // 全局弯音：相位增量的 Q1.15 相对变化（0=无弯音），作用于全部声部（通道级弯音）。
    // 由 control_event_router 的 PITCH_BEND 经 src/pitch_bend_map.v 提供。
    input  wire signed [15:0]              bend,
    // 全局调制深度（0..255）：驱动内部约 5 Hz 三角波 LFO 产生颤音。
    input  wire [7:0]                      mod_depth,
    // 当前声部的通道/复音压力；压力只临时提高波表亮度，不改写自然亮度包络。
    input  wire [15:0]                     pressure,
    output wire [3:0]                      expression_query_channel,
    output wire [6:0]                      expression_query_note
);
    // Original synthesized approximations, not recordings. Values are envelope
    // codes/sample at 48828 Hz; held voices keep their own patch across KEY1 changes.
    function [15:0] patch_attack(input [2:0] p);
        case(p) 0:patch_attack=32; 1:patch_attack=64; 2:patch_attack=16;
        3:patch_attack=80; 4:patch_attack=2048; 5:patch_attack=1024;
        6:patch_attack=1024; default:patch_attack=2048; endcase
    endfunction
    function [15:0] patch_decay(input [2:0] p);
        case(p) 0:patch_decay=16; 1:patch_decay=16; 2:patch_decay=8;
        3:patch_decay=24; 4:patch_decay=3; 5:patch_decay=2;
        6:patch_decay=4; default:patch_decay=1; endcase
    endfunction
    function [15:0] patch_sustain(input [2:0] p);
        case(p) 0:patch_sustain=52000; 1:patch_sustain=52000;
        2:patch_sustain=56000; 3:patch_sustain=48000;
        6:patch_sustain=8192; default:patch_sustain=0; endcase
    endfunction
    function [15:0] patch_release(input [2:0] p);
        case(p) 0:patch_release=128; 1:patch_release=192; 2:patch_release=32;
        3:patch_release=192; 4:patch_release=64; 5:patch_release=32;
        6:patch_release=128; default:patch_release=16; endcase
    endfunction
    wire [ENV_WIDTH-1:0] attack_current = PATCH_BANK_ENABLE ? patch_attack(work_patch) : (RUNTIME_ADSR_ENABLE ? adsr_attack : ATTACK_STEP);
    wire [ENV_WIDTH-1:0] decay_current = PATCH_BANK_ENABLE ? patch_decay(work_patch) : (RUNTIME_ADSR_ENABLE ? adsr_decay : DECAY_STEP);
    wire [ENV_WIDTH-1:0] sustain_current = PATCH_BANK_ENABLE ? patch_sustain(work_patch) : (RUNTIME_ADSR_ENABLE ? adsr_sustain : SUSTAIN_LEVEL);
    wire [ENV_WIDTH-1:0] release_current = PATCH_BANK_ENABLE ? patch_release(work_patch) : (RUNTIME_ADSR_ENABLE ? adsr_release : RELEASE_STEP);
    /*
     * 弯音与调制（全局，所有声部共享）：
     *   总比率增量 bend_total(Q1.15) = 外部弯音 bend + LFO × mod_depth；
     *   应用到相位增量 base_inc → base_inc + (base_inc * bend_total) >> 15。
     * bend_total = 0 时结果与未加弯音完全一致，因此旧回归不受影响。
     */
    localparam integer LFO_INC = (5 * 65536) / SAMPLE_RATE_HZ;  // 约 5 Hz
    reg [15:0]             lfo_phase;
    // 三角波：0..65535 上扫再下扫，中心化为 ±32768。
    // lfo_tri 本身只有 0..32767；左移一位展开到 0..65534 再减 32768，才能得到
    // 以 0 为中心的双极性三角波。若直接减 32768，LFO 恒为负，颤音只会单向下沉。
    wire [15:0]            lfo_tri      = lfo_phase[15] ? ~lfo_phase : lfo_phase;
    wire signed [16:0]     lfo_centered = $signed({lfo_tri, 1'b0}) - 17'sd32768;
    // 深度缩放右移 12 位：满深度约 ±1 半音。
    wire signed [25:0]     mod_product  = lfo_centered * $signed({1'b0, mod_depth});
    // 算术右移保留符号；不能对 part-select 直接赋值（part-select 是无符号的，
    // 负积会被零扩展成正值，颤音变成只升不降）。
    wire signed [15:0]     mod_term     = mod_product >>> 12;
    wire signed [15:0]     bend_total   = bend + mod_term;

    // 把 Q1.15 比率增量应用到相位增量；乘法落在寄存器输入，不进入相位累加关键路径。
    reg signed [15:0] work_bend;
    function [PHASE_WIDTH-1:0] bend_adjust;
        input [PHASE_WIDTH-1:0] base_inc;
        reg signed [PHASE_WIDTH+15:0] prod;
        begin
            prod = $signed({1'b0, base_inc}) * work_bend;
            bend_adjust = base_inc + prod[PHASE_WIDTH+14:15];
        end
    endfunction
    // 包络状态编码只用于内部控制；所有加减转换均在每个声部被遍历时发生一次。
    localparam [2:0] ENV_IDLE    = 3'd0;
    localparam [2:0] ENV_ATTACK  = 3'd1;
    localparam [2:0] ENV_DECAY   = 3'd2;
    localparam [2:0] ENV_SUSTAIN = 3'd3;
    localparam [2:0] ENV_RELEASE = 3'd4;

    /*
     * 每声部固定经过九个工作状态：
     * LOAD 只锁存动态数组，PREPARE 再计算相位/包络并提交波表地址，切断 voice_index
     * 经多路选择和 32-bit 运算直达乘法器的关键路径；两次波表读取各用一拍等待
     * 加一拍捕获，严格匹配同步 ROM 的地址寄存/数据寄存时序；
     * ENV_GAIN 把“波形×包络”缩放结果寄存，切断两个乘法器级联的关键路径；GAIN 再完成
     * 力度乘法并加入累加器；WRITE 回写相位/包络并选择下一声部或发布整帧样本。
     */
    localparam [3:0] SCHED_IDLE        = 4'd0;
    localparam [3:0] SCHED_LOAD        = 4'd1;
    localparam [3:0] SCHED_ROM_WAIT    = 4'd2;
    localparam [3:0] SCHED_ENV_GAIN    = 4'd3;
    localparam [3:0] SCHED_GAIN        = 4'd4;
    localparam [3:0] SCHED_WRITE       = 4'd5;
    localparam [3:0] SCHED_EVENT_SCAN  = 4'd6;
    localparam [3:0] SCHED_EVENT_APPLY = 4'd7;
    localparam [3:0] SCHED_PREPARE     = 4'd8;
    // 层间插值需要第二次 ROM 读（相邻的两层）；同步 ROM 的请求与捕获不能同拍。
    localparam [3:0] SCHED_ROM_WAIT2   = 4'd9;
    localparam [3:0] SCHED_ROM_LOWER   = 4'd10;
    localparam [3:0] SCHED_ROM_BLEND   = 4'd11;
    localparam [3:0] SCHED_EXPRESSION  = 4'd12;
    localparam [3:0] SCHED_PITCH = 4'd13;
    localparam [4:0] SCHED_PIANO_WAIT0 = 5'd14,
                     SCHED_PIANO_READ0 = 5'd15,
                     SCHED_PIANO_WAIT1 = 5'd16,
                     SCHED_PIANO_PHASE = 5'd17,
                     SCHED_PIANO_LAYER = 5'd18;

    // 连续亮度刻度是 7-bit；高 LAYER_BITS 位选层、低 FRAC_BITS 位作层内插值系数。
    // 8 层 → 3+4；4 层 → 2+5；2 层（贝斯）→ 1+6。
    // 注意：WAVE_LAYERS 必须是 2 的幂（2/4/8），否则层号会越界取到不存在的层。
    localparam integer BRIGHT_BITS = 7;
    localparam integer LAYER_BITS = (WAVE_LAYERS <= 2) ? 1 : $clog2(WAVE_LAYERS);
    localparam integer FRAC_BITS = (PATCH_BANK_ENABLE || PIANO_REFINED) ? 8 : BRIGHT_BITS - LAYER_BITS;

    /*
     * 返回容纳 value 个不同编码所需的向上取整 log2 位数。
     * 输入 value 是需要覆盖的正整数数量；在本模块中用于声部索引和多声部混音保护位。
     * 返回值为 integer；VOICE_NUM=1 时允许返回 0，索引宽度会在调用处另行夹到至少 1 bit。
     */
    function integer ceil_log2;
        input integer value;     // 需要编码或累加保护的元素数量。
        integer remaining;       // 逐次右移的 value-1 临时量，不形成公开状态。
        begin
            remaining = value - 1;
            ceil_log2 = 0;
            while (remaining > 0) begin
                remaining = remaining >> 1;
                ceil_log2 = ceil_log2 + 1;
            end
        end
    endfunction

    /*
     * 把任意 VELOCITY_WIDTH 的无符号力度压缩为 2-bit 软/中/亮/强四层索引。
     * 1-bit 特殊配置把 0/1 映射到最软/最强；常用 7-bit 配置直接取最高两位。
     */
    function [1:0] velocity_to_timbre_layer;
        input [VELOCITY_WIDTH-1:0] velocity_value; // 当前声部在 Note On 时锁存的力度。
        begin
            if (VELOCITY_WIDTH == 1)
                velocity_to_timbre_layer = {2{velocity_value[0]}};
            else
                velocity_to_timbre_layer = velocity_value >> (VELOCITY_WIDTH - 2);
        end
    endfunction

    /*
     * 把任意位宽力度归一化到 7-bit 亮度刻度（0..127）。8 层波表下，高 3 位选层、
     * 低 4 位作层内插值系数，因此亮度和力度共用同一刻度。
     */
    function [6:0] to_brightness7;
        input [VELOCITY_WIDTH-1:0] velocity_value;
        begin
            if (VELOCITY_WIDTH == 7)
                to_brightness7 = velocity_value;
            else if (VELOCITY_WIDTH < 7)
                to_brightness7 = velocity_value << (7 - VELOCITY_WIDTH);
            else
                to_brightness7 = velocity_value >> (VELOCITY_WIDTH - 7);
        end
    endfunction

    /*
     * 起音亮度 = 力度；低音粗弦与最高音区再亮一档（低/高音区高次谐波更丰富）。
     * 亮度随后单调衰减，因此不再需要按包络阶段"换层"，起音天然就是最亮的。
     */
    function [6:0] brightness_init;
        input [VELOCITY_WIDTH-1:0] velocity_value;
        input [6:0] note_value;
        reg [7:0] value;
        begin
            value = {1'b0, to_brightness7(velocity_value)};
            if (PIANO_REFINED && note_value > 7'd60) begin
                // Smoothly soften the upper register; no C5 timbre threshold.
                value = (value > (note_value-7'd60)) ? value-(note_value-7'd60) : 0;
            end else if (note_value < 7'd48 || (!PIANO_REFINED && note_value >= 7'd84))
                value = value + BRIGHT_KEY_BIAS[7:0];
            brightness_init = (value > 8'd127) ? 7'd127 : value[6:0];
        end
    endfunction

    /*
     * 亮度衰减地板：按起音亮度的固定比例下移（起音亮度本身就是力度的度量），
     * 于是强音的持续音色本来就比弱音亮，而不会所有音最后都收敛到同一层。
     */
    function [6:0] brightness_floor;
        input [VELOCITY_WIDTH-1:0] velocity_value;
        input [6:0] note_value;
        reg [7:0] start;
        reg [7:0] value;
        begin
            start = PIANO_REFINED ? {1'b0,brightness_init(velocity_value,note_value)} : {1'b0, to_brightness7(velocity_value)};
            value = start - (start >> BRIGHT_FLOOR_SHIFT);
            brightness_floor = (value < BRIGHT_FLOOR_MIN[7:0])
                               ? BRIGHT_FLOOR_MIN[6:0] : value[6:0];
        end
    endfunction

    /*
     * 亮度衰减分频：每计数这么多采样亮度减 1。周期 = BASE + (127 - 力度) * SLOPE，
     * 即力度越大周期越短、亮度掉得越快（高次谐波先衰）。
     * 默认强力 128 拍/级、弱音 382 拍/级；中音区一次完整亮度衰减约 0.2-0.3 s。
     */
    function [8:0] brightness_period;
        input [VELOCITY_WIDTH-1:0] velocity_value;
        reg [8:0] bright9;
        begin
            bright9 = {2'b0, to_brightness7(velocity_value)};
            brightness_period = BRIGHT_PERIOD_BASE[8:0]
                              + ((9'd127 - bright9) * BRIGHT_PERIOD_SLOPE[8:0]);
        end
    endfunction

    /*
     * 返回“计数到该值后执行一次自然衰减”的终值。低音弦衰减最慢，高音弦最快；
     * 默认 48 kHz、16-bit 包络、步长 1 时约对应 30/15/7.5/3.75 秒的主体尾音。
     */
    function [NATURAL_DECAY_COUNTER_WIDTH-1:0] natural_decay_terminal_for_note;
        input [6:0] note_value; // 当前 MIDI 音符号。
        begin
            if (PIANO_REFINED) begin
                // Gradual damping instead of halving the tail exactly at C5.
                // Period is 32 samples at C3, 26 at C4, 20 at C5, 14 at C6.
                if (note_value < 48)
                    natural_decay_terminal_for_note = 31 + ((48-note_value) >> 1);
                else if (note_value < 104)
                    natural_decay_terminal_for_note = 31 - ((note_value-48) >> 1);
                else
                    natural_decay_terminal_for_note = 3;
            end else if (note_value < 7'd48)
                natural_decay_terminal_for_note = 31;
            else if (note_value < 7'd72)
                natural_decay_terminal_for_note = 15;
            else if (note_value < 7'd96)
                natural_decay_terminal_for_note = 7;
            else
                natural_decay_terminal_for_note = 3;
        end
    endfunction

    /*
     * Note Off 的 velocity 字段在本工程中复用为 0..满量程的踏板位置。位置越深，
     * 阻尼器接触琴弦越轻，Release 步长越小；任何右移结果都至少钳为 1。
     */
    function [ENV_WIDTH-1:0] release_step_from_pedal;
        input [VELOCITY_WIDTH-1:0] pedal_position_value; // Note Off 携带的半踏板位置。
        reg [1:0] pedal_quarter;                         // 位置最高两位，表示四档阻尼强度。
        reg [ENV_WIDTH-1:0] shifted_step;               // 按踏板深度缩慢后的释放步长。
        begin
            pedal_quarter = velocity_to_timbre_layer(pedal_position_value);
            case (pedal_quarter)
                2'd0: shifted_step = release_current;
                2'd1: shifted_step = release_current >> 1;
                2'd2: shifted_step = release_current >> 2;
                default: shifted_step = release_current >> 3;
            endcase
            release_step_from_pedal =
                (shifted_step == {ENV_WIDTH{1'b0}}) ?
                {{(ENV_WIDTH-1){1'b0}}, 1'b1} : shifted_step;
        end
    endfunction

    // 两级乘法各多保留一个显式无符号操作数前导零，避免包络/力度最高位被解释为符号位。
    localparam [ENV_WIDTH-1:0] ENV_MAX = {ENV_WIDTH{1'b1}};
    localparam integer WAVE_ENV_PRODUCT_WIDTH = AUDIO_WIDTH + ENV_WIDTH + 1;
    localparam integer VELOCITY_PRODUCT_WIDTH = AUDIO_WIDTH + VELOCITY_WIDTH + 1;
    localparam integer VOICE_SUM_WIDTH = AUDIO_WIDTH + ceil_log2(VOICE_NUM);
    localparam integer VOICE_INDEX_WIDTH = (VOICE_NUM <= 1) ? 1 : ceil_log2(VOICE_NUM);
    // 即使用户请求位宽过窄，也至少保留 AUDIO_WIDTH+ceil(log2(VOICE_NUM))，防止多声部先行回绕。
    localparam integer INTERNAL_MIX_ACC_WIDTH =
        (MIX_ACC_WIDTH > VOICE_SUM_WIDTH) ? MIX_ACC_WIDTH : VOICE_SUM_WIDTH;

    /*
     * 每个数组下标代表一个独立逻辑声部；状态彼此独立，但并未复制 VOICE_NUM 套乘法器。
     * active 表示声部仍占用，key_down 区分按键保持与已进入 Release。age 是 Note On
     * 分配顺序，用于满载抢占；32-bit next_age 在 2^32 次 Note On 后回绕，届时无符号
     * 最小值不再严格等价于真实最老声部，这是当前实现的已知长期运行限制。
     */
    reg [2:0] pending_patch, work_patch;
    reg [2:0] voice_patch [0:VOICE_NUM-1];
    reg voice_active [0:VOICE_NUM-1];                    // 1=该声部仍占用并参与遍历。
    reg voice_key_down [0:VOICE_NUM-1];                  // 1=实体按键尚未收到匹配 Note Off。
    reg [6:0] voice_note [0:VOICE_NUM-1];                // 每个声部当前的 MIDI 音符号。
    reg [3:0] voice_channel [0:VOICE_NUM-1];             // 每个声部所属 MIDI 通道。
    reg [PHASE_WIDTH-1:0] voice_phase [0:VOICE_NUM-1];   // 每个声部当前 DDS 相位累加值。
    reg [VELOCITY_WIDTH-1:0] voice_velocity [0:VOICE_NUM-1];// Note On 时锁存的力度。
    reg [2:0] voice_envelope_state [0:VOICE_NUM-1];      // 当前 ADSR 阶段，编码见 ENV_*。
    reg [ENV_WIDTH-1:0] voice_envelope_level [0:VOICE_NUM-1];// 当前无符号包络幅度。
    reg [ENV_WIDTH-1:0] voice_release_step [0:VOICE_NUM-1];// 当前声部由半踏板位置决定的释放步长。
    reg [NATURAL_DECAY_COUNTER_WIDTH-1:0] voice_decay_counter [0:VOICE_NUM-1];// 按音区分频的自然衰减计数。
    reg [31:0] voice_age [0:VOICE_NUM-1] /* synthesis syn_ramstyle = "block_ram" */;                // 分配序号；数值较小者优先被满载抢占。
    // 连续亮度包络：起音时 = 力度（低/高音区更亮），随后按与力度相关的速率衰减到地板值。
    // 真实钢琴里高次谐波衰减比基频快，击弦越重衰减越明显，这里按该规律建模。
    reg [6:0] voice_bright [0:VOICE_NUM-1];              // 当前亮度（0..127），高位选层、低位插值。
    reg [8:0] voice_bright_cnt [0:VOICE_NUM-1];          // 亮度衰减分频计数。

    /*
     * 单项 pending 槽实现 ready/valid 解耦。event_ready 仅表示该槽为空；遍历进行中仍可接收
     * 一个事件，但事件只能在完整声部遍历之间由 SCHED_EVENT_APPLY
     * 统一修改声部数组。
     */
    reg pending_valid;                                  // 1=单项事件槽内已有待执行事件。
    reg pending_note_on;                                // 待执行事件类型，1=On、0=Off。
    reg [6:0] pending_note;                             // 待执行事件的 MIDI 音符号。
    reg [3:0] pending_channel;                          // 待执行事件的 MIDI 通道。
    reg [VELOCITY_WIDTH-1:0] pending_velocity;          // 待执行 Note On 的力度。
    reg [31:0] next_age;                                // 下一次声部分配要写入的单调年龄编号。
    reg sample_pending;                                 // 调度忙时到达的采样请求，等待空闲后启动。

    // 共享物理运算通路一次只处理 voice_index 指向的一个逻辑声部。
    reg [4:0] scheduler_state;                          // 当前共享调度阶段，编码见 SCHED_*。
    integer voice_index;                               // 当前被共享运算通路处理的声部数组下标。
    reg signed [INTERNAL_MIX_ACC_WIDTH-1:0] mix_accumulator;// 本帧已处理声部的有符号和。

    // 工作寄存器隔离当前声部的旧状态、下一状态与同步 ROM 延迟。
    reg work_active;                                   // 当前声部在 LOAD 时锁存的 active 快照。
    reg [3:0] work_channel;
    reg [6:0] work_note;                               // 当前声部 MIDI 音符快照。
    reg [PHASE_WIDTH-1:0] work_phase_current;          // 当前声部 LOAD 时读取的旧相位。
    reg [PHASE_WIDTH-1:0] work_phase_increment;        // 当前声部 LOAD 时读取的相位增量。
    reg [PHASE_WIDTH-1:0] work_phase_next;             // 当前声部本帧应回写的下一 DDS 相位。
    reg [VELOCITY_WIDTH-1:0] work_velocity;            // 当前声部锁存的力度操作数。
    reg [2:0] work_envelope_state;                     // 当前声部本帧应回写的包络阶段。
    reg [ENV_WIDTH-1:0] work_envelope_level;           // 当前声部本帧应回写的包络幅度。
    reg [6:0] work_bright;                             // 当前声部 LOAD 时锁存的亮度快照。
    reg [6:0] work_bright_next;                        // 本帧应回写的亮度。
    reg [8:0] work_bright_cnt;                         // 当前声部锁存的亮度分频计数。
    reg [8:0] work_bright_cnt_next;                    // 本帧应回写的亮度分频计数。
    reg [ENV_WIDTH-1:0] work_release_step;              // 当前声部本帧使用的半踏板释放步长。
    reg [NATURAL_DECAY_COUNTER_WIDTH-1:0] work_decay_counter;// 当前声部自然衰减计数的下一值。
    reg signed [AUDIO_WIDTH-1:0] work_envelope_scaled_sample;// 波形乘包络后的流水寄存值。
    reg work_release_done;                             // 1=本帧 Release 已降到零，应释放声部。
    reg [WAVE_ADDR_WIDTH-1:0] waveform_address;        // 提交给同步波表 ROM 的高位相位地址。
    reg [LAYER_BITS-1:0] waveform_layer;               // 当前波表层（8 层时 0..7）。
    reg [FRAC_BITS-1:0] waveform_frac;                 // 亮度在层内的插值系数，层间线性混合用。
    reg signed [AUDIO_WIDTH-1:0] wave_lower;           // 层 L 的同步 ROM 样本。
    reg signed [AUDIO_WIDTH-1:0] wave_blend;           // 层 L 与 L+1 按 waveform_frac 混合后的样本。
    reg signed [AUDIO_WIDTH-1:0] phase_lower, phase_upper;
    reg [7:0] piano_layer_frac;

    wire [7:0] pressured_bright_sum = {1'b0, work_bright} + {3'b000, pressure[15:11]};
    wire [6:0] pressured_bright = pressured_bright_sum[7] ? 7'd127 : pressured_bright_sum[6:0];

    wire sample_tick;                                  // 分数节拍器输出的一拍采样请求。
    wire [PHASE_WIDTH-1:0] lookup_phase_inc;          // pending_note 的同步 ROM 相位增量。
    wire signed [AUDIO_WIDTH-1:0] waveform_sample;     // 当前 waveform_address 的同步 ROM 样本。
    wire signed [WAVE_ENV_PRODUCT_WIDTH-1:0] wave_envelope_product;// 有符号波形×无符号包络全精度积。
    wire signed [WAVE_ENV_PRODUCT_WIDTH-1:0] envelope_shifted_full;// 包络积按 ENV_WIDTH 缩放后的全宽值。
    wire signed [AUDIO_WIDTH-1:0] envelope_scaled_sample;// 缩放并截取到音频宽度的波形。
    wire signed [VELOCITY_PRODUCT_WIDTH-1:0] velocity_product;// 包络后波形×无符号力度全精度积。
    wire signed [VELOCITY_PRODUCT_WIDTH-1:0] scaled_voice_product;// 力度积按 VELOCITY_WIDTH 缩放值。
    wire signed [INTERNAL_MIX_ACC_WIDTH-1:0] voice_mix_value;// 当前声部扩展到混音累加宽度的贡献。
    wire signed [AUDIO_WIDTH-1:0] limited_audio;       // 完整混音经缩放和硬限幅后的 PCM。

    /*
     * 事件声部查找每拍只检查一个槽，避免 VOICE_NUM 路 oldest-age 比较形成超长组合路径。
     * Note On 同时记录第一个空闲槽和最老活动槽；Note Off 记录第一个匹配且仍按下的槽。
     * 完整扫描后统一在 SCHED_EVENT_APPLY 修改声部数组，因而音频遍历始终看到一致快照。
     */
    reg [VOICE_INDEX_WIDTH-1:0] event_scan_index;       // 事件查找本拍检查的声部下标。
    reg event_found_inactive;                          // 已找到首个空闲声部的标志。
    reg [VOICE_INDEX_WIDTH-1:0] event_inactive_index;  // 首个空闲声部下标。
    reg event_found_oldest;                            // 已建立最老活动声部候选的标志。
    reg [VOICE_INDEX_WIDTH-1:0] event_oldest_index;    // 当前最老活动声部下标。
    reg [31:0] event_oldest_age;                       // 当前最老候选的年龄值。
    reg event_found_retrigger, event_found_tail;
    reg [VOICE_INDEX_WIDTH-1:0] event_retrigger_index, event_tail_index;
    reg [31:0] event_tail_age;
    reg event_found_release;                           // 已找到匹配 Note Off 声部的标志。
    reg [VOICE_INDEX_WIDTH-1:0] event_release_index;   // 首个仍按下且音符匹配的声部下标。
    wire [VOICE_INDEX_WIDTH-1:0] event_allocation_index;// Note On 最终选择的空闲/抢占下标。

    assign event_allocation_index = (PIANO_REFINED && event_found_retrigger) ? event_retrigger_index :
        event_found_inactive ? event_inactive_index :
        (PIANO_REFINED && event_found_tail) ? event_tail_index : event_oldest_index;
    // One-cycle lookahead keeps the existing one-slot-per-clock scan order.
    // Only active voices are compared, and an allocation writes the age before
    // setting that voice active. The RAM therefore needs no bulk reset.
    wire [VOICE_INDEX_WIDTH-1:0] age_read_index = (scheduler_state == SCHED_EVENT_SCAN && event_scan_index != VOICE_NUM-1) ? event_scan_index+1'b1 : 0;
    reg [31:0] event_scan_age;
    always @(posedge clk) begin
        event_scan_age <= voice_age[age_read_index];
        if(rst_n && scheduler_state == SCHED_EVENT_APPLY && pending_note_on && (event_found_inactive || event_found_oldest))
            voice_age[event_allocation_index] <= next_age;
    end

    assign expression_query_channel = work_channel;
    assign expression_query_note = work_note;

    // 上游必须保持事件字段，直到某个上升沿同时观察到 valid 和 ready。
    assign event_ready = !pending_valid;

    // 分数节拍器产生一拍宽 sample_tick；若上次遍历未结束，会计入 deadline_miss_count。
    sample_tick_gen #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),
        .SAMPLE_PERIOD_CYCLES(SAMPLE_PERIOD_CYCLES)
    ) sample_clock (
        .clk(clk),
        .rst_n(rst_n),
        .sample_tick(sample_tick)
    );

    /*
     * 相位 ROM 为一拍同步读，直接按当前声部音符查询。LOAD提交work_note，
     * EXPRESSION等待ROM并锁存弯音，PITCH应用弯音；不再重复缓存每声部相位增量。
     */
    note_phase_rom #(
        .PHASE_WIDTH(PHASE_WIDTH),
        .MEMORY_FILE(NOTE_PHASE_FILE)
    ) phase_lookup (
        .clk(clk),
        .note(work_note),
        .phase_inc(lookup_phase_inc)
    );

    // 分层波表是同步读；每次修改层号/地址后先等待 ROM 更新，再在下一拍捕获。
    piano_waveform_rom #(
        .WAVE_ADDR_WIDTH(WAVE_ADDR_WIDTH),
        .AUDIO_WIDTH(AUDIO_WIDTH), .STORAGE_WIDTH(WAVE_STORAGE_WIDTH),
        .LAYERS(WAVE_LAYERS),
        .MEMORY_FILE(WAVE_MEMORY_FILE)
    ) waveform_lookup (
        .clk(clk),
        .layer(waveform_layer),
        .address(waveform_address),
        .sample(waveform_sample)
    );

    /*
     * 定点增益严格分两级：signed 波形 × 带前导零的无符号包络，右移 ENV_WIDTH 丢弃
     * 包络小数位并恢复近似 AUDIO_WIDTH；再乘力度并右移 VELOCITY_WIDTH。不能把两次
     * 右移合并到末尾，否则中间截断规则、负数算术舍入和既定输出样本都会改变。
     */
    /*
     * 层间插值：先读层 L（wave_lower），再读层 L+1（waveform_sample），按力度低 4 位
     * 线性混合。这样力度→音色不再是 8 级台阶，而是连续的。
     */
    wire signed [AUDIO_WIDTH-1:0] wave_upper = (PIANO_REFINED && scheduler_state == SCHED_PIANO_LAYER) ? phase_upper : waveform_sample;
    wire signed [AUDIO_WIDTH:0]     wave_diff   = $signed(wave_upper) - $signed(wave_lower);
    wire signed [AUDIO_WIDTH+FRAC_BITS+1:0] wave_prod = wave_diff * $signed({1'b0, waveform_frac});
    wire signed [AUDIO_WIDTH-1:0]   wave_interp = wave_lower + wave_prod[AUDIO_WIDTH+FRAC_BITS-1:FRAC_BITS];

    assign wave_envelope_product = $signed(wave_blend) * $signed({1'b0, work_envelope_level});
    // 明确截取移位结果的低 AUDIO_WIDTH 位；合法包络范围内更高位只是符号扩展。
    // 这样既固定定点格式，也避免综合器对“隐式 17->16 位截断”给出误导性警告。
    assign envelope_shifted_full = wave_envelope_product >>> ENV_WIDTH;
    assign envelope_scaled_sample = envelope_shifted_full[AUDIO_WIDTH-1:0];
    assign velocity_product = work_envelope_scaled_sample * $signed({1'b0, work_velocity});
    assign scaled_voice_product = velocity_product >>> VELOCITY_WIDTH;

    // 将单声部结果截断或符号扩展到带保护位的内部累加器宽度。
    generate
        if (INTERNAL_MIX_ACC_WIDTH <= VELOCITY_PRODUCT_WIDTH) begin : narrow_mix_value
            assign voice_mix_value = scaled_voice_product[INTERNAL_MIX_ACC_WIDTH-1:0];
        end else begin : wide_mix_value
            assign voice_mix_value =
                {{(INTERNAL_MIX_ACC_WIDTH-VELOCITY_PRODUCT_WIDTH){scaled_voice_product[VELOCITY_PRODUCT_WIDTH-1]}},
                 scaled_voice_product};
        end
    endgenerate

    // 完整声部和在 OUTPUT_SHIFT 后做有符号硬饱和，结果由最后一个 WRITE 沿锁存。
    audio_limiter #(
        .INPUT_WIDTH(INTERNAL_MIX_ACC_WIDTH),
        .OUTPUT_WIDTH(AUDIO_WIDTH),
        .OUTPUT_SHIFT(OUTPUT_SHIFT)
    ) output_limiter (
        .mix_in(mix_accumulator),
        .audio_out(limited_audio)
    );

    // 同步低有效复位清空协议槽、调度器、输出、计数器和全部声部状态。
    integer reset_index;
    always @(posedge clk) begin
        if (!rst_n) begin
            pending_valid <= 1'b0;
            pending_note_on <= 1'b0;
            pending_note <= 7'd0;
            pending_patch <= 0; work_patch <= 0;
            pending_channel <= 4'd0;
            pending_velocity <= {VELOCITY_WIDTH{1'b0}};
            next_age <= 32'd0;
            sample_pending <= 1'b0;
            scheduler_state <= SCHED_IDLE;
            lfo_phase <= 16'd0;
            voice_index <= 0;
            mix_accumulator <= {INTERNAL_MIX_ACC_WIDTH{1'b0}};
            work_active <= 1'b0;
            work_channel <= 4'd0;
            work_bend <= 0;
            work_note <= 7'd0;
            work_phase_current <= {PHASE_WIDTH{1'b0}};
            work_phase_increment <= {PHASE_WIDTH{1'b0}};
            work_phase_next <= {PHASE_WIDTH{1'b0}};
            work_velocity <= {VELOCITY_WIDTH{1'b0}};
            work_envelope_state <= ENV_IDLE;
            work_envelope_level <= {ENV_WIDTH{1'b0}};
            work_release_step <= release_current;
            work_decay_counter <= {NATURAL_DECAY_COUNTER_WIDTH{1'b0}};
            work_bright <= 7'd0;
            work_bright_next <= 7'd0;
            work_bright_cnt <= 9'd0;
            work_bright_cnt_next <= 9'd0;
            work_envelope_scaled_sample <= {AUDIO_WIDTH{1'b0}};
            work_release_done <= 1'b0;
            waveform_address <= {WAVE_ADDR_WIDTH{1'b0}};
            waveform_layer <= {LAYER_BITS{1'b0}};
            waveform_frac  <= {FRAC_BITS{1'b0}};
            wave_lower     <= {AUDIO_WIDTH{1'b0}};
            wave_blend     <= {AUDIO_WIDTH{1'b0}};
            phase_lower <= 0; phase_upper <= 0; piano_layer_frac <= 0;
            audio_sample <= {AUDIO_WIDTH{1'b0}};
            audio_valid <= 1'b0;
            active_voice_count <= 32'd0;
            deadline_miss_count <= 32'd0;
            event_scan_index <= {VOICE_INDEX_WIDTH{1'b0}};
            event_found_inactive <= 1'b0;
            event_inactive_index <= {VOICE_INDEX_WIDTH{1'b0}};
            event_found_oldest <= 1'b0;
            event_oldest_index <= {VOICE_INDEX_WIDTH{1'b0}};
            event_oldest_age <= 32'd0;
            event_found_retrigger <= 0; event_found_tail <= 0;
            event_tail_age <= 0; event_retrigger_index <= 0; event_tail_index <= 0;
            event_found_release <= 1'b0;
            event_release_index <= {VOICE_INDEX_WIDTH{1'b0}};
            for (reset_index = 0; reset_index < VOICE_NUM; reset_index = reset_index + 1) begin
                voice_patch[reset_index] <= 0;
                voice_active[reset_index] <= 1'b0;
                voice_key_down[reset_index] <= 1'b0;
                voice_note[reset_index] <= 7'd0;
                voice_channel[reset_index] <= 4'd0;
                voice_phase[reset_index] <= {PHASE_WIDTH{1'b0}};
                voice_velocity[reset_index] <= {VELOCITY_WIDTH{1'b0}};
                voice_envelope_state[reset_index] <= ENV_IDLE;
                voice_envelope_level[reset_index] <= {ENV_WIDTH{1'b0}};
                voice_release_step[reset_index] <= release_current;
                voice_decay_counter[reset_index] <= {NATURAL_DECAY_COUNTER_WIDTH{1'b0}};
                voice_bright[reset_index] <= 7'd0;
                voice_bright_cnt[reset_index] <= 9'd0;
            end
        end else begin
            // 默认每拍撤销 valid，仅在完整遍历结束的 WRITE 沿拉高一拍。
            audio_valid <= 1'b0;

            // 接收只写 pending 槽，不在同一沿直接修改声部数组。
            if (event_valid && event_ready) begin
                pending_valid <= 1'b1;
                pending_note_on <= event_note_on;
                pending_note <= event_note;
                pending_patch <= event_patch;
                pending_channel <= event_channel;
                pending_velocity <= event_velocity;
            end

            /*
             * 事件扫描最多延迟一次音频遍历的启动，不丢弃该 tick：首次碰撞置 sample_pending，
             * APPLY 后立即开始计算。若音频遍历仍忙，或已有一个 tick 在等待时又来第二个，
             * 才是真正无法按期处理的采样截止期失败。
             */
            if (sample_tick) begin
                lfo_phase <= lfo_phase + LFO_INC[15:0];
                if (scheduler_state == SCHED_LOAD || scheduler_state == SCHED_EXPRESSION || scheduler_state == SCHED_PITCH || scheduler_state == SCHED_PREPARE ||
                    scheduler_state == SCHED_ROM_WAIT || scheduler_state == SCHED_ROM_LOWER ||
                    scheduler_state == SCHED_ROM_WAIT2 || scheduler_state == SCHED_ROM_BLEND ||
                    (scheduler_state >= SCHED_PIANO_WAIT0 && scheduler_state <= SCHED_PIANO_LAYER) ||
                    scheduler_state == SCHED_ENV_GAIN || scheduler_state == SCHED_GAIN ||
                    (scheduler_state == SCHED_WRITE && voice_index != VOICE_NUM - 1) ||
                    sample_pending) begin
                    deadline_miss_count <= deadline_miss_count + 1'b1;
                end else if (scheduler_state == SCHED_EVENT_SCAN ||
                             scheduler_state == SCHED_EVENT_APPLY ||
                             (scheduler_state == SCHED_IDLE && pending_valid) ||
                             (scheduler_state == SCHED_WRITE && voice_index == VOICE_NUM - 1)) begin
                    sample_pending <= 1'b1;
                end
            end

            case (scheduler_state)
                SCHED_IDLE: begin
                    // 已经排队的事件先完成有界扫描；与其相撞的单个 tick 由 sample_pending 保存。
                    if (pending_valid) begin
                        event_scan_index <= {VOICE_INDEX_WIDTH{1'b0}};
                        event_found_inactive <= 1'b0;
                        event_inactive_index <= {VOICE_INDEX_WIDTH{1'b0}};
                        event_found_oldest <= 1'b0;
                        event_found_retrigger <= 1'b0;
                        event_found_tail <= 1'b0;
                        event_tail_age <= 0;
                        event_retrigger_index <= 0;
                        event_tail_index <= 0;
                        event_oldest_index <= {VOICE_INDEX_WIDTH{1'b0}};
                        event_oldest_age <= 32'd0;
                        event_found_release <= 1'b0;
                        event_release_index <= {VOICE_INDEX_WIDTH{1'b0}};
                        scheduler_state <= SCHED_EVENT_SCAN;
                    end else if (sample_tick || sample_pending) begin
                        sample_pending <= 1'b0;
                        mix_accumulator <= {INTERNAL_MIX_ACC_WIDTH{1'b0}};
                        voice_index <= 0;
                        scheduler_state <= SCHED_LOAD;
                    end
                end

                SCHED_EVENT_SCAN: begin
                    if (pending_note_on) begin
                        // Repeated strikes of one piano string reuse that string.
                        // When full, reclaim an existing release tail before a held note.
                        if (PIANO_REFINED && voice_active[event_scan_index]) begin
                            if (!event_found_retrigger && voice_note[event_scan_index] == pending_note &&
                                voice_channel[event_scan_index] == pending_channel) begin
                                event_found_retrigger <= 1;
                                event_retrigger_index <= event_scan_index;
                            end
                            if (voice_envelope_state[event_scan_index] == ENV_RELEASE &&
                                (!event_found_tail || event_scan_age < event_tail_age)) begin
                                event_found_tail <= 1;
                                event_tail_index <= event_scan_index;
                                event_tail_age <= event_scan_age;
                            end
                        end
                        if (!event_found_inactive && !voice_active[event_scan_index]) begin
                            event_found_inactive <= 1'b1;
                            event_inactive_index <= event_scan_index;
                        end
                        if (voice_active[event_scan_index] &&
                            (!event_found_oldest || event_scan_age < event_oldest_age)) begin
                            event_found_oldest <= 1'b1;
                            event_oldest_index <= event_scan_index;
                            event_oldest_age <= event_scan_age;
                        end
                    end else if (!event_found_release && voice_active[event_scan_index] &&
                                 voice_key_down[event_scan_index] &&
                                 voice_note[event_scan_index] == pending_note &&
                                 voice_channel[event_scan_index] == pending_channel &&
                                 (!PATCH_BANK_ENABLE || voice_patch[event_scan_index] == pending_patch)) begin
                        event_found_release <= 1'b1;
                        event_release_index <= event_scan_index;
                    end

                    if (event_scan_index == VOICE_NUM - 1)
                        scheduler_state <= SCHED_EVENT_APPLY;
                    else
                        event_scan_index <= event_scan_index + 1'b1;
                end

                SCHED_EVENT_APPLY: begin
                    /*
                     * 新 inactive 声部使计数加一；满载抢占保持计数。Note Off 只进入
                     * RELEASE，真正回收和计数减一仍由音频遍历在包络到零时完成。
                     */
                    pending_valid <= 1'b0;
                    if (pending_note_on && (event_found_inactive || event_found_oldest)) begin
                        if (event_found_inactive && !(PIANO_REFINED && event_found_retrigger))
                            active_voice_count <= active_voice_count + 1'b1;
                        voice_active[event_allocation_index] <= 1'b1;
                        voice_key_down[event_allocation_index] <= 1'b1;
                        voice_note[event_allocation_index] <= pending_note;
                        voice_channel[event_allocation_index] <= pending_channel;
                        voice_patch[event_allocation_index] <= pending_patch;
                        voice_phase[event_allocation_index] <= {PHASE_WIDTH{1'b0}};
                        voice_velocity[event_allocation_index] <= pending_velocity;
                        // 起音亮度 = 力度（低/高音区更亮）；随后由亮度包络单调衰减。
                        voice_bright[event_allocation_index] <=
                            brightness_init(pending_velocity, pending_note);
                        voice_bright_cnt[event_allocation_index] <= 9'd0;
                        voice_envelope_state[event_allocation_index] <= ENV_ATTACK;
                        voice_envelope_level[event_allocation_index] <= {ENV_WIDTH{1'b0}};
                        voice_release_step[event_allocation_index] <= PATCH_BANK_ENABLE ? patch_release(pending_patch) : release_current;
                        voice_decay_counter[event_allocation_index] <=
                            {NATURAL_DECAY_COUNTER_WIDTH{1'b0}};
                        next_age <= next_age + 1'b1;
                    end else if (!pending_note_on && event_found_release) begin
                        voice_key_down[event_release_index] <= 1'b0;
                        if (!PATCH_BANK_ENABLE || pedal_position < 64)
                            voice_envelope_state[event_release_index] <= ENV_RELEASE;
                        voice_release_step[event_release_index] <= PATCH_BANK_ENABLE ?
                            patch_release(voice_patch[event_release_index]) : release_step_from_pedal(pending_velocity);
                    end

                    // 应用完成后优先兑现扫描期间锁存的 tick，新状态在下一拍 LOAD 中被读取。
                    if (sample_tick || sample_pending) begin
                        sample_pending <= 1'b0;
                        mix_accumulator <= {INTERNAL_MIX_ACC_WIDTH{1'b0}};
                        voice_index <= 0;
                        scheduler_state <= SCHED_LOAD;
                    end else begin
                        scheduler_state <= SCHED_IDLE;
                    end
                end

                SCHED_LOAD: begin
                    /*
                     * 这一拍只从 voice_index 指向的数组项读取并寄存，不做相位加法、
                     * 动态层选择或包络运算。这样动态数组多路选择后立即进入寄存器。
                     */
                    work_active <= voice_active[voice_index];
                    work_note <= voice_note[voice_index];
                    work_channel <= voice_channel[voice_index];
                    work_patch <= voice_patch[voice_index];
                    work_phase_current <= voice_phase[voice_index];
                    work_velocity <= voice_velocity[voice_index];
                    work_bright   <= voice_bright[voice_index];
                    work_bright_cnt <= voice_bright_cnt[voice_index];
                    work_envelope_state <= voice_envelope_state[voice_index];
                    work_envelope_level <= voice_envelope_level[voice_index];
                    work_release_step <= voice_release_step[voice_index];
                    work_decay_counter <= voice_decay_counter[voice_index];
                    work_release_done <= 1'b0;
                    if (PATCH_BANK_ENABLE && voice_active[voice_index] && !voice_key_down[voice_index] &&
                        pedal_position < 64 && voice_envelope_state[voice_index] != ENV_RELEASE) begin
                        work_envelope_state <= ENV_RELEASE;
                        work_release_step <= (pedal_position >= 32) ?
                            (patch_release(voice_patch[voice_index]) >> 1) : patch_release(voice_patch[voice_index]);
                    end
                    scheduler_state <= SCHED_EXPRESSION;
                end

                // Query the registered channel/note snapshot before computing
                // the modulated increment. This cuts the RAM/mux/multiply path.
                SCHED_EXPRESSION: begin
                    // LOAD registered note/channel. The synchronous phase ROM
                    // produces this note's increment at this edge; snapshot bend.
                    work_bend <= bend_total;
                    scheduler_state <= SCHED_PITCH;
                end
                SCHED_PITCH: begin
                    work_phase_increment <= bend_adjust(lookup_phase_inc);
                    scheduler_state <= SCHED_PREPARE;
                end

                SCHED_PREPARE: begin
                    /*
                     * 使用上一拍已寄存的声部快照计算下一相位、音色层和包络下一状态。
                     * 所有端点均饱和钳位，避免无符号加减的回绕。
                     */
                    work_phase_next <= work_phase_current + work_phase_increment;
                    waveform_address <= (work_phase_current + work_phase_increment) >>
                                        (PHASE_WIDTH - WAVE_ADDR_WIDTH);
                    // 连续亮度包络：高 LAYER_BITS 位选层、低 FRAC_BITS 位作层内插值。
                    // 不再按包络阶段换层——起音时亮度本来就最高，之后单调衰减。
                    waveform_layer <= pressured_bright[BRIGHT_BITS-1 -: LAYER_BITS];
                    waveform_frac <= pressured_bright;
                    if (PATCH_BANK_ENABLE) begin
                        // Four conservative anti-alias bands per patch; second ROM read
                        // interpolates adjacent phase samples, not different instruments.
                        waveform_layer <= {work_patch, (work_note < 60 ? 2'd0 : work_note < 84 ? 2'd1 : work_note < 108 ? 2'd2 : 2'd3)};
                        waveform_frac <= (work_phase_current + work_phase_increment) >> (PHASE_WIDTH-WAVE_ADDR_WIDTH-8);
                    end
                    // 亮度衰减：每 brightness_period 拍减 1，不低于力度决定的地板值。
                    if (PIANO_REFINED) begin
                        waveform_layer <= {work_note < 84 ? 2'd0 : work_note < 96 ? 2'd1 : work_note < 108 ? 2'd2 : 2'd3,
                                           pressured_bright[6:4]};
                        waveform_frac <= (work_phase_current + work_phase_increment) >> (PHASE_WIDTH-WAVE_ADDR_WIDTH-8);
                        piano_layer_frac <= {pressured_bright[3:0],4'b0};
                    end
                    if (work_active && work_bright > brightness_floor(work_velocity,work_note)) begin
                        if (work_bright_cnt >= brightness_period(work_velocity)) begin
                            work_bright_next     <= work_bright - 1'b1;
                            work_bright_cnt_next <= 9'd0;
                        end else begin
                            work_bright_next     <= work_bright;
                            work_bright_cnt_next <= work_bright_cnt + 1'b1;
                        end
                    end else begin
                        work_bright_next     <= work_bright;
                        work_bright_cnt_next <= work_bright_cnt;
                    end

                    if (work_active) begin
                        case (work_envelope_state)
                            ENV_ATTACK: begin
                                // 剩余距离不大于步长时钳到满幅并转入 DECAY。
                                if ((ENV_MAX - work_envelope_level) <= attack_current) begin
                                    work_envelope_level <= ENV_MAX;
                                    work_envelope_state <= ENV_DECAY;
                                    work_decay_counter <= {NATURAL_DECAY_COUNTER_WIDTH{1'b0}};
                                end else begin
                                    work_envelope_level <= work_envelope_level + attack_current;
                                end
                            end
                            ENV_DECAY: begin
                                // 已到或一步将跨过 sustain 时钳位，避免无符号减法下穿。
                                if (work_envelope_level <= sustain_current ||
                                    (work_envelope_level - sustain_current) <= decay_current) begin
                                    work_envelope_level <= sustain_current;
                                    work_envelope_state <= ENV_SUSTAIN;
                                    work_decay_counter <= {NATURAL_DECAY_COUNTER_WIDTH{1'b0}};
                                end else begin
                                    work_envelope_level <= work_envelope_level - decay_current;
                                end
                            end
                            ENV_SUSTAIN: begin
                                /*
                                 * 钢琴即使一直按住琴键也会自然消失。各音区按不同周期减 1：
                                 * 低音最长、高音最短；到零后像 Release 一样回收声部。
                                 */
                                if (NATURAL_DECAY_ENABLE == 0 || (PATCH_BANK_ENABLE && work_patch < 4)) begin
                                    work_envelope_level <= sustain_current;
                                end else if (work_decay_counter >=
                                             natural_decay_terminal_for_note(work_note)) begin
                                    work_decay_counter <=
                                        {NATURAL_DECAY_COUNTER_WIDTH{1'b0}};
                                    if (work_envelope_level <= NATURAL_DECAY_STEP) begin
                                        work_envelope_level <= {ENV_WIDTH{1'b0}};
                                        work_envelope_state <= ENV_IDLE;
                                        work_release_done <= 1'b1;
                                    end else begin
                                        work_envelope_level <=
                                            work_envelope_level - NATURAL_DECAY_STEP;
                                    end
                                end else begin
                                    work_decay_counter <= work_decay_counter + 1'b1;
                                end
                            end
                            ENV_RELEASE: begin
                                // 最后一步钳到零并标记释放完成；实际清 active 在 WRITE 沿执行。
                                if (work_envelope_level <= work_release_step) begin
                                    work_envelope_level <= {ENV_WIDTH{1'b0}};
                                    work_envelope_state <= ENV_IDLE;
                                    work_release_done <= 1'b1;
                                end else begin
                                    work_envelope_level <= work_envelope_level - work_release_step;
                                end
                            end
                            default: begin
                                work_envelope_level <= {ENV_WIDTH{1'b0}};
                                work_envelope_state <= ENV_IDLE;
                            end
                        endcase
                    end
                    scheduler_state <= SCHED_ROM_WAIT;
                end

                SCHED_ROM_WAIT: begin
                    // PREPARE 沿才提交地址；本拍让同步 ROM 输出层 L，不在同沿消费旧数据。
                    scheduler_state <= SCHED_ROM_LOWER;
                end

                SCHED_ROM_LOWER: begin
                    // 层 L 已稳定，先捕获；同时提交相邻层 L+1 的读取请求。
                    wave_lower <= waveform_sample;
                    if (PATCH_BANK_ENABLE || PIANO_REFINED)
                        waveform_address <= waveform_address + 1'b1;
                    else if (waveform_layer < (WAVE_LAYERS - 1))
                        waveform_layer <= waveform_layer + 1'b1;
                    scheduler_state <= SCHED_ROM_WAIT2;
                end

                SCHED_ROM_WAIT2: begin
                    // 层号在上一拍才改变；本拍让同步 ROM 输出层 L+1，避免混入层 L 旧值。
                    scheduler_state <= SCHED_ROM_BLEND;
                end

                SCHED_ROM_BLEND: begin
                    // 层 L+1 已稳定，与层 L 按亮度小数线性混合（最高层时两者相同）。
                    wave_blend <= wave_interp;
                    scheduler_state <= SCHED_ENV_GAIN;
                    if (PIANO_REFINED) begin
                        phase_lower <= wave_interp;
                        waveform_address <= waveform_address - 1'b1;
                        if (waveform_layer[2:0] != 7)
                            waveform_layer <= waveform_layer + 1'b1;
                        scheduler_state <= SCHED_PIANO_WAIT0;
                    end
                end

                SCHED_PIANO_WAIT0: scheduler_state <= SCHED_PIANO_READ0;
                SCHED_PIANO_READ0: begin
                    wave_lower <= waveform_sample;
                    waveform_address <= waveform_address + 1'b1;
                    scheduler_state <= SCHED_PIANO_WAIT1;
                end
                SCHED_PIANO_WAIT1: scheduler_state <= SCHED_PIANO_PHASE;
                SCHED_PIANO_PHASE: begin
                    phase_upper <= wave_interp;
                    wave_lower <= phase_lower;
                    waveform_frac <= piano_layer_frac;
                    scheduler_state <= SCHED_PIANO_LAYER;
                end
                SCHED_PIANO_LAYER: begin
                    wave_blend <= wave_interp;
                    scheduler_state <= SCHED_ENV_GAIN;
                end

                SCHED_ENV_GAIN: begin
                    // 第一乘法级单独寄存，避免波表 ROM 后串接两个乘法器再进入累加器。
                    work_envelope_scaled_sample <= envelope_scaled_sample;
                    scheduler_state <= SCHED_GAIN;
                end

                SCHED_GAIN: begin
                    // GAIN 结束沿把当前有效声部的两级定点结果加入宽累加器。
                    if (work_active)
                        mix_accumulator <= mix_accumulator + voice_mix_value;
                    scheduler_state <= SCHED_WRITE;
                end

                SCHED_WRITE: begin
                    // 回写相位与包络；Release 到零的声部在这里释放并递减活动计数。
                    if (work_active) begin
                        voice_phase[voice_index] <= work_phase_next;
                        voice_envelope_state[voice_index] <= work_envelope_state;
                        voice_envelope_level[voice_index] <= work_envelope_level;
                        voice_release_step[voice_index] <= work_release_step;
                        voice_decay_counter[voice_index] <= work_decay_counter;
                        voice_bright[voice_index] <= work_bright_next;
                        voice_bright_cnt[voice_index] <= work_bright_cnt_next;
                        if (work_release_done) begin
                            voice_active[voice_index] <= 1'b0;
                            voice_key_down[voice_index] <= 1'b0;
                            active_voice_count <= active_voice_count - 1'b1;
                        end
                    end

                    if (voice_index == VOICE_NUM - 1) begin
                        /*
                         * 最后声部的加法已在前一个 GAIN 沿写入 mix_accumulator，因此此处
                         * limited_audio 包含包括最后声部在内的完整和；随后锁存输出并拉高
                         * audio_valid 一拍。非末声部则递增索引，复用同一通路继续 LOAD。
                         */
                        audio_sample <= limited_audio;
                        audio_valid <= 1'b1;
                        scheduler_state <= SCHED_IDLE;
                    end else begin
                        voice_index <= voice_index + 1;
                        scheduler_state <= SCHED_LOAD;
                    end
                end

                default: scheduler_state <= SCHED_IDLE;
            endcase
        end
    end
endmodule
