/*
 * 音板模态系数 ROM：每条 48 bit = {a1[47:32], a2[31:16], gain[15:0]}，均为 Q1.14。
 * 数据源 src/body_mode_rom.mem，由 reference/gen_tables.py 的 BODY_MODES 生成。
 */
module body_mode_rom #(
    parameter integer MODES = 3,
    parameter integer MODE_INDEX_WIDTH = 2
) (
    input  wire                       clk,
    input  wire [MODE_INDEX_WIDTH-1:0] mode,
    output reg  signed [15:0]         a1,
    output reg  signed [15:0]         a2,
    output reg  signed [15:0]         gain
);
    reg [47:0] modal_rom [0:MODES-1];

    initial
        $readmemh("src/body_mode_rom.mem", modal_rom);

    always @(posedge clk) begin
        a1   <= modal_rom[mode][47:32];
        a2   <= modal_rom[mode][31:16];
        gain <= modal_rom[mode][15:0];
    end
endmodule
