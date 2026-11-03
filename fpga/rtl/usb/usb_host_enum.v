`timescale 1ns / 1ps

// Minimal Full-Speed USB host enumeration engine over one ULPI port.
//
// Sequence (all control transfers on EP0, address 0 then 1):
//   1. GET_DESCRIPTOR(Device, 8)   -> read bMaxPacketSize0
//   2. SET_ADDRESS(1)              -> status-IN ZLP, then use address 1
//   3. GET_DESCRIPTOR(Device, 18)  -> VID / PID / bcdUSB / class
//   4. GET_DESCRIPTOR(Config, 9)   -> bConfigurationValue
//   5. SET_CONFIGURATION(bConfigurationValue) -> configured
//
// Every data packet is checked for the expected DATA0/DATA1 toggle and for the
// USB CRC16 residue (0xB001); tokens carry a CRC5 built by usb_token_crc5.
// NAKed IN tokens are retried; STALL, timeout, a bad toggle or a bad CRC abort
// with error set.
//
// Port bring-up: debounce the FS J line state, drive USB reset through
// Function Control (SE0 then FS host), wait reset recovery, then enumerate.
// The EP0 max packet comes from the device descriptor, and the complete
// configuration descriptor is streamed through a parser that locates the
// MIDIStreaming Bulk IN endpoint.  A PHY host-disconnect event or sustained
// SE0 restarts bring-up. SOFs begin during reset recovery and continue through
// enumeration; after configuration the Bulk IN endpoint is polled between SOFs.
module usb_host_enum #(
    parameter integer RESET_CYCLES  = 600000,
    parameter integer SETTLE_CYCLES = 60000,
    parameter integer TX_TIMEOUT_CYCLES = 6000,
    parameter integer RX_TIMEOUT_CYCLES = 60000,
    parameter integer MAX_RETRY = 8,
    // Host port supervision, in ULPI CLKOUT (60 MHz) cycles.
    // At 60 MHz: attach debounce 100 ms, root-port reset 50 ms, recovery 10 ms
    // (USB 2.0 Figure 7-29 and 7.1.7.5). Hub-port reset has a different minimum.
    parameter integer CONNECT_DEBOUNCE_CYCLES = 6000000,
    parameter integer BUS_RESET_CYCLES = 3000000,
    parameter integer RESET_RECOVERY_CYCLES = 600000,
    // USB 2.0 9.2.6.3: 2 ms at 60 MHz. The derived default preserves the
    // existing scaled-time tests; it can also be overridden independently.
    parameter integer SET_ADDRESS_RECOVERY_CYCLES = RESET_RECOVERY_CYCLES / 5,
    parameter integer DISCONNECT_DEBOUNCE_CYCLES = 60000,
    parameter integer SOF_CYCLES = 60000,
    parameter integer PORT_RESET_ENABLE = 1,
    // 1 = after SET_CONFIGURATION, poll a bulk IN endpoint and emit 4-byte
    // USB-MIDI packets.  LINK_BYTES then covers PID + 64 data + 2 CRC.
    parameter integer BULK_ENABLE = 0,
    parameter integer EP_NUM = 4,
    parameter integer POLL_CYCLES = 60000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,

    // ULPI pins
    output wire        phy_rst,
    input  wire        ulpi_dir,
    input  wire        ulpi_nxt,
    inout  wire [7:0]  ulpi_data,
    output wire        ulpi_stp,

    // Results
    output reg         done,
    output reg         error,
    output reg         busy,
    output reg  [15:0] id_vendor,
    output reg  [15:0] id_product,
    output reg  [15:0] bcd_usb,
    output reg  [7:0]  max_packet,
    output reg  [7:0]  config_value,
    output reg  [7:0]  device_class,
    output reg  [6:0]  device_address,
    output wire [7:0]  status,

    // Bulk IN stream (one USB-MIDI event packet per handshake).
    output reg         midi_valid,
    input  wire        midi_ready,
    output reg  [31:0] midi_packet,
    output reg  [31:0] bulk_packets,
    output reg  [31:0] bulk_naks,
    output reg  [31:0] bulk_errors
);

    // A 64-byte Bulk IN packet needs PID + 64 data + 2 CRC.  EP0 packets above
    // 13 bytes therefore require BULK_ENABLE=1 (the main design always sets it).
    localparam integer LINK_BYTES = (BULK_ENABLE != 0) ? 68 : 16;
    localparam integer LEN_W = $clog2(LINK_BYTES + 1);

    // ----------------------------------------------------------------
    // ULPI packet link
    // ----------------------------------------------------------------
    reg         l_start;
    reg  [3:0]  l_pid;
    reg  [LEN_W-1:0] l_len;
    reg  [LINK_BYTES*8-1:0] l_data;
    reg         l_expect;
    reg         l_crc;
    wire        l_done, l_timeout, l_ready, l_busy, l_rx_error, l_rx_crc_ok;
    wire [3:0]  l_rx_pid;
    wire [LEN_W-1:0] l_rx_len;
    wire [LINK_BYTES*8-1:0] l_rx_data;

    // Runtime register writes (bus reset) and RXCMD view.
    reg         l_wr_req;
    reg  [5:0]  l_wr_addr;
    reg  [7:0]  l_wr_data;
    wire        l_wr_busy, l_wr_done, l_wr_error;
    wire [1:0]  l_linestate, l_vbus_state, l_rx_event;
    wire        l_rx_cmd_valid;

    ulpi_packet_link #(
        .RESET_CYCLES(RESET_CYCLES),
        .SETTLE_CYCLES(SETTLE_CYCLES),
        .TX_TIMEOUT_CYCLES(TX_TIMEOUT_CYCLES),
        .RX_TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES),
        .DATA_BYTES(LINK_BYTES)
    ) link (
        .clk(clk), .rst_n(rst_n),
        .start(l_start), .pid(l_pid), .len(l_len), .data(l_data),
        .expect_rx(l_expect), .crc16_append(l_crc),
        .done(l_done), .timeout(l_timeout),
        .rx_pid(l_rx_pid), .rx_len(l_rx_len), .rx_data(l_rx_data),
        .rx_error(l_rx_error), .rx_crc_ok(l_rx_crc_ok),
        .ready(l_ready), .busy(l_busy),
        .wr_req(l_wr_req), .wr_addr(l_wr_addr), .wr_data(l_wr_data),
        .wr_busy(l_wr_busy), .wr_done(l_wr_done), .wr_error(l_wr_error),
        .rx_linestate(l_linestate), .rx_vbus_state(l_vbus_state),
        .rx_event(l_rx_event), .rx_cmd_valid(l_rx_cmd_valid),
        .phy_rst(phy_rst), .ulpi_dir(ulpi_dir), .ulpi_nxt(ulpi_nxt),
        .ulpi_data(ulpi_data), .ulpi_stp(ulpi_stp)
    );

    // ----------------------------------------------------------------
    // Token CRC5 (function form: always inlined, no swept sub-module)
    // ----------------------------------------------------------------
    function [4:0] crc5_of;
        input [6:0] a;
        input [3:0] e;
        integer n;
        reg [4:0] c;
        begin
            c = 5'h1F;
            for (n = 0; n < 7; n = n + 1)
                c = (c[0] ^ a[n]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
            for (n = 0; n < 4; n = n + 1)
                c = (c[0] ^ e[n]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
            crc5_of = ~c;
        end
    endfunction

    function [7:0] ep0_clamp;
        input [7:0] v;
        begin
            ep0_clamp = ((v == 8'd8) || (v == 8'd16) ||
                         (v == 8'd32) || (v == 8'd64)) ? v : 8'd8;
        end
    endfunction

    wire [4:0] tok_crc5 = crc5_of(device_address, 4'd0);
    wire [7:0] tok_b1 = {1'b0, device_address};
    wire [7:0] tok_b2 = {tok_crc5, 3'b000};
    wire [15:0] token_word = {tok_b2, tok_b1};

    // Bulk endpoint token (endpoint number resolved from the descriptor, or
    // the EP_NUM default when no usable descriptor was found).
    localparam [3:0] BULK_EP_DEFAULT = EP_NUM[3:0];
    reg  [3:0] bulk_ep_num;
    wire [3:0] BULK_EP = bulk_ep_num;
    wire [4:0] bulk_crc5 = crc5_of(device_address, BULK_EP);
    wire [7:0] bulk_b1 = {BULK_EP[0], device_address};
    wire [7:0] bulk_b2 = {bulk_crc5, BULK_EP[3:1]};
    wire [15:0] bulk_token_word = {bulk_b2, bulk_b1};

    // SOF packet: 11-bit frame number + CRC5, sent every 1 ms.
    reg [10:0] sof_frame;
    function [4:0] crc5_sof;
        input [10:0] f;
        integer n;
        reg [4:0] c;
        begin
            c = 5'h1F;
            for (n = 0; n < 11; n = n + 1)
                c = (c[0] ^ f[n]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
            crc5_sof = ~c;
        end
    endfunction

    wire [4:0]  sof_crc5 = crc5_sof(sof_frame);
    wire [15:0] sof_word = {{sof_crc5, sof_frame[10:8]}, sof_frame[7:0]};
    reg  [31:0] sof_timer;
    reg sof_enabled;
    reg [4:0] sof_resume_ts;

    // ----------------------------------------------------------------
    // PID constants (4-bit PID field)
    // ----------------------------------------------------------------
    localparam [3:0] PID_OUT   = 4'h1;
    localparam [3:0] PID_IN    = 4'h9;
    localparam [3:0] PID_SOF   = 4'h5;
    localparam [3:0] PID_SETUP = 4'hD;
    localparam [3:0] PID_DATA0 = 4'h3;
    localparam [3:0] PID_DATA1 = 4'hB;
    localparam [3:0] PID_ACK   = 4'h2;
    localparam [3:0] PID_NAK   = 4'hA;
    localparam [3:0] PID_STALL = 4'hE;

    // ----------------------------------------------------------------
    // Buffers and request state
    // ----------------------------------------------------------------
    reg [7:0] dev_desc [0:23];
    reg [7:0] cfg_desc [0:15];
    wire [15:0] cfg_total_len = {cfg_desc[3], cfg_desc[2]};

    reg [7:0]  req_type, req_code;
    reg [15:0] req_value, req_index, req_len;
    reg        req_status_in;   // 1 = status stage is an IN ZLP
    reg        req_buf_cfg;     // 1 = data goes to the config descriptor
    reg        req_parse_cfg;   // 1 = stream config descriptor to the parser

    // Configuration descriptor stream parser (no full buffer: one byte per
    // clock after each received packet).  It locates the MIDIStreaming
    // interface and its Bulk IN endpoint.
    reg [7:0]  d_len, d_type, d_body_idx;
    reg [15:0] d_left;
    reg [1:0]  d_kind;          // 0=length, 1=type, 2=body
    reg [7:0]  d_if_class, d_if_subclass;
    reg        d_in_midi_if;
    reg [7:0]  d_ep_addr, d_ep_attr, d_ep_max_lo;
    reg [3:0]  d_bulk_ep;
    reg [15:0] d_bulk_max;
    reg        d_midi_found;
    reg        d_any_bulk_found;
    reg [3:0]  d_any_bulk_ep;
    reg [15:0] d_any_bulk_max;
    reg [7:0]  parse_idx;

    localparam integer MAX_CONFIG_BYTES = 512;

    reg [15:0] remaining;
    reg [15:0] buf_off;
    reg [7:0]  ep0_max;
    reg        exp_toggle;
    reg [7:0]  retry;
    reg        nak_seen;
    reg        crc_error_seen;

    // Setup packet word: 8 bytes, byte0 in bits [7:0].
    wire [127:0] setup_word = {
        req_len[15:8],   req_len[7:0],
        req_index[15:8], req_index[7:0],
        req_value[15:8], req_value[7:0],
        req_code, req_type
    };

    // ----------------------------------------------------------------
    // Sequence FSM
    // ----------------------------------------------------------------
    localparam SQ_IDLE    = 4'd0;
    localparam SQ_GD8     = 4'd1;
    localparam SQ_SETADDR = 4'd2;
    localparam SQ_GD18    = 4'd3;
    localparam SQ_GDCFG   = 4'd4;
    localparam SQ_SETCFG  = 4'd5;
    localparam SQ_FINISH  = 4'd6;
    localparam SQ_ERR     = 4'd7;
    localparam SQ_BULK    = 4'd8;
    localparam SQ_CONNECT = 4'd9;
    localparam SQ_RST_SET = 4'd10;
    localparam SQ_RST_HOLD= 4'd11;
    localparam SQ_RST_REL = 4'd12;
    localparam SQ_RECOVER = 4'd13;
    localparam SQ_GDCFG2  = 4'd14;
    localparam SQ_ADDR_WAIT = 4'd15;

    reg [3:0] sq;
    reg       xfer_go;
    reg       addr_set, configured;

    // Host port supervision: ULPI 1.1 section 3.8.5.1 and USB3300 Table 6-8.
    //   0x50 = SuspendM=1, XcvrSelect=HS, TermSelect=0, OpMode=10.
    //          The host's 45-ohm ground terminations establish reset SE0.
    //          No TXCMD/host chirp is sent: after the hold, return to FS.
    //   0x45 = SuspendM=1, XcvrSelect=FS, TermSelect=1, OpMode=Normal.
    // OTG DpPulldown/DmPulldown remain enabled throughout (OTG=0x26).
    // Non-Driving (0x4D) disables ALL terminations; it is NOT a bus reset.
    localparam [7:0] FUNC_SE0 = 8'h50;
    localparam [7:0] FUNC_FS  = 8'h45;
    reg [31:0] port_timer;
    reg [31:0] se0_cnt;
    reg        disc_event;
    reg        wr_pending;
    reg        reset_done;

    wire monitor_disconnect = (sq == SQ_GD8) || (sq == SQ_SETADDR) ||
                              (sq == SQ_ADDR_WAIT) ||
                              (sq == SQ_GD18) || (sq == SQ_GDCFG) ||
                              (sq == SQ_GDCFG2) || (sq == SQ_SETCFG) ||
                              (sq == SQ_BULK) || (sq == SQ_FINISH);

    // ----------------------------------------------------------------
    // Transfer FSM
    // ----------------------------------------------------------------
    localparam TS_IDLE      = 5'd0;
    localparam TS_SETUP_TOK = 5'd1;
    localparam TS_SETUP_TW  = 5'd2;
    localparam TS_SETUP_DAT = 5'd3;
    localparam TS_SETUP_DW  = 5'd4;
    localparam TS_IN_TOK    = 5'd5;
    localparam TS_IN_W      = 5'd6;
    // State 7 was the buffered CRC pass; retain the remaining diagnostic codes.
    localparam TS_RX_DONE   = 5'd8;
    localparam TS_IN_ACK    = 5'd9;
    localparam TS_IN_ACKW   = 5'd10;
    localparam TS_OUT_TOK   = 5'd11;
    localparam TS_OUT_TW    = 5'd12;
    localparam TS_OUT_DAT   = 5'd13;
    localparam TS_OUT_DW    = 5'd14;
    localparam TS_STIN_TOK  = 5'd15;
    localparam TS_STIN_W    = 5'd16;
    localparam TS_STIN_DONE = 5'd17;
    localparam TS_STIN_ACK  = 5'd18;
    localparam TS_STIN_ACKW = 5'd19;
    localparam TS_DONE      = 5'd20;
    localparam TS_ERR       = 5'd21;
    localparam TS_BULK_GAP  = 5'd22;
    localparam TS_BULK_TOK  = 5'd23;
    localparam TS_BULK_WAIT = 5'd24;
    localparam TS_BULK_DONE = 5'd25;
    localparam TS_BULK_ACK  = 5'd26;
    localparam TS_BULK_ACKW = 5'd27;
    localparam TS_BULK_STRM = 5'd28;
    localparam TS_SOF_TOK   = 5'd29;
    localparam TS_SOF_W     = 5'd30;
    localparam TS_PARSE     = 5'd31;

    reg [4:0]  ts;
    reg        xfer_done, xfer_err;
    reg        last_data;
    reg        chk_bad;
    reg [LINK_BYTES*8-1:0] rx_payload;
    wire [7:0] parse_byte = rx_payload[parse_idx*8 +: 8];
    reg [7:0]  payload_len;
    reg        rx_is_data;
    // Bulk IN polling
    reg [31:0] bulk_timer;
    reg        bulk_deliver;
    reg [7:0]  bulk_left;
    reg [LINK_BYTES*8-1:0] bulk_shift;

    localparam [7:0] RETRY_MAX = MAX_RETRY;

    // A received packet is {PID, payload..., CRC16_lo, CRC16_hi}; the CRC only
    // covers the payload. Exclude PID and CRC bytes when deriving its length.
    wire [7:0] rx_len8         = {{(8-LEN_W){1'b0}}, l_rx_len};
    wire [7:0] rx_payload_len  = (rx_len8 >= 8'd3) ? (rx_len8 - 8'd3) : 8'd0;

    integer i;

    // CRC is accumulated by the link as bytes arrive. Buffering and then
    // serially rechecking 64 bytes exceeds the FS ACK decision window.
    task automatic latch_received_payload;
        begin
            chk_bad <= !l_rx_crc_ok;
            rx_payload <= l_rx_data >> 8;
            payload_len <= rx_payload_len;
            rx_is_data <= (l_rx_pid == PID_DATA0) || (l_rx_pid == PID_DATA1);
        end
    endtask

    // ----------------------------------------------------------------
    // Main sequential logic
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sq <= SQ_IDLE; ts <= TS_IDLE;
            done <= 1'b0; error <= 1'b0; busy <= 1'b0;
            id_vendor <= 16'd0; id_product <= 16'd0; bcd_usb <= 16'd0;
            max_packet <= 8'd0; config_value <= 8'd0; device_class <= 8'd0;
            device_address <= 7'd0; addr_set <= 1'b0; configured <= 1'b0;
            l_start <= 1'b0; l_pid <= 4'd0; l_len <= {LEN_W{1'b0}}; l_data <= {LINK_BYTES*8{1'b0}};
            l_expect <= 1'b0; l_crc <= 1'b0;
            xfer_go <= 1'b0; xfer_done <= 1'b0; xfer_err <= 1'b0;
            req_type <= 8'd0; req_code <= 8'd0; req_value <= 16'd0;
            req_index <= 16'd0; req_len <= 16'd0;
            req_status_in <= 1'b0; req_buf_cfg <= 1'b0;
            remaining <= 16'd0; buf_off <= 16'd0;
            ep0_max <= 8'd8; bulk_ep_num <= BULK_EP_DEFAULT;
            req_parse_cfg <= 1'b0;
            d_len <= 8'd0; d_type <= 8'd0; d_body_idx <= 8'd0;
            d_left <= 16'd0; d_kind <= 2'd0;
            d_if_class <= 8'd0; d_if_subclass <= 8'd0; d_in_midi_if <= 1'b0;
            d_ep_addr <= 8'd0; d_ep_attr <= 8'd0; d_ep_max_lo <= 8'd0;
            d_bulk_ep <= 4'd0; d_bulk_max <= 16'd0;
            d_midi_found <= 1'b0; d_any_bulk_found <= 1'b0;
            d_any_bulk_ep <= 4'd0; d_any_bulk_max <= 16'd0;
            parse_idx <= 8'd0;
            exp_toggle <= 1'b1; retry <= 8'd0;
            nak_seen <= 1'b0; crc_error_seen <= 1'b0;
            last_data <= 1'b0;
            chk_bad <= 1'b0;
            midi_valid <= 1'b0; midi_packet <= 32'd0;
            bulk_packets <= 32'd0; bulk_naks <= 32'd0; bulk_errors <= 32'd0;
            bulk_timer <= 32'd0; bulk_deliver <= 1'b0; bulk_left <= 8'd0;
            bulk_shift <= {LINK_BYTES*8{1'b0}};
            l_wr_req <= 1'b0; l_wr_addr <= 6'd0; l_wr_data <= 8'd0;
            port_timer <= 32'd0;
            reset_done <= 1'b0;
            sof_frame <= 11'd0; sof_timer <= 32'd0;
            sof_enabled <= 1'b0; sof_resume_ts <= TS_IDLE;
            for (i = 0; i < 24; i = i + 1) dev_desc[i] <= 8'd0;
            for (i = 0; i < 16; i = i + 1) cfg_desc[i] <= 8'd0;
        end else begin
            // Defaults (one-cycle pulses).
            l_start    <= 1'b0;
            xfer_go    <= 1'b0;
            xfer_done  <= 1'b0;
            xfer_err   <= 1'b0;
            // A register write request stays asserted until the link answers.
            if (l_wr_done || l_wr_error)
                l_wr_req <= 1'b0;
            // Bulk streaming is only active in BULK_ENABLE builds.
            if (BULK_ENABLE == 0)
                midi_valid <= 1'b0;

            // Independent, saturating deadlines keep running during USB
            // transfers and parsing.  A SOF must not reset the Bulk IN
            // deadline: with both production periods at 1 ms that would
            // otherwise starve all Bulk IN traffic forever.
            // Keep an attached FS device active during reset recovery,
            // SET_ADDRESS recovery and descriptor transfers as well as Bulk IN.
            if (sof_enabled && start && sof_timer < SOF_CYCLES)
                sof_timer <= sof_timer + 32'd1;
            if ((sq == SQ_BULK) && start && bulk_timer < POLL_CYCLES)
                bulk_timer <= bulk_timer + 32'd1;

            // --------------------------------------------------------
            // Sequence FSM
            // --------------------------------------------------------
            // A disconnect (PHY host-disconnect event or sustained SE0) aborts
            // the current enumeration and sends the port back to connect wait.
            if (disc_event && monitor_disconnect) begin
                sq             <= SQ_CONNECT;
                ts             <= TS_IDLE;
                busy           <= 1'b0;
                done           <= 1'b0;
                error          <= 1'b0;
                configured     <= 1'b0;
                addr_set       <= 1'b0;
                device_address <= 7'd0;
                midi_valid     <= 1'b0;
                port_timer     <= 32'd0;
                l_start        <= 1'b0;
                sof_enabled    <= 1'b0;
            end else begin
            case (sq)
                SQ_IDLE: begin
                    done <= 1'b0;
                    if (start && l_ready) begin
                        busy <= 1'b1;
                        error <= 1'b0;
                        nak_seen <= 1'b0;
                        crc_error_seen <= 1'b0;
                        device_address <= 7'd0;
                        addr_set <= 1'b0;
                        configured <= 1'b0;
                        reset_done <= 1'b0;
                        sof_frame <= 11'd0;
                        sof_timer <= 32'd0;
                        sof_enabled <= 1'b0;
                        port_timer <= 32'd0;
                        ts <= TS_IDLE;
                        sq <= SQ_CONNECT;
                    end
                end

                // FS uses the D+ pull-up (J=01). Require a stable attachment
                // for 100 ms before driving the root-port USB reset.
                SQ_CONNECT: begin
                    busy <= 1'b1;
                    done <= 1'b0;
                    if (PORT_RESET_ENABLE == 0) begin
                        sof_enabled <= 1'b1;
                        sof_timer <= 32'd0;
                        reset_done <= 1'b1;
                        port_timer <= 32'd0;
                        sq <= SQ_RECOVER;
                    end else if (l_linestate == 2'b01) begin
                        if (port_timer >= CONNECT_DEBOUNCE_CYCLES) begin
                            port_timer <= 32'd0;
                            l_wr_addr  <= 6'h04;   // Function Control
                            l_wr_data  <= FUNC_SE0;
                            l_wr_req   <= 1'b1;
                            sq         <= SQ_RST_SET;
                        end else begin
                            port_timer <= port_timer + 32'd1;
                        end
                    end else begin
                        port_timer <= 32'd0;
                    end
                end

                SQ_RST_SET: begin
                    if (l_wr_error) begin
                        port_timer <= 32'd0;
                        sq <= SQ_ERR;
                    end else if (l_wr_done) begin
                        port_timer <= 32'd0;
                        sq <= SQ_RST_HOLD;
                    end
                end

                SQ_RST_HOLD: begin
                    if (port_timer >= BUS_RESET_CYCLES) begin
                        port_timer <= 32'd0;
                        l_wr_addr  <= 6'h04;
                        l_wr_data  <= FUNC_FS;
                        l_wr_req   <= 1'b1;
                        sq         <= SQ_RST_REL;
                    end else begin
                        port_timer <= port_timer + 32'd1;
                    end
                end

                SQ_RST_REL: begin
                    if (l_wr_error) begin
                        port_timer <= 32'd0;
                        sq <= SQ_ERR;
                    end else if (l_wr_done) begin
                        port_timer <= 32'd0;
                        sof_enabled <= 1'b1;
                        sof_timer <= 32'd0;
                        sq <= SQ_RECOVER;
                    end
                end

                // Recovery delays control requests for 10 ms; periodic SOFs
                // keep the device from suspending during that interval.
                SQ_RECOVER: begin
                    if (port_timer >= RESET_RECOVERY_CYCLES && ts == TS_IDLE && !l_busy) begin
                        port_timer <= 32'd0;
                        reset_done <= 1'b1;
                        exp_toggle <= 1'b1;
                        device_address <= 7'd0;
                        // GET_DESCRIPTOR(Device, 8)
                        req_type <= 8'h80; req_code <= 8'h06;
                        req_value <= 16'h0100; req_index <= 16'd0;
                        req_len <= 16'd8;
                        req_status_in <= 1'b0; req_buf_cfg <= 1'b0;
                        req_parse_cfg <= 1'b0;
                        ts <= TS_IDLE;
                        xfer_go <= 1'b1;
                        sq <= SQ_GD8;
                    end else begin
                        port_timer <= port_timer + 32'd1;
                    end
                end

                SQ_GD8: if (xfer_done) begin
                    if (xfer_err) sq <= SQ_ERR;
                    else begin
                        ep0_max <= ep0_clamp(dev_desc[7]);
                        // Fresh descriptor parse state for the config read.
                        d_left <= 16'd0; d_kind <= 2'd0; d_body_idx <= 8'd0;
                        d_in_midi_if <= 1'b0;
                        d_midi_found <= 1'b0; d_any_bulk_found <= 1'b0;
                        // SET_ADDRESS(1)
                        req_type <= 8'h00; req_code <= 8'h05;
                        req_value <= 16'h0001; req_index <= 16'd0;
                        req_len <= 16'd0;
                        req_status_in <= 1'b1; req_buf_cfg <= 1'b0;
                        req_parse_cfg <= 1'b0;
                        ts <= TS_IDLE;
                        xfer_go <= 1'b1;
                        sq <= SQ_SETADDR;
                    end
                end

                SQ_SETADDR: if (xfer_done) begin
                    if (xfer_err) sq <= SQ_ERR;
                    else begin
                        // The status stage still uses address zero. Only after
                        // its ACK is complete may the address and recovery begin.
                        device_address <= 7'd1;
                        addr_set <= 1'b1;
                        port_timer <= 32'd0;
                        sq <= SQ_ADDR_WAIT;
                    end
                end
                SQ_ADDR_WAIT: begin
                    if (port_timer >= SET_ADDRESS_RECOVERY_CYCLES && ts == TS_IDLE && !l_busy) begin
                        port_timer <= 32'd0;
                        req_type <= 8'h80; req_code <= 8'h06;
                        req_value <= 16'h0100; req_index <= 16'd0;
                        req_len <= 16'd18;
                        req_status_in <= 1'b0; req_buf_cfg <= 1'b0;
                        req_parse_cfg <= 1'b0;
                        ts <= TS_IDLE;
                        xfer_go <= 1'b1;
                        sq <= SQ_GD18;
                    end else port_timer <= port_timer + 32'd1;
                end

                SQ_GD18: if (xfer_done) begin
                    if (xfer_err) sq <= SQ_ERR;
                    else begin
                        id_vendor  <= {dev_desc[9],  dev_desc[8]};
                        id_product <= {dev_desc[11], dev_desc[10]};
                        bcd_usb    <= {dev_desc[3],  dev_desc[2]};
                        max_packet <= dev_desc[7];
                        ep0_max <= ep0_clamp(dev_desc[7]);
                        device_class <= dev_desc[4];
                        // GET_DESCRIPTOR(Config, 9)
                        req_type <= 8'h80; req_code <= 8'h06;
                        req_value <= 16'h0200; req_index <= 16'd0;
                        req_len <= 16'd9;
                        req_status_in <= 1'b0; req_buf_cfg <= 1'b1;
                        ts <= TS_IDLE;
                        xfer_go <= 1'b1;
                        sq <= SQ_GDCFG;
                    end
                end

                SQ_GDCFG: if (xfer_done) begin
                    if (xfer_err) sq <= SQ_ERR;
                    else begin
                        config_value <= cfg_desc[5];
                        if ((cfg_total_len > 16'd9) &&
                            (cfg_total_len <= MAX_CONFIG_BYTES)) begin
                            // Re-read the whole configuration descriptor and
                            // stream it through the interface/endpoint parser.
                            req_type <= 8'h80; req_code <= 8'h06;
                            req_value <= 16'h0200; req_index <= 16'd0;
                            req_len <= cfg_total_len;
                            req_status_in <= 1'b0; req_buf_cfg <= 1'b0;
                            req_parse_cfg <= 1'b1;
                            ts <= TS_IDLE;
                            xfer_go <= 1'b1;
                            sq <= SQ_GDCFG2;
                        end else begin
                            // Apply the value advertised by the descriptor.  A
                            // value other than one is legal and must not be
                            // silently replaced with the common-case default.
                            req_type <= 8'h00; req_code <= 8'h09;
                            req_value <= {8'd0, cfg_desc[5]}; req_index <= 16'd0;
                            req_len <= 16'd0;
                            req_status_in <= 1'b1; req_buf_cfg <= 1'b0;
                            req_parse_cfg <= 1'b0;
                            ts <= TS_IDLE;
                            xfer_go <= 1'b1;
                            sq <= SQ_SETCFG;
                        end
                    end
                end

                SQ_GDCFG2: if (xfer_done) begin
                    if (xfer_err) sq <= SQ_ERR;
                    else begin
                        req_type <= 8'h00; req_code <= 8'h09;
                        req_value <= {8'd0, cfg_desc[5]}; req_index <= 16'd0;
                        req_len <= 16'd0;
                        req_status_in <= 1'b1; req_buf_cfg <= 1'b0;
                        req_parse_cfg <= 1'b0;
                        ts <= TS_IDLE;
                        xfer_go <= 1'b1;
                        sq <= SQ_SETCFG;
                    end
                end

                SQ_SETCFG: if (xfer_done) begin
                    if (xfer_err) sq <= SQ_ERR;
                    else begin
                        configured <= 1'b1;
                        done <= 1'b1;
                        if (BULK_ENABLE != 0) begin
                            busy <= 1'b1;
                            // Prefer the MIDIStreaming Bulk IN endpoint found
                            // in the descriptor; otherwise the first Bulk IN
                            // endpoint; otherwise the EP_NUM default.
                            if (d_midi_found)
                                bulk_ep_num <= d_bulk_ep;
                            else if (d_any_bulk_found)
                                bulk_ep_num <= d_any_bulk_ep;
                            else
                                bulk_ep_num <= BULK_EP_DEFAULT;
                            exp_toggle <= 1'b0;   // bulk IN starts at DATA0
                            bulk_timer <= 32'd0;
                            ts <= TS_BULK_GAP;
                            sq <= SQ_BULK;
                        end else begin
                            busy <= 1'b0;
                            sq <= SQ_FINISH;
                        end
                    end
                end

                SQ_BULK: begin
                    done <= 1'b1;
                    busy <= 1'b1;
                    if (!start) begin
                        ts   <= TS_IDLE;
                        busy <= 1'b0;
                        sq   <= SQ_FINISH;
                    end
                end

                SQ_FINISH: begin
                    done <= 1'b1;
                    if (!start) begin
                        done <= 1'b0;
                        sq   <= SQ_IDLE;
                    end
                end

                SQ_ERR: begin
                    sof_enabled <= 1'b0;
                    error <= 1'b1;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    ts    <= TS_IDLE;
                    // The top level holds start high, so retry the whole port
                    // bring-up after a recovery delay instead of waiting for a
                    // new start pulse.
                    if (!start) begin
                        port_timer <= 32'd0;
                        sq <= SQ_IDLE;
                    end else if (port_timer >= RESET_RECOVERY_CYCLES) begin
                        port_timer <= 32'd0;
                        error <= 1'b0;
                        done <= 1'b0;
                        busy <= 1'b1;
                        configured <= 1'b0;
                        addr_set <= 1'b0;
                        device_address <= 7'd0;
                        reset_done <= 1'b0;
                        nak_seen <= 1'b0;
                        crc_error_seen <= 1'b0;
                        sq <= SQ_CONNECT;
                    end else begin
                        port_timer <= port_timer + 32'd1;
                    end
                end

                default: sq <= SQ_IDLE;
            endcase
            end

            // --------------------------------------------------------
            // Transfer FSM
            // --------------------------------------------------------
            // Insert SOF only between complete USB transactions. Preserve the
            // control-transfer continuation; never split SETUP/OUT from DATA.
            // A disconnect owns all state changes for this cycle.
            if (disc_event && monitor_disconnect) begin end
            else if (sof_enabled && start && sof_timer >= SOF_CYCLES &&
                     !xfer_go && !xfer_done && !xfer_err && !l_busy &&
                     ((ts == TS_SETUP_TOK) || (ts == TS_IN_TOK) ||
                      (ts == TS_STIN_TOK) || (ts == TS_BULK_GAP) ||
                      ((ts == TS_IDLE) &&
                       ((sq == SQ_RECOVER && port_timer < RESET_RECOVERY_CYCLES) ||
                        (sq == SQ_ADDR_WAIT && port_timer < SET_ADDRESS_RECOVERY_CYCLES))))) begin
                sof_timer <= 32'd0;
                sof_resume_ts <= ts;
                ts <= TS_SOF_TOK;
            end else case (ts)
                TS_IDLE: begin
                    if (xfer_go) begin
                        remaining <= req_len;
                        buf_off <= 16'd0;
                        exp_toggle <= 1'b1;
                        retry <= 8'd0;
                        last_data <= 1'b0;
                        ts <= TS_SETUP_TOK;
                    end
                end

                // SETUP token packet (CRC5 built from address/endpoint).
                TS_SETUP_TOK: begin
                    l_pid <= PID_SETUP; l_len <= 5'd2;
                    l_data <= {112'd0, token_word};
                    l_expect <= 1'b0; l_crc <= 1'b0;
                    l_start <= 1'b1;
                    ts <= TS_SETUP_TW;
                end
                TS_SETUP_TW: if (l_done) begin
                    if (l_timeout || l_rx_error) ts <= TS_ERR;
                    else ts <= TS_SETUP_DAT;
                end

                // SETUP data packet: DATA0 + 8 bytes + CRC16, expect ACK.
                TS_SETUP_DAT: begin
                    l_pid <= PID_DATA0; l_len <= 5'd8;
                    l_data <= setup_word;
                    l_expect <= 1'b1; l_crc <= 1'b1;
                    l_start <= 1'b1;
                    ts <= TS_SETUP_DW;
                end
                TS_SETUP_DW: if (l_done) begin
                    if (l_timeout || l_rx_error || l_rx_pid != PID_ACK || l_rx_len != 1) ts <= TS_ERR;
                    else if (req_len == 16'd0) ts <= TS_STIN_TOK;
                    else ts <= TS_IN_TOK;
                end

                // Data stage: IN token, capture DATAx, check CRC, ACK.
                TS_IN_TOK: begin
                    l_pid <= PID_IN; l_len <= 5'd2;
                    l_data <= {112'd0, token_word};
                    l_expect <= 1'b1; l_crc <= 1'b0;
                    l_start <= 1'b1;
                    ts <= TS_IN_W;
                end
                TS_IN_W: if (l_done) begin
                    if (l_timeout || l_rx_error) ts <= TS_ERR;
                    else if (l_rx_pid == PID_NAK) begin
                        nak_seen <= 1'b1;
                        if (retry >= RETRY_MAX) ts <= TS_ERR;
                        else begin
                            retry <= retry + 8'd1;
                            ts <= TS_IN_TOK;
                        end
                    end else if (l_rx_pid == PID_STALL ||
                                 (l_rx_pid != PID_DATA0 && l_rx_pid != PID_DATA1)) begin
                        ts <= TS_ERR;
                    end else if (((l_rx_pid == PID_DATA1) ? 1'b1 : 1'b0) != exp_toggle) begin
                        ts <= TS_ERR;
                    end else begin
                        latch_received_payload;
                        ts <= TS_RX_DONE;
                    end
                end

                TS_RX_DONE: begin
                    if (chk_bad || !rx_is_data || payload_len > ep0_max) begin
                        crc_error_seen <= 1'b1;
                        ts <= TS_ERR;
                    end else begin
                        if (!req_parse_cfg) begin
                            for (i = 0; i < 24; i = i + 1)
                                if ((i < payload_len) &&
                                    ((buf_off + i) < 16'd24)) begin
                                    if (req_buf_cfg) begin
                                        if ((buf_off + i) < 16'd16)
                                            cfg_desc[buf_off + i] <= rx_payload[8*i +: 8];
                                    end else
                                        dev_desc[buf_off + i] <= rx_payload[8*i +: 8];
                                end
                        end
                        remaining <= (remaining > payload_len) ?
                                     (remaining - payload_len) : 16'd0;
                        buf_off <= buf_off + payload_len;
                        exp_toggle <= ~exp_toggle;
                        last_data <= (payload_len < ep0_max) ||
                                     (remaining <= payload_len);
                        ts <= TS_IN_ACK;
                    end
                end

                TS_IN_ACK: begin
                    l_pid <= PID_ACK; l_len <= 5'd0; l_data <= 128'd0;
                    l_expect <= 1'b0; l_crc <= 1'b0;
                    l_start <= 1'b1;
                    ts <= TS_IN_ACKW;
                end
                TS_IN_ACKW: if (l_done) begin
                    if (l_timeout || l_rx_error) ts <= TS_ERR;
                    else if (req_parse_cfg) begin
                        parse_idx <= 8'd0;
                        ts <= TS_PARSE;
                    end else if (last_data) ts <= req_status_in ? TS_STIN_TOK : TS_OUT_TOK;
                    else ts <= TS_IN_TOK;
                end

                // Consume one received payload byte per cycle.  rx_payload is
                // stable until the next IN token, so the whole packet can be
                // parsed after it has been ACKed.
                TS_PARSE: begin
                    if (d_kind == 2'd0) begin
                        d_len      <= parse_byte;
                        d_kind     <= 2'd1;
                    end else if (d_kind == 2'd1) begin
                        d_type     <= parse_byte;
                        d_body_idx <= 8'd0;
                        d_left     <= {8'd0, d_len} - 16'd2;
                        d_kind     <= (d_len > 8'd2) ? 2'd2 : 2'd0;
                        if (parse_byte == 8'h04)
                            d_in_midi_if <= 1'b0;
                    end else begin
                        if (d_type == 8'h04) begin
                            if (d_body_idx == 8'd3)
                                d_if_class <= parse_byte;
                            if (d_body_idx == 8'd4)
                                d_if_subclass <= parse_byte;
                            if (d_left == 16'd1)
                                d_in_midi_if <= (d_if_class == 8'h01) &&
                                                (d_if_subclass == 8'h03);
                        end else if (d_type == 8'h05) begin
                            if (d_body_idx == 8'd0)
                                d_ep_addr <= parse_byte;
                            if (d_body_idx == 8'd1)
                                d_ep_attr <= parse_byte;
                            if (d_body_idx == 8'd2)
                                d_ep_max_lo <= parse_byte;
                            if (d_body_idx == 8'd3) begin
                                if ((d_ep_attr[1:0] == 2'b10) && d_ep_addr[7]) begin
                                    d_any_bulk_found <= 1'b1;
                                    d_any_bulk_ep  <= d_ep_addr[3:0];
                                    d_any_bulk_max <= {5'd0,
                                                       parse_byte[2:0],
                                                       d_ep_max_lo};
                                    if (d_in_midi_if) begin
                                        d_midi_found <= 1'b1;
                                        d_bulk_ep    <= d_ep_addr[3:0];
                                        d_bulk_max   <= {5'd0,
                                                         parse_byte[2:0],
                                                         d_ep_max_lo};
                                    end
                                end
                            end
                        end
                        d_body_idx <= d_body_idx + 8'd1;
                        d_left     <= d_left - 16'd1;
                        if (d_left == 16'd1)
                            d_kind <= 2'd0;
                    end
                    if (parse_idx + 8'd1 >= payload_len) begin
                        if (last_data)
                            ts <= req_status_in ? TS_STIN_TOK : TS_OUT_TOK;
                        else
                            ts <= TS_IN_TOK;
                    end else begin
                        parse_idx <= parse_idx + 8'd1;
                    end
                end

                // Status stage for a control read: OUT token + DATA1 ZLP + CRC.
                TS_OUT_TOK: begin
                    l_pid <= PID_OUT; l_len <= 5'd2;
                    l_data <= {112'd0, token_word};
                    l_expect <= 1'b0; l_crc <= 1'b0;
                    l_start <= 1'b1;
                    ts <= TS_OUT_TW;
                end
                TS_OUT_TW: if (l_done) begin
                    if (l_timeout || l_rx_error) ts <= TS_ERR;
                    else ts <= TS_OUT_DAT;
                end
                TS_OUT_DAT: begin
                    l_pid <= PID_DATA1; l_len <= 5'd0; l_data <= 128'd0;
                    l_expect <= 1'b1; l_crc <= 1'b1;   // zero-length data still has CRC16
                    l_start <= 1'b1;
                    ts <= TS_OUT_DW;
                end
                TS_OUT_DW: if (l_done) begin
                    if (l_timeout || l_rx_error || l_rx_pid != PID_ACK || l_rx_len != 1) ts <= TS_ERR;
                    else ts <= TS_DONE;
                end

                // Status stage for a no-data transfer: IN ZLP from the device.
                TS_STIN_TOK: begin
                    l_pid <= PID_IN; l_len <= 5'd2;
                    l_data <= {112'd0, token_word};
                    l_expect <= 1'b1; l_crc <= 1'b0;
                    l_start <= 1'b1;
                    ts <= TS_STIN_W;
                end
                TS_STIN_W: if (l_done) begin
                    if (l_timeout || l_rx_error) ts <= TS_ERR;
                    else if (l_rx_pid == PID_NAK) begin
                        nak_seen <= 1'b1;
                        if (retry >= RETRY_MAX) ts <= TS_ERR;
                        else begin
                            retry <= retry + 8'd1;
                            ts <= TS_STIN_TOK;
                        end
                    end else if (l_rx_pid != PID_DATA1 || l_rx_len != 3) begin
                        ts <= TS_ERR;
                    end else begin
                        latch_received_payload;
                        ts <= TS_STIN_DONE;
                    end
                end
                TS_STIN_DONE: begin
                    if (chk_bad || payload_len != 5'd0) ts <= TS_ERR;
                    else ts <= TS_STIN_ACK;
                end
                TS_STIN_ACK: begin
                    l_pid <= PID_ACK; l_len <= 5'd0; l_data <= 128'd0;
                    l_expect <= 1'b0; l_crc <= 1'b0;
                    l_start <= 1'b1;
                    ts <= TS_STIN_ACKW;
                end
                TS_STIN_ACKW: if (l_done) begin
                    if (l_timeout || l_rx_error) ts <= TS_ERR;
                    else ts <= TS_DONE;
                end

                // ---- Bulk IN polling after enumeration ----
                TS_BULK_GAP: begin
                    if (!start) ts <= TS_IDLE;
                    else if (bulk_timer >= POLL_CYCLES) begin
                        bulk_timer <= 32'd0;
                        ts <= TS_BULK_TOK;
                    end
                end

                // SOF token: 11-bit frame number + CRC5, every 1 ms.
                TS_SOF_TOK: begin
                    if (!start) ts <= TS_IDLE;
                    else begin
                        l_pid    <= PID_SOF;
                        l_len    <= 5'd2;
                        l_data   <= {112'd0, sof_word};
                        l_expect <= 1'b0;
                        l_crc    <= 1'b0;
                        l_start  <= 1'b1;
                        ts       <= TS_SOF_W;
                    end
                end

                TS_SOF_W: if (l_done) begin
                    sof_frame <= sof_frame + 11'd1;
                    ts <= sof_resume_ts;
                end

                TS_BULK_TOK: begin
                    if (!start) ts <= TS_IDLE;
                    else begin
                        l_pid    <= PID_IN;
                        l_len    <= 5'd2;
                        l_data   <= bulk_token_word;
                        l_expect <= 1'b1;
                        l_crc    <= 1'b0;
                        l_start  <= 1'b1;
                        ts       <= TS_BULK_WAIT;
                    end
                end

                TS_BULK_WAIT: if (l_done) begin
                    if (l_timeout || l_rx_error) begin
                        bulk_errors <= bulk_errors + 32'd1;
                        ts <= TS_BULK_GAP;
                    end else if (l_rx_pid == PID_NAK) begin
                        bulk_naks <= bulk_naks + 32'd1;
                        ts <= TS_BULK_GAP;
                    end else if (l_rx_pid == PID_STALL) begin
                        bulk_errors <= bulk_errors + 32'd1;
                        ts <= TS_BULK_GAP;
                    end else if (l_rx_pid == PID_DATA0 || l_rx_pid == PID_DATA1) begin
                        latch_received_payload;
                        ts <= TS_BULK_DONE;
                    end else begin
                        bulk_errors <= bulk_errors + 32'd1;
                        ts <= TS_BULK_GAP;
                    end
                end

                TS_BULK_DONE: begin
                    if (chk_bad) begin
                        // No ACK: the device keeps its toggle and retransmits.
                        bulk_errors <= bulk_errors + 32'd1;
                        ts <= TS_BULK_GAP;
                    end else begin
                        bulk_deliver <= ((l_rx_pid == PID_DATA1) ? 1'b1 : 1'b0) == exp_toggle;
                        exp_toggle   <= ~((l_rx_pid == PID_DATA1) ? 1'b1 : 1'b0);
                        l_pid    <= PID_ACK;
                        l_len    <= 5'd0;
                        l_data   <= {LINK_BYTES*8{1'b0}};
                        l_expect <= 1'b0;
                        l_crc    <= 1'b0;
                        l_start  <= 1'b1;
                        ts       <= TS_BULK_ACKW;
                    end
                end

                TS_BULK_ACKW: if (l_done) begin
                    if (l_timeout || l_rx_error) begin
                        bulk_errors <= bulk_errors + 32'd1;
                        ts <= TS_BULK_GAP;
                    end else if (bulk_deliver && payload_len >= 8'd4) begin
                        bulk_left   <= {1'b0, payload_len[7:2]};
                        bulk_shift  <= rx_payload;
                        midi_packet <= rx_payload[31:0];
                        midi_valid  <= 1'b1;
                        ts          <= TS_BULK_STRM;
                    end else begin
                        ts <= TS_BULK_GAP;
                    end
                end

                TS_BULK_STRM: begin
                    if (midi_valid && midi_ready) begin
                        bulk_packets <= bulk_packets + 32'd1;
                        if (bulk_left <= 8'd1) begin
                            midi_valid <= 1'b0;
                            ts <= TS_BULK_GAP;
                        end else begin
                            bulk_shift  <= bulk_shift >> 32;
                            midi_packet <= bulk_shift[63:32];
                            bulk_left   <= bulk_left - 8'd1;
                        end
                    end
                end

                TS_DONE: begin
                    xfer_done <= 1'b1;
                    ts <= TS_IDLE;
                end
                TS_ERR: begin
                    // The sequence FSM consumes {done,error} together. Without
                    // done it waits forever after the transfer FSM returns Idle.
                    xfer_done <= 1'b1;
                    xfer_err <= 1'b1;
                    ts <= TS_IDLE;
                end

                default: ts <= TS_IDLE;
            endcase
        end
    end

    // ----------------------------------------------------------------
    // Disconnect supervision (single writer for se0_cnt/disc_event)
    // ----------------------------------------------------------------
    // A PHY host-disconnect event is authoritative.  A sustained SE0 line
    // state is a second, debounced indication used if the event is missed.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            se0_cnt    <= 32'd0;
            disc_event <= 1'b0;
        end else if (monitor_disconnect) begin
            if (l_rx_cmd_valid && (l_rx_event == 2'b10))
                disc_event <= 1'b1;
            if (l_linestate == 2'b00) begin
                if (se0_cnt >= DISCONNECT_DEBOUNCE_CYCLES) begin
                    se0_cnt    <= 32'd0;
                    disc_event <= 1'b1;
                end else begin
                    se0_cnt <= se0_cnt + 32'd1;
                end
            end else begin
                se0_cnt <= 32'd0;
            end
        end else begin
            se0_cnt    <= 32'd0;
            disc_event <= 1'b0;
        end
    end

    assign status = {configured, addr_set, busy, done, error,
                     crc_error_seen, nak_seen, l_ready};

endmodule
