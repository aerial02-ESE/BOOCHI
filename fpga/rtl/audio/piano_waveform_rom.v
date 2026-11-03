/*
 * 分层力度钢琴波表 ROM。
 *
 * layer 由柔和到明亮逐层存放（默认 8 层：由 4 条锚点谐波曲线插值而来），每层
 * 均为同样深度的一周期 signed 波形。music_synth_core 按力度给出的连续亮度选择层，
 * 并在相邻两层之间做线性插值，因此轻触保持较少高次谐波、重触更明亮。
 * ROM 数据由 reference/gen_tables.py 确定性生成。
 *
 * 注意：layer 端口位宽必须随 LAYERS 增长（8 层需 3 bit）。曾因沿用 4 层时代的
 * 2-bit 端口，导致层号 4..7 被截成 0..3（力度 >=64 的音反而读最柔和的层）——
 * 这是一个真实缺陷，现已参数化并有测试覆盖。
 */
module piano_waveform_rom #(
    // 每个力度层的相位地址位宽；默认 10 bit，即每层 1024 点。
    parameter integer WAVE_ADDR_WIDTH = 10,
    // 每个有符号波形采样的位宽。
    parameter integer AUDIO_WIDTH = 24,
    parameter integer STORAGE_WIDTH = AUDIO_WIDTH,
    // 力度层数（默认 8：4 条锚点曲线插值而来；贝斯表为 2 层）。必须是 2 的幂。
    parameter integer LAYERS = 8,
    // 层号位宽；必须能表达 0..LAYERS-1（8 层需 3 bit）。用 parameter 而非 localparam，
    // 因为端口列表要先引用它。
    parameter integer LAYER_BITS = (LAYERS <= 2) ? 1 : $clog2(LAYERS),
    // 连续存放的十六进制存储初始化文件。
    parameter MEMORY_FILE = "src/piano_waveform_rom.mem"
) (
    // 同步 ROM 读时钟。
    input  wire                          clk,
    // 音色层，范围 0..LAYERS-1（位宽随层数参数化）。
    input  wire [LAYER_BITS-1:0]         layer,
    // 当前层内的 DDS 相位地址。
    input  wire [WAVE_ADDR_WIDTH-1:0]    address,
    // 提交地址后一拍得到的 signed 波形值。
    output reg signed [AUDIO_WIDTH-1:0]  sample
);
    localparam integer TABLE_DEPTH = (1 << WAVE_ADDR_WIDTH);
    localparam integer TOTAL_DEPTH = LAYERS * TABLE_DEPTH;

    reg signed [STORAGE_WIDTH-1:0] memory [0:TOTAL_DEPTH-1];
    wire [LAYER_BITS+WAVE_ADDR_WIDTH-1:0] layered_address;

    // 高位选层，低位保持该层内相位索引。
    assign layered_address = {layer, address};

    initial begin
        $readmemh(MEMORY_FILE, memory);
    end

    always @(posedge clk) begin
        sample <= $signed({{(AUDIO_WIDTH-STORAGE_WIDTH){memory[layered_address][STORAGE_WIDTH-1]}}, memory[layered_address]}) <<< (AUDIO_WIDTH-STORAGE_WIDTH);
    end
endmodule
