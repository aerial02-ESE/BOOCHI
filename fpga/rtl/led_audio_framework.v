`timescale 1ns / 1ps

// LED 指引 + TAS5805 I2S 音频的框架顶层。
//
// 现在不接生产顶层，也不分配 FPGA 引脚；先用独立工程做综合/仿真，
// 等 SDRAM 排针物理映射确定后再由 tang_mega_60k_spectrum_keys_top 实例化。
//
// 音频：audio_left/right 直接来自 esp32_audio_engine 的 post-effect 立体声
//       （需要在该模块新增 post_valid/post_left/post_right 端口）。
// LED：pressed_notes 来自 local_instrument_mapper；guide/expected 预留给
//       曲谱/手机下发，当前可接 0。
module led_audio_framework #(
    parameter integer CLK_FREQ_HZ  = 50_000_000,
    parameter integer NUM_STRIPS   = 3,
    parameter integer STRIP0_LEDS  = 52,
    parameter integer STRIP1_LEDS  = 36,
    parameter integer STRIP2_LEDS  = 0,
    parameter integer MAX_LEDS     = 52,
    parameter integer ADDR_W       = 7,
    parameter integer FRAME_HZ     = 300,
    parameter         LED_MAP_FILE = "src/led_map.mem",
    parameter integer I2C_FREQ_HZ  = 400_000,
    parameter [6:0]   TAS_ADDR     = 7'h2d,
    parameter integer TAS_INIT_COUNT = 1679,
    parameter         TAS_INIT_FILE  = "src/tas5805_init.mem",
    parameter integer BCLK_DIV       = 8
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire [127:0]            pressed_notes,
    input  wire [127:0]            guide_notes,
    input  wire [127:0]            expected_notes,
    input  wire [3:0]              brightness_shift,

    input  wire                    audio_valid,
    input  wire signed [23:0]      audio_left,
    input  wire signed [23:0]      audio_right,

    input  wire                    tas_enable,
    input  wire                    tas_mute,

    output wire [NUM_STRIPS-1:0]   led_data,
    output wire                    led_busy,

    output wire                    i2s_sclk,
    output wire                    i2s_lrclk,
    output wire                    i2s_sdin,

    output wire                    tas_pdn,
    output wire                    tas_scl,
    inout  wire                    tas_sda,
    output wire                    tas_busy,
    output wire                    tas_init_done,
    output wire                    tas_error
);

    led_guide_controller #(
        .NUM_STRIPS(NUM_STRIPS),
        .STRIP0_LEDS(STRIP0_LEDS),
        .STRIP1_LEDS(STRIP1_LEDS),
        .STRIP2_LEDS(STRIP2_LEDS),
        .MAX_LEDS(MAX_LEDS),
        .ADDR_W(ADDR_W),
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .FRAME_HZ(FRAME_HZ),
        .LED_MAP_FILE(LED_MAP_FILE)
    ) u_led (
        .clk(clk),
        .rst_n(rst_n),
        .pressed_notes(pressed_notes),
        .guide_notes(guide_notes),
        .expected_notes(expected_notes),
        .brightness_shift(brightness_shift),
        .led_data(led_data),
        .led_busy(led_busy)
    );

    i2s_tx #(
        .DATA_WIDTH(24),
        .SLOT_WIDTH(32),
        .BCLK_DIV(BCLK_DIV),
        .LEFT_WHEN_LOW(1)
    ) u_i2s (
        .clk(clk),
        .rst_n(rst_n),
        .sample_valid(audio_valid),
        .sample_left(audio_left),
        .sample_right(audio_right),
        .mute(tas_mute),
        .sclk(i2s_sclk),
        .lrclk(i2s_lrclk),
        .sdout(i2s_sdin),
        .frame_done(),
        .underflow()
    );

    tas5805_ctrl #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .I2C_FREQ_HZ(I2C_FREQ_HZ),
        .DEV_ADDR(TAS_ADDR),
        .INIT_COUNT(TAS_INIT_COUNT),
        .INIT_FILE(TAS_INIT_FILE)
    ) u_tas (
        .clk(clk),
        .rst_n(rst_n),
        .enable(tas_enable),
        .pdn(tas_pdn),
        .scl(tas_scl),
        .sda(tas_sda),
        .busy(tas_busy),
        .init_done(tas_init_done),
        .error(tas_error)
    );

endmodule
