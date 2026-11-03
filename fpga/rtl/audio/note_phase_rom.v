/*
 * MIDI 音符号到 DDS 相位增量的同步 ROM。
 * note 是 0..127 的无符号索引；在 clk 上升沿读取，phase_inc 使用非阻塞赋值，因此
 * 对某个 note 的结果在该上升沿之后才可用，具有一个时钟的同步读延迟。模块无复位，
 * 上层必须按流水线时序等待有效数据。初始块从版本控制中的十六进制文件装载 128 项，
 * 以便 ModelSim 仿真并让 Gowin 推断 ROM/BSRAM，而不是依赖厂商软 IP。
 */
module note_phase_rom #(
    // 单位 bit，合法范围 >=2；增大可提高 DDS 调音分辨率，也增加 ROM 宽度和相位加法资源。
    // 修改后必须用相同 PHASE_WIDTH 与 SAMPLE_RATE_HZ 重生成 note_phase_rom.mem。
    parameter integer PHASE_WIDTH = 32,
    // 相位增量表初始化文件；默认 48 kHz 表，板级换采样率时可传其他文件。
    parameter MEMORY_FILE = "src/note_phase_rom.mem"
) (
    // 同步 ROM 读时钟；note 在其上升沿采样。
    input  wire                   clk,
    // 7-bit MIDI 音符索引，0..127 分别选择 phase_table 的对应表项。
    input  wire [6:0]             note,
    // note 对应的 DDS 每采样点相位增量；在读时钟上升沿之后更新。
    output reg  [PHASE_WIDTH-1:0] phase_inc
);
    // 128 个逻辑表项对应完整 7-bit MIDI 音符空间。
    reg [PHASE_WIDTH-1:0] phase_table [0:127] /* synthesis syn_romstyle="logic" */;

    initial
        $readmemh(MEMORY_FILE, phase_table);

    // 同步读：地址在本上升沿采样，输出寄存器在沿后更新。
    always @(posedge clk)
        phase_inc <= phase_table[note];
endmodule
