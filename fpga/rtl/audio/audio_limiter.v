/*
 * 有符号混音缩放与硬限幅器，完全组合逻辑、无时钟和复位。
 * mix_in 先做算术右移以保留负数符号，再与扩展到输入位宽的正负输出轨比较；超出范围
 * 时分别钳位到 +2^(OUTPUT_WIDTH-1)-1 或 -2^(OUTPUT_WIDTH-1)，范围内才截取低位。
 * 先符号扩展轨值再比较，可避免不同位宽表达式把负数误当无符号数。audio_out 会随
 * mix_in 的组合传播延迟更新，上层只能在其混音累加值稳定后锁存。
 */
module audio_limiter #(
    // 单位 bit，合法范围 INPUT_WIDTH>=OUTPUT_WIDTH；增加会提高混音余量和比较器资源。
    // 无 ROM，修改后无需重生成表。
    parameter integer INPUT_WIDTH = 24,
    // 单位 bit，合法范围 >=2 且 <=INPUT_WIDTH；决定输出动态范围和饱和轨。
    // 单独使用本模块无需 ROM；完整核心若修改音频位宽，必须重生成 composite_waveform.mem。
    parameter integer OUTPUT_WIDTH = 16,
    // 单位 bit，合法范围 0..INPUT_WIDTH-1；增大可降低增益并增加削顶余量，不增加 ROM。
    parameter integer OUTPUT_SHIFT = 5
) (
    // 已完成多声部求和的有符号混音值；组合输入，无 ready/valid 握手。
    input  wire signed [INPUT_WIDTH-1:0] mix_in,
    // mix_in 右移并限幅后的有符号 PCM；随组合传播延迟更新。
    output reg  signed [OUTPUT_WIDTH-1:0] audio_out
);
    // 二补码上下轨：最高位分别为 0/1，其余位分别为全 1/0。
    localparam signed [OUTPUT_WIDTH-1:0] AUDIO_MAX = {1'b0, {(OUTPUT_WIDTH-1){1'b1}}};
    localparam signed [OUTPUT_WIDTH-1:0] AUDIO_MIN = {1'b1, {(OUTPUT_WIDTH-1){1'b0}}};

    wire signed [INPUT_WIDTH-1:0] shifted_mix;       // mix_in 算术右移 OUTPUT_SHIFT 后的同宽值。
    wire signed [INPUT_WIDTH-1:0] audio_max_extended;// 正输出轨符号扩展到 INPUT_WIDTH 的比较值。
    wire signed [INPUT_WIDTH-1:0] audio_min_extended;// 负输出轨符号扩展到 INPUT_WIDTH 的比较值。

    // >>> 在 signed 操作数上复制符号位；负数缩放不会被补零变成大正数。
    assign shifted_mix = mix_in >>> OUTPUT_SHIFT;
    // 将两条输出轨符号扩展至 INPUT_WIDTH 后再作同宽有符号比较。
    assign audio_max_extended = {{(INPUT_WIDTH-OUTPUT_WIDTH){AUDIO_MAX[OUTPUT_WIDTH-1]}}, AUDIO_MAX};
    assign audio_min_extended = {{(INPUT_WIDTH-OUTPUT_WIDTH){AUDIO_MIN[OUTPUT_WIDTH-1]}}, AUDIO_MIN};

    // 超轨值硬饱和；仅对已经确认在范围内的值保留 OUTPUT_WIDTH 个低位。
    always @* begin
        if (shifted_mix > audio_max_extended)
            audio_out = AUDIO_MAX;
        else if (shifted_mix < audio_min_extended)
            audio_out = AUDIO_MIN;
        else
            audio_out = shifted_mix[OUTPUT_WIDTH-1:0];
    end
endmodule
