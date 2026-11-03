`timescale 1ns / 1ps

// 32 actual-PCM Goertzel bands; 2048 consecutive samples, then shared MAC.
// Q2.16 coefficients encode 2*cos(w). Input is reduced to signed 12 bits
// so the 32-bit recurrence has headroom at the lowest frequency.
// Unlike the earlier analyser, RAM reads have an explicit wait cycle and
// every cross-term is signed. Silence maps to zero, not a synthetic animation.
module spectrum_analyzer (
    input wire clk,
    input wire rst_n,
    input wire audio_valid,
    input wire signed [23:0] audio_sample,
    output reg [255:0] spectrum_levels,
    output reg [255:0] spectrum_peaks
);
    localparam FILL=0, INIT=1, ADDRESS=2, WAIT_RAM=3, MAC=4, ACC=5,
               POWER0=6, POWER1=7, POWER2=8, POWER3=9, LEVEL=10, EMIT=11;
    reg [3:0] state;
    reg signed [11:0] samples [0:2047];
    reg signed [17:0] coefficients [0:31];
    reg [10:0] fill_index, sample_index, read_address;
    reg [4:0] band;
    reg signed [11:0] sample_read, x;
    reg signed [17:0] coefficient;
    reg signed [31:0] s1, s2, scaled_s1;
    reg signed [49:0] product;
    reg signed [63:0] square1, square2, cross;
    reg signed [65:0] power_value;
    reg [7:0] target;
    wire signed [31:0] input_extended = {{20{x[11]}}, x};
    // These are the low 32 bits of the Q2.16 arithmetic shift.
    wire signed [31:0] product_scaled = product[47:16];
    reg [7:0] previous, previous_peak;
    wire [7:0] falling = previous > 8 ? previous - 8'd8 : 8'd0;
    wire [7:0] new_level = target >= previous ? target :
                          (target > falling ? target : falling);
    wire [7:0] falling_peak = previous_peak > 2 ? previous_peak - 8'd2 : 8'd0;
    initial $readmemb("src/spectrum_coefficients.mem", coefficients);

    // Log-like display, fixed gain. ~3 dB per 8 display units.
    function [7:0] power_to_level;
        input signed [65:0] p;
        integer bit_no;
        reg [7:0] result;
        reg [65:0] normalized;
        begin
            result = 0;
            normalized = 0;
            if (p > 0) begin
                for (bit_no=8; bit_no<65; bit_no=bit_no+1) begin
                    if (p[bit_no]) begin
                        if (bit_no >= 40)
                            result = 255;
                        else begin
                            normalized = p >> (bit_no-3);
                            result = (bit_no-8)*8 + normalized[2:0];
                        end
                    end
                end
            end
            power_to_level = result;
        end
    endfunction

    always @(posedge clk) begin
        if (state == FILL && audio_valid)
            samples[fill_index] <= audio_sample[23:12];
        sample_read <= samples[read_address];
        coefficient <= coefficients[band];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= FILL;
            fill_index <= 0;
            sample_index <= 0;
            read_address <= 0;
            band <= 0;
            s1 <= 0; s2 <= 0; x <= 0; product <= 0;
            scaled_s1 <= 0; square1 <= 0; square2 <= 0;
            cross <= 0; power_value <= 0; target <= 0;
            spectrum_levels <= 0;
            spectrum_peaks <= 0;
        end else begin
            case (state)
                FILL: if (audio_valid) begin
                    if (fill_index == 2047) begin
                        fill_index <= 0; band <= 0; state <= INIT;
                    end else fill_index <= fill_index + 1'b1;
                end
                INIT: begin s1 <= 0; s2 <= 0; sample_index <= 0; state <= ADDRESS; end
                ADDRESS: begin read_address <= sample_index; state <= WAIT_RAM; end
                WAIT_RAM: state <= MAC;
                MAC: begin x <= sample_read; product <= coefficient * s1; state <= ACC; end
                ACC: begin
                    s1 <= input_extended + product_scaled - s2;
                    s2 <= s1;
                    if (sample_index == 2047) state <= POWER0;
                    else begin sample_index <= sample_index + 1'b1; state <= ADDRESS; end
                end
                POWER0: begin
                    square1 <= s1 * s1; square2 <= s2 * s2;
                    product <= coefficient * s1; state <= POWER1;
                end
                POWER1: begin scaled_s1 <= product_scaled; state <= POWER2; end
                POWER2: begin cross <= scaled_s1 * s2; state <= POWER3; end
                POWER3: begin
                    // Prefetch the current band's display state before EMIT.
                    previous <= spectrum_levels[{band,3'b000} +: 8];
                    previous_peak <= spectrum_peaks[{band,3'b000} +: 8];
                    power_value <= $signed({{2{square1[63]}},square1}) +
                                   $signed({{2{square2[63]}},square2}) -
                                   $signed({{2{cross[63]}},cross});
                    state <= LEVEL;
                end
                LEVEL: begin target <= power_to_level(power_value); state <= EMIT; end
                EMIT: begin
                    spectrum_levels[{band,3'b000} +: 8] <= new_level;
                    spectrum_peaks[{band,3'b000} +: 8] <=
                        new_level >= falling_peak ? new_level : falling_peak;
                    if (band == 31) state <= FILL;
                    else begin band <= band + 1'b1; state <= INIT; end
                end
                default: state <= FILL;
            endcase
        end
    end
endmodule
