/*
 * 参数化 8N1 UART 接收器。RX 先经两级同步；在起始位中点确认后，
 * 每 BAUD_DIV 个 clk 采样一个数据位。错误停止位只计数，不输出字节。
 */
module uart_rx_8n1 #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer BAUD_RATE = 1_000_000,
    parameter integer COUNT_WIDTH = 32
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   rx,
    output reg                    byte_valid,
    output reg  [7:0]             byte_data,
    output reg  [COUNT_WIDTH-1:0] framing_error_count
);
    localparam integer BAUD_DIV = (CLK_FREQ_HZ + (BAUD_RATE / 2)) / BAUD_RATE;
    localparam integer HALF_DIV = BAUD_DIV / 2;
    localparam [1:0] ST_IDLE = 2'd0, ST_START = 2'd1, ST_DATA = 2'd2, ST_STOP = 2'd3;

    reg rx_meta, rx_sync, rx_prev;
    reg [1:0] state;
    reg [31:0] baud_count;
    reg [2:0] bit_index;
    reg [7:0] shift;

    function [COUNT_WIDTH-1:0] sat_inc;
        input [COUNT_WIDTH-1:0] value;
        begin
            sat_inc = (value == {COUNT_WIDTH{1'b1}}) ? value : value + 1'b1;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            rx_prev <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            rx_prev <= rx_sync;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            baud_count <= 32'd0;
            bit_index <= 3'd0;
            shift <= 8'd0;
            byte_valid <= 1'b0;
            byte_data <= 8'd0;
            framing_error_count <= {COUNT_WIDTH{1'b0}};
        end else begin
            byte_valid <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (rx_prev && !rx_sync) begin
                        state <= ST_START;
                        baud_count <= (HALF_DIV > 0) ? HALF_DIV - 1 : 0;
                    end
                end
                ST_START: begin
                    if (baud_count != 0) begin
                        baud_count <= baud_count - 1'b1;
                    end else if (!rx_sync) begin
                        state <= ST_DATA;
                        bit_index <= 3'd0;
                        baud_count <= BAUD_DIV - 1;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
                ST_DATA: begin
                    if (baud_count != 0) begin
                        baud_count <= baud_count - 1'b1;
                    end else begin
                        shift[bit_index] <= rx_sync;
                        baud_count <= BAUD_DIV - 1;
                        if (bit_index == 3'd7)
                            state <= ST_STOP;
                        else
                            bit_index <= bit_index + 1'b1;
                    end
                end
                default: begin
                    if (baud_count != 0) begin
                        baud_count <= baud_count - 1'b1;
                    end else begin
                        state <= ST_IDLE;
                        if (rx_sync) begin
                            byte_data <= shift;
                            byte_valid <= 1'b1;
                        end else begin
                            framing_error_count <= sat_inc(framing_error_count);
                        end
                    end
                end
            endcase
        end
    end
endmodule
