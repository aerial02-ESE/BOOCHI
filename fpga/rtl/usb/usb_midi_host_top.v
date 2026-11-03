`timescale 1ns / 1ps

// Integrated single-port USB-MIDI host: enumeration + bulk IN polling +
// USB-MIDI -> ControlEvent parsing, all in the ULPI 60 MHz clock domain.
// The 64-bit event stream can be crossed into the audio clock domain by the
// integrator (not done here).
module usb_midi_host_top #(
    parameter [3:0] SOURCE = 4'd0,
    parameter integer EP_NUM = 4,
    parameter integer POLL_CYCLES = 60000,
    parameter integer RESET_CYCLES = 600000,
    parameter integer SETTLE_CYCLES = 60000,
    parameter integer TX_TIMEOUT_CYCLES = 6000,
    parameter integer RX_TIMEOUT_CYCLES = 60000,
    parameter integer CONNECT_DEBOUNCE_CYCLES = 6000000,
    parameter integer BUS_RESET_CYCLES = 3000000,
    parameter integer RESET_RECOVERY_CYCLES = 600000,
    parameter integer DISCONNECT_DEBOUNCE_CYCLES = 60000,
    parameter integer SOF_CYCLES = 60000
) (
    input  wire        clk,        // USB3300 CLKOUT, 60 MHz
    input  wire        rst_n,
    input  wire        start,      // level enable: enumerates then polls

    output wire        phy_rst,
    input  wire        ulpi_dir,
    input  wire        ulpi_nxt,
    inout  wire [7:0]  ulpi_data,
    output wire        ulpi_stp,

    output wire        done,
    output wire        error,
    output wire [7:0]  status,
    output wire [15:0] id_vendor,
    output wire [15:0] id_product,
    output wire [7:0]  config_value,
    output wire [6:0]  device_address,

    output wire        event_valid,
    input  wire        event_ready,
    output wire [63:0] event_data,
    output wire [31:0] bulk_packets,
    output wire [31:0] bulk_naks,
    output wire [31:0] bulk_errors,
    output wire [31:0] parser_ignored,
    output wire [31:0] parser_unsupported
);

    wire        midi_valid, midi_ready;
    wire [31:0] midi_packet;

    usb_host_enum #(
        .RESET_CYCLES(RESET_CYCLES), .SETTLE_CYCLES(SETTLE_CYCLES),
        .TX_TIMEOUT_CYCLES(TX_TIMEOUT_CYCLES),
        .RX_TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES),
        .CONNECT_DEBOUNCE_CYCLES(CONNECT_DEBOUNCE_CYCLES),
        .BUS_RESET_CYCLES(BUS_RESET_CYCLES),
        .RESET_RECOVERY_CYCLES(RESET_RECOVERY_CYCLES),
        .DISCONNECT_DEBOUNCE_CYCLES(DISCONNECT_DEBOUNCE_CYCLES),
        .SOF_CYCLES(SOF_CYCLES),
        .BULK_ENABLE(1), .EP_NUM(EP_NUM), .POLL_CYCLES(POLL_CYCLES)
    ) host (
        .clk(clk), .rst_n(rst_n), .start(start),
        .phy_rst(phy_rst), .ulpi_dir(ulpi_dir), .ulpi_nxt(ulpi_nxt),
        .ulpi_data(ulpi_data), .ulpi_stp(ulpi_stp),
        .done(done), .error(error), .busy(),
        .id_vendor(id_vendor), .id_product(id_product), .bcd_usb(),
        .max_packet(), .config_value(config_value), .device_class(),
        .device_address(device_address), .status(status),
        .midi_valid(midi_valid), .midi_ready(midi_ready),
        .midi_packet(midi_packet),
        .bulk_packets(bulk_packets), .bulk_naks(bulk_naks),
        .bulk_errors(bulk_errors)
    );

    usb_midi_parser #(.SOURCE(SOURCE), .TRACK_OWNER(0)) parser (
        .clk(clk), .rst_n(rst_n),
        .in_valid(midi_valid), .in_ready(midi_ready), .in_packet(midi_packet),
        .out_valid(event_valid), .out_ready(event_ready), .out_event(event_data),
        .ignored_packets(parser_ignored),
        .unsupported_messages(parser_unsupported),
        .knob_events(), .pad_events()
    );

endmodule
