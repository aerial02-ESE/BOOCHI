`timescale 1ns / 1ps

// ULPI packet transaction link for one USB3300.
//
// One transaction:
//   start + {pid[3:0], len[4:0], data[127:0], expect_rx}
//   -> TX packet: TXD CMD = {2'b01,2'b00,pid}, then len data bytes,
//      then one STP pulse and the PHY-reported full-speed EOP.
//   -> if expect_rx: capture the PHY receive bytes while DIR=1/NXT=1.
//
// Bus rules taken from the USX3300/USB3300 datasheet:
//   * DIR high means the PHY owns DATA; the link must tri-state immediately.
//   * Every DIR change is followed by one turnaround cycle where nobody drives.
//   * When DIR is low and the link is not sending, the link drives ULPI Idle
//     (0x00); a floating bus may be decoded as a command.
//   * STP is pulsed after the last accepted byte. FS transmit completion
//     comes later via RXCMD SE0-to-J; subsequent packets need an IFS.
//   * An RXD CMD is DIR=1 with NXT=0; only NXT=1 bytes are packet data.
//   * NXT throttles transmit bytes. DIR preemption before command acceptance
//     permits retry; DIR after acceptance aborts the PID packet.
//   * A missing response must time out instead of hanging; NAK is a response.
module ulpi_packet_link #(
    // USB3300 RESET high time and post-reset settle time, in CLKOUT cycles.
    parameter integer RESET_CYCLES  = 600000,
    parameter integer SETTLE_CYCLES = 60000,
    // Abort a transmit if one byte/state is not acknowledged in this time.
    parameter integer TX_TIMEOUT_CYCLES = 6000,
    // Abort a transaction if the expected response never arrives.
    parameter integer RX_TIMEOUT_CYCLES = 60000,
    // Retry transient startup handshakes, then remain safely disabled.
    parameter integer INIT_RETRY_CYCLES = 6000000, // 100 ms at 60 MHz
    parameter integer INIT_MAX_RETRIES = 3,
    // Payload/RX buffer bytes.  Control transfers need 16; a 64-byte bulk
    // endpoint needs 68 (PID + 64 data + 2 CRC).
    parameter integer DATA_BYTES = 16,
    parameter integer LEN_W = $clog2(DATA_BYTES + 1)
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [3:0]  pid,
    input  wire [LEN_W-1:0] len,
    input  wire [DATA_BYTES*8-1:0] data,
    input  wire        expect_rx,
    // 1 = append the USB CRC16 (data packets, including zero-length ZLPs)
    input  wire        crc16_append,

    output reg         done,
    output reg         timeout,
    output reg  [3:0]  rx_pid,
    output reg  [LEN_W-1:0] rx_len,
    output reg  [DATA_BYTES*8-1:0] rx_data,
    output reg         rx_error,
    output reg         rx_crc_ok,
    output reg         ready,
    output reg         busy,

    // Runtime ULPI register write, used for host bus reset (Function Control).
    // Addresses are the USB3300 write addresses; the link serialises the write
    // with packet traffic and reports completion with a one-cycle pulse.
    input  wire        wr_req,
    input  wire [5:0]  wr_addr,
    input  wire [7:0]  wr_data,
    output reg         wr_busy,
    output reg         wr_done,
    output reg         wr_error,

    // Latest RXCMD fields and a pulse for each observed RXCMD byte.
    output reg  [1:0]  rx_linestate,
    output reg  [1:0]  rx_vbus_state,
    output reg  [1:0]  rx_event,
    output reg         rx_cmd_valid,

    output reg         phy_rst,
    input  wire        ulpi_dir,
    input  wire        ulpi_nxt,
    inout  wire [7:0]  ulpi_data,
    output wire        ulpi_stp
);

    localparam X_IDLE = 2'd0;
    localparam X_TX   = 2'd1;
    localparam X_RX   = 2'd2;
    localparam X_DONE = 2'd3;

    reg [1:0]  xstate;
    reg [3:0]  pid_lat;
    reg [LEN_W-1:0] len_lat;
    reg [DATA_BYTES*8-1:0] data_lat;
    reg        expect_lat;
    reg        crc_lat;
    reg        tx_start;
    reg        tx_done;
    reg        tx_abort;
    reg [31:0] rx_wait_cnt;

    localparam T_IDLE      = 4'd0;
    localparam T_WAIT      = 4'd1;
    localparam T_CMD       = 4'd2;
    localparam T_DATA      = 4'd4;
    localparam T_STP       = 4'd5;
    localparam T_EOP       = 4'd6;
    localparam T_CRC_LO    = 4'd7;
    localparam T_CRC_HI    = 4'd8;

    reg [3:0]  tx_state;
    reg [3:0]  tx_pid_l;
    reg [LEN_W-1:0] tx_len_l;
    reg [LEN_W-1:0] tx_idx;
    reg [DATA_BYTES*8-1:0] tx_shift;
    reg [7:0]  cmd_byte;
    reg        ulpi_oe;
    reg [7:0]  ulpi_data_out;
    reg        ulpi_stp_reg;
    reg [31:0] tx_timer;
    reg [31:0] tx_progress_timer, tx_total_timer;
    localparam integer TX_TOTAL_CYCLES = TX_TIMEOUT_CYCLES * (DATA_BYTES + 4);
    reg        crc_en;
    reg [15:0] tx_crc;

    // Reflected CRC-16/USB step used while streaming a transmit payload.
    function [15:0] crc_step;
        input [15:0] c;
        input [7:0]  d;
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {8'h00, d};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ 16'hA001) : (x >> 1);
            crc_step = x;
        end
    endfunction

    wire [15:0] crc_next = crc_step(tx_crc, tx_shift[7:0]);

    localparam R_IDLE = 1'd0;
    localparam R_DATA = 1'd1;

    reg        rx_state;
    reg [LEN_W-1:0] rx_cnt;
    reg [7:0]  rx_buf [0:DATA_BYTES-1];
    integer n;
    reg        rx_packet_ready;
    reg        rx_flush;
    reg        rx_ack;
    reg        dir_prev;
    // RxActive can fall while DIR stays high for further status updates.
    wire rxcmd_now = ulpi_dir && dir_prev && !ulpi_nxt;
    wire rx_complete = (rx_state == R_DATA) &&
                       (!ulpi_dir || (rxcmd_now && !ulpi_data[4]));
    reg [15:0] rx_crc;
    wire fs_eop_now = rxcmd_now && (rx_linestate == 2'b00) &&
                      (ulpi_data[1:0] == 2'b01);
    reg [3:0] fs_gap_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fs_gap_count <= 4'd0;
        else if (fs_eop_now) fs_gap_count <= 4'd7;
        else if (fs_gap_count != 0) fs_gap_count <= fs_gap_count - 1'b1;
    end

    reg [31:0] reset_cnt;
    reg [31:0] settle_cnt;

    // USB3300 start-up initialization.  The external RESET pin is active
    // high.  Once it is released, configure the PHY as a full-speed host and
    // enable the external VBUS switch through CPEN before packet traffic is
    // allowed onto the ULPI bus.
    localparam I_RESET  = 4'd0;
    localparam I_SETTLE = 4'd1;
    localparam I_WAIT   = 4'd2;
    localparam I_CMD    = 4'd3;
    localparam I_DATA   = 4'd4;
    localparam I_STP    = 4'd5;
    localparam I_GAP    = 4'd6;
    localparam I_DONE   = 4'd7;
    localparam I_FAIL   = 4'd8;

    reg [3:0]  init_state;
    reg [1:0]  init_step;
    reg        init_oe;
    reg [7:0]  init_data_out;
    reg        init_stp;
    reg [31:0] init_timer;
    reg [31:0] init_total_timer, init_retry_timer, init_retry_count;
    localparam integer INIT_TOTAL_CYCLES = TX_TIMEOUT_CYCLES * 4;
    reg        wr_run;
    reg [5:0]  wr_addr_l;
    reg [7:0]  wr_data_l;

    // RESET does not reset the ULPI register file (USB3300 section 6.4.2).
    // Write complete host values rather than OR-ing bits into unknown old state.
    wire [5:0] init_addr = wr_run ? wr_addr_l :
                           (init_step == 2'd0) ? 6'h04 :
                           (init_step == 2'd1) ? 6'h07 : 6'h0A;
    wire [7:0] init_wdata = wr_run ? wr_data_l :
                            (init_step == 2'd0) ? 8'h45 :
                            (init_step == 2'd1) ? 8'h10 : 8'h26;
    wire init_active = (init_state == I_WAIT) || (init_state == I_CMD) ||
                       (init_state == I_DATA) || (init_state == I_STP);

    wire [7:0] ulpi_data_in = ulpi_data;

    // Keep STP high and DATA tri-stated during reset/settle as required by
    // USB3300 interface protection.  The init/write FSM owns the bus until it
    // parks in I_DONE; only then may the packet engine drive it.
    wire init_hold = (init_state == I_RESET) ||
                     (init_state == I_SETTLE) ||
                     (init_state == I_FAIL);
    wire init_owns = (init_state != I_DONE);
    assign ulpi_stp = init_owns ? (init_hold ? 1'b1 : init_stp) : ulpi_stp_reg;

    // DATA is tri-stated while DIR is high or during the turnaround cycle
    // after DIR falls; otherwise the active owner drives its byte or Idle.
    assign ulpi_data = (ulpi_dir || init_hold) ? 8'bz :
                       (init_owns ?
                        ((init_oe && !dir_prev) ? init_data_out :
                         (dir_prev ? 8'bz : 8'h00)) :
                        ((ulpi_oe && !dir_prev) ? ulpi_data_out :
                         (dir_prev ? 8'bz : 8'h00)));

    // ------------------------------------------------------------------
    // PHY reset / settle / mandatory host initialization
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reset_cnt  <= 32'd0;
            settle_cnt <= 32'd0;
            phy_rst    <= 1'b1;   // USB3300 RESET is active high
            ready      <= 1'b0;
            init_state    <= I_RESET;
            init_step     <= 2'd0;
            init_oe       <= 1'b0;
            init_data_out <= 8'h00;
            init_stp      <= 1'b1;
            init_timer    <= 32'd0;
            init_total_timer <= 32'd0;
            init_retry_timer <= 32'd0;
            init_retry_count <= 32'd0;
            wr_run        <= 1'b0;
            wr_addr_l     <= 6'd0;
            wr_data_l     <= 8'd0;
            wr_busy       <= 1'b0;
            wr_done       <= 1'b0;
            wr_error      <= 1'b0;
        end else begin
            wr_done  <= 1'b0;
            wr_error <= 1'b0;
            // Do not restart this deadline when DIR preempts a command. A PHY
            // repeatedly claiming/releasing the bus must not hang startup or
            // a runtime register write forever.
            if (!init_active) init_total_timer <= 32'd0;
            else if (init_total_timer < INIT_TOTAL_CYCLES)
                init_total_timer <= init_total_timer + 32'd1;
            if (init_active && init_total_timer >= INIT_TOTAL_CYCLES) begin
                init_oe <= 1'b0;
                init_stp <= 1'b1;
                if (wr_run) begin
                    wr_run <= 1'b0;
                    wr_busy <= 1'b0;
                    wr_error <= 1'b1;
                    init_state <= I_DONE;
                end else init_state <= I_FAIL;
            end else begin
            case (init_state)
                I_RESET: begin
                    ready         <= 1'b0;
                    phy_rst       <= 1'b1;
                    init_oe       <= 1'b0;
                    init_stp      <= 1'b1;
                    reset_cnt     <= reset_cnt + 32'd1;
                    if (reset_cnt >= RESET_CYCLES - 1) begin
                        phy_rst    <= 1'b0;
                        settle_cnt <= 32'd0;
                        init_state <= I_SETTLE;
                    end
                end

                I_SETTLE: begin
                    phy_rst   <= 1'b0;
                    init_oe   <= 1'b0;
                    init_stp  <= 1'b1;
                    settle_cnt <= settle_cnt + 32'd1;
                    if (settle_cnt >= SETTLE_CYCLES - 1) begin
                        init_stp   <= 1'b0;
                        init_timer <= 32'd0;
                        init_state <= I_WAIT;
                    end
                end

                // Wait for DIR low plus the mandatory turnaround cycle.
                I_WAIT: begin
                    init_oe  <= 1'b0;
                    init_stp <= 1'b0;
                    if (!ulpi_dir && !dir_prev) begin
                        init_oe       <= 1'b1;
                        init_data_out <= {2'b10, init_addr};
                        init_timer    <= 32'd0;
                        init_state    <= I_CMD;
                    end else if (init_timer >= TX_TIMEOUT_CYCLES) begin
                        if (wr_run) begin
                            wr_run   <= 1'b0;
                            wr_busy  <= 1'b0;
                            wr_error <= 1'b1;
                            init_state <= I_DONE;
                        end else begin
                            init_state <= I_FAIL;
                        end
                    end else begin
                        init_timer <= init_timer + 32'd1;
                    end
                end

                // Register write command accepted when NXT is high.
                I_CMD: begin
                    if (ulpi_dir) begin
                        init_oe    <= 1'b0;
                        init_timer <= 32'd0;
                        init_state <= I_WAIT;
                    end else if (ulpi_nxt) begin
                        init_data_out <= init_wdata;
                        init_timer    <= 32'd0;
                        init_state    <= I_DATA;
                    end else if (init_timer >= TX_TIMEOUT_CYCLES) begin
                        if (wr_run) begin
                            wr_run   <= 1'b0;
                            wr_busy  <= 1'b0;
                            wr_error <= 1'b1;
                            init_state <= I_DONE;
                        end else begin
                            init_state <= I_FAIL;
                        end
                    end else begin
                        init_timer <= init_timer + 32'd1;
                    end
                end

                // Register data accepted when NXT is high; present Idle and
                // STP to terminate the write, per USB3300 Figure 6-4.
                I_DATA: begin
                    if (ulpi_dir) begin
                        init_oe    <= 1'b0;
                        init_timer <= 32'd0;
                        init_state <= I_WAIT;
                    end else if (ulpi_nxt) begin
                        init_data_out <= 8'h00;
                        init_stp      <= 1'b1;
                        init_timer    <= 32'd0;
                        init_state    <= I_STP;
                    end else if (init_timer >= TX_TIMEOUT_CYCLES) begin
                        if (wr_run) begin
                            wr_run   <= 1'b0;
                            wr_busy  <= 1'b0;
                            wr_error <= 1'b1;
                            init_state <= I_DONE;
                        end else begin
                            init_state <= I_FAIL;
                        end
                    end else begin
                        init_timer <= init_timer + 32'd1;
                    end
                end

                I_STP: begin
                    init_oe       <= 1'b1;
                    init_data_out <= 8'h00;
                    init_stp      <= 1'b1;
                    if (!ulpi_nxt) begin
                        init_stp   <= 1'b0;
                        init_oe    <= 1'b0;
                        init_timer <= 32'd0;
                        if (wr_run) begin
                            wr_run     <= 1'b0;
                            wr_busy    <= 1'b0;
                            wr_done    <= 1'b1;
                            init_state <= I_DONE;
                        end else if (init_step == 2'd2)
                            init_state <= I_DONE;
                        else begin
                            init_step  <= init_step + 2'd1;
                            init_state <= I_GAP;
                        end
                    end else if (init_timer >= TX_TIMEOUT_CYCLES) begin
                        if (wr_run) begin
                            wr_run   <= 1'b0;
                            wr_busy  <= 1'b0;
                            wr_error <= 1'b1;
                            init_state <= I_DONE;
                        end else begin
                            init_state <= I_FAIL;
                        end
                    end else begin
                        init_timer <= init_timer + 32'd1;
                    end
                end

                // One explicit Idle cycle between register writes.
                I_GAP: begin
                    init_oe       <= 1'b1;
                    init_data_out <= 8'h00;
                    init_stp      <= 1'b0;
                    init_timer    <= 32'd0;
                    init_state    <= I_WAIT;
                end

                I_DONE: begin
                    phy_rst   <= 1'b0;
                    init_oe   <= 1'b0;
                    init_stp  <= 1'b0;
                    ready     <= 1'b1;
                    if (wr_req && !wr_busy && !wr_done && !wr_error && !busy) begin
                        wr_addr_l  <= wr_addr;
                        wr_data_l  <= wr_data;
                        wr_run     <= 1'b1;
                        wr_busy    <= 1'b1;
                        init_timer <= 32'd0;
                        init_state <= I_WAIT;
                    end else begin
                        init_state <= I_DONE;
                    end
                end

                // Terminate/wake the interface with STP, wait, then retry from
                // the first deterministic register write. A persistent fault
                // exhausts the finite retry budget and never raises ready.
                I_FAIL: begin
                    phy_rst <= 1'b0;
                    ready   <= 1'b0;
                    init_oe <= 1'b0;
                    init_stp <= 1'b1;
                    if (init_retry_count < INIT_MAX_RETRIES) begin
                        if (init_retry_timer >= INIT_RETRY_CYCLES - 1) begin
                            init_retry_timer <= 32'd0;
                            init_retry_count <= init_retry_count + 32'd1;
                            init_step <= 2'd0;
                            init_timer <= 32'd0;
                            init_state <= I_WAIT;
                        end else init_retry_timer <= init_retry_timer + 32'd1;
                    end
                end

                default: init_state <= I_RESET;
            endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // RXCMD observation (linestate, VBUS comparator, RX events)
    // ------------------------------------------------------------------
    // The PHY presents an RXCMD byte whenever it owns DATA with NXT low.
    // The first cycle after DIR rises is the bus turnaround and is not valid.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_linestate  <= 2'b00;
            rx_vbus_state <= 2'b00;
            rx_event      <= 2'b00;
            rx_cmd_valid  <= 1'b0;
        end else begin
            rx_cmd_valid <= 1'b0;
            if (ulpi_dir && dir_prev && !ulpi_nxt) begin
                rx_linestate  <= ulpi_data_in[1:0];
                rx_vbus_state <= ulpi_data_in[3:2];
                rx_event      <= ulpi_data_in[5:4];
                rx_cmd_valid  <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Transaction FSM
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xstate          <= X_IDLE;
            pid_lat         <= 4'd0;
            len_lat         <= {LEN_W{1'b0}};
            data_lat        <= 64'd0;
            expect_lat      <= 1'b0;
            tx_start        <= 1'b0;
            done            <= 1'b0;
            timeout         <= 1'b0;
            busy            <= 1'b0;
            rx_wait_cnt     <= 32'd0;
            rx_flush        <= 1'b0;
            rx_ack          <= 1'b0;
            crc_lat         <= 1'b0;
        end else begin
            done     <= 1'b0;
            tx_start <= 1'b0;
            rx_flush <= 1'b0;
            rx_ack   <= 1'b0;

            case (xstate)
                X_IDLE: begin
                    busy    <= 1'b0;
                    timeout <= 1'b0;
                    if (ready && (init_state == I_DONE) && !wr_busy && start) begin
                        pid_lat         <= pid;
                        len_lat         <= len;
                        data_lat        <= data;
                        expect_lat      <= expect_rx;
                        crc_lat         <= crc16_append;
                        tx_start        <= 1'b1;
                        busy            <= 1'b1;
                        rx_flush        <= 1'b1;
                        rx_wait_cnt     <= 32'd0;
                        xstate          <= X_TX;
                    end
                end

                X_TX: begin
                    if (tx_done) begin
                        if (tx_abort) begin
                            timeout <= 1'b1;
                            xstate  <= X_DONE;
                        end else if (expect_lat) begin
                            rx_wait_cnt <= 32'd0;
                            xstate      <= X_RX;
                        end else begin
                            xstate <= X_DONE;
                        end
                    end
                end

                X_RX: begin
                    if (rx_packet_ready) begin
                        rx_ack <= 1'b1;
                        xstate <= X_DONE;
                    end else if (rx_wait_cnt >= RX_TIMEOUT_CYCLES) begin
                        timeout <= 1'b1;
                        xstate  <= X_DONE;
                    end else begin
                        rx_wait_cnt <= rx_wait_cnt + 32'd1;
                    end
                end

                X_DONE: begin
                    done   <= 1'b1;
                    busy   <= 1'b0;
                    xstate <= X_IDLE;
                end

                default: xstate <= X_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // TX packet FSM
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state      <= T_IDLE;
            tx_pid_l      <= 4'd0;
            tx_len_l      <= {LEN_W{1'b0}};
            tx_idx        <= {LEN_W{1'b0}};
            tx_shift      <= {DATA_BYTES*8{1'b0}};
            cmd_byte      <= 8'd0;
            ulpi_oe       <= 1'b0;
            ulpi_data_out <= 8'd0;
            ulpi_stp_reg  <= 1'b0;
            tx_done       <= 1'b0;
            tx_abort      <= 1'b0;
            tx_timer      <= 32'd0;
            tx_progress_timer <= 32'd0;
            tx_total_timer <= 32'd0;
            crc_en        <= 1'b0;
            tx_crc        <= 16'hFFFF;
        end else begin
            tx_done  <= 1'b0;
            tx_abort <= 1'b0;
            // A real accepted byte is progress; arbitration alone is not.
            if (tx_state == T_IDLE) begin
                tx_progress_timer <= 32'd0;
                tx_total_timer <= 32'd0;
            end else begin
                if (!ulpi_dir && ulpi_nxt &&
                    ((tx_state == T_CMD) || (tx_state == T_DATA) ||
                     (tx_state == T_CRC_LO) || (tx_state == T_CRC_HI)))
                    tx_progress_timer <= 32'd0;
                else if (tx_progress_timer < TX_TIMEOUT_CYCLES)
                    tx_progress_timer <= tx_progress_timer + 32'd1;
                if (tx_total_timer < TX_TOTAL_CYCLES)
                    tx_total_timer <= tx_total_timer + 32'd1;
            end
            if ((tx_state != T_IDLE) &&
                ((tx_progress_timer >= TX_TIMEOUT_CYCLES) ||
                 (tx_total_timer >= TX_TOTAL_CYCLES))) begin
                ulpi_oe <= 1'b0;
                ulpi_stp_reg <= 1'b1;
                tx_done <= 1'b1;
                tx_abort <= 1'b1;
                tx_state <= T_IDLE;
            end else begin
            case (tx_state)
                T_IDLE: begin
                    ulpi_oe      <= 1'b0;
                    ulpi_stp_reg <= 1'b0;
                    tx_timer     <= 32'd0;
                    if (tx_start) begin
                        tx_pid_l <= pid_lat;
                        tx_len_l <= len_lat;
                        tx_shift <= data_lat;
                        tx_idx   <= {LEN_W{1'b0}};
                        cmd_byte <= {2'b01, 2'b00, pid_lat};
                        crc_en   <= crc_lat;
                        tx_crc   <= 16'hFFFF;
                        tx_timer <= 32'd0;
                        tx_state <= T_WAIT;
                    end
                end

                // Wait for a free bus plus one turnaround cycle after DIR falls.
                T_WAIT: begin
                    if (!ulpi_dir && !dir_prev && fs_gap_count == 0) begin
                        ulpi_oe       <= 1'b1;
                        ulpi_data_out <= cmd_byte;
                        tx_timer      <= 32'd0;
                        tx_state      <= T_CMD;
                    end else if (tx_timer >= TX_TIMEOUT_CYCLES) begin
                        ulpi_oe  <= 1'b0;
                        tx_done  <= 1'b1;
                        tx_abort <= 1'b1;
                        tx_state <= T_IDLE;
                    end else begin
                        tx_timer <= tx_timer + 32'd1;
                    end
                end

                T_CMD: begin
                    if (ulpi_dir) begin
                        // PHY took the bus (throttling or RXD CMD): release and
                        // re-send the command after the next turnaround.
                        ulpi_oe  <= 1'b0;
                        tx_timer <= 32'd0;
                        tx_state <= T_WAIT;
                    end else if (ulpi_nxt) begin
                        if (tx_len_l == {LEN_W{1'b0}}) begin
                            if (crc_en) begin
                                // A zero-length DATA packet still carries the
                                // CRC16 (init 0xFFFF -> transmitted 0x0000).
                                ulpi_data_out <= 8'h00;
                                tx_crc        <= 16'hFFFF;
                                tx_timer      <= 32'd0;
                                tx_state      <= T_CRC_LO;
                            end else begin
                                ulpi_stp_reg  <= 1'b1;
                                ulpi_data_out <= 8'h00;
                                tx_timer      <= 32'd0;
                                tx_state      <= T_STP;
                            end
                        end else begin
                            ulpi_data_out <= tx_shift[7:0];
                            tx_crc        <= 16'hFFFF;
                            tx_timer      <= 32'd0;
                            tx_state      <= T_DATA;
                        end
                    end else if (tx_timer >= TX_TIMEOUT_CYCLES) begin
                        ulpi_oe  <= 1'b0;
                        tx_done  <= 1'b1;
                        tx_abort <= 1'b1;
                        tx_state <= T_IDLE;
                    end else begin
                        tx_timer <= tx_timer + 32'd1;
                    end
                end

                T_DATA: begin
                    if (ulpi_dir) begin
                        // DIR during an accepted PID transmission aborts the
                        // whole packet; it is not byte-level flow control.
                        ulpi_oe <= 1'b0;
                        tx_done <= 1'b1;
                        tx_abort <= 1'b1;
                        tx_state <= T_IDLE;
                    end else if (ulpi_nxt) begin
                        if (tx_idx == tx_len_l - 1'b1) begin
                            if (crc_en) begin
                                // Last payload byte: the CRC for it is ready
                                // combinationally on this edge, so the next
                                // cycle can present the CRC low byte with no
                                // inter-byte stall.
                                ulpi_data_out <= ~crc_next[7:0];
                                tx_crc        <= crc_next;
                                tx_timer      <= 32'd0;
                                tx_state      <= T_CRC_LO;
                            end else begin
                                ulpi_stp_reg  <= 1'b1;
                                ulpi_data_out <= 8'h00;
                                tx_timer      <= 32'd0;
                                tx_state      <= T_STP;
                            end
                        end else begin
                            tx_shift      <= tx_shift >> 8;
                            ulpi_data_out <= tx_shift[15:8];
                            tx_idx        <= tx_idx + 1'b1;
                            tx_crc        <= crc_next;
                            tx_timer      <= 32'd0;
                        end
                    end else if (tx_timer >= TX_TIMEOUT_CYCLES) begin
                        ulpi_oe  <= 1'b0;
                        tx_done  <= 1'b1;
                        tx_abort <= 1'b1;
                        tx_state <= T_IDLE;
                    end else begin
                        tx_timer <= tx_timer + 32'd1;
                    end
                end

                // CRC16 low byte (complemented, LSB first).
                T_CRC_LO: begin
                    if (ulpi_dir) begin
                        ulpi_oe <= 1'b0;
                        tx_done <= 1'b1;
                        tx_abort <= 1'b1;
                        tx_state <= T_IDLE;
                    end else if (ulpi_nxt) begin
                        ulpi_data_out <= ~tx_crc[15:8];
                        tx_timer      <= 32'd0;
                        tx_state      <= T_CRC_HI;
                    end else if (tx_timer >= TX_TIMEOUT_CYCLES) begin
                        ulpi_oe  <= 1'b0;
                        tx_done  <= 1'b1;
                        tx_abort <= 1'b1;
                        tx_state <= T_IDLE;
                    end else begin
                        tx_timer <= tx_timer + 32'd1;
                    end
                end

                // CRC16 high byte, then STP.
                T_CRC_HI: begin
                    if (ulpi_dir) begin
                        ulpi_oe <= 1'b0;
                        tx_done <= 1'b1;
                        tx_abort <= 1'b1;
                        tx_state <= T_IDLE;
                    end else if (ulpi_nxt) begin
                        ulpi_stp_reg  <= 1'b1;
                        ulpi_data_out <= 8'h00;
                        tx_timer      <= 32'd0;
                        tx_state      <= T_STP;
                    end else if (tx_timer >= TX_TIMEOUT_CYCLES) begin
                        ulpi_oe  <= 1'b0;
                        tx_done  <= 1'b1;
                        tx_abort <= 1'b1;
                        tx_state <= T_IDLE;
                    end else begin
                        tx_timer <= tx_timer + 32'd1;
                    end
                end

                // STP terminates ULPI input, not transmission on D+/D-.
                // Pulse it once, then wait for the PHY's FS SE0 -> J report.
                T_STP: begin
                    ulpi_stp_reg <= 1'b0;
                    ulpi_oe <= 1'b0;
                    tx_timer <= 32'd0;
                    tx_state <= T_EOP;
                end
                T_EOP: begin
                    if (fs_eop_now) begin
                        tx_done <= 1'b1;
                        tx_state <= T_IDLE;
                    end else if (tx_timer >= TX_TIMEOUT_CYCLES) begin
                        tx_done <= 1'b1;
                        tx_abort <= 1'b1;
                        tx_state <= T_IDLE;
                    end else tx_timer <= tx_timer + 32'd1;
                end

                default: tx_state <= T_IDLE;
            endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // RX packet FSM
    // ------------------------------------------------------------------
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_error <= 1'b0;
            rx_crc_ok <= 1'b0;
            rx_crc <= 16'hFFFF;
            rx_state        <= R_IDLE;
            rx_cnt          <= {LEN_W{1'b0}};
            rx_packet_ready <= 1'b0;
            rx_pid          <= 4'd0;
            rx_len          <= {LEN_W{1'b0}};
            rx_data         <= {DATA_BYTES*8{1'b0}};
            dir_prev        <= 1'b0;
            for (k = 0; k < DATA_BYTES; k = k + 1)
                rx_buf[k] <= 8'd0;
        end else begin
            dir_prev <= ulpi_dir;

            // Single writer for rx_packet_ready: a flush/ack from the
            // transaction FSM wins over a packet finishing in the same cycle.
            if (rx_flush || rx_ack)
                rx_packet_ready <= 1'b0;
            else if (rx_complete)
                rx_packet_ready <= 1'b1;

            if (rx_flush) begin
                rx_error <= 1'b0;
                rx_crc_ok <= 1'b0;
            end
            if (rx_flush || rx_ack || xstate == X_IDLE) begin
                rx_state <= R_IDLE;
                rx_cnt <= {LEN_W{1'b0}};
            end else case (rx_state)
                R_IDLE: begin
                    // Only a transaction expecting a response may capture, and
                    // DIR and NXT can rise together to announce RXACTIVE
                    // (USB3300 Fig. 6-7). DATA is still invalid during that
                    // turnaround; only a subsequent NXT=1 cycle is a byte.
                    if (!rx_packet_ready && expect_lat &&
                        (xstate == X_TX || xstate == X_RX) &&
                        ulpi_dir && dir_prev && ulpi_nxt) begin
                        rx_error <= (ulpi_data_in[7:4] != ~ulpi_data_in[3:0]);
                        rx_crc <= 16'hFFFF; // PID is excluded from CRC16.
                        rx_buf[0] <= ulpi_data_in;
                        rx_cnt    <= {{LEN_W-1{1'b0}}, 1'b1};
                        rx_state  <= R_DATA;
                    end
                end

                R_DATA: begin
                    if (rxcmd_now && ulpi_data_in[5]) rx_error <= 1'b1;
                    if (rx_complete) begin
                        rx_crc_ok <= (rx_crc == 16'hB001) && (rx_cnt >= 3) &&
                                     !rx_error && !(rxcmd_now && ulpi_data_in[5]);
                        rx_len  <= rx_cnt;
                        rx_pid  <= rx_buf[0][3:0];
                        for (n = 0; n < DATA_BYTES; n = n + 1)
                            rx_data[8*n +: 8] <= rx_buf[n];
                        rx_state <= R_IDLE;
                    end else if (ulpi_dir && dir_prev && ulpi_nxt) begin
                        if (rx_cnt < DATA_BYTES) begin
                            rx_buf[rx_cnt] <= ulpi_data_in;
                            rx_cnt <= rx_cnt + 1'b1;
                            rx_crc <= crc_step(rx_crc, ulpi_data_in);
                        end else rx_error <= 1'b1;
                    end
                end
            endcase
        end
    end

endmodule


