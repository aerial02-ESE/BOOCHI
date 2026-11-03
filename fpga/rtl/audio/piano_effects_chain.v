/*
 * 增强钢琴效果链：阻尼反馈空间延迟、踏板控制的弦/音板共振和机械踏板噪声。
 *
 * 每个 input_valid 表示一个新 PCM 样本；两个延迟 RAM 只在有效样本时推进，所以参数
 * 单位都是音频采样点。空间延迟提供较长的房间尾音；较短的共振延迟由踏板位置控制
 * 反馈与输出，使阻尼器抬起时历史能量产生近似的同情弦/音板共鸣。
 *
 * pedal_position 变化会触发一个确定性 LFSR 噪声包络，模拟踏板机构和阻尼器动作。
 * 两块 RAM 都故意不逐项复位；各自写满一圈前把读值视为 0，避免未初始化内容出声。
 */
module piano_effects_chain #(
    // signed PCM 位宽；当前工程使用 16 bit。
    parameter integer DATA_WIDTH = 16,
    // 空间反馈延迟长度，单位为 input_valid 样本；4096 点在 48 kHz 下约 85.3 ms。
    parameter integer DELAY_SAMPLES = 4096,
    // 1=启用空间反馈延迟，0=关闭该支路。
    parameter integer ENABLE = 1,
    // 空间湿声增益为 1/(2**WET_SHIFT)。
    parameter integer WET_SHIFT = 2,
    // 空间反馈增益为 1/(2**FEEDBACK_SHIFT)，必须大于 0。
    parameter integer FEEDBACK_SHIFT = 2,
    // 连续踏板位置位宽；默认 7 bit 对应 0..127。
    parameter integer PEDAL_POSITION_WIDTH = 7,
    // 1=启用踏板控制的短延迟共振支路。
    parameter integer STRING_RESONANCE_ENABLE = 1,
    // 共振延迟长度；997 点在 48 kHz 下约 20.8 ms，形成低频梳状模态及其泛音。
    parameter integer STRING_RESONANCE_DELAY_SAMPLES = 997,
    // 共振输出和反馈的二进制右移增益。
    parameter integer STRING_RESONANCE_WET_SHIFT = 3,
    parameter integer STRING_RESONANCE_FEEDBACK_SHIFT = 1,
    // 1=踏板位置改变时加入短促机械噪声。
    parameter integer PEDAL_NOISE_ENABLE = 1,
    // 机械噪声最终右移增益；越大越安静。
    parameter integer PEDAL_NOISE_GAIN_SHIFT = 4,
    // 噪声包络每样本衰减约 1/(2**该值)；8 对应约 5.3 ms e-fold。
    parameter integer PEDAL_NOISE_DECAY_SHIFT = 8
) (
    // 合成系统时钟；input_valid 的平均采样率由上游决定。
    input  wire                                      clk,
    // 同步低有效复位；只清控制状态，不清大延迟 RAM。
    input  wire                                      rst_n,
    // 输入样本有效脉冲。
    input  wire                                      input_valid,
    // 当前 signed 干声 PCM。
    input  wire signed [DATA_WIDTH-1:0]             input_sample,
    // 已滤波的连续踏板位置；0=松开，满量程=完全踩下。
    input  wire [PEDAL_POSITION_WIDTH-1:0]          pedal_position,
    // 输入被第一级接受后的下一个 clk 上升沿产生输出有效脉冲。
    output reg                                       output_valid,
    // 干声、空间、共振和机械噪声混合后经饱和的 signed PCM。
    output reg signed [DATA_WIDTH-1:0]              output_sample
);
    // 返回至少 1 bit 的向上取整 log2，用于非 2 次幂 RAM 指针。
    function integer ceil_log2_nonzero;
        input integer value;            // 需要编码的元素数量。
        integer remaining;              // value-1 的局部右移临时量。
        begin
            remaining = value - 1;
            ceil_log2_nonzero = 0;
            while (remaining > 0) begin
                remaining = remaining >> 1;
                ceil_log2_nonzero = ceil_log2_nonzero + 1;
            end
            if (ceil_log2_nonzero < 1)
                ceil_log2_nonzero = 1;
        end
    endfunction

    localparam integer DELAY_POINTER_WIDTH = ceil_log2_nonzero(DELAY_SAMPLES);
    localparam integer RESONANCE_POINTER_WIDTH =
        ceil_log2_nonzero(STRING_RESONANCE_DELAY_SAMPLES);
    localparam integer MIX_WIDTH = DATA_WIDTH + 4;
    localparam integer PEDAL_PRODUCT_WIDTH =
        DATA_WIDTH + PEDAL_POSITION_WIDTH + 1;
    localparam integer NOISE_PRODUCT_WIDTH = DATA_WIDTH + 17;

    /*
     * 把 MIX_WIDTH signed 值钳位到 DATA_WIDTH。input_value 是四条支路求和，
     * 返回值是不会发生二补码回绕的最终 PCM 或 RAM 写回值。
     */
    function signed [DATA_WIDTH-1:0] saturate_sample;
        input signed [MIX_WIDTH-1:0] input_value; // 需要饱和的扩展位宽有符号值。
        reg signed [MIX_WIDTH-1:0] maximum_value; // 输出正最大值的符号扩展。
        reg signed [MIX_WIDTH-1:0] minimum_value; // 输出负最小值的符号扩展。
        begin
            maximum_value = ({{(MIX_WIDTH-1){1'b0}}, 1'b1} << (DATA_WIDTH - 1)) - 1'b1;
            minimum_value = -({{(MIX_WIDTH-1){1'b0}}, 1'b1} << (DATA_WIDTH - 1));
            if (input_value > maximum_value)
                saturate_sample = {1'b0, {(DATA_WIDTH-1){1'b1}}};
            else if (input_value < minimum_value)
                saturate_sample = {1'b1, {(DATA_WIDTH-1){1'b0}}};
            else
                saturate_sample = input_value[DATA_WIDTH-1:0];
        end
    endfunction

    // 长空间延迟；不复位 RAM 内容，只复位指针和安全填满标志。
    reg signed [DATA_WIDTH-1:0] delay_memory [0:DELAY_SAMPLES-1];
    reg [DELAY_POINTER_WIDTH-1:0] delay_pointer;       // 下一有效样本读写的长延迟地址。
    reg delay_filled;                                  // 长延迟至少完整写过一圈。
    reg signed [DATA_WIDTH-1:0] previous_delay;       // 上一长延迟样本，用于两点阻尼。

    // 短共振延迟；同样用填满标志屏蔽上电未知 RAM 内容。
    reg signed [DATA_WIDTH-1:0] resonance_memory [0:STRING_RESONANCE_DELAY_SAMPLES-1];
    reg [RESONANCE_POINTER_WIDTH-1:0] resonance_pointer;// 下一有效样本读写的共振地址。
    reg resonance_filled;                              // 共振 RAM 至少完整写过一圈。
    reg signed [DATA_WIDTH-1:0] previous_resonance;   // 上一共振样本，用于高频阻尼。

    // 机械噪声状态；LFSR 使用固定非零种子，仿真和硬件可重复。
    reg [15:0] pedal_noise_lfsr;                       // x^16+x^14+x^13+x^11+1 LFSR。
    reg [DATA_WIDTH-1:0] pedal_noise_envelope;         // 无符号噪声幅度包络。
    reg [PEDAL_POSITION_WIDTH-1:0] previous_pedal_position;// 上个有效样本观察到的位置。

    /*
     * 效果流水寄存器：第一级读取延迟 RAM、完成乘法和各支路缩放，第二级再求和、
     * 饱和并写回 RAM。这样 BSRAM->DSP 与多路加法不会落在同一条 sys_clk 路径上。
     * stage_* 每项都只对应同一个 input_valid 样本；地址随样本保存，允许连续输入。
     */
    reg stage_valid;                                   // 1=stage_* 中保存一个待输出样本。
    reg signed [DATA_WIDTH-1:0] stage_dry_sample;      // 第一级锁存的干声。
    reg signed [DATA_WIDTH-1:0] stage_delay_sample;    // 第一级锁存的阻尼空间延迟。
    reg signed [DATA_WIDTH-1:0] stage_resonance_sample;// 第一级锁存的踏板缩放共振。
    reg signed [DATA_WIDTH-1:0] stage_noise_sample;    // 第一级锁存的机械噪声。
    reg [DELAY_POINTER_WIDTH-1:0] stage_delay_address;// 该样本应写回的空间 RAM 地址。
    reg [RESONANCE_POINTER_WIDTH-1:0] stage_resonance_address;// 该样本应写回的共振地址。

    wire signed [DATA_WIDTH-1:0] raw_delay_sample;    // 长延迟当前地址的原始 RAM 值。
    wire signed [DATA_WIDTH-1:0] effective_delay;     // 未填满前强制为 0 的长延迟值。
    wire signed [DATA_WIDTH:0] delay_damping_sum;     // 当前与上一长延迟值之和。
    wire signed [DATA_WIDTH-1:0] damped_delay;        // 两点平均后的空间反馈。

    wire signed [DATA_WIDTH-1:0] raw_resonance_sample;// 共振当前地址的原始 RAM 值。
    wire signed [DATA_WIDTH-1:0] effective_resonance; // 未填满前强制为 0 的共振值。
    wire signed [DATA_WIDTH:0] resonance_damping_sum; // 当前与上一共振值之和。
    wire signed [DATA_WIDTH-1:0] damped_resonance;    // 两点平均后的共振反馈。
    wire signed [PEDAL_PRODUCT_WIDTH-1:0] resonance_pedal_product;// 共振×无符号踏板位置。
    wire signed [PEDAL_PRODUCT_WIDTH-1:0] resonance_position_shifted;// 除以位置满量程后的值。
    wire signed [DATA_WIDTH-1:0] resonance_position_scaled;// 踏板控制后的 DATA_WIDTH 共振值。

    wire [PEDAL_POSITION_WIDTH:0] pedal_movement_delta;// 相邻有效样本间的绝对踏板位移。
    wire pedal_moving_down;                           // 1=位置数值增加，即继续踩下。
    wire [DATA_WIDTH-1:0] movement_envelope_down;     // 踩下动作的目标噪声包络。
    wire [DATA_WIDTH-1:0] movement_envelope_up;       // 松开动作的较轻目标噪声包络。
    wire [DATA_WIDTH-1:0] pedal_noise_decay_amount;   // 每样本至少 1 LSB 的包络衰减量。
    wire signed [15:0] pedal_noise_random;            // LFSR 解释为二补码宽带噪声。
    wire signed [NOISE_PRODUCT_WIDTH-1:0] pedal_noise_product;// 噪声×无符号包络全精度积。
    wire signed [NOISE_PRODUCT_WIDTH-1:0] pedal_noise_shifted;// 缩放后的机械噪声。
    wire signed [DATA_WIDTH-1:0] pedal_noise_sample;  // 截取到音频位宽的机械噪声。

    wire signed [MIX_WIDTH-1:0] dry_extended;         // 扩展后的流水干声样本。
    wire signed [MIX_WIDTH-1:0] delay_extended;       // 扩展后的流水空间延迟样本。
    wire signed [MIX_WIDTH-1:0] resonance_extended;   // 扩展后的流水踏板共振样本。
    wire signed [MIX_WIDTH-1:0] pedal_noise_extended; // 扩展后的流水机械噪声样本。
    wire signed [MIX_WIDTH-1:0] delay_output_component;// 空间延迟的有符号湿声分量。
    wire signed [MIX_WIDTH-1:0] resonance_output_component;// 弦共振的有符号湿声分量。
    wire signed [MIX_WIDTH-1:0] noise_output_component;// 踏板机械噪声分量。
    wire signed [MIX_WIDTH-1:0] output_mix;           // 四条支路的输出求和。
    wire signed [MIX_WIDTH-1:0] delay_feedback_mix;   // 干声加空间反馈，写回长 RAM。
    wire signed [MIX_WIDTH-1:0] resonance_feedback_mix;// 干声加踏板控制反馈，写回短 RAM。

    assign raw_delay_sample = delay_memory[delay_pointer];
    assign effective_delay = delay_filled ? raw_delay_sample : {DATA_WIDTH{1'b0}};
    assign delay_damping_sum = $signed(effective_delay) + $signed(previous_delay);
    assign damped_delay = delay_damping_sum >>> 1;

    assign raw_resonance_sample = resonance_memory[resonance_pointer];
    assign effective_resonance = resonance_filled ? raw_resonance_sample : {DATA_WIDTH{1'b0}};
    assign resonance_damping_sum = $signed(effective_resonance) + $signed(previous_resonance);
    assign damped_resonance = resonance_damping_sum >>> 1;
    assign resonance_pedal_product =
        $signed(damped_resonance) * $signed({1'b0, pedal_position});
    assign resonance_position_shifted =
        resonance_pedal_product >>> PEDAL_POSITION_WIDTH;
    assign resonance_position_scaled =
        resonance_position_shifted[DATA_WIDTH-1:0];

    assign pedal_moving_down = pedal_position > previous_pedal_position;
    assign pedal_movement_delta = pedal_moving_down ?
        ({1'b0, pedal_position} - {1'b0, previous_pedal_position}) :
        ({1'b0, previous_pedal_position} - {1'b0, pedal_position});
    // 默认 16/7 位配置下，踩下位移左移 8、松开左移 7，形成不同机械力度。
    assign movement_envelope_down =
        pedal_movement_delta << (DATA_WIDTH - PEDAL_POSITION_WIDTH - 1);
    assign movement_envelope_up =
        pedal_movement_delta << (DATA_WIDTH - PEDAL_POSITION_WIDTH - 2);
    assign pedal_noise_decay_amount =
        ((pedal_noise_envelope >> PEDAL_NOISE_DECAY_SHIFT) == 0) ?
        {{(DATA_WIDTH-1){1'b0}}, 1'b1} :
        (pedal_noise_envelope >> PEDAL_NOISE_DECAY_SHIFT);
    assign pedal_noise_random = $signed(pedal_noise_lfsr);
    assign pedal_noise_product =
        pedal_noise_random * $signed({1'b0, pedal_noise_envelope});
    assign pedal_noise_shifted =
        pedal_noise_product >>> (DATA_WIDTH - 1 + PEDAL_NOISE_GAIN_SHIFT);
    assign pedal_noise_sample = pedal_noise_shifted[DATA_WIDTH-1:0];

    assign dry_extended =
        {{(MIX_WIDTH-DATA_WIDTH){stage_dry_sample[DATA_WIDTH-1]}}, stage_dry_sample};
    assign delay_extended =
        {{(MIX_WIDTH-DATA_WIDTH){stage_delay_sample[DATA_WIDTH-1]}},
         stage_delay_sample};
    assign resonance_extended =
        {{(MIX_WIDTH-DATA_WIDTH){stage_resonance_sample[DATA_WIDTH-1]}},
         stage_resonance_sample};
    assign pedal_noise_extended =
        {{(MIX_WIDTH-DATA_WIDTH){stage_noise_sample[DATA_WIDTH-1]}},
         stage_noise_sample};

    /*
     * 先在独立的 signed 网络上做算术右移。不要把 >>> 直接放在
     * “signed 数据 : unsigned 零向量”的三目表达式里：Verilog 的上下文
     * 类型会把负数湿声改成逻辑右移。24-bit 模式下每个负共振样本
     * 因此额外产生 2**24 的正偏置，并在最终饱和器处卡到正满幅。
     */
    generate
        if (ENABLE != 0) begin : gen_delay_output
            assign delay_output_component = delay_extended >>> WET_SHIFT;
        end else begin : gen_no_delay_output
            assign delay_output_component = {MIX_WIDTH{1'b0}};
        end

        if (STRING_RESONANCE_ENABLE != 0) begin : gen_resonance_output
            assign resonance_output_component =
                resonance_extended >>> STRING_RESONANCE_WET_SHIFT;
        end else begin : gen_no_resonance_output
            assign resonance_output_component = {MIX_WIDTH{1'b0}};
        end

        if (PEDAL_NOISE_ENABLE != 0) begin : gen_noise_output
            assign noise_output_component = pedal_noise_extended;
        end else begin : gen_no_noise_output
            assign noise_output_component = {MIX_WIDTH{1'b0}};
        end
    endgenerate

    assign output_mix = dry_extended + delay_output_component +
        resonance_output_component + noise_output_component;
    assign delay_feedback_mix = dry_extended + (delay_extended >>> FEEDBACK_SHIFT);
    assign resonance_feedback_mix =
        dry_extended + (resonance_extended >>> STRING_RESONANCE_FEEDBACK_SHIFT);

    // synthesis translate_off
    initial begin
        if (DATA_WIDTH < 16 || DELAY_SAMPLES < 2 ||
            STRING_RESONANCE_DELAY_SAMPLES < 2 || PEDAL_POSITION_WIDTH < 2 ||
            DATA_WIDTH <= PEDAL_POSITION_WIDTH + 2 || WET_SHIFT < 1 ||
            FEEDBACK_SHIFT < 1 || STRING_RESONANCE_WET_SHIFT < 1 ||
            STRING_RESONANCE_FEEDBACK_SHIFT < 1 || PEDAL_NOISE_GAIN_SHIFT < 1 ||
            PEDAL_NOISE_DECAY_SHIFT < 1)
            $error("piano_effects_chain: invalid width, delay, or gain parameters");
    end
    // synthesis translate_on

    always @(posedge clk) begin
        if (!rst_n) begin
            delay_pointer <= {DELAY_POINTER_WIDTH{1'b0}};
            delay_filled <= 1'b0;
            previous_delay <= {DATA_WIDTH{1'b0}};
            resonance_pointer <= {RESONANCE_POINTER_WIDTH{1'b0}};
            resonance_filled <= 1'b0;
            previous_resonance <= {DATA_WIDTH{1'b0}};
            pedal_noise_lfsr <= 16'h1ace;
            pedal_noise_envelope <= {DATA_WIDTH{1'b0}};
            previous_pedal_position <= {PEDAL_POSITION_WIDTH{1'b0}};
            stage_valid <= 1'b0;
            stage_dry_sample <= {DATA_WIDTH{1'b0}};
            stage_delay_sample <= {DATA_WIDTH{1'b0}};
            stage_resonance_sample <= {DATA_WIDTH{1'b0}};
            stage_noise_sample <= {DATA_WIDTH{1'b0}};
            stage_delay_address <= {DELAY_POINTER_WIDTH{1'b0}};
            stage_resonance_address <= {RESONANCE_POINTER_WIDTH{1'b0}};
            output_valid <= 1'b0;
            output_sample <= {DATA_WIDTH{1'b0}};
        end else begin
            // 第二级消费上拍锁存的四条支路；无有效样本时不改 PCM 数值。
            output_valid <= stage_valid;
            if (stage_valid) begin
                output_sample <= saturate_sample(output_mix);

                if (ENABLE != 0) begin
                    delay_memory[stage_delay_address] <=
                        saturate_sample(delay_feedback_mix);
                end

                if (STRING_RESONANCE_ENABLE != 0) begin
                    resonance_memory[stage_resonance_address] <=
                        saturate_sample(resonance_feedback_mix);
                end
            end

            // 第一级可每拍接收一个样本；顶层实际相邻样本约间隔 1667 个 sys_clk。
            stage_valid <= input_valid;
            if (input_valid) begin
                stage_dry_sample <= input_sample;
                stage_delay_sample <= damped_delay;
                stage_resonance_sample <= resonance_position_scaled;
                stage_noise_sample <= pedal_noise_sample;
                stage_delay_address <= delay_pointer;
                stage_resonance_address <= resonance_pointer;

                if (ENABLE != 0) begin
                    previous_delay <= effective_delay;
                    if (delay_pointer == DELAY_SAMPLES - 1) begin
                        delay_pointer <= {DELAY_POINTER_WIDTH{1'b0}};
                        delay_filled <= 1'b1;
                    end else begin
                        delay_pointer <= delay_pointer + 1'b1;
                    end
                end

                if (STRING_RESONANCE_ENABLE != 0) begin
                    previous_resonance <= effective_resonance;
                    if (resonance_pointer == STRING_RESONANCE_DELAY_SAMPLES - 1) begin
                        resonance_pointer <= {RESONANCE_POINTER_WIDTH{1'b0}};
                        resonance_filled <= 1'b1;
                    end else begin
                        resonance_pointer <= resonance_pointer + 1'b1;
                    end
                end

                previous_pedal_position <= pedal_position;
                if (PEDAL_NOISE_ENABLE != 0) begin
                    pedal_noise_lfsr <=
                        {pedal_noise_lfsr[14:0],
                         pedal_noise_lfsr[15] ^ pedal_noise_lfsr[13] ^
                         pedal_noise_lfsr[12] ^ pedal_noise_lfsr[10]};
                    if (pedal_movement_delta != 0) begin
                        pedal_noise_envelope <= pedal_moving_down ?
                            movement_envelope_down : movement_envelope_up;
                    end else if (pedal_noise_envelope != 0) begin
                        if (pedal_noise_envelope <= pedal_noise_decay_amount)
                            pedal_noise_envelope <= {DATA_WIDTH{1'b0}};
                        else
                            pedal_noise_envelope <=
                                pedal_noise_envelope - pedal_noise_decay_amount;
                    end
                end else begin
                    pedal_noise_envelope <= {DATA_WIDTH{1'b0}};
                end
            end
        end
    end
endmodule
