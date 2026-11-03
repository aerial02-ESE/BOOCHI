/*
 * ESP32 -> FPGA UART ControlEvent v1 帧接收器。
 *
 * 固定 14 Byte：A5 5A | UART_VERSION(01) | LENGTH(08) |
 *               ControlEvent[63:0]（B0..B7，大端） | CRC16（大端）。
 * CRC-16/CCITT-FALSE 覆盖 version、length 与 8 Byte ControlEvent，不含 SOF。
 * 输出使用 ready/valid 单槽；下游反压时保持事件，后续合法帧计 overflow。
 */
module uart_control_event_rx #(
    parameter integer COUNT_WIDTH = 32
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   byte_valid,
    input  wire [7:0]             byte_data,
    output reg                    event_valid,
    input  wire                   event_ready,
    output reg  [63:0]            event_data,
    output reg                    frame_seen_pulse,
    output reg  [COUNT_WIDTH-1:0] valid_frame_count,
    output reg  [COUNT_WIDTH-1:0] crc_error_count,
    output reg  [COUNT_WIDTH-1:0] format_error_count,
    output reg  [COUNT_WIDTH-1:0] overflow_count,
    output reg  [COUNT_WIDTH-1:0] sequence_gap_count,
    output reg  [COUNT_WIDTH-1:0] duplicate_count
);
    localparam [2:0] ST_SOF_A5  = 3'd0;
    localparam [2:0] ST_SOF_5A  = 3'd1;
    localparam [2:0] ST_VERSION = 3'd2;
    localparam [2:0] ST_LENGTH  = 3'd3;
    localparam [2:0] ST_PAYLOAD = 3'd4;
    localparam [2:0] ST_CRC_HI  = 3'd5;
    localparam [2:0] ST_CRC_LO  = 3'd6;

    reg [2:0] state;
    reg [7:0] uart_version;
    reg [3:0] payload_count;
    reg [63:0] event_shift;
    reg [15:0] crc_accum;
    reg [7:0] received_crc_hi;
    reg sequence_initialized;
    reg [7:0] last_sequence;

    function [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0] data;
        integer i;
        reg [15:0] crc;
        begin
            crc = crc_in ^ {data, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                crc = crc[15] ? ((crc << 1) ^ 16'h1021) : (crc << 1);
            crc16_byte = crc;
        end
    endfunction

    function [COUNT_WIDTH-1:0] sat_inc;
        input [COUNT_WIDTH-1:0] value;
        begin
            sat_inc = (value == {COUNT_WIDTH{1'b1}}) ? value : value + 1'b1;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_SOF_A5;
            uart_version <= 8'd0;
            payload_count <= 4'd0;
            event_shift <= 64'd0;
            crc_accum <= 16'hFFFF;
            received_crc_hi <= 8'd0;
            event_valid <= 1'b0;
            event_data <= 64'd0;
            frame_seen_pulse <= 1'b0;
            valid_frame_count <= {COUNT_WIDTH{1'b0}};
            crc_error_count <= {COUNT_WIDTH{1'b0}};
            format_error_count <= {COUNT_WIDTH{1'b0}};
            overflow_count <= {COUNT_WIDTH{1'b0}};
            sequence_gap_count <= {COUNT_WIDTH{1'b0}};
            duplicate_count <= {COUNT_WIDTH{1'b0}};
            sequence_initialized <= 1'b0;
            last_sequence <= 8'd0;
        end else begin
            frame_seen_pulse <= 1'b0;
            if (event_valid && event_ready)
                event_valid <= 1'b0;

            if (byte_valid) begin
                case (state)
                    ST_SOF_A5: begin
                        if (byte_data == 8'hA5)
                            state <= ST_SOF_5A;
                    end
                    ST_SOF_5A: begin
                        if (byte_data == 8'h5A)
                            state <= ST_VERSION;
                        else if (byte_data != 8'hA5)
                            state <= ST_SOF_A5;
                    end
                    ST_VERSION: begin
                        uart_version <= byte_data;
                        crc_accum <= crc16_byte(16'hFFFF, byte_data);
                        state <= ST_LENGTH;
                    end
                    ST_LENGTH: begin
                        if (uart_version != 8'h01 || byte_data != 8'd8) begin
                            format_error_count <= sat_inc(format_error_count);
                            state <= (byte_data == 8'hA5) ? ST_SOF_5A : ST_SOF_A5;
                        end else begin
                            crc_accum <= crc16_byte(crc_accum, byte_data);
                            event_shift <= 64'd0;
                            payload_count <= 4'd0;
                            state <= ST_PAYLOAD;
                        end
                    end
                    ST_PAYLOAD: begin
                        event_shift <= {event_shift[55:0], byte_data};
                        crc_accum <= crc16_byte(crc_accum, byte_data);
                        if (payload_count == 4'd7)
                            state <= ST_CRC_HI;
                        else
                            payload_count <= payload_count + 1'b1;
                    end
                    ST_CRC_HI: begin
                        received_crc_hi <= byte_data;
                        state <= ST_CRC_LO;
                    end
                    default: begin
                        /* A truncated frame may make the current byte the next
                         * SOF A5; retain it instead of losing resynchronization. */
                        state <= (byte_data == 8'hA5) ? ST_SOF_5A : ST_SOF_A5;
                        if ({received_crc_hi, byte_data} != crc_accum) begin
                            crc_error_count <= sat_inc(crc_error_count);
                        end else if (event_shift[63:62] != 2'b01) begin
                            format_error_count <= sat_inc(format_error_count);
                        end else begin
                            valid_frame_count <= sat_inc(valid_frame_count);
                            frame_seen_pulse <= 1'b1;
                            if (sequence_initialized) begin
                                if (event_shift[7:0] == last_sequence)
                                    duplicate_count <= sat_inc(duplicate_count);
                                else if (event_shift[7:0] != (last_sequence + 1'b1))
                                    sequence_gap_count <= sat_inc(sequence_gap_count);
                            end
                            sequence_initialized <= 1'b1;
                            last_sequence <= event_shift[7:0];
                            if (!event_valid || event_ready) begin
                                event_data <= event_shift;
                                event_valid <= 1'b1;
                            end else begin
                                overflow_count <= sat_inc(overflow_count);
                            end
                        end
                    end
                endcase
            end
        end
    end
endmodule
