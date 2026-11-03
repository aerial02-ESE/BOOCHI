/*
 * 分数累加采样节拍发生器。
 * 输入 clk 是合成核心的系统时钟；rst_n 在上升沿同步、低有效。复位期间清零余数并
 * 压低 sample_tick。复位释放后，sample_tick 只在 clk 上升沿更新，并在需要产生一个
 * 新采样点的那个周期保持高电平一个时钟，供上层调度器启动一次声部遍历。
 *
 * 每拍把 SAMPLE_RATE_HZ 加入余数；和达到 CLK_FREQ_HZ 时减去 CLK_FREQ_HZ 并输出
 * 一个脉冲。这等价于保存“尚未兑换成采样点”的分数时钟，因此长期平均频率精确为
 * SAMPLE_RATE_HZ。若直接使用 CLK_FREQ_HZ / SAMPLE_RATE_HZ 的整数商作分频，在
 * 100 MHz / 48 kHz 这类不能整除的配置下会丢掉余数，造成持续的采样率和音高误差。
 */
module sample_tick_gen #(
    // 单位 Hz，合法范围 SAMPLE_RATE_HZ+1 及以上；越高则每个采样周期可用调度拍数越多。
    // 本模块无 ROM；修改它本身不需重生成表，但顶层相位增量按采样率而非系统时钟计算。
    parameter integer CLK_FREQ_HZ = 100000000,
    // 单位 Hz，合法范围 1..CLK_FREQ_HZ-1；决定采样时序和 DDS 音高换算。
    // 在完整核心中修改此值必须重生成 note_phase_rom.mem，波表内容本身无需重生成。
    parameter integer SAMPLE_RATE_HZ = 48000,
    // 0=使用上述分数累加器；>0=每固定时钟数产生一次节拍，用于与同源串行帧精确锁定。
    parameter integer SAMPLE_PERIOD_CYCLES = 0
) (
    // 系统逻辑时钟，实际频率必须与 CLK_FREQ_HZ 参数一致。
    input  wire clk,
    // 同步低有效复位；为 0 时清零分数余数并压低 sample_tick。
    input  wire rst_n,
    // 单周期采样使能；长期平均每秒产生 SAMPLE_RATE_HZ 个脉冲。
    output reg  sample_tick
);
    // 保存 [0, CLK_FREQ_HZ-1] 范围内的分数余数；integer 足以覆盖默认 100 MHz。
    integer phase_accumulator;
    integer exact_cycle_counter;

    always @(posedge clk) begin
        if (!rst_n) begin
            phase_accumulator <= 0;
            exact_cycle_counter <= 0;
            sample_tick <= 1'b0;
        // 同源音频时钟模式：消除分数 Hz 参数与整数串行分频之间的长期漂移。
        end else if (SAMPLE_PERIOD_CYCLES > 0) begin
            phase_accumulator <= 0;
            if (exact_cycle_counter >= SAMPLE_PERIOD_CYCLES - 1) begin
                exact_cycle_counter <= 0;
                sample_tick <= 1'b1;
            end else begin
                exact_cycle_counter <= exact_cycle_counter + 1;
                sample_tick <= 1'b0;
            end
        // 越过阈值时保留减法后的余数，而不是把累加器粗暴清零。
        end else if ((phase_accumulator + SAMPLE_RATE_HZ) >= CLK_FREQ_HZ) begin
            exact_cycle_counter <= 0;
            phase_accumulator <= phase_accumulator + SAMPLE_RATE_HZ - CLK_FREQ_HZ;
            sample_tick <= 1'b1;
        end else begin
            phase_accumulator <= phase_accumulator + SAMPLE_RATE_HZ;
            sample_tick <= 1'b0;
        end
    end
endmodule
