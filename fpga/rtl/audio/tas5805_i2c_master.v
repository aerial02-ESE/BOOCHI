`timescale 1ns / 1ps

// 极简 I2C 主机，只实现“写一个 8-bit 寄存器”所需的时序：
//   START, address+W, reg, data, STOP
// 每个 bit 4 个 quarter；SCL 高 2 quarter、低 2 quarter。
// SDA 为开漏：sda_oe=1 时拉低，0 时释放（依赖外部上拉）。
// 400 kHz 下，50 MHz 的 QUARTER 约 31 个周期。
module tas5805_i2c_master #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer I2C_FREQ_HZ = 400_000,
    parameter [6:0]   DEV_ADDR    = 7'h2d
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] reg_addr,
    input  wire [7:0] reg_data,
    output reg        busy,
    output reg        done,
    output reg        ack_error,
    output reg        scl,
    inout  wire       sda
);

    // Round the quarter period up: truncating 31.25 to 31 pushes the bus to
    // 403 kHz, above the 400 kHz Fast-mode limit.
    localparam integer I2C_TICK    = I2C_FREQ_HZ * 4;
    localparam integer QUARTER_RAW = (CLK_FREQ_HZ + I2C_TICK - 1) / I2C_TICK;
    localparam integer QUARTER     = (QUARTER_RAW < 1) ? 1 : QUARTER_RAW;

    localparam IDLE  = 3'd0;
    localparam START = 3'd1;
    localparam SEND  = 3'd2;
    localparam ACK   = 3'd3;
    localparam STOP  = 3'd4;
    localparam DONE  = 3'd5;

    reg [2:0]  state;
    reg [1:0]  phase;
    reg [15:0] qcnt;
    reg [2:0]  bit_idx;
    reg [1:0]  byte_sel;
    reg [7:0]  tx_byte;
    reg [7:0]  reg_addr_lat;
    reg [7:0]  reg_data_lat;
    reg        sda_oe;
    reg        sda_bit;
    reg        start_pending;

    wire quarter_tick = (qcnt == (QUARTER - 1));
    wire sda_in = sda;

    assign sda = sda_oe ? 1'b0 : 1'bz;

    always @(*) begin
        scl    = 1'b1;
        sda_oe = 1'b0;
        case (state)
            IDLE: begin
                scl = 1'b1;
            end
            START: begin
                scl    = (phase < 2);
                sda_oe = (phase >= 1);
            end
            SEND: begin
                scl    = (phase >= 2);
                sda_oe = ~sda_bit;
            end
            ACK: begin
                scl    = (phase >= 2);
                sda_oe = 1'b0;
            end
            STOP: begin
                // SDA may only fall while SCL is low: pull it down one quarter
                // after SCL falls, then release it while SCL is high for STOP.
                scl    = (phase >= 2);
                sda_oe = (phase == 1) || (phase == 2);
            end
            DONE: begin
                scl = 1'b1;
            end
            default: begin
                scl = 1'b1;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            phase        <= 2'd0;
            qcnt         <= 16'd0;
            bit_idx      <= 3'd7;
            byte_sel     <= 2'd0;
            tx_byte      <= 8'd0;
            reg_addr_lat <= 8'd0;
            reg_data_lat <= 8'd0;
            sda_bit      <= 1'b1;
            busy         <= 1'b0;
            done         <= 1'b0;
            ack_error    <= 1'b0;
            start_pending <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && (state == IDLE))
                start_pending <= 1'b1;

            if (!quarter_tick) begin
                qcnt <= qcnt + 16'd1;
            end else begin
                qcnt <= 16'd0;

                if (phase != 2'd3) begin
                    // SDA 只在 SCL 低电平期间改变，避免被从机误判为 START。
                    if ((phase == 2'd0) && (state == SEND))
                        sda_bit <= tx_byte[bit_idx];
                    phase <= phase + 2'd1;
                end else begin
                    phase <= 2'd0;

                    case (state)
                        IDLE: begin
                            if (start || start_pending) begin
                                reg_addr_lat <= reg_addr;
                                reg_data_lat <= reg_data;
                                tx_byte      <= {DEV_ADDR, 1'b0};
                                byte_sel     <= 2'd0;
                                bit_idx      <= 3'd7;
                                ack_error    <= 1'b0;
                                busy         <= 1'b1;
                                start_pending <= 1'b0;
                                state        <= START;
                            end
                        end

                        START: begin
                            tx_byte <= {DEV_ADDR, 1'b0};
                            sda_bit <= DEV_ADDR[6];
                            bit_idx <= 3'd7;
                            state   <= SEND;
                        end

                        SEND: begin
                            if (bit_idx == 3'd0) begin
                                state <= ACK;
                            end else begin
                                bit_idx <= bit_idx - 1'b1;
                            end
                        end

                        ACK: begin
                            if (sda_in) begin
                                // NACK：停止本次传输。
                                ack_error <= 1'b1;
                                state     <= STOP;
                            end else if (byte_sel == 2'd0) begin
                                tx_byte  <= reg_addr_lat;
                                byte_sel <= 2'd1;
                                bit_idx  <= 3'd7;
                                state    <= SEND;
                            end else if (byte_sel == 2'd1) begin
                                tx_byte  <= reg_data_lat;
                                byte_sel <= 2'd2;
                                bit_idx  <= 3'd7;
                                state    <= SEND;
                            end else begin
                                state <= STOP;
                            end
                        end

                        STOP: begin
                            state <= DONE;
                        end

                        DONE: begin
                            done  <= 1'b1;
                            busy  <= 1'b0;
                            state <= IDLE;
                        end

                        default: state <= IDLE;
                    endcase
                end
            end
        end
    end

endmodule
