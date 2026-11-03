`timescale 1ns / 1ps

// Tang Mega 60K RGB LCD + direct USB0 88-key + ESP32 SMK-25/BLE top level.
//
// The Tang Mega NEO Dock drives its 40-pin FPC in RGB666 wiring: LCD R0/R1,
// G0/G1 and B0/B1 are tied low by the dock, while the remaining six bits of
// each colour are connected to the FPGA's CH569_HSPI|RGB_LCD net group.
// The source image is RGB565; red and blue are expanded to six bits here.
//
// CTP remains electrically safe and idle. The panel document specifies the
// I2C pins, but does not identify its controller or register protocol.
module tang_mega_60k_spectrum_keys_top #(
    // 0 = UART only, 1 = proven USB0/ULPI0, 2 = both USB hosts.
    parameter integer USB_PORTS = 1,
    parameter integer USB_EP_NUM = 4,
    parameter integer USB_RESET_CYCLES = 600000,
    parameter integer USB_SETTLE_CYCLES = 60000,
    parameter integer USB_POLL_CYCLES = 60000,
    parameter integer USB_TX_TIMEOUT_CYCLES = 6000,
    parameter integer USB_RX_TIMEOUT_CYCLES = 60000,
    parameter integer USB_CONNECT_DEBOUNCE_CYCLES = 6000000,
    parameter integer USB_BUS_RESET_CYCLES = 3000000,
    parameter integer USB_RESET_RECOVERY_CYCLES = 600000,
    parameter integer USB_DISCONNECT_DEBOUNCE_CYCLES = 60000,
    parameter integer USB_SOF_CYCLES = 60000,
    // 1 = emit 32 NOTE_ON events at power-on for the spectrum self test.
    parameter integer TEST_TONE_ENABLE = 0,
    // 1 = play src/score_demo.mem at power-on for the offline LED guide.
    parameter integer SCORE_PLAYER_ENABLE = 0,
    // 1 = instantiate the TAS5805 I2S output and the 3 WS2812 strips.
    parameter integer LED_AUDIO_ENABLE = 1
) (
    input  wire       sys_clk_50m,
    input  wire       sys_rst_n,
    // KEY1=Y12 cycles piano/organ/drum/source-assigned; KEY2=AB13 cycles spectrum/XY/score.
    input  wire       key1_n,
    input  wire       key2_n,
    input  wire       esp_uart_rx,

    // USB0/ULPI0 = HOST v4 USB3300 U1 and USB1/ULPI1 = USB3300 U3.
    // Each port has its own 60 MHz CLKOUT domain (Dock J13 B17/E17).
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

    // Amplifier / LED board (HOST board J13 header).
    output wire [2:0] led_data,
    output wire       i2s_sclk,
    output wire       i2s_lrclk,
    output wire       i2s_sdin,
    output wire       tas_pdn,
    output wire       tas_scl,
    inout  wire       tas_sda,

    output wire       ctp_rst_n,
    input  wire       ctp_int,
    inout  wire       ctp_sda,
    inout  wire       ctp_scl
);

    wire [9:0] pixel_x;
    wire [9:0] render_x = pixel_x;

    wire [8:0] pixel_y;
    wire [8:0] render_y = pixel_y;
    wire       active_video;
    wire       frame_toggle;
    wire [4:0] red_565;
    wire [5:0] green_565;
    wire [4:0] blue_565;
    wire [3:0] ui_instrument_mode;
    wire [3:0] key1_mode;
    wire page_next;
    wire ui_event;
    wire [1:0] ui_label;
    wire [6:0] ui_value;
    reg [26:0] ui_timer;
    reg [1:0] ui_label_reg;
    reg [6:0] ui_value_reg;
    reg ui_active_reg;
    wire [127:0] pressed_notes;
    wire [127:0] human_pressed_notes;
    wire [29:0] usb88_low_pressed;
    wire [87:0] usb88_pressed;
    wire visual_audio_valid;
    wire signed [23:0] visual_audio_sample;
    wire post_valid;
    wire signed [23:0] post_left, post_right;
    wire [255:0] spectrum_levels;
    wire [255:0] spectrum_peaks;

    // ESP32-P4-Module-DEV-KIT UART1 (GPIO26) -> FPGA ControlEvent v1. The
    // parser and audio engine intentionally share this one event stream with
    // the LCD UI, so a key press affects sound and visualization together.
    wire uart_byte_valid;
    wire [7:0] uart_byte;
    wire uart_event_valid;
    wire uart_event_ready;
    wire [63:0] uart_event_data;
    wire score_view_event = uart_event_data[63:62] == 2'b01 &&
                            uart_event_data[61:56] == 6'h0c &&
                            uart_event_data[55:52] == 4'd3;
    wire score_led_event = uart_event_data[63:62] == 2'b01 &&
                           uart_event_data[61:56] == 6'h0d &&
                           uart_event_data[55:52] == 4'd3;
    wire practice_event=uart_event_data[63:62]==1 && uart_event_data[55:52]==3 &&
                        (uart_event_data[61:56]==14 || uart_event_data[61:56]==15);
    wire practice_command_ready,practice_key_ready,practice_active,practice_display;
    wire[7:0]practice_flags,practice_session,practice_last_note,practice_last_result;
    wire[15:0]practice_total,practice_hits,practice_wrong,practice_misses;
    wire[23:0]practice_elapsed;
    wire[87:0]practice_guide,practice_correct,practice_incorrect;
    // Trusted phone PARAM_CTRL 0x21 selects a display page without entering audio.
    wire app_page_event = uart_event_data[63:56] == 8'h4b &&
                          uart_event_data[55:48] == 8'h2f &&
                          uart_event_data[39:32] == 8'h21 &&
                          uart_event_data[31:16] <= 16'd2 &&
                          uart_event_data[15:8] == 0;
    wire non_audio_event = score_view_event || score_led_event || practice_event || app_page_event;
    wire score_fifo_ready;
    wire [127:0] score_pitch_codes;
    wire [31:0] score_instruments;
      wire [63:0] score_rhythms;
    wire [15:0] score_occupied;
    wire [127:0] score_led_guide_notes, score_led_expected_notes;
    wire event_valid;
    wire event_ready;
    wire [63:0] event_data;
    // USB0 (60 MHz) event stream after CDC, then merged with UART. USB1 is
    // retained as a disabled hardware shell for pin-compatible integration.
    wire usb0_ev_valid, usb0_ev_ready;
    wire [63:0] usb0_ev_data;
    wire usb0_ev50_valid, usb0_ev50_ready;
    wire [63:0] usb0_ev50_data;
    wire usb1_ev_valid, usb1_ev_ready;
    wire [63:0] usb1_ev_data;
    wire usb1_ev50_valid, usb1_ev50_ready;
    wire [63:0] usb1_ev50_data;
    wire usb_merged_valid, usb_merged_ready;
    wire [63:0] usb_merged_data;
    wire merged_valid;
    wire [63:0] merged_data;
    wire        tone_valid, tone_ready;
    wire [63:0] tone_data;
    wire        score_valid, score_ready;
    wire [63:0] score_data;
    wire [127:0] score_expected_notes;
    wire        internal_valid, internal_ready;
    wire [63:0] internal_data;
    wire        pre_arb_ready;
    wire        mapper_in_valid, mapper_in_ready;
    wire [63:0] mapper_in_data;
    wire mapped_valid, mapped_ready;
    wire [63:0] mapped_data;
    wire link_timeout_pulse;
    wire frame_seen;
    wire event_fifo_rst_n = sys_rst_n && !link_timeout_pulse;

    // sys_rst_n is asynchronous to both USB3300 CLKOUTs, so each 60 MHz domain
    // gets its own reset synchronizer.  The hosts, their parsers and the write
    // side of their event FIFOs leave reset inside their own clock domain; the
    // 50 MHz read side stays on sys_rst_n.
    reg [1:0] usb0_rst_sync, usb1_rst_sync;
    always @(posedge ulpi0_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) usb0_rst_sync <= 2'b00;
        else            usb0_rst_sync <= {usb0_rst_sync[0], 1'b1};
    end
    always @(posedge ulpi1_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) usb1_rst_sync <= 2'b00;
        else            usb1_rst_sync <= {usb1_rst_sync[0], 1'b1};
    end
    wire usb0_rst_n = usb0_rst_sync[1];
    wire usb1_rst_n = usb1_rst_sync[1];

    uart_rx_8n1 #(.CLK_FREQ_HZ(50000000), .BAUD_RATE(1000000)) u_uart_rx (
        .clk(sys_clk_50m), .rst_n(sys_rst_n), .rx(esp_uart_rx),
        .byte_valid(uart_byte_valid), .byte_data(uart_byte),
        .framing_error_count()
    );

    uart_control_event_rx u_event_rx (
        .clk(sys_clk_50m), .rst_n(sys_rst_n),
        .byte_valid(uart_byte_valid), .byte_data(uart_byte),
        .event_valid(uart_event_valid), .event_ready(uart_event_ready),
        .event_data(uart_event_data), .frame_seen_pulse(frame_seen),
        .valid_frame_count(), .crc_error_count(), .format_error_count(),
        .overflow_count(), .sequence_gap_count(), .duplicate_count()
    );

    // Score screen/LED frames pass UART CRC and sequence checks, then bypass
    // the audio event FIFO entirely.
    assign uart_event_ready = practice_event ? practice_command_ready : non_audio_event ? 1'b1 : score_fifo_ready;
    score_viewer u_score_viewer (
        .clk(sys_clk_50m), .rst_n(sys_rst_n),
        .event_valid(uart_event_valid && uart_event_ready && score_view_event),
        .event_data(uart_event_data),
          .pitch_codes(score_pitch_codes), .instruments(score_instruments),
          .rhythms(score_rhythms),
        .occupied(score_occupied)
    );
    score_led_guide u_score_led_guide (
        .clk(sys_clk_50m), .rst_n(sys_rst_n),
        .event_valid(uart_event_valid && uart_event_ready && score_led_event),
        .event_data(uart_event_data),
        .guide_notes(score_led_guide_notes),
        .expected_notes(score_led_expected_notes)
    );

    event_fifo #(.DATA_WIDTH(64), .DEPTH(128)) u_event_fifo (
        // Drop buffered notes when the UART link dies, so they cannot sound
        // again immediately after the audio engine's panic pulse.
        .clk(sys_clk_50m), .rst_n(event_fifo_rst_n),
        .wr_valid(uart_event_valid && !non_audio_event),
        .wr_ready(score_fifo_ready), .wr_data(uart_event_data),
        .rd_valid(event_valid), .rd_ready(event_ready), .rd_data(event_data),
        .overflow_count()
    );

    event_link_watchdog #(.TIMEOUT_CYCLES(25000000)) u_link_watchdog (
        .clk(sys_clk_50m), .rst_n(sys_rst_n), .frame_seen(frame_seen),
        .link_alive(), .timeout_pulse(link_timeout_pulse)
    );

    key1_instrument_select u_instrument_select (
        .clk(sys_clk_50m), .rst_n(sys_rst_n),
        .key1_n(key1_n), .mode(key1_mode)
    );
    key_pulse_debounce #(.DEBOUNCE_CYCLES(500000)) u_key2_page (
        .clk(sys_clk_50m), .rst_n(sys_rst_n),
        .key_n(key2_n), .pulse(page_next)
    );
    local_instrument_mapper u_instrument_mapper (
        .clk(sys_clk_50m), .rst_n(sys_rst_n), .panic(link_timeout_pulse),
        .mode(key1_mode),
        .in_valid(mapper_in_valid), .in_ready(mapper_in_ready), .in_data(mapper_in_data),
        .out_valid(mapped_valid), .out_ready(mapped_ready), .out_data(mapped_data),
        .pressed_notes(pressed_notes),
        .human_pressed_notes(human_pressed_notes),
        .usb88_low_pressed(usb88_low_pressed),.usb88_pressed(usb88_pressed),
        .display_mode(ui_instrument_mode)
    );

    // Dedicated W22 strip, independent of the disabled TAS5805/three-strip board.
    keyboard_ws2812 #(.NUM_LEDS(45),.KEY_COUNT(44),.LED_OFFSET(1)) u_key_led (
        .clk(sys_clk_50m), .rst_n(sys_rst_n),
        .pressed_keys(usb88_pressed),.practice_mode(practice_display),
        .guide_keys(practice_guide),.correct_keys(practice_correct),.incorrect_keys(practice_incorrect),.dout(key_led_dout)
    );
    keyboard_ws2812 #(.NUM_LEDS(45),.KEY_START(44),.KEY_COUNT(44),.REVERSE(0),.LED_OFFSET(1)) u_key_led_high (
        .clk(sys_clk_50m),.rst_n(sys_rst_n),.pressed_keys(usb88_pressed),
        .practice_mode(practice_display),.guide_keys(practice_guide),
        .correct_keys(practice_correct),.incorrect_keys(practice_incorrect),.dout(key_led_high_dout)
    );

    wire practice_usb_on=usb0_ev50_data[55:52]==1 &&
        usb0_ev50_data[39:32]>=21 && usb0_ev50_data[39:32]<=108 &&
        usb0_ev50_data[61:56]==1 && usb0_ev50_data[31:16]!=0;
    wire practice_usb_gate=!practice_active || !practice_usb_on || practice_key_ready;
    wire usb0_arb_ready;
    assign usb0_ev50_ready=usb0_arb_ready&&practice_usb_gate;
    practice_judge u_practice(
        .clk(sys_clk_50m),.rst_n(sys_rst_n),.panic(link_timeout_pulse),
        .command_valid(uart_event_valid&&practice_event),.command_ready(practice_command_ready),.command_data(uart_event_data),
        .key_valid(usb0_ev50_valid&&usb0_ev50_ready&&practice_usb_on),.key_ready(practice_key_ready),.key_note(usb0_ev50_data[38:32]),
        .active(practice_active),.display_mode(practice_display),.flags(practice_flags),.session(practice_session),
        .total(practice_total),.hits(practice_hits),.wrong(practice_wrong),.misses(practice_misses),.elapsed_ms(practice_elapsed),
        .last_note(practice_last_note),.last_result(practice_last_result),.guide(practice_guide),.correct(practice_correct),.incorrect(practice_incorrect)
    );
    practice_report_tx u_practice_tx(.clk(sys_clk_50m),.rst_n(sys_rst_n),.session(practice_session),.flags(practice_flags),
        .total(practice_total),.hits(practice_hits),.wrong(practice_wrong),.misses(practice_misses),
        .elapsed_ms(practice_elapsed),.last_note(practice_last_note),.last_result(practice_last_result),.tx(esp_uart_tx));

    // ---------------- USB0/USB1 hosts, CDCs, and event merge ----------------
    generate
        if (USB_PORTS >= 1) begin : g_usb0
            usb_midi_host_top #(
                // Source 1 is reserved for the direct 88-key USB input.
                .SOURCE(4'd1), .EP_NUM(USB_EP_NUM),
                .POLL_CYCLES(USB_POLL_CYCLES),
                .RESET_CYCLES(USB_RESET_CYCLES),
                .SETTLE_CYCLES(USB_SETTLE_CYCLES),
                .TX_TIMEOUT_CYCLES(USB_TX_TIMEOUT_CYCLES),
                .RX_TIMEOUT_CYCLES(USB_RX_TIMEOUT_CYCLES),
                .CONNECT_DEBOUNCE_CYCLES(USB_CONNECT_DEBOUNCE_CYCLES),
                .BUS_RESET_CYCLES(USB_BUS_RESET_CYCLES),
                .RESET_RECOVERY_CYCLES(USB_RESET_RECOVERY_CYCLES),
                .DISCONNECT_DEBOUNCE_CYCLES(USB_DISCONNECT_DEBOUNCE_CYCLES),
                .SOF_CYCLES(USB_SOF_CYCLES)
            ) u_usb0 (
                .clk(ulpi0_clk), .rst_n(usb0_rst_n), .start(1'b1),
                .phy_rst(ulpi0_phy_rst), .ulpi_dir(ulpi0_dir),
                .ulpi_nxt(ulpi0_nxt), .ulpi_data(ulpi0_data),
                .ulpi_stp(ulpi0_stp),
                .done(), .error(), .status(),
                .id_vendor(), .id_product(), .config_value(),
                .device_address(),
                .event_valid(usb0_ev_valid), .event_ready(usb0_ev_ready),
                .event_data(usb0_ev_data),
                .bulk_packets(), .bulk_naks(), .bulk_errors(),
                .parser_ignored(), .parser_unsupported()
            );

            event_cdc_fifo #(.DATA_WIDTH(64), .DEPTH(16)) u_cdc0 (
                .wr_clk(ulpi0_clk), .wr_rst_n(usb0_rst_n),
                .wr_valid(usb0_ev_valid), .wr_ready(usb0_ev_ready),
                .wr_data(usb0_ev_data), .overflow_count(),
                .rd_clk(sys_clk_50m), .rd_rst_n(sys_rst_n),
                .rd_valid(usb0_ev50_valid), .rd_ready(usb0_ev50_ready),
                .rd_data(usb0_ev50_data), .underflow_count()
            );
        end else begin : g_no_usb0
            // USB3300 RESET is active high; keep a disabled port released.
            assign ulpi0_phy_rst   = 1'b0;
            assign ulpi0_stp       = 1'b1;
            assign usb0_ev50_valid = 1'b0;
            assign usb0_ev50_data  = 64'd0;
        end
    endgenerate

    generate
        if (USB_PORTS >= 2) begin : g_usb1
            usb_midi_host_top #(
                .SOURCE(4'd3), .EP_NUM(USB_EP_NUM),
                .POLL_CYCLES(USB_POLL_CYCLES),
                .RESET_CYCLES(USB_RESET_CYCLES),
                .SETTLE_CYCLES(USB_SETTLE_CYCLES),
                .TX_TIMEOUT_CYCLES(USB_TX_TIMEOUT_CYCLES),
                .RX_TIMEOUT_CYCLES(USB_RX_TIMEOUT_CYCLES),
                .CONNECT_DEBOUNCE_CYCLES(USB_CONNECT_DEBOUNCE_CYCLES),
                .BUS_RESET_CYCLES(USB_BUS_RESET_CYCLES),
                .RESET_RECOVERY_CYCLES(USB_RESET_RECOVERY_CYCLES),
                .DISCONNECT_DEBOUNCE_CYCLES(USB_DISCONNECT_DEBOUNCE_CYCLES),
                .SOF_CYCLES(USB_SOF_CYCLES)
            ) u_usb1 (
                .clk(ulpi1_clk), .rst_n(usb1_rst_n), .start(1'b1),
                .phy_rst(ulpi1_phy_rst), .ulpi_dir(ulpi1_dir),
                .ulpi_nxt(ulpi1_nxt), .ulpi_data(ulpi1_data),
                .ulpi_stp(ulpi1_stp),
                .done(), .error(), .status(),
                .id_vendor(), .id_product(), .config_value(),
                .device_address(),
                .event_valid(usb1_ev_valid), .event_ready(usb1_ev_ready),
                .event_data(usb1_ev_data),
                .bulk_packets(), .bulk_naks(), .bulk_errors(),
                .parser_ignored(), .parser_unsupported()
            );

            event_cdc_fifo #(.DATA_WIDTH(64), .DEPTH(16)) u_cdc1 (
                .wr_clk(ulpi1_clk), .wr_rst_n(usb1_rst_n),
                .wr_valid(usb1_ev_valid), .wr_ready(usb1_ev_ready),
                .wr_data(usb1_ev_data), .overflow_count(),
                .rd_clk(sys_clk_50m), .rd_rst_n(sys_rst_n),
                .rd_valid(usb1_ev50_valid), .rd_ready(usb1_ev50_ready),
                .rd_data(usb1_ev50_data), .underflow_count()
            );
        end else begin : g_no_usb1
            // USB3300 RESET is active high; keep a disabled port released.
            assign ulpi1_phy_rst   = 1'b0;
            assign ulpi1_stp       = 1'b1;
            assign usb1_ev50_valid = 1'b0;
            assign usb1_ev50_data  = 64'd0;
        end
    endgenerate

    // USB0 vs disabled USB1, then the winner vs UART. Arbitration is fair.
    event_arbiter u_arb_usb (
        .clk(sys_clk_50m), .rst_n(sys_rst_n),
        .in0_valid(usb0_ev50_valid&&practice_usb_gate), .in0_ready(usb0_arb_ready),
        .in0_data(usb0_ev50_data),
        .in1_valid(usb1_ev50_valid), .in1_ready(usb1_ev50_ready),
        .in1_data(usb1_ev50_data),
        .out_valid(usb_merged_valid), .out_ready(usb_merged_ready),
        .out_data(usb_merged_data)
    );

    event_arbiter u_event_arb (
        .clk(sys_clk_50m), .rst_n(sys_rst_n),
        .in0_valid(usb_merged_valid), .in0_ready(usb_merged_ready),
        .in0_data(usb_merged_data),
        .in1_valid(event_valid), .in1_ready(event_ready), .in1_data(event_data),
        .out_valid(merged_valid), .out_ready(pre_arb_ready),
        .out_data(merged_data)
    );

    // Optional internal sources: power-on self test and/or offline score.
    generate
        if (TEST_TONE_ENABLE != 0 || SCORE_PLAYER_ENABLE != 0) begin : g_demo
            if (TEST_TONE_ENABLE != 0) begin : g_tone
                test_tone_gen #(
                    .START_DELAY_CYCLES(50_000_000),
                    .EVENT_GAP_CYCLES(50_000),
                    .VELOCITY(7'd64),
                    // Source 1 = directly attached 88-key path.
                    .SOURCE(4'd1)
                ) u_test_tone (
                    .clk(sys_clk_50m), .rst_n(sys_rst_n),
                    .out_valid(tone_valid), .out_ready(tone_ready), .out_data(tone_data),
                    .done()
                );
            end else begin : g_no_tone
                assign tone_valid = 1'b0;
                assign tone_data  = 64'd0;
            end

            if (SCORE_PLAYER_ENABLE != 0) begin : g_score
                score_player #(
                    .CLK_FREQ_HZ(50_000_000),
                    .SCORE_FILE("src/score_demo.mem")
                ) u_score_player (
                    .clk(sys_clk_50m), .rst_n(sys_rst_n),
                    .out_valid(score_valid), .out_ready(score_ready), .out_data(score_data),
                    .expected_notes(score_expected_notes), .done()
                );
            end else begin : g_no_score
                assign score_valid           = 1'b0;
                assign score_data            = 64'd0;
                assign score_expected_notes  = 128'd0;
            end

            event_arbiter u_event_arb_demo (
                .clk(sys_clk_50m), .rst_n(sys_rst_n),
                .in0_valid(tone_valid), .in0_ready(tone_ready), .in0_data(tone_data),
                .in1_valid(score_valid), .in1_ready(score_ready), .in1_data(score_data),
                .out_valid(internal_valid), .out_ready(internal_ready), .out_data(internal_data)
            );
            event_arbiter u_event_arb_test (
                .clk(sys_clk_50m), .rst_n(sys_rst_n),
                .in0_valid(merged_valid), .in0_ready(pre_arb_ready), .in0_data(merged_data),
                .in1_valid(internal_valid), .in1_ready(internal_ready), .in1_data(internal_data),
                .out_valid(mapper_in_valid), .out_ready(mapper_in_ready), .out_data(mapper_in_data)
            );
        end else begin : g_no_demo
            assign score_expected_notes = 128'd0;
            assign pre_arb_ready        = mapper_in_ready;
            assign mapper_in_valid      = merged_valid;
            assign mapper_in_data       = merged_data;
        end
    endgenerate

    // TAS5805 I2S output, three WS2812 strips and the LED guide.
    generate
        if (LED_AUDIO_ENABLE != 0) begin : g_led_audio
            led_audio_framework #(
                .CLK_FREQ_HZ(50_000_000),
                .LED_MAP_FILE("src/led_map.mem"),
                .TAS_INIT_FILE("src/tas5805_init.mem")
            ) u_led_audio (
                .clk(sys_clk_50m), .rst_n(sys_rst_n),
                .pressed_notes(human_pressed_notes),
                .guide_notes(score_led_guide_notes),
                .expected_notes(score_expected_notes | score_led_expected_notes),
                .brightness_shift(4'd6),
                .audio_valid(post_valid),
                .audio_left(post_left), .audio_right(post_right),
                .tas_enable(1'b1), .tas_mute(1'b0),
                .led_data(led_data), .led_busy(),
                .i2s_sclk(i2s_sclk), .i2s_lrclk(i2s_lrclk), .i2s_sdin(i2s_sdin),
                .tas_pdn(tas_pdn), .tas_scl(tas_scl), .tas_sda(tas_sda),
                .tas_busy(), .tas_init_done(), .tas_error()
            );
        end else begin : g_no_led_audio
            assign led_data  = 3'b000;
            assign i2s_sclk  = 1'b0;
            assign i2s_lrclk = 1'b0;
            assign i2s_sdin  = 1'b0;
            assign tas_pdn   = 1'b1;
            assign tas_scl   = 1'b0;
            assign tas_sda   = 1'bz;
        end
    endgenerate

    esp32_audio_engine #(
        .SYS_CLK_FREQ_HZ(50000000), .AUDIO_CLK_FREQ_HZ(50000000),
        .SAMPLE_RATE_HZ(48828), .SAMPLE_PERIOD_CYCLES(1024), .PT_BCLK_DIV(16),
        .PIANO_PHASE_FILE("src/note_phase_rom_48828.mem"),
        .BASS_PHASE_FILE("src/note_phase_rom_48828.mem"),
        .PIANO_WAVE_FILE("src/piano_refined_18bit.mem"),
        .ORGAN_WAVE_FILE("src/organ_waveform_rom.mem")
    ) u_audio_engine (
        .sys_clk(sys_clk_50m), .audio_clk(sys_clk_50m), .rst_n(sys_rst_n),
        .event_valid(mapped_valid), .event_ready(mapped_ready), .event_data(mapped_data),
        .link_timeout_pulse(link_timeout_pulse),
        .pt_bck(pt_bck), .pt_ws(pt_ws), .pt_din(pt_din), .pa_en(pa_en),
        .active_voice_count(), .deadline_miss_count(), .audio_overflow_count(),
        .audio_underflow_count(), .unknown_type_count(), .unknown_instrument_count(),
        .visual_audio_valid(visual_audio_valid), .visual_audio_sample(visual_audio_sample),
        // Stereo post-effect tap feeds the waveform / Lissajous pages.
        .post_valid(post_valid), .post_left(post_left), .post_right(post_right),
        .ui_event(ui_event), .ui_label(ui_label), .ui_value(ui_value)
    );

    // Show the last knob value for about 2 seconds at 50 MHz.
    always @(posedge sys_clk_50m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            ui_timer <= 27'd0;
            ui_label_reg <= 2'd0;
            ui_value_reg <= 7'd0;
            ui_active_reg <= 1'b0;
        end else if (ui_event) begin
            ui_timer <= 27'd100_000_000;
            ui_label_reg <= ui_label;
            ui_value_reg <= ui_value;
            ui_active_reg <= 1'b1;
        end else begin
            if (ui_timer != 0)
                ui_timer <= ui_timer - 1'b1;
            ui_active_reg <= (ui_timer != 0);
        end
    end

    spectrum_analyzer u_spectrum (
        .clk(sys_clk_50m), .rst_n(sys_rst_n),
        .audio_valid(visual_audio_valid), .audio_sample(visual_audio_sample),
        .spectrum_levels(spectrum_levels), .spectrum_peaks(spectrum_peaks)
    );

    lcd_rgb_timing u_lcd_rgb_timing (
        .clk_50m      (sys_clk_50m),
        .rst_n        (sys_rst_n),
        .lcd_pclk     (lcd_pclk),
        .lcd_hsync    (lcd_hsync),
        .lcd_vsync    (lcd_vsync),
        .lcd_de       (lcd_de),
        .active_video (active_video),
        .pixel_x      (pixel_x),
        .pixel_y      (pixel_y),
        .frame_toggle (frame_toggle)
    );

    spectrum_keys_renderer u_renderer (
        .clk(sys_clk_50m), .rst_n(sys_rst_n), .frame_toggle(frame_toggle),
        .active_video (active_video),
        .pixel_x      (render_x),
        .pixel_y      (render_y),
        .instrument_mode(ui_instrument_mode),
        .ui_label(ui_label_reg),
        .ui_value(ui_value_reg),
        .ui_active(ui_active_reg),
        .pressed_notes(pressed_notes),
        .spectrum_levels(spectrum_levels),
        .spectrum_peaks(spectrum_peaks),
        .scope_l(post_left),
        .scope_r(post_right),
        .scope_valid(post_valid),
        .page_next(page_next),
        .page_set_valid(uart_event_valid && uart_event_ready && app_page_event),
        .page_set(uart_event_data[17:16]),
        .score_pitch_codes(score_pitch_codes),
        .score_instruments(score_instruments),
          .score_rhythms(score_rhythms),
        .score_occupied(score_occupied),
        .guide_notes(score_led_guide_notes),
        .expected_notes(score_led_expected_notes),
        .red_565      (red_565),
        .green_565    (green_565),
        .blue_565     (blue_565)
    );

    // Expand RGB565 into the Dock's RGB666 wiring.  The six signals in each
    // group drive LCD R[7:2], G[7:2] and B[7:2] respectively; the Dock holds
    // LCD R[1:0], G[1:0] and B[1:0] at ground.
    assign dock_lcd_r6 = active_video ? {red_565, red_565[4]} : 6'h00;
    assign dock_lcd_g6 = active_video ? green_565 : 6'h00;

    assign dock_lcd_b6 = active_video ? {blue_565, blue_565[4]} : 6'h00;

    lcd_backlight_pwm #(
        .STARTUP_CYCLES (22'd2500000),  // 50 ms at 50 MHz
        .PWM_PERIOD     (16'd50000),    // 1 kHz
        .PWM_ON_CYCLES  (16'd40000)     // 80 % duty
    ) u_lcd_backlight_pwm (
        .clk_50m (sys_clk_50m),
        .rst_n   (sys_rst_n),
        .pwm_out (lcd_bl_pwm)
    );

    touch_i2c_safe_idle #(
        .RESET_RELEASE_CYCLES (21'd1000000) // 20 ms at 50 MHz
    ) u_touch_i2c_safe_idle (
        .clk_50m   (sys_clk_50m),
        .rst_n     (sys_rst_n),
        .ctp_int   (ctp_int),
        .ctp_rst_n (ctp_rst_n),
        .ctp_sda   (ctp_sda),
        .ctp_scl   (ctp_scl)
    );

endmodule

