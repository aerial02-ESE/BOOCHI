`timescale 1ns / 1ps

// WS2812B / SK6812 单灯带发送器。
//
// 颜色字为 {G[7:0], R[7:0], B[7:0]}，按 MSB-first 发出 G7..G0、R7..R0、B7..B0。
// 颜色 RAM 只能在 busy=0 时写入；写入完成后给 start 一个单拍脉冲，模块会
// 非阻塞地串出整条灯带，结束后再拉低 busy。调用方必须等 busy 回低再改颜色。
//
// 默认 50 MHz / 800 kHz：BIT_CYCLES=62（实际约 806 kHz，在 WS2812B 容差内）。
// 参数允许测试平台缩短时序，不必改 RTL。
module ws2812_tx #(
    parameter integer NUM_LEDS    = 52,
    parameter integer ADDR_W      = 7,
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer BIT_RATE_HZ = 800_000,
    parameter integer BIT_CYCLES  = CLK_FREQ_HZ / BIT_RATE_HZ,
    parameter integer RESET_US    = 300,
    parameter integer RESET_CYCLES = (CLK_FREQ_HZ / 1_000_000) * RESET_US
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              start,
    input  wire              wr_en,
    input  wire [ADDR_W-1:0] wr_addr,
    input  wire [23:0]       wr_data,
    output reg               dout,
    output wire              busy,
    output reg               frame_done
);

    // 0.4 us / 0.8 us 的高电平宽度，四舍五入到整周期。
    localparam integer T0H_CYCLES = ((BIT_CYCLES * 32) + 50) / 100;
    localparam integer T1H_CYCLES = ((BIT_CYCLES * 64) + 50) / 100;
    localparam integer T0L_CYCLES = BIT_CYCLES - T0H_CYCLES;
    localparam integer T1L_CYCLES = BIT_CYCLES - T1H_CYCLES;

    localparam IDLE = 3'd0;
    localparam LOAD = 3'd1;
    localparam HIGH = 3'd2;
    localparam LOW  = 3'd3;
    localparam RESET = 3'd4;
    localparam DONE = 3'd5;

    reg [23:0]       mem [0:NUM_LEDS-1];
    reg [23:0]       shift;
    reg [4:0]        bit_idx;
    reg [ADDR_W-1:0] led_idx;
    reg [15:0]       wait_cnt;
    reg [2:0]        state;
    reg              busy_r;

    assign busy = busy_r;

    // 单写端口；busy 期间忽略写入，避免破坏当前帧。
    always @(posedge clk) begin
        if (wr_en && !busy_r && (wr_addr < NUM_LEDS))
            mem[wr_addr] <= wr_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout       <= 1'b0;
            shift      <= 24'd0;
            bit_idx    <= 5'd23;
            led_idx    <= {ADDR_W{1'b0}};
            wait_cnt   <= 16'd0;
            state      <= IDLE;
            busy_r     <= 1'b0;
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            case (state)
                IDLE: begin
                    dout   <= 1'b0;
                    busy_r <= 1'b0;
                    if (start) begin
                        led_idx <= {ADDR_W{1'b0}};
                        bit_idx <= 5'd23;
                        wait_cnt <= 16'd0;
                        state  <= LOAD;
                        busy_r <= 1'b1;
                    end
                end

                LOAD: begin
                    shift    <= mem[led_idx];
                    dout     <= 1'b1;
                    wait_cnt <= 16'd0;
                    state    <= HIGH;
                end

                HIGH: begin
                    if (wait_cnt >= ((shift[bit_idx] ? T1H_CYCLES : T0H_CYCLES) - 1)) begin
                        dout     <= 1'b0;
                        wait_cnt <= 16'd0;
                        state    <= LOW;
                    end else begin
                        wait_cnt <= wait_cnt + 16'd1;
                    end
                end

                LOW: begin
                    if (wait_cnt >= ((shift[bit_idx] ? T1L_CYCLES : T0L_CYCLES) - 1)) begin
                        wait_cnt <= 16'd0;
                        if (bit_idx == 5'd0) begin
                            if (led_idx == (NUM_LEDS - 1)) begin
                                state <= RESET;
                            end else begin
                                led_idx <= led_idx + 1'b1;
                                bit_idx <= 5'd23;
                                state   <= LOAD;
                            end
                        end else begin
                            bit_idx <= bit_idx - 1'b1;
                            dout    <= 1'b1;
                            state   <= HIGH;
                        end
                    end else begin
                        wait_cnt <= wait_cnt + 16'd1;
                    end
                end

                RESET: begin
                    dout <= 1'b0;
                    if (wait_cnt >= (RESET_CYCLES - 1)) begin
                        busy_r <= 1'b0;
                        state  <= DONE;
                    end else begin
                        wait_cnt <= wait_cnt + 16'd1;
                    end
                end

                DONE: begin
                    frame_done <= 1'b1;
                    state      <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
