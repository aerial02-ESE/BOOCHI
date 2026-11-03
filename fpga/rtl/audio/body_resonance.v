/*
 * 共享音板谐振：把混音后的单声道 PCM 通过几个固定二阶谐振模态，近似木质音板对声音的
 * 染色与延长。所有声部共享这一级，不阻塞音频（每样本分时处理 MODES 个模态）。
 *
 * 每个模态：y = ((a1*y1 - a2*y2) >>> 14) + ((x*gain) >>> 14)，a1/a2/gain 为 Q1.14。
 * 输出 = 模态和 + 干声，保持直接通路。系数由 reference/gen_tables.py 的 BODY_MODES 生成。
 */
module body_resonance #(
    parameter integer MODES = 3,
    parameter integer MODE_INDEX_WIDTH = 2,
    parameter integer DATA_WIDTH = 24,
    parameter integer Y_WIDTH = 32,
    parameter integer PROD_WIDTH = 48,
    // Wet gain is 1/(2**WET_SHIFT). The modes are a coloration on top of the
    // dry piano; with a dense cluster the dry sum is already near full scale,
    // so the wet path must stay well below it to preserve output headroom.
    parameter integer WET_SHIFT = 3
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         in_valid,
    input  wire signed [DATA_WIDTH-1:0] in_sample,
    output reg                          out_valid,
    output reg  signed [DATA_WIDTH-1:0] out_sample
);
    localparam [2:0] S_IDLE = 2'd0;
    localparam [2:0] S_LOAD = 2'd1;
    localparam [2:0] S_MUL  = 2'd2;
    localparam [2:0] S_COMB = 2'd3;

    reg signed [Y_WIDTH-1:0] y1 [0:MODES-1];
    reg signed [Y_WIDTH-1:0] y2 [0:MODES-1];
    reg [MODE_INDEX_WIDTH-1:0] mode;
    reg signed [DATA_WIDTH-1:0] x;
    reg signed [63:0] acc;
    reg signed [PROD_WIDTH-1:0] prod1;
    reg signed [PROD_WIDTH-1:0] prod2;
    reg signed [PROD_WIDTH-1:0] prod3;
    reg [2:0] state;
    localparam [2:0] S_DC_DIFF=3'd4, S_DC_OUT=3'd5;
    reg signed [DATA_WIDTH-1:0] out_sat_q;
    reg signed [47:0] dc_diff_q;

    wire signed [15:0] a1;
    wire signed [15:0] a2;
    wire signed [15:0] gain;

    body_mode_rom #(
        .MODES(MODES),
        .MODE_INDEX_WIDTH(MODE_INDEX_WIDTH)
    ) coefficient_rom (
        .clk(clk),
        .mode(mode),
        .a1(a1),
        .a2(a2),
        .gain(gain)
    );

    wire signed [PROD_WIDTH-1:0] p1m2  = prod1 - prod2;
    wire signed [PROD_WIDTH-1:0] p1m2s = p1m2 >>> 14;
    wire signed [PROD_WIDTH-1:0] p3s   = prod3 >>> 14;
    wire signed [PROD_WIDTH:0]   y_new = p1m2s + p3s;
    wire signed [63:0]           body_wet = acc + y_new;
    wire signed [63:0]           out_comb = x + (body_wet >>> WET_SHIFT);

    // The shared body is driven by all piano voices summed together. A full
    // cluster can push the high-Q low mode well past 24 bits; truncating
    // either the state or the output then wraps around and turns into noise.
    localparam signed [Y_WIDTH-1:0] Y_MAX = {1'b0, {(Y_WIDTH-1){1'b1}}};
    localparam signed [Y_WIDTH-1:0] Y_MIN = {1'b1, {(Y_WIDTH-1){1'b0}}};
    localparam signed [PROD_WIDTH:0] Y_MAX_EXT =
        {{(PROD_WIDTH + 1 - Y_WIDTH){1'b0}}, Y_MAX};
    localparam signed [PROD_WIDTH:0] Y_MIN_EXT =
        {{(PROD_WIDTH + 1 - Y_WIDTH){1'b1}}, Y_MIN};
    wire signed [Y_WIDTH-1:0] y_sat =
        (y_new > Y_MAX_EXT) ? Y_MAX :
        (y_new < Y_MIN_EXT) ? Y_MIN :
        y_new[Y_WIDTH-1:0];

    localparam signed [DATA_WIDTH-1:0] OUT_MAX =
        {1'b0, {(DATA_WIDTH-1){1'b1}}};
    localparam signed [DATA_WIDTH-1:0] OUT_MIN =
        {1'b1, {(DATA_WIDTH-1){1'b0}}};
    localparam signed [63:0] OUT_MAX_EXT64 =
        {{(64-DATA_WIDTH){1'b0}}, OUT_MAX};
    localparam signed [63:0] OUT_MIN_EXT64 =
        {{(64-DATA_WIDTH){1'b1}}, OUT_MIN};
    wire signed [DATA_WIDTH-1:0] out_sat =
        (out_comb > OUT_MAX_EXT64) ? OUT_MAX :
        (out_comb < OUT_MIN_EXT64) ? OUT_MIN :
        out_comb[DATA_WIDTH-1:0];

    // ~15 Hz high-pass on the body input. Removing DC/subsonic energy before
    // the high-Q low mode is what prevents a dense cluster from pumping the
    // resonator into its rail; the output blocker alone cannot recover once
    // the dry path is already clipped.
    localparam integer IN_DC_SHIFT = 9; // 512 samples, about 10.5 ms
    reg signed [47:0] in_dc_avg;
    wire signed [47:0] in_dc_next =
        in_dc_avg - (in_dc_avg >>> IN_DC_SHIFT) + in_sample;
    wire signed [47:0] in_dc_offset = in_dc_avg >>> IN_DC_SHIFT;
    wire signed [47:0] in_dc_diff = $signed(in_sample) - in_dc_offset;
    wire signed [DATA_WIDTH-1:0] in_hp =
        (in_dc_diff > OUT_MAX_EXT64) ? OUT_MAX :
        (in_dc_diff < OUT_MIN_EXT64) ? OUT_MIN :
        in_dc_diff[DATA_WIDTH-1:0];

    // ~15 Hz DC blocker on the body output as a final safety net.
    localparam integer DC_AVG_SHIFT = 9; // 512 samples, about 10.5 ms
    reg signed [47:0] dc_avg;
    wire signed [47:0] dc_offset = dc_avg >>> DC_AVG_SHIFT;
    wire signed [47:0] dc_diff = $signed(out_sat_q) - dc_offset;
    wire signed [DATA_WIDTH-1:0] dc_out =
        (dc_diff_q > OUT_MAX_EXT64) ? OUT_MAX :
        (dc_diff_q < OUT_MIN_EXT64) ? OUT_MIN :
        dc_diff_q[DATA_WIDTH-1:0];

    integer reset_index;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            out_valid  <= 1'b0;
            out_sample <= {DATA_WIDTH{1'b0}};
            mode       <= {MODE_INDEX_WIDTH{1'b0}};
            acc        <= 64'd0;
            for (reset_index = 0; reset_index < MODES; reset_index = reset_index + 1) begin
                y1[reset_index] <= {Y_WIDTH{1'b0}};
                y2[reset_index] <= {Y_WIDTH{1'b0}};
            end
            out_sat_q <= 0; dc_diff_q <= 0;
            dc_avg <= 48'sd0;
            in_dc_avg <= 48'sd0;
        end else begin
            out_valid <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (in_valid) begin
                        x         <= in_hp;
                        in_dc_avg <= in_dc_next;
                        acc       <= 64'd0;
                        mode      <= {MODE_INDEX_WIDTH{1'b0}};
                        state     <= S_LOAD;
                    end
                end

                S_LOAD: begin
                    state <= S_MUL;   // ROM 系数下一拍有效
                end

                S_MUL: begin
                    prod1 <= a1 * y1[mode];
                    prod2 <= a2 * y2[mode];
                    prod3 <= gain * x;
                    state <= S_COMB;
                end

                S_COMB: begin
                    y2[mode] <= y1[mode];
                    y1[mode] <= y_sat;
                    acc      <= acc + y_new;
                    if (mode == MODES - 1) begin
                        // Preserve the exact saturated body value before the
                        // output DC blocker; split the former long output path.
                        out_sat_q <= out_sat;
                        state <= S_DC_DIFF;
                    end else begin
                        mode  <= mode + 1'b1;
                        state <= S_LOAD;
                    end
                end

                S_DC_DIFF: begin
                    dc_diff_q <= dc_diff;
                    state <= S_DC_OUT;
                end
                S_DC_OUT: begin
                    out_sample <= dc_out;
                    // Algebraically identical modulo 2^48 to avg - offset + sat.
                    dc_avg <= dc_avg + dc_diff_q;
                    out_valid <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
