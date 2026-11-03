/*
 * PT8211 输出链：24-bit 双声道 PCM -> 对称舍入/饱和量化到 16-bit -> 串行。
 *
 * audio_clk 为精确音频主时钟（默认 12.288 MHz）；pt8211_tx 用 BCLK_DIV=4 产生
 * BCK=1.536 MHz、WS=48 kHz。pcm_ready 与 render_tick 同为帧边界脉冲，正好可以
 * 直接驱动 audio_cdc_fifo 的 rd_request：每个立体声帧消费一组左右样本。
 *
 * 单拍 pcm_valid 被 1 项弹性缓冲吸收；帧边界后一拍锁存新样本，避开与 BCK 下降沿
 * 同拍冲突。缓冲为空时重复上一帧数据并累加 underflow_count；PA_EN 上电计
 * STARTUP_FRAMES 帧后拉低（0=功放打开）。
 */
module pt8211_output_chain #(
    // 输入有符号 PCM 位宽。
    parameter integer PCM_WIDTH      = 24,
    // pt8211_tx 的 BCK 分频：BCK = audio_clk / (2*BCLK_DIV)。
    parameter integer BCLK_DIV       = 4,
    // 24->16 bit 量化右移位数；量化前加入正负对称的半 LSB 舍入偏置。
    parameter integer QUANT_SHIFT    = 8,
    // 上电后保持 PA_EN=1（关）的帧数，之后拉低为 0（开）。
    parameter integer STARTUP_FRAMES = 32,
    // 诊断计数器位宽。
    parameter integer COUNT_WIDTH    = 32
) (
    // 精确音频主时钟。
    input  wire                         audio_clk,
    // 同步低有效复位。
    input  wire                         rst_n,
    // 上游单拍有效左右样本；不可回压，缓冲自行记录覆盖。
    input  wire                         pcm_valid,
    // 上游有符号左/右 PCM 样本。
    input  wire signed [PCM_WIDTH-1:0]  pcm_left,
    input  wire signed [PCM_WIDTH-1:0]  pcm_right,
    // 帧边界脉冲；同时作为上游（CDC FIFO）的取数请求。
    output wire                         pcm_ready,
    // 每帧一次的渲染节拍，与 pcm_ready 同周期。
    output wire                         render_tick,
    // PT8211 位时钟。
    output wire                         pt_bck,
    // PT8211 左右声道选择；低=右、高=左。
    output wire                         pt_ws,
    // PT8211 串行数据。
    output wire                         pt_din,
    // 功放使能；0=打开（上电延时后）。
    output wire                         pa_en,
    // 旧样本未被取走又到新样本的累计次数。
    output wire [COUNT_WIDTH-1:0]       overwrite_count,
    // 帧边界无可用样本的累计次数。
    output wire [COUNT_WIDTH-1:0]       underflow_count
);
    wire signed [15:0] quantized_left, quantized_right;
    wire signed [PCM_WIDTH:0] quantizer_input_left, quantizer_input_right;
    wire signed [15:0] frame_left, frame_right;
    wire frame_valid;
    wire load_strobe;
    wire frame_done;

    reg  frame_done_d1;
    reg  [COUNT_WIDTH-1:0] underflow_q;
    reg  [7:0] startup_count;

    wire signed [PCM_WIDTH:0] round_bias_left;
    wire signed [PCM_WIDTH:0] round_bias_right;

    generate
        if (QUANT_SHIFT > 0) begin : rounded_quantizer_input
            // 正数加 0.5 LSB；负数加 0.5 LSB-1，得到对称的 nearest/away tie。
            assign round_bias_left  = pcm_left[PCM_WIDTH-1]
                                    ? ((1 << (QUANT_SHIFT - 1)) - 1)
                                    :  (1 << (QUANT_SHIFT - 1));
            assign round_bias_right = pcm_right[PCM_WIDTH-1]
                                    ? ((1 << (QUANT_SHIFT - 1)) - 1)
                                    :  (1 << (QUANT_SHIFT - 1));
            assign quantizer_input_left  = {pcm_left[PCM_WIDTH-1], pcm_left}
                                         + round_bias_left;
            assign quantizer_input_right = {pcm_right[PCM_WIDTH-1], pcm_right}
                                         + round_bias_right;
        end else begin : unrounded_quantizer_input
            assign quantizer_input_left  = {pcm_left[PCM_WIDTH-1], pcm_left};
            assign quantizer_input_right = {pcm_right[PCM_WIDTH-1], pcm_right};
        end
    endgenerate

    audio_limiter #(
        .INPUT_WIDTH(PCM_WIDTH + 1),
        .OUTPUT_WIDTH(16),
        .OUTPUT_SHIFT(QUANT_SHIFT)
    ) quantizer_left (
        .mix_in(quantizer_input_left),
        .audio_out(quantized_left)
    );

    audio_limiter #(
        .INPUT_WIDTH(PCM_WIDTH + 1),
        .OUTPUT_WIDTH(16),
        .OUTPUT_SHIFT(QUANT_SHIFT)
    ) quantizer_right (
        .mix_in(quantizer_input_right),
        .audio_out(quantized_right)
    );

    audio_sample_buffer #(
        .INPUT_WIDTH(16),
        .OUTPUT_WIDTH(16),
        .COUNT_WIDTH(COUNT_WIDTH)
    ) pending (
        .clk(audio_clk),
        .rst_n(rst_n),
        .s_valid(pcm_valid),
        .s_sample_left(quantized_left),
        .s_sample_right(quantized_right),
        .s_ready(),
        .m_valid(frame_valid),
        .m_sample_left(frame_left),
        .m_sample_right(frame_right),
        .m_ready(load_strobe),
        .overwrite_count(overwrite_count)
    );

    pt8211_tx #(
        .AUDIO_WIDTH(16),
        .BCLK_DIV(BCLK_DIV),
        .WS_LOW_IS_LEFT(0)
    ) serializer (
        .clk(audio_clk),
        .rst_n(rst_n),
        .load(load_strobe),
        .sample_left(frame_left),
        .sample_right(frame_right),
        .mute(1'b0),
        .pt_bck(pt_bck),
        .pt_ws(pt_ws),
        .pt_din(pt_din),
        .frame_done(frame_done)
    );

    assign pcm_ready   = frame_done;
    assign render_tick = frame_done;
    assign load_strobe = frame_done_d1;
    assign pa_en       = (startup_count >= STARTUP_FRAMES) ? 1'b0 : 1'b1;
    assign underflow_count = underflow_q;

    always @(posedge audio_clk) begin
        if (!rst_n) begin
            frame_done_d1 <= 1'b0;
            underflow_q   <= {COUNT_WIDTH{1'b0}};
            startup_count <= 8'd0;
        end else begin
            frame_done_d1 <= frame_done;

            if (frame_done) begin
                if (startup_count < STARTUP_FRAMES)
                    startup_count <= startup_count + 8'd1;
                if (!frame_valid && !(&underflow_q))
                    underflow_q <= underflow_q + 1'b1;
            end
        end
    end
endmodule
