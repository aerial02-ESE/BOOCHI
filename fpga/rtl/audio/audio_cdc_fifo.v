/*
 * 合成核时钟域到音频时钟域的异步 FIFO。
 *
 * 写侧接受不可回压的 PCM 样本；FIFO 满时 wr_ready 拉低，若上游仍拉高
 * wr_valid，则丢弃该拍并增加饱和 overflow_count。读侧每个 rd_request
 * 最多取出一个样本；非空时在同一个 rd_clk 上升沿之后产生一拍 rd_valid
 * 和稳定 rd_data，空时不产生 rd_valid，并增加饱和 underflow_count。
 * 该时序允许音频域在本帧 render tick 发出请求，将随后得到的 rd_valid
 * 交给 audio_sample_buffer 保存，供下一帧使用。
 *
 * CDC 规则：
 *   - 数据只通过双口存储阵列跨域；多位二进制指针绝不直接跨域读取。
 *   - 每个指针先转 Gray 码，再在目的域经过两级同步器。
 *   - wr_rst_n/rd_rst_n 可分别连接各自时钟域复位，但一次 FIFO 清空必须
 *     同时断言两个复位。释放后，上游和下游都必须等待各自至少两个时钟
 *     上升沿再传输。运行中只复位单侧会破坏两侧对同一队列的共同认知，
 *     因而不属于本模块支持的操作。
 *
 * DEPTH 必须是至少为 4 的 2 的幂。实现采用 Verilog-2001，可被 Gowin
 * 综合器识别；存储器不复位，只有在同步后的非空状态下才会读取它。
 */
