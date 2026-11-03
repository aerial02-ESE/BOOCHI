`timescale 1ns / 1ps

// 88 键 LED 演奏指引控制器。
//
// 输入是 128-bit MIDI 键状态（pressed/guide/expected），输出是每条 WS2812 灯带的
// 串行数据。键到灯的映射来自 src/led_map.mem，每行 16 bit：
//   [15]    valid
//   [14:12] strip  (0..NUM_STRIPS-1)
//   [11:0]  led index
// 因此 88 键可以映射到更少的灯、合并到同一颗灯，或暂时留空；物理灯位调整后
// 只需要替换 .mem，不必改 RTL。
//
// 每帧先清空所有灯，再按 guide(蓝) -> expected(白) -> pressed(绿/红) 的顺序覆盖，
// 后写的 pass 优先级更高。整帧构建约几百个周期，串行输出由 ws2812_tx 非阻塞完成。
module led_guide_controller #(
    parameter integer NUM_STRIPS   = 3,
    parameter integer STRIP0_LEDS  = 52,
    parameter integer STRIP1_LEDS  = 36,
    parameter integer STRIP2_LEDS  = 0,
    parameter integer MAX_LEDS     = 52,
    parameter integer ADDR_W       = 7,
    parameter integer CLK_FREQ_HZ  = 50_000_000,
    parameter integer FRAME_HZ     = 300,
    parameter         LED_MAP_FILE = "src/led_map.mem"
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire [127:0]        pressed_notes,
    input  wire [127:0]        guide_notes,
    input  wire [127:0]        expected_notes,
    input  wire [3:0]          brightness_shift,
    output wire [NUM_STRIPS-1:0] led_data,
    output wire                led_busy
);

    localparam [23:0] COLOR_GUIDE    = 24'h0000ff; // {G,R,B} 蓝
    localparam [23:0] COLOR_EXPECTED = 24'hffffff; // 白
    localparam [23:0] COLOR_CORRECT  = 24'h00ff00; // 绿
    localparam [23:0] COLOR_WRONG    = 24'hff0000; // 红

    localparam integer FRAME_CYCLES = CLK_FREQ_HZ / FRAME_HZ;

    localparam IDLE    = 3'd0;
    localparam CLEAR   = 3'd1;
    localparam GUIDE   = 3'd2;
    localparam EXPECTED = 3'd3;
    localparam PRESSED = 3'd4;
    localparam START   = 3'd5;
    localparam WAIT    = 3'd6;

    reg [15:0] map_rom [0:127];
    integer k;
    initial begin
        for (k = 0; k < 128; k = k + 1)
            map_rom[k] = 16'h0000;
        $readmemh(LED_MAP_FILE, map_rom);
    end

    function [15:0] strip_len;
        input [2:0] s;
        begin
            case (s)
                3'd0:    strip_len = STRIP0_LEDS;
                3'd1:    strip_len = STRIP1_LEDS;
                3'd2:    strip_len = STRIP2_LEDS;
                default: strip_len = 16'd0;
            endcase
        end
    endfunction

    function [7:0] scale8;
        input [7:0] c;
        input [3:0] sh;
        begin
            if (sh == 4'd0)
                scale8 = 8'd0;
            else if (sh >= 4'd7)
                scale8 = c;
            else
                scale8 = c >> (7 - sh);
        end
    endfunction

    function [23:0] scale_color;
        input [23:0] c;
        input [3:0] sh;
        begin
            scale_color = {scale8(c[23:16], sh),
                           scale8(c[15:8],  sh),
                           scale8(c[7:0],   sh)};
        end
    endfunction

    wire [NUM_STRIPS-1:0] strip_busy;
    reg  [NUM_STRIPS-1:0] strip_start;
    reg  [NUM_STRIPS-1:0] wr_en;
    reg  [ADDR_W-1:0]     wr_addr;
    reg  [23:0]           wr_data;
    wire                  any_busy = |strip_busy;

    genvar gi;
    generate
        for (gi = 0; gi < NUM_STRIPS; gi = gi + 1) begin: g_strip
            localparam integer L = (gi == 0) ? STRIP0_LEDS :
                                   (gi == 1) ? STRIP1_LEDS :
                                   (gi == 2) ? STRIP2_LEDS : 0;
            if (L > 0) begin: g_tx
                ws2812_tx #(
                    .NUM_LEDS(L),
                    .ADDR_W(ADDR_W),
                    .CLK_FREQ_HZ(CLK_FREQ_HZ),
                    .BIT_RATE_HZ(800_000),
                    .RESET_US(300)
                ) u_tx (
                    .clk(clk),
                    .rst_n(rst_n),
                    .start(strip_start[gi]),
                    .wr_en(wr_en[gi]),
                    .wr_addr(wr_addr),
                    .wr_data(wr_data),
                    .dout(led_data[gi]),
                    .busy(strip_busy[gi]),
                    .frame_done()
                );
            end else begin: g_none
                assign led_data[gi] = 1'b0;
                assign strip_busy[gi] = 1'b0;
            end
        end
    endgenerate

    reg [2:0]        state;
    reg [1:0]        clear_strip;
    reg [ADDR_W-1:0] clear_idx;
    reg [6:0]        note_idx;
    reg              seen_busy;
    reg [31:0]       frame_cnt;

    wire frame_tick = (frame_cnt == (FRAME_CYCLES - 1));

    wire [15:0] map_entry  = map_rom[note_idx];
    wire        map_valid  = map_entry[15];
    wire [2:0]  map_strip  = map_entry[14:12];
    wire [11:0] map_index  = map_entry[11:0];
    wire        map_ok     = map_valid &&
                             (map_strip < NUM_STRIPS) &&
                             (map_index < strip_len(map_strip));

    assign led_busy = any_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            clear_strip  <= 2'd0;
            clear_idx    <= {ADDR_W{1'b0}};
            note_idx     <= 7'd0;
            seen_busy    <= 1'b0;
            frame_cnt    <= 32'd0;
            strip_start  <= {NUM_STRIPS{1'b0}};
            wr_en        <= {NUM_STRIPS{1'b0}};
            wr_addr      <= {ADDR_W{1'b0}};
            wr_data      <= 24'd0;
        end else begin
            wr_en       <= {NUM_STRIPS{1'b0}};
            strip_start <= {NUM_STRIPS{1'b0}};

            if (frame_cnt == (FRAME_CYCLES - 1))
                frame_cnt <= 32'd0;
            else
                frame_cnt <= frame_cnt + 32'd1;

            case (state)
                IDLE: begin
                    seen_busy <= 1'b0;
                    if (frame_tick && !any_busy) begin
                        clear_strip <= 2'd0;
                        clear_idx   <= {ADDR_W{1'b0}};
                        note_idx    <= 7'd0;
                        state       <= CLEAR;
                    end
                end

                CLEAR: begin
                    if (clear_idx < strip_len({1'b0, clear_strip})) begin
                        wr_en[clear_strip] <= 1'b1;
                        wr_addr            <= clear_idx;
                        wr_data            <= 24'h000000;
                    end
                    if (clear_idx == (MAX_LEDS - 1)) begin
                        clear_idx <= {ADDR_W{1'b0}};
                        if (clear_strip == (NUM_STRIPS - 1)) begin
                            note_idx <= 7'd0;
                            state    <= GUIDE;
                        end else begin
                            clear_strip <= clear_strip + 1'b1;
                        end
                    end else begin
                        clear_idx <= clear_idx + 1'b1;
                    end
                end

                GUIDE: begin
                    if (guide_notes[note_idx] && map_ok) begin
                        wr_en[map_strip] <= 1'b1;
                        wr_addr          <= map_index[ADDR_W-1:0];
                        wr_data          <= scale_color(COLOR_GUIDE, brightness_shift);
                    end
                    if (note_idx == 7'd127) begin
                        note_idx <= 7'd0;
                        state    <= EXPECTED;
                    end else begin
                        note_idx <= note_idx + 1'b1;
                    end
                end

                EXPECTED: begin
                    if (expected_notes[note_idx] && map_ok) begin
                        wr_en[map_strip] <= 1'b1;
                        wr_addr          <= map_index[ADDR_W-1:0];
                        wr_data          <= scale_color(COLOR_EXPECTED, brightness_shift);
                    end
                    if (note_idx == 7'd127) begin
                        note_idx <= 7'd0;
                        state    <= PRESSED;
                    end else begin
                        note_idx <= note_idx + 1'b1;
                    end
                end

                PRESSED: begin
                    if (pressed_notes[note_idx] && map_ok) begin
                        wr_en[map_strip] <= 1'b1;
                        wr_addr          <= map_index[ADDR_W-1:0];
                        wr_data          <= scale_color(expected_notes[note_idx] ?
                                                        COLOR_CORRECT : COLOR_WRONG,
                                                        brightness_shift);
                    end
                    if (note_idx == 7'd127) begin
                        state <= START;
                    end else begin
                        note_idx <= note_idx + 1'b1;
                    end
                end

                START: begin
                    strip_start <= {NUM_STRIPS{1'b1}};
                    seen_busy   <= 1'b0;
                    state       <= WAIT;
                end

                WAIT: begin
                    if (any_busy)
                        seen_busy <= 1'b1;
                    if (seen_busy && !any_busy)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
