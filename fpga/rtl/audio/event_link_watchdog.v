/* 有效 UART 帧心跳看门狗；只在链路曾经活跃后产生一次超时脉冲。 */
module event_link_watchdog #(
    parameter integer TIMEOUT_CYCLES = 25_000_000
) (
    input  wire clk,
    input  wire rst_n,
    input  wire frame_seen,
    output reg  link_alive,
    output reg  timeout_pulse
);
    localparam integer EFFECTIVE_TIMEOUT = (TIMEOUT_CYCLES < 1) ? 1 : TIMEOUT_CYCLES;
    reg [31:0] counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= 32'd0;
            link_alive <= 1'b0;
            timeout_pulse <= 1'b0;
        end else begin
            timeout_pulse <= 1'b0;
            if (frame_seen) begin
                counter <= 32'd0;
                link_alive <= 1'b1;
            end else if (link_alive) begin
                if (counter >= EFFECTIVE_TIMEOUT - 1) begin
                    counter <= 32'd0;
                    link_alive <= 1'b0;
                    timeout_pulse <= 1'b1;
                end else begin
                    counter <= counter + 1'b1;
                end
            end
        end
    end
endmodule
