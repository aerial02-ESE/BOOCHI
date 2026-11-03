/*
 * 双声道 PCM 到 I2S 帧数据的单项弹性缓冲。
 *
 * 合成核的 s_valid 只拉高一拍，而 I2S 发送器只在帧边界拉高
 * m_ready。本模块保存最新一组完整左右采样，并将 16-bit 有符号 PCM
 * 左对齐到 24-bit I2S 有效数据；左右声道分别保存。
 *
 * s_ready 恒为 1：这个适配器能接收不可回压的单拍脉冲。若旧样本尚未
 * 被 m_ready 取走又到了新样本，则保留更新的样本并增加 overwrite_count，
 * 使上游超速不会静默发生。发送器在接收后将其内部帧寄存器作为第二级
 * 缓冲，因而两模块合起来形成 pending/active 双缓冲。
 */
module audio_sample_buffer #(
    parameter integer INPUT_WIDTH = 16,
    parameter integer OUTPUT_WIDTH = 24,
    parameter integer COUNT_WIDTH = 32
) (
    input  wire                           clk,
    input  wire                           rst_n,

    input  wire                           s_valid,
    input  wire signed [INPUT_WIDTH-1:0]  s_sample_left,
    input  wire signed [INPUT_WIDTH-1:0]  s_sample_right,
    output wire                           s_ready,

    output wire                           m_valid,
    output wire signed [OUTPUT_WIDTH-1:0] m_sample_left,
    output wire signed [OUTPUT_WIDTH-1:0] m_sample_right,
    input  wire                           m_ready,

    output reg [COUNT_WIDTH-1:0]          overwrite_count
);
    reg pending_valid;
    reg signed [OUTPUT_WIDTH-1:0] pending_left;
    reg signed [OUTPUT_WIDTH-1:0] pending_right;

    // synthesis translate_off
    initial begin
        if (INPUT_WIDTH < 1 || OUTPUT_WIDTH < INPUT_WIDTH || COUNT_WIDTH < 1) begin
            $display("ERROR audio_sample_buffer: require OUTPUT_WIDTH >= INPUT_WIDTH >= 1 and COUNT_WIDTH >= 1");
            $finish;
        end
    end
    // synthesis translate_on

    function signed [OUTPUT_WIDTH-1:0] align_sample;
        input signed [INPUT_WIDTH-1:0] sample;
        begin
            if (OUTPUT_WIDTH > INPUT_WIDTH)
                align_sample = {sample, {(OUTPUT_WIDTH-INPUT_WIDTH){1'b0}}};
            else if (OUTPUT_WIDTH == INPUT_WIDTH)
                align_sample = sample;
            else
                align_sample = {OUTPUT_WIDTH{1'b0}};
        end
    endfunction

    wire signed [OUTPUT_WIDTH-1:0] aligned_left  = align_sample(s_sample_left);
    wire signed [OUTPUT_WIDTH-1:0] aligned_right = align_sample(s_sample_right);

    assign s_ready = 1'b1;
    assign m_valid = pending_valid;
    assign m_sample_left = pending_left;
    assign m_sample_right = pending_right;

    always @(posedge clk) begin
        if (!rst_n) begin
            pending_valid <= 1'b0;
            pending_left <= {OUTPUT_WIDTH{1'b0}};
            pending_right <= {OUTPUT_WIDTH{1'b0}};
            overwrite_count <= {COUNT_WIDTH{1'b0}};
        end else begin
            // 只有下游真正看到 valid 时才消费；空缓冲上的 ready 不会吃掉同拍新数据。
            if (m_ready && pending_valid)
                pending_valid <= 1'b0;

            if (s_valid) begin
                if (pending_valid && !m_ready && !(&overwrite_count))
                    overwrite_count <= overwrite_count + 1'b1;
                pending_left <= aligned_left;
                pending_right <= aligned_right;
                pending_valid <= 1'b1;
            end
        end
    end
endmodule
