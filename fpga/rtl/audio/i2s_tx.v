`timescale 1ns / 1ps

// 标准 Philips I2S 发送器（主模式）。
//
// 每个声道 SLOT_WIDTH 个 BCLK，数据 MSB-first，MSB 比 LRCLK 边沿晚一个 BCLK
// （I2S 标准的一位延迟）。DATA_WIDTH 之后补零到 SLOT_WIDTH。
// BCLK = clk / (2*BCLK_DIV)。默认 50 MHz、BCLK_DIV=8 -> BCLK=3.125 MHz，
// 32-bit slot -> LRCLK=48.828 kHz，正好与当前 PT8211 音频帧率一致。
//
// sample_valid 每帧给一个单拍脉冲；若某个左声道帧没有新样本，重复上一帧并置
// underflow。mute 时输出零，但帧结构保持连续。
module i2s_tx #(
    parameter integer DATA_WIDTH    = 24,
    parameter integer SLOT_WIDTH    = 32,
    parameter integer BCLK_DIV      = 8,
    // 1: LRCLK 低电平为左声道；0: 高电平为左声道。
    parameter integer LEFT_WHEN_LOW = 1
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         sample_valid,
    input  wire signed [DATA_WIDTH-1:0] sample_left,
    input  wire signed [DATA_WIDTH-1:0] sample_right,
    input  wire                         mute,
    output reg                          sclk,
    output reg                          lrclk,
    output reg                          sdout,
    output reg                          frame_done,
    output reg                          underflow
);

    function integer clog2;
        input integer value;
        integer temporary;
        begin
            temporary = value - 1;
            clog2 = 0;
            while (temporary > 0) begin
                temporary = temporary >> 1;
                clog2 = clog2 + 1;
            end
        end
    endfunction

    localparam integer PHASE_BITS = 2 * SLOT_WIDTH;
    localparam integer BIT_W      = clog2(PHASE_BITS);
    localparam integer DIV_W      = clog2(BCLK_DIV);

    reg [DIV_W-1:0] div_cnt;
    reg [BIT_W-1:0] bit_cnt;
    reg signed [DATA_WIDTH-1:0] shift_reg;
    reg signed [DATA_WIDTH-1:0] left_latch;
    reg signed [DATA_WIDTH-1:0] right_latch;
    reg sample_seen;

    wire div_tick = (div_cnt == (BCLK_DIV - 1));
    wire bclk_fall = div_tick && sclk;

    wire [BIT_W-1:0] next_channel = (bit_cnt == {BIT_W{1'b0}}) ? {BIT_W{1'b0}} : {{(BIT_W-1){1'b0}}, 1'b1};
    wire next_lrclk = LEFT_WHEN_LOW ? next_channel[0] : ~next_channel[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt     <= {DIV_W{1'b0}};
            bit_cnt     <= {BIT_W{1'b0}};
            shift_reg   <= {DATA_WIDTH{1'b0}};
            left_latch  <= {DATA_WIDTH{1'b0}};
            right_latch <= {DATA_WIDTH{1'b0}};
            sample_seen <= 1'b0;
            sclk        <= 1'b0;
            lrclk       <= LEFT_WHEN_LOW ? 1'b0 : 1'b1;
            sdout       <= 1'b0;
            frame_done  <= 1'b0;
            underflow   <= 1'b0;
        end else begin
            frame_done <= 1'b0;

            if (sample_valid) begin
                left_latch  <= sample_left;
                right_latch <= sample_right;
                sample_seen <= 1'b1;
            end

            if (div_tick) begin
                div_cnt <= {DIV_W{1'b0}};
                sclk    <= ~sclk;
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end

            if (bclk_fall) begin
                if ((bit_cnt == {BIT_W{1'b0}}) || (bit_cnt == SLOT_WIDTH)) begin
                    // 新声道开始：LRCLK 换边，装入该声道样本，先发一位延迟。
                    lrclk     <= next_lrclk;
                    sdout     <= 1'b0;
                    shift_reg <= mute ? {DATA_WIDTH{1'b0}} :
                                 (next_channel[0] ? right_latch : left_latch);

                    if (!next_channel[0]) begin
                        if (sample_seen) begin
                            // A sample arriving on this same edge is for the
                            // next frame; keep the flag instead of clearing it.
                            if (!sample_valid) sample_seen <= 1'b0;
                            underflow   <= 1'b0;
                        end else begin
                            underflow   <= 1'b1;
                        end
                    end

                    bit_cnt <= bit_cnt + 1'b1;
                end else begin
                    if ((bit_cnt >= 1 && bit_cnt <= DATA_WIDTH) ||
                        (bit_cnt >= (SLOT_WIDTH + 1) && bit_cnt <= (SLOT_WIDTH + DATA_WIDTH))) begin
                        sdout     <= shift_reg[DATA_WIDTH-1];
                        shift_reg <= {shift_reg[DATA_WIDTH-2:0], 1'b0};
                    end else begin
                        sdout <= 1'b0;
                    end

                    if (bit_cnt == (PHASE_BITS - 1)) begin
                        bit_cnt    <= {BIT_W{1'b0}};
                        frame_done <= 1'b1;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end
            end
        end
    end

endmodule
