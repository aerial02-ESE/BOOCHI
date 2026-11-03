`timescale 1ns / 1ps

// Tang Mega 60K + FPGA_USB_MIDI_HOST_v4 board-level wrapper.
//
// The HOST board occupies the NEO Dock J13 2x20 header.  Those pins were also
// used by the optional TAS5805/WS2812 daughterboard in the generic top level,
// so this wrapper disables that mutually-exclusive peripheral and does not
// expose its signals as package pins.  PT8211 audio on the Dock remains active.
//
// USB3300 U1 is ULPI0/source 0; USB3300 U3 is ULPI1/source 1.  Each PHY supplies
// its own 60 MHz CLKOUT and has its own active-high RESET output.
module tang_mega_60k_usbhost_top (
    input  wire       sys_clk_50m,
    input  wire       sys_rst_n,
    input  wire       key1_n,
    input  wire       key2_n,
    input  wire       esp_uart_rx,

    input  wire       ulpi0_clk,
    input  wire       ulpi0_dir,
    input  wire       ulpi0_nxt,
    inout  wire [7:0] ulpi0_data,
    output wire       ulpi0_stp,
    output wire       ulpi0_phy_rst,

    input  wire       ulpi1_clk,
    input  wire       ulpi1_dir,
    input  wire       ulpi1_nxt,
    inout  wire [7:0] ulpi1_data,
    output wire       ulpi1_stp,
    output wire       ulpi1_phy_rst,

    output wire [5:0] dock_lcd_r6,
    output wire [5:0] dock_lcd_g6,
    output wire [5:0] dock_lcd_b6,
    output wire       lcd_pclk,
    output wire       lcd_hsync,
    output wire       lcd_vsync,
    output wire       lcd_de,
    output wire       lcd_bl_pwm,

    output wire       pt_bck,
    output wire       pt_ws,
    output wire       pt_din,
    output wire       pa_en,
    output wire       key_led_dout,
    output wire       key_led_high_dout,
    output wire       esp_uart_tx,

    output wire       ctp_rst_n,
    input  wire       ctp_int,
    inout  wire       ctp_sda,
    inout  wire       ctp_scl
);
    wire [2:0] unused_led_data;
    wire       unused_i2s_sclk;
    wire       unused_i2s_lrclk;
    wire       unused_i2s_sdin;
    wire       unused_tas_pdn;
    wire       unused_tas_scl;
    wire       unused_tas_sda;

    tang_mega_60k_spectrum_keys_top #(
        .USB_PORTS(1),
        .LED_AUDIO_ENABLE(0)
    ) u_main (
        .sys_clk_50m(sys_clk_50m),
        .sys_rst_n(sys_rst_n),
        .key1_n(key1_n),
        .key2_n(key2_n),
        .esp_uart_rx(esp_uart_rx),

        .ulpi0_clk(ulpi0_clk),
        .ulpi0_dir(ulpi0_dir),
        .ulpi0_nxt(ulpi0_nxt),
        .ulpi0_data(ulpi0_data),
        .ulpi0_stp(ulpi0_stp),
        .ulpi0_phy_rst(ulpi0_phy_rst),

        .ulpi1_clk(ulpi1_clk),
        .ulpi1_dir(ulpi1_dir),
        .ulpi1_nxt(ulpi1_nxt),
        .ulpi1_data(ulpi1_data),
        .ulpi1_stp(ulpi1_stp),
        .ulpi1_phy_rst(ulpi1_phy_rst),

        .dock_lcd_r6(dock_lcd_r6),
        .dock_lcd_g6(dock_lcd_g6),
        .dock_lcd_b6(dock_lcd_b6),
        .lcd_pclk(lcd_pclk),
        .lcd_hsync(lcd_hsync),
        .lcd_vsync(lcd_vsync),
        .lcd_de(lcd_de),
        .lcd_bl_pwm(lcd_bl_pwm),

        .pt_bck(pt_bck),
        .pt_ws(pt_ws),
        .pt_din(pt_din),
        .pa_en(pa_en),
        .key_led_dout(key_led_dout),
        .key_led_high_dout(key_led_high_dout),
        .esp_uart_tx(esp_uart_tx),

        .led_data(unused_led_data),
        .i2s_sclk(unused_i2s_sclk),
        .i2s_lrclk(unused_i2s_lrclk),
        .i2s_sdin(unused_i2s_sdin),
        .tas_pdn(unused_tas_pdn),
        .tas_scl(unused_tas_scl),
        .tas_sda(unused_tas_sda),

        .ctp_rst_n(ctp_rst_n),
        .ctp_int(ctp_int),
        .ctp_sda(ctp_sda),
        .ctp_scl(ctp_scl)
    );
endmodule
