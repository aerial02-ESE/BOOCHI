`timescale 1ns / 1ps

// TAS5805M 上电与初始化控制。
//
// 时序：PDN 低 -> PDN 高 -> 等待稳定 -> 逐条 I2C 写初始化表 -> 等待 -> init_done。
// 初始化表 src/tas5805_init.mem 每行 16 bit：{reg_addr[7:0], reg_data[7:0]}。
// 0xFE 为延时条目（低 8 位为毫秒数），0xFFFF 为结束标记。
// 当前表由 ESP-ADF 的 tas5805m_reg_cfg.h（Apache-2.0）转换而来；
// 正式上板前仍建议用 TI PPC3/EVM 或整机厂提供的序列复核。
//
// INIT_COUNT 必须 >= 文件中实际条目数（含 0xFFFF 也可，控制器会提前结束）。
// PDN 在 FPGA 未配置时应由外部下拉保持低，避免功放随机上电。
module tas5805_ctrl #(
    parameter integer CLK_FREQ_HZ  = 50_000_000,
    parameter integer I2C_FREQ_HZ  = 400_000,
    parameter [6:0]   DEV_ADDR     = 7'h2d,
    parameter integer PDN_LOW_MS   = 1,
    parameter integer PDN_SETTLE_MS = 20,
    parameter integer UNMUTE_MS    = 50,
    parameter integer INIT_COUNT   = 1679,
    parameter         INIT_FILE    = "src/tas5805_init.mem"
) (
    input  wire clk,
    input  wire rst_n,
    input  wire enable,
    output reg  pdn,
    output wire scl,
    inout  wire sda,
    output reg  busy,
    output reg  init_done,
    output reg  error
);

    localparam integer MS_CYCLES = (CLK_FREQ_HZ / 1000 < 1) ? 1 : (CLK_FREQ_HZ / 1000);
    localparam integer PDN_LOW_CYCLES    = MS_CYCLES * PDN_LOW_MS;
    localparam integer PDN_SETTLE_CYCLES = MS_CYCLES * PDN_SETTLE_MS;
    localparam integer UNMUTE_CYCLES     = MS_CYCLES * UNMUTE_MS;

    localparam WAIT_ENABLE = 4'd0;
    localparam PDN_LOW     = 4'd1;
    localparam SETTLE      = 4'd2;
    localparam INIT_REQ    = 4'd3;
    localparam INIT_WAIT   = 4'd4;
    localparam UNMUTE      = 4'd5;
    localparam RUN         = 4'd6;
    localparam ERROR       = 4'd7;
    localparam INIT_DELAY  = 4'd8;
    localparam ROM_READ    = 4'd9;

    reg [15:0] init_rom [0:INIT_COUNT-1];
    integer    rom_i;
    initial begin
        for (rom_i = 0; rom_i < INIT_COUNT; rom_i = rom_i + 1)
            init_rom[rom_i] = 16'hFFFF;
        $readmemh(INIT_FILE, init_rom);
    end

    reg [3:0]  state;
    reg [31:0] delay_cnt;
    reg [31:0] delay_target;
    reg [15:0] init_idx;
    reg [15:0] init_entry;
    reg        i2c_start;
    reg [7:0]  i2c_reg_addr;
    reg [7:0]  i2c_reg_data;
    wire       i2c_busy;
    wire       i2c_done;
    wire       i2c_ack_error;

    // 同步读，让 Gowin 把 1679x16 的初始化表推断成 BSRAM，而不是分布式 LUTRAM。
    always @(posedge clk) begin
        init_entry <= init_rom[init_idx];
    end

    tas5805_i2c_master #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .I2C_FREQ_HZ(I2C_FREQ_HZ),
        .DEV_ADDR(DEV_ADDR)
    ) u_i2c (
        .clk(clk),
        .rst_n(rst_n),
        .start(i2c_start),
        .reg_addr(i2c_reg_addr),
        .reg_data(i2c_reg_data),
        .busy(i2c_busy),
        .done(i2c_done),
        .ack_error(i2c_ack_error),
        .scl(scl),
        .sda(sda)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= WAIT_ENABLE;
            delay_cnt    <= 32'd0;
            delay_target <= 32'd0;
            init_idx     <= 16'd0;
            i2c_start    <= 1'b0;
            i2c_reg_addr <= 8'd0;
            i2c_reg_data <= 8'd0;
            pdn          <= 1'b0;
            busy         <= 1'b0;
            init_done    <= 1'b0;
            error        <= 1'b0;
        end else begin
            i2c_start <= 1'b0;

            case (state)
                WAIT_ENABLE: begin
                    pdn       <= 1'b0;
                    busy      <= 1'b0;
                    init_done <= 1'b0;
                    error     <= 1'b0;
                    delay_cnt <= 32'd0;
                    init_idx  <= 16'd0;
                    if (enable) begin
                        busy  <= 1'b1;
                        state <= PDN_LOW;
                    end
                end

                PDN_LOW: begin
                    pdn <= 1'b0;
                    if (delay_cnt >= PDN_LOW_CYCLES) begin
                        delay_cnt <= 32'd0;
                        pdn       <= 1'b1;
                        state     <= SETTLE;
                    end else begin
                        delay_cnt <= delay_cnt + 32'd1;
                    end
                end

                SETTLE: begin
                    pdn <= 1'b1;
                    if (delay_cnt >= PDN_SETTLE_CYCLES) begin
                        delay_cnt <= 32'd0;
                        init_idx  <= 16'd0;
                        state     <= ROM_READ;
                    end else begin
                        delay_cnt <= delay_cnt + 32'd1;
                    end
                end

                ROM_READ: begin
                    // init_entry 在上面的同步读 always 中更新。
                    state <= INIT_REQ;
                end

                INIT_REQ: begin
                    if (init_idx >= INIT_COUNT) begin
                        delay_cnt <= 32'd0;
                        state     <= UNMUTE;
                    end else if (init_entry == 16'hFFFF) begin
                        delay_cnt <= 32'd0;
                        state     <= UNMUTE;
                    end else if (init_entry[15:8] == 8'hfe) begin
                        // 0xFE: 延时条目，低 8 位为毫秒数。
                        delay_target <= MS_CYCLES * init_entry[7:0];
                        delay_cnt    <= 32'd0;
                        state        <= INIT_DELAY;
                    end else if (init_entry[15:8] == 8'hff) begin
                        // 0xFF: 元命令，当前序列未使用，跳过。
                        init_idx <= init_idx + 16'd1;
                        state    <= ROM_READ;
                    end else if (init_entry[15:8] == 8'hfd) begin
                        // 0xFD: burst 写，当前控制器不支持。
                        error <= 1'b1;
                        pdn   <= 1'b0;
                        busy  <= 1'b0;
                        state <= ERROR;
                    end else begin
                        i2c_reg_addr <= init_entry[15:8];
                        i2c_reg_data <= init_entry[7:0];
                        i2c_start    <= 1'b1;
                        state        <= INIT_WAIT;
                    end
                end

                INIT_DELAY: begin
                    if (delay_cnt >= delay_target) begin
                        delay_cnt <= 32'd0;
                        init_idx  <= init_idx + 16'd1;
                        state     <= ROM_READ;
                    end else begin
                        delay_cnt <= delay_cnt + 32'd1;
                    end
                end

                INIT_WAIT: begin
                    if (i2c_done) begin
                        if (i2c_ack_error) begin
                            error <= 1'b1;
                            pdn   <= 1'b0;
                            busy  <= 1'b0;
                            state <= ERROR;
                        end else begin
                            init_idx <= init_idx + 16'd1;
                            state    <= ROM_READ;
                        end
                    end
                end

                UNMUTE: begin
                    if (delay_cnt >= UNMUTE_CYCLES) begin
                        init_done <= 1'b1;
                        busy      <= 1'b0;
                        state     <= RUN;
                    end else begin
                        delay_cnt <= delay_cnt + 32'd1;
                    end
                end

                RUN: begin
                    if (!enable) begin
                        pdn       <= 1'b0;
                        init_done <= 1'b0;
                        busy      <= 1'b0;
                        state     <= WAIT_ENABLE;
                    end
                end

                ERROR: begin
                    pdn   <= 1'b0;
                    busy  <= 1'b0;
                    if (!enable) begin
                        error <= 1'b0;
                        state <= WAIT_ENABLE;
                    end
                end

                default: state <= WAIT_ENABLE;
            endcase
        end
    end

endmodule
