/*
 * 两层力度贝斯波表 ROM（第二种必交付音色）。
 *
 * layer=0 柔和、layer=1 明亮；每层一个同样深度的一周期 signed 波形。数据由
 * reference/gen_tables.py 的 BASS_HARMONIC_PROFILES 确定性生成。与钢琴波表分开存放，
 * 便于后续按 instrument 选择音色。
 */
module bass_waveform_rom #(
    parameter integer WAVE_ADDR_WIDTH = 10,
    parameter integer AUDIO_WIDTH = 24,
    parameter MEMORY_FILE = "src/bass_waveform_rom.mem"
) (
    input  wire                          clk,
    input  wire                          layer,
    input  wire [WAVE_ADDR_WIDTH-1:0]    address,
    output reg signed [AUDIO_WIDTH-1:0]  sample
);
    localparam integer TABLE_DEPTH = (1 << WAVE_ADDR_WIDTH);
    localparam integer TOTAL_DEPTH = 2 * TABLE_DEPTH;

    reg [AUDIO_WIDTH-1:0] memory [0:TOTAL_DEPTH-1];
    wire [WAVE_ADDR_WIDTH:0] layered_address;

    assign layered_address = {layer, address};

    initial begin
        $readmemh(MEMORY_FILE, memory);
    end

    always @(posedge clk) begin
        sample <= memory[layered_address];
    end
endmodule