module audio_cdc_fifo #(
    // 单个 PCM 数据字的位宽，单位 bit，必须大于等于 1。
    parameter integer DATA_WIDTH  = 16,
    // FIFO 可保存的数据字数；必须为不小于 4 的 2 的幂。
    parameter integer DEPTH       = 16,
    // 溢出/欠载诊断计数器位宽，单位 bit，必须大于等于 1。
    parameter integer COUNT_WIDTH = 32
) (
    // 写时钟域时钟；所有 wr_* 信号均相对于其上升沿。
    input  wire                      wr_clk,
    // 写域异步低有效复位；清空 FIFO 时必须与 rd_rst_n 同时断言。
    input  wire                      wr_rst_n,
    // 写数据有效；与 wr_ready 同拍为 1 时写入一个数据字。
    input  wire                      wr_valid,
    // 写侧可接收指示；FIFO 未满时为 1。
    output wire                      wr_ready,
    // 待写入的 PCM 数据，wr_valid && wr_ready 时采样。
    input  wire [DATA_WIDTH-1:0]     wr_data,
    // 满 FIFO 上仍收到 wr_valid 的累计次数，达到全 1 后饱和。
    output reg  [COUNT_WIDTH-1:0]    overflow_count,

    // 读时钟域时钟；所有 rd_* 信号均相对于其上升沿。
    input  wire                      rd_clk,
    // 读域异步低有效复位；清空 FIFO 时必须与 wr_rst_n 同时断言。
    input  wire                      rd_rst_n,
    // 下游取数请求；FIFO 非空时每拍最多接受一次。
    input  wire                      rd_request,
    // 读数据有效单周期脉冲；只在成功响应 rd_request 后产生。
    output reg                       rd_valid,
    // 成功读取的数据，与 rd_valid 在读时钟域内同时有效。
    output reg  [DATA_WIDTH-1:0]     rd_data,
    // 空 FIFO 上收到 rd_request 的累计次数，达到全 1 后饱和。
    output reg  [COUNT_WIDTH-1:0]    underflow_count
);
    // 函数 clog2：计算表示 value 个状态所需的最小位数。
    // 入参 value：正整数状态数；本模块用合法的 DEPTH 调用。
    // 返回值：ceil(log2(value))；DEPTH>=4 保证结果至少为 2。
    function integer clog2;
        input integer value;
        // value-1 的移位工作副本。
        integer remaining;
        begin
            clog2 = 0;
            remaining = value - 1;
            while (remaining > 0) begin
                clog2 = clog2 + 1;
                remaining = remaining >> 1;
            end
        end
    endfunction

    // 存储阵列地址位宽，只编码 DEPTH 个物理槽位。
    localparam integer ADDR_WIDTH = clog2(DEPTH);
    // 跨域读写指针位宽；比地址多一位回绕标志以区分空和满。
    localparam integer PTR_WIDTH  = ADDR_WIDTH + 1;

    // 双时钟访问的数据存储阵列；复位不清内容，空标志保证无效内容不会被读出。
    reg [DATA_WIDTH-1:0] storage [0:DEPTH-1];

    // 写域二进制指针，低 ADDR_WIDTH 位作为实际写地址。
    reg [PTR_WIDTH-1:0] wr_bin;
    // 写指针的 Gray 码副本，供读域安全同步。
    reg [PTR_WIDTH-1:0] wr_gray;
    // 写域锁存的 FIFO 满标志。
    reg                 wr_full;
    // 读 Gray 指针进入写域的第一级亚稳态吸收寄存器。
    (* async_reg = "true" *) reg [PTR_WIDTH-1:0] rd_gray_sync1_wr;
    // 读 Gray 指针进入写域的第二级稳定同步值。
    (* async_reg = "true" *) reg [PTR_WIDTH-1:0] rd_gray_sync2_wr;

    // 读域二进制指针，低 ADDR_WIDTH 位作为实际读地址。
    reg [PTR_WIDTH-1:0] rd_bin;
    // 读指针的 Gray 码副本，供写域安全同步。
    reg [PTR_WIDTH-1:0] rd_gray;
    // 读域锁存的 FIFO 空标志。
    reg                 rd_empty;
    // 写 Gray 指针进入读域的第一级亚稳态吸收寄存器。
    (* async_reg = "true" *) reg [PTR_WIDTH-1:0] wr_gray_sync1_rd;
    // 写 Gray 指针进入读域的第二级稳定同步值。
    (* async_reg = "true" *) reg [PTR_WIDTH-1:0] wr_gray_sync2_rd;

    // 本写时钟沿真正接受一个数据字的握手条件。
    wire wr_accept;
    // 本读时钟沿真正接受一次取数请求的握手条件。
    wire rd_accept;
    // 按本拍握手结果计算的下一写二进制指针。
    wire [PTR_WIDTH-1:0] wr_bin_next;
    // 下一写指针对应的 Gray 码。
    wire [PTR_WIDTH-1:0] wr_gray_next;
    // 按本拍握手结果计算的下一读二进制指针。
    wire [PTR_WIDTH-1:0] rd_bin_next;
    // 下一读指针对应的 Gray 码。
    wire [PTR_WIDTH-1:0] rd_gray_next;
    // 以下一写指针和同步读指针计算的下一拍满状态。
    wire wr_full_next;
    // 以下一读指针和同步写指针计算的下一拍空状态。
    wire rd_empty_next;

    // synthesis translate_off
    initial begin
        if (DATA_WIDTH < 1 || COUNT_WIDTH < 1 || DEPTH < 4 ||
            ((DEPTH & (DEPTH - 1)) != 0)) begin
            $display("ERROR audio_cdc_fifo: DATA_WIDTH/COUNT_WIDTH must be >= 1 and DEPTH must be a power of two >= 4");
            $finish;
        end
    end
    // synthesis translate_on

    // 函数 bin_to_gray：把本地域二进制 FIFO 指针转换为单比特跳变的 Gray 码。
    // 入参 binary_value：包含回绕位的 PTR_WIDTH 位二进制指针。
    // 返回值：与输入等宽的 Gray 码，供另一时钟域两级同步。
    function [PTR_WIDTH-1:0] bin_to_gray;
        input [PTR_WIDTH-1:0] binary_value;
        begin
            bin_to_gray = (binary_value >> 1) ^ binary_value;
        end
    endfunction

    // Match the ready/valid contract at reset as well: the reset branch does
    // not write storage, so it must not advertise a successful write.
    assign wr_ready = wr_rst_n && !wr_full;
    assign wr_accept = wr_valid && wr_ready;
    assign rd_accept = rd_request && !rd_empty;

    assign wr_bin_next = wr_bin + {{(PTR_WIDTH-1){1'b0}}, wr_accept};
    assign wr_gray_next = bin_to_gray(wr_bin_next);
    assign rd_bin_next = rd_bin + {{(PTR_WIDTH-1){1'b0}}, rd_accept};
    assign rd_gray_next = bin_to_gray(rd_bin_next);

    // 对同步后的读指针最高两位取反，是 2^N 深度异步 FIFO 的满判定。
    assign wr_full_next =
        (wr_gray_next == {~rd_gray_sync2_wr[PTR_WIDTH-1:PTR_WIDTH-2],
                          rd_gray_sync2_wr[PTR_WIDTH-3:0]});
    assign rd_empty_next = (rd_gray_next == wr_gray_sync2_rd);

    // 写时钟域：存储写入、写指针、满标志和溢出诊断。
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin <= {PTR_WIDTH{1'b0}};
            wr_gray <= {PTR_WIDTH{1'b0}};
            wr_full <= 1'b0;
            overflow_count <= {COUNT_WIDTH{1'b0}};
        end else begin
            if (wr_accept)
                storage[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;

            wr_bin <= wr_bin_next;
            wr_gray <= wr_gray_next;
            wr_full <= wr_full_next;

            if (wr_valid && wr_full && !(&overflow_count))
                overflow_count <= overflow_count + 1'b1;
        end
    end

    // 读 Gray 指针进入写域的两级同步。
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_sync1_wr <= {PTR_WIDTH{1'b0}};
            rd_gray_sync2_wr <= {PTR_WIDTH{1'b0}};
        end else begin
            // 第一级可进入亚稳态，第二级才供本时钟域逻辑使用。
            rd_gray_sync1_wr <= rd_gray;
            rd_gray_sync2_wr <= rd_gray_sync1_wr;
        end
    end

    // 读时钟域：同步读出、读指针、空标志和欠载诊断。
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin <= {PTR_WIDTH{1'b0}};
            rd_gray <= {PTR_WIDTH{1'b0}};
            rd_empty <= 1'b1;
            rd_valid <= 1'b0;
            rd_data <= {DATA_WIDTH{1'b0}};
            underflow_count <= {COUNT_WIDTH{1'b0}};
        end else begin
            rd_valid <= 1'b0;
            if (rd_accept) begin
                rd_data <= storage[rd_bin[ADDR_WIDTH-1:0]];
                rd_valid <= 1'b1;
            end

            rd_bin <= rd_bin_next;
            rd_gray <= rd_gray_next;
            rd_empty <= rd_empty_next;

            if (rd_request && rd_empty && !(&underflow_count))
                underflow_count <= underflow_count + 1'b1;
        end
    end

    // 写 Gray 指针进入读域的两级同步。
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_sync1_rd <= {PTR_WIDTH{1'b0}};
            wr_gray_sync2_rd <= {PTR_WIDTH{1'b0}};
        end else begin
            // 第一级可进入亚稳态，第二级才供本时钟域逻辑使用。
            wr_gray_sync1_rd <= wr_gray;
            wr_gray_sync2_rd <= wr_gray_sync1_rd;
        end
    end
endmodule
