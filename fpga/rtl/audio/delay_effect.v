/*
 * 可旁路 Delay / Echo 效果（主计划 R09）。
 *
 * 位于合成混音之后、I2S 之前。参数：Delay Time（`delay_samples`）、Feedback、Wet、Dry 与
 * `bypass`。环形缓冲 + 反馈：写回 = in + feedback*delayed，输出 = dry*in + wet*delayed；
 * bypass=1 时只输出干声。每 valid 样本用一条两级流水处理，不阻塞音频。
 * 增益为无符号 Q0.GAIN_SHIFT（GAIN_SHIFT=8 时 0..255 表示 0..~1）。
 */
module delay_effect #(
    parameter integer DATA_WIDTH = 24,
    parameter integer MAX_DELAY = 8192,
    parameter integer ADDR_WIDTH = 13,
    parameter integer GAIN_SHIFT = 8
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          in_valid,
    input  wire signed [DATA_WIDTH-1:0]  in_sample,
    input  wire                          bypass,
    input  wire [ADDR_WIDTH-1:0]         delay_samples,
    input  wire [GAIN_SHIFT-1:0]         feedback_gain,
    input  wire [GAIN_SHIFT-1:0]         wet_gain,
    output reg                           out_valid,
    output reg  signed [DATA_WIDTH-1:0]  out_sample
);
    localparam integer WIDE = DATA_WIDTH + GAIN_SHIFT + 1;
    localparam signed [WIDE-1:0] MAX_SAMPLE = (1 << (DATA_WIDTH-1)) - 1;
    localparam signed [WIDE-1:0] MIN_SAMPLE = -(1 << (DATA_WIDTH-1));

    function signed [DATA_WIDTH-1:0] saturate;
        input signed [WIDE-1:0] value;
        begin
            if (value > MAX_SAMPLE)      saturate = MAX_SAMPLE[DATA_WIDTH-1:0];
            else if (value < MIN_SAMPLE) saturate = MIN_SAMPLE[DATA_WIDTH-1:0];
            else                         saturate = value[DATA_WIDTH-1:0];
        end
    endfunction

    reg signed [DATA_WIDTH-1:0] mem [0:MAX_DELAY-1];
    reg [ADDR_WIDTH-1:0] wptr;
    reg [ADDR_WIDTH-1:0] rd_addr;
    reg signed [DATA_WIDTH-1:0] rd_reg;
    reg signed [DATA_WIDTH-1:0] x;
    reg bypass_r;
    reg [GAIN_SHIFT-1:0] fb_r;
    reg [GAIN_SHIFT-1:0] wet_r;
    reg busy;
    reg phase;
    reg [ADDR_WIDTH:0] history_count;

    // RAM 不逐项复位。只有当前 delay_samples 对应的历史已经实际写入后才读取，
    // 避免上电时未初始化内容进入反馈；不必等待整个 MAX_DELAY 缓冲区填满。
    wire history_valid = (delay_samples != {ADDR_WIDTH{1'b0}}) &&
                         (history_count >= {1'b0, delay_samples});
    wire signed [DATA_WIDTH-1:0] effective_delayed =
        history_valid ? rd_reg : {DATA_WIDTH{1'b0}};
    wire signed [WIDE-1:0] x_ext = {{(GAIN_SHIFT+1){x[DATA_WIDTH-1]}}, x};
    wire signed [DATA_WIDTH+GAIN_SHIFT-1:0] fb_prod = effective_delayed * $signed({1'b0, fb_r});
    wire signed [DATA_WIDTH+GAIN_SHIFT-1:0] wet_prod = effective_delayed * $signed({1'b0, wet_r});
    // Verilog 拼接表达式默认为 unsigned；若直接对拼接结果用 >>>，
    // 负乘积会被逻辑补 0，变成巨大正数并将反馈链推到满幅。
    // 先落到明确的 signed 线网再算术右移，保留负半波符号。
    wire signed [WIDE-1:0] fb_prod_ext =
        {{1{fb_prod[DATA_WIDTH+GAIN_SHIFT-1]}}, fb_prod};
    wire signed [WIDE-1:0] wet_prod_ext =
        {{1{wet_prod[DATA_WIDTH+GAIN_SHIFT-1]}}, wet_prod};
    wire signed [WIDE-1:0] fb_ext = fb_prod_ext >>> GAIN_SHIFT;
    wire signed [WIDE-1:0] wet_ext = wet_prod_ext >>> GAIN_SHIFT;
    wire signed [WIDE-1:0] write_sum = x_ext + fb_ext;
    wire signed [WIDE-1:0] out_sum = bypass_r ? x_ext : (x_ext + wet_ext);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_reg <= {DATA_WIDTH{1'b0}};
            history_count <= {(ADDR_WIDTH+1){1'b0}};
        end else if (busy) begin
            if (phase == 1'b0) begin
                rd_reg <= mem[rd_addr];
            end else begin
                mem[wptr] <= saturate(write_sum);
                if (history_count < MAX_DELAY[ADDR_WIDTH:0])
                    history_count <= history_count + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= {ADDR_WIDTH{1'b0}};
            rd_addr <= {ADDR_WIDTH{1'b0}};
            x <= {DATA_WIDTH{1'b0}};
            bypass_r <= 1'b0;
            fb_r <= {GAIN_SHIFT{1'b0}};
            wet_r <= {GAIN_SHIFT{1'b0}};
            busy <= 1'b0;
            phase <= 1'b0;
            out_valid <= 1'b0;
            out_sample <= {DATA_WIDTH{1'b0}};
        end else begin
            out_valid <= 1'b0;
            if (!busy && in_valid) begin
                x <= in_sample;
                bypass_r <= bypass;
                fb_r <= feedback_gain;
                wet_r <= wet_gain;
                rd_addr <= wptr - delay_samples;
                busy <= 1'b1;
                phase <= 1'b0;
            end else if (busy) begin
                if (phase == 1'b0) begin
                    phase <= 1'b1;
                end else begin
                    out_sample <= saturate(out_sum);
                    out_valid <= 1'b1;
                    wptr <= wptr + 1'b1;
                    busy <= 1'b0;
                end
            end
        end
    end
endmodule
