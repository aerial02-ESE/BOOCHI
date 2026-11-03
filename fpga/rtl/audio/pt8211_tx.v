/*
 * PT8211（NEO 板载 16-bit DAC）串行发送器。
 *
 * 每帧 32 个 BCK：16 bit 左 + 16 bit 右；WS 低/高对应左右（由 WS_LOW_IS_LEFT 选择）。
 * 数据在 BCK 下降沿更新、上升沿被 DAC 采样；16-bit MSB first。BCK = clk / (2*BCLK_DIV)。
 * `load` 每帧拉高一拍把 sample_left/right 锁存进本帧的移位寄存器；`mute=1` 输出全零。
 *
 * 说明：PT8211 精确字长/极性/对齐（Japanese/LSBJ）与上电默认态须按最终原理图和数据手册
 * 在 D19-AUDIO 签核；本模块只保证结构与时序参数化，最终常量在此更换。
 */
module pt8211_tx #(
    parameter integer AUDIO_WIDTH = 16,
    parameter integer BCLK_DIV = 4,
    // PT8211：WS 低电平发送右声道，WS 高电平发送左声道。
    parameter integer WS_LOW_IS_LEFT = 0
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      load,
    input  wire [AUDIO_WIDTH-1:0]    sample_left,
    input  wire [AUDIO_WIDTH-1:0]    sample_right,
    input  wire                      mute,
    output reg                       pt_bck,
    output reg                       pt_ws,
    output reg                       pt_din,
    output reg                       frame_done
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

    localparam integer DIV_W = clog2(BCLK_DIV);
    localparam integer PHASE_BITS = AUDIO_WIDTH * 2;
    localparam integer BIT_W = clog2(PHASE_BITS);

    reg [DIV_W-1:0] div_cnt;
    reg [BIT_W-1:0] bit_cnt;
    reg [AUDIO_WIDTH-1:0] shift_l;
    reg [AUDIO_WIDTH-1:0] shift_r;

    wire div_tick = (div_cnt == BCLK_DIV - 1);
    wire bck_fall = div_tick && pt_bck;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= {DIV_W{1'b0}};
            pt_bck <= 1'b0;
            pt_ws <= 1'b0;
            pt_din <= 1'b0;
            bit_cnt <= {BIT_W{1'b0}};
            shift_l <= {AUDIO_WIDTH{1'b0}};
            shift_r <= {AUDIO_WIDTH{1'b0}};
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;

            if (div_tick) begin
                div_cnt <= {DIV_W{1'b0}};
                pt_bck <= ~pt_bck;
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end

            if (load) begin
                shift_l <= mute ? {AUDIO_WIDTH{1'b0}} : sample_left;
                shift_r <= mute ? {AUDIO_WIDTH{1'b0}} : sample_right;
            end

            if (bck_fall) begin
                if (bit_cnt < AUDIO_WIDTH) begin
                    pt_din <= shift_l[AUDIO_WIDTH-1];
                    shift_l <= {shift_l[AUDIO_WIDTH-2:0], 1'b0};
                end else begin
                    pt_din <= shift_r[AUDIO_WIDTH-1];
                    shift_r <= {shift_r[AUDIO_WIDTH-2:0], 1'b0};
                end

                if (WS_LOW_IS_LEFT != 0)
                    pt_ws <= (bit_cnt >= AUDIO_WIDTH);
                else
                    pt_ws <= (bit_cnt < AUDIO_WIDTH);

                if (bit_cnt == PHASE_BITS - 1) begin
                    bit_cnt <= {BIT_W{1'b0}};
                    frame_done <= 1'b1;
                end else begin
                    bit_cnt <= bit_cnt + 1'b1;
                end
            end
        end
    end
endmodule
