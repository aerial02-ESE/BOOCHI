/*
 * 弯音值 → 相位增量比率映射（Q1.15 增量）。
 *
 * ControlEvent 的 PITCH_BEND value 为 0..65535，32768 为中点。合成核需要的不是绝对值
 * 而是"相位增量的相对变化"：delta = 2^(bend/1200) - 1（bend 单位为半音）。
 * 默认范围 ±200 音分（±2 半音），该范围内用线性近似即可：
 *   full_scale_delta = 2^(200/1200) - 1 = 0.12246 → Q1.15 = 4014。
 * 因此 delta_q15 = (value - 32768) * 4014 / 32768。
 *
 * 若要改变弯音范围 RANGE_CENTS，需同步更新 BEND_FULL_SCALE_Q15
 * （= round((2^(RANGE_CENTS/1200) - 1) * 32768)）。
 */
module pitch_bend_map #(
    // 弯音范围（音分，全量程对应值）；仅用于文档，实际由 BEND_FULL_SCALE_Q15 决定。
    parameter integer RANGE_CENTS = 200,
    // 全量程对应的 Q1.15 增量（默认 ±200 音分）。
    parameter integer BEND_FULL_SCALE_Q15 = 4014
) (
    // 0..65535，32768 为中点。
    input  wire [15:0]       value,
    // 有符号 Q1.15 增量：0 表示无弯音，正值升调。
    output wire signed [15:0] delta_q15
);
    // 以 32768 为中心的有符号偏差。
    wire signed [16:0] centered = $signed({1'b0, value}) - 17'sd32768;
    // 乘系数后右移 15 位还原 Q1.15。
    wire signed [32:0] product  = centered * $signed(BEND_FULL_SCALE_Q15);
    assign delta_q15 = product[30:15];
endmodule
