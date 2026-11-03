`timescale 1ns / 1ps

// One 480x272 screen. Top: actual PCM spectrum. Bottom: all 88 piano keys.
// Per-column ROM replaces divisions and pitch searches in the pixel path.
// The pixel path is split into two 50 MHz stages (text selection, then base
// colour + glyph lookup) so the LCD's 5-clock pixel window has timing margin.
module spectrum_keys_renderer #(
    parameter integer XY_REFRESH_CYCLES = 2_500_000
) (
    input wire clk,
    input wire rst_n,
    input wire frame_toggle,
    input wire active_video,
    input wire [9:0] pixel_x,
    input wire [8:0] pixel_y,
    input wire [3:0] instrument_mode,
    input wire [1:0] ui_label,
    input wire [6:0] ui_value,
    input wire ui_active,
    input wire [127:0] pressed_notes,
    input wire [255:0] spectrum_levels,
    input wire [255:0] spectrum_peaks,
    input wire signed [23:0] scope_l,
    input wire signed [23:0] scope_r,
    input wire scope_valid,
    input wire page_next,
    input wire page_set_valid,
    input wire [1:0] page_set,
    input wire [127:0] score_pitch_codes,
    input wire [31:0] score_instruments,
    input wire [63:0] score_rhythms,
    input wire [15:0] score_occupied,
    input wire [127:0] guide_notes,
    input wire [127:0] expected_notes,
    output reg [4:0] red_565,
    output reg [5:0] green_565,
    output reg [4:0] blue_565
);
    reg [31:0] columns [0:479];
    reg [31:0] column;
    reg frame_previous;
    reg [3:0] mode_frame;
    reg [127:0] mode_text_frame;
    reg [7:0] xy_hue;
    reg [2:0] xy_hue_div;
    function [15:0] xy_colour;
        input [7:0] hue;
        reg [5:0] ramp;
        begin
            ramp = {hue[4:0],1'b0};
            case(hue[7:5])
                0: xy_colour = {5'd31,ramp,5'd0};
                1: xy_colour = {~hue[4:0],6'd63,5'd0};
                2: xy_colour = {5'd0,6'd63,hue[4:0]};
                3: xy_colour = {5'd0,~ramp,5'd31};
                4: xy_colour = {hue[4:0],6'd0,5'd31};
                5: xy_colour = {5'd31,6'd0,~hue[4:0]};
                6: xy_colour = {5'd31,ramp,5'd0};
                default: xy_colour = {5'd31,~ramp,5'd0};
            endcase
        end
    endfunction
    reg [127:0] ui_text_frame;
    reg [127:0] keys_frame;
    reg [127:0] score_codes_frame;
    reg [31:0] score_instruments_frame;
    reg [63:0] score_rhythms_frame;
    reg [15:0] score_occupied_frame;
    reg [127:0] guide_frame, expected_frame;
    reg [255:0] levels_frame, peaks_frame;
    reg [8:0] bar_top_frame [0:31];
    reg [8:0] peak_y_frame [0:31];
    reg [4:0] bar_calc_idx;
    reg bar_calc_active;
    // Match 07 exactly: preserve the full 8x7-bit product before >> 8.
    // An inline multiply in the 9-bit destination context truncated the
    // product and made even loud spectrum bars only one pixel high.
    wire [14:0] level_height_product =
        spectrum_levels[bar_calc_idx*8 +: 8] * 7'd90;
    wire [14:0] peak_height_product =
        spectrum_peaks[bar_calc_idx*8 +: 8] * 7'd90;
    integer bar_init;
    wire [127:0] ui_text_line;

    initial $readmemh("src/screen_columns.mem", columns);
    always @(posedge clk) begin
        column <= columns[pixel_x < 480 ? pixel_x : 10'd0];
    end

    // ---------------- Real stereo Lissajous bitmap ----------------
    // Page 0 = 07 spectrum + keys; 1 = stereo XY; 2 = score guide.
    reg [1:0]   page, page_prev, page_frame;
    reg [21:0] xy_refresh_count;
    reg [23:0] xy_peak;
    reg [4:0] xy_shift_y;
    reg [127:0] page_text_frame;

    reg [119:0] xy_rows [0:135];
    reg [119:0] xy_line;
    reg [6:0]  xy_bx_d;
    reg [7:0]  xy_by_d;
    reg [6:0]  xy_plot_bx;
    reg [7:0]  xy_plot_by;
    reg [119:0] xy_plot_row;
    reg [1:0]  plot_state;
    reg        xy_clear_busy;
    reg [7:0]  xy_clear_idx;

    wire signed [23:0] sl = scope_l;
    wire signed [23:0] sr = scope_r;
    wire [23:0] abs_l = sl[23] ? (~sl + 24'd1) : sl;
    wire [23:0] abs_r = sr[23] ? (~sr + 24'd1) : sr;
    wire [23:0] sample_peak = (abs_l > abs_r) ? abs_l : abs_r;
    // Use one gain for both real PCM channels, preserving phase and relative
    // amplitude. 120x136 uses the same scale on X and Y.
    wire signed [23:0] bx_raw = 24'sd60 + (sl >>> xy_shift_y);
    wire signed [23:0] by_raw = 24'sd68 - (sr >>> xy_shift_y);

    function [4:0] shift_for_peak;
        input [23:0] peak;
        integer bit_index;
        reg found;
        begin
            shift_for_peak = 5'd9;
            found = 1'b0;
            for (bit_index = 23; bit_index >= 8; bit_index = bit_index - 1) begin
                if (!found && peak[bit_index]) begin
                    shift_for_peak = bit_index - 5;
                    found = 1'b1;
                end
            end
        end
    endfunction

    reg [6:0] plot_bx;
    reg [7:0] plot_by;
    always @(*) begin
        if (bx_raw < 0)              plot_bx = 7'd0;
        else if (bx_raw > 24'sd119)  plot_bx = 7'd119;
        else                         plot_bx = bx_raw[6:0];

        if (by_raw < 0)              plot_by = 8'd0;
        else if (by_raw > 24'sd135)  plot_by = 8'd135;
        else                         plot_by = by_raw[7:0];

    end

    wire [7:0] xy_by_calc = pixel_y[8:1];
    wire [6:0] xy_bx_calc = pixel_x[8:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page <= 2'd0;
            page_prev <= 2'd0;
            xy_refresh_count <= 22'd0;
            xy_peak <= 24'd0;
            xy_shift_y <= 5'd9;
            plot_state <= 2'd0;
            xy_clear_busy <= 1'b0;
            xy_clear_idx <= 8'd0;
        end else begin
            page_prev <= page;

            if (page_set_valid && page_set < 2'd3) begin
                page <= page_set;
            end else if (page_next) begin
                page <= (page == 2'd2) ? 2'd0 : page + 1'b1;
            end

            // Measure PCM on both pages, so XY is calibrated before entry.
            // Clear its plotted history every 50 ms while the page is visible.
            if (xy_refresh_count == XY_REFRESH_CYCLES - 1) begin
                xy_refresh_count <= 22'd0;
                if (xy_peak >= 24'd256)
                    xy_shift_y <= shift_for_peak(xy_peak);
                xy_peak <= 24'd0;
            end else begin
                xy_refresh_count <= xy_refresh_count + 1'b1;
                if (scope_valid && sample_peak > xy_peak)
                    xy_peak <= sample_peak;
            end

            if (page != page_prev && page == 2'd1) begin
                xy_clear_busy <= 1'b1;
                xy_clear_idx  <= 8'd0;
            end else if (page == 2'd1 && xy_refresh_count == XY_REFRESH_CYCLES - 1) begin
                xy_clear_busy <= 1'b1;
                xy_clear_idx  <= 8'd0;
            end else if (xy_clear_busy) begin
                if (xy_clear_idx == 8'd135)
                    xy_clear_busy <= 1'b0;
                else
                    xy_clear_idx <= xy_clear_idx + 1'b1;
            end

    // Two-step read-modify-write plot into the 120x136 XY bitmap.
            if (plot_state == 2'd0) begin
                if (scope_valid && !xy_clear_busy) begin
                    xy_plot_bx <= plot_bx;
                    xy_plot_by <= plot_by;
                    plot_state <= 2'd1;
                end
            end else if (plot_state == 2'd1) begin
                xy_plot_row <= xy_rows[xy_plot_by];
                plot_state  <= 2'd2;
            end else begin
                plot_state <= 2'd0;
            end
        end
    end

    // Simple dual-port: xys are read while the plot engine writes.
    always @(posedge clk) begin
        xy_line <= xy_rows[xy_by_calc];
        xy_bx_d <= xy_bx_calc;
        if (xy_clear_busy)
            xy_rows[xy_clear_idx] <= 120'd0;
        else if (plot_state == 2'd2)
            xy_rows[xy_plot_by] <= xy_plot_row | (120'd1 << xy_plot_bx);
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xy_hue <= 0; xy_hue_div <= 0;
            frame_previous <= 0;
            mode_frame <= 2'd0;
            mode_text_frame <= 0;
            ui_text_frame <= 0;
            keys_frame <= 0;
            score_codes_frame <= 0;
            score_instruments_frame <= 0;
            score_rhythms_frame <= 0;
            score_occupied_frame <= 0;
            guide_frame <= 0;
            expected_frame <= 0;
            levels_frame <= 0;
            peaks_frame <= 0;
            bar_calc_idx <= 0;
            bar_calc_active <= 0;
            for (bar_init = 0; bar_init < 32; bar_init = bar_init + 1) begin
                bar_top_frame[bar_init] <= 9'd122;
                peak_y_frame[bar_init] <= 9'd122;
            end
        end else begin
            frame_previous <= frame_toggle;
            if (frame_previous != frame_toggle) begin
                xy_hue_div <= xy_hue_div + 1'b1;
                if (xy_hue_div == 0) xy_hue <= xy_hue + 1'b1;
                mode_frame <= instrument_mode;
                mode_text_frame <= (instrument_mode == 4'd11) ? "BELL            " :
                                   (instrument_mode == 4'd10) ? "E.BASS          " :
                                   (instrument_mode == 4'd9) ? "E.PIANO         " :
                                   (instrument_mode == 4'd8) ? "NYLON GUITAR    " :
                                   (instrument_mode == 4'd7) ? "TRUMPET         " :
                                   (instrument_mode == 4'd6) ? "VIOLIN          " :
                                   (instrument_mode == 4'd5) ? "CLARINET        " :
                                   (instrument_mode == 4'd4) ? "FLUTE           " :
                                   (instrument_mode == 2'd3) ? "SPLIT           " :
                                   (instrument_mode == 2'd2) ? "DRUM            " :
                                   (instrument_mode == 2'd1) ? "ORGAN           " :
                                                                "PIANO           ";
                ui_text_frame <= ui_active ? ui_text_line : "LIVE MIDI       ";
                page_frame <= page;
                page_text_frame <= (page == 2'd1) ? "LISSAJOUS       " :
                                       (page == 2'd2) ? "SCORE GUIDE     " :
                                                        "PCM SPECTRUM    ";
                keys_frame <= pressed_notes;
                score_codes_frame <= score_pitch_codes;
                score_instruments_frame <= score_instruments;
                score_rhythms_frame <= score_rhythms;
                score_occupied_frame <= score_occupied;
                guide_frame <= guide_notes;
                expected_frame <= expected_notes;
                levels_frame <= spectrum_levels;
                peaks_frame <= spectrum_peaks;
                bar_calc_idx <= 0;
                bar_calc_active <= 1;
            end else if (bar_calc_active) begin
                bar_top_frame[bar_calc_idx] <=
                    9'd122 - {2'b00, level_height_product[14:8]};
                peak_y_frame[bar_calc_idx] <=
                    9'd122 - {2'b00, peak_height_product[14:8]};
                if (bar_calc_idx == 5'd31)
                    bar_calc_active <= 0;
                else
                    bar_calc_idx <= bar_calc_idx + 1'b1;
            end
        end
    end

    function [34:0] font;
        input [7:0] c;
        begin
            case(c)
                "A":font={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "B":font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "C":font={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "D":font={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "E":font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "F":font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "G":font={5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110};
                "H":font={5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "I":font={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
                "K":font={5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                "L":font={5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "M":font={5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "N":font={5'b10001,5'b11001,5'b11001,5'b10101,5'b10011,5'b10011,5'b10001};
                "O":font={5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "P":font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "R":font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "S":font={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "T":font={5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "U":font={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "V":font={5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                "W":font={5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                "X":font={5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
                "Y":font={5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                "0":font={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1":font={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2":font={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3":font={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "4":font={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                "5":font={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                "6":font={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                "7":font={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                "8":font={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                "9":font={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                "-":font={5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
                "#":font={5'b01010,5'b01010,5'b11111,5'b01010,5'b11111,5'b01010,5'b01010};
                ":":font={5'b00000,5'b00100,5'b00100,5'b00000,5'b00100,5'b00100,5'b00000};
                ".":font={5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00100,5'b00100};
                default:font=0;
            endcase
        end
    endfunction
    function [7:0] text_character;
        input [127:0] text_line;
        input [4:0] index;
        begin
            text_character = index < 16 ? text_line[(15-index)*8 +: 8] : 8'h20;
        end
    endfunction

    function [23:0] three_digits;
        input [6:0] value;
        reg [6:0] v;
        reg [3:0] tens;
        begin
            v = value;
            if (v >= 7'd100) begin
                three_digits = {8'h31, 8'h30, 8'h30 + (v - 7'd100)};
            end else begin
                if (v >= 7'd90) begin tens = 4'd9; v = v - 7'd90; end
                else if (v >= 7'd80) begin tens = 4'd8; v = v - 7'd80; end
                else if (v >= 7'd70) begin tens = 4'd7; v = v - 7'd70; end
                else if (v >= 7'd60) begin tens = 4'd6; v = v - 7'd60; end
                else if (v >= 7'd50) begin tens = 4'd5; v = v - 7'd50; end
                else if (v >= 7'd40) begin tens = 4'd4; v = v - 7'd40; end
                else if (v >= 7'd30) begin tens = 4'd3; v = v - 7'd30; end
                else if (v >= 7'd20) begin tens = 4'd2; v = v - 7'd20; end
                else if (v >= 7'd10) begin tens = 4'd1; v = v - 7'd10; end
                else begin tens = 4'd0; end
                three_digits = {8'h30, 8'h30 + {4'b0, tens}, 8'h30 + {4'b0, v[3:0]}};
            end
        end
    endfunction

    assign ui_text_line = (ui_label == 2'd1) ?
        {"REVERB ", three_digits(ui_value), "      "} :
        {"CHORUS ", three_digits(ui_value), "      "};

    // Stage 1: text selection only (no column ROM dependency).
    reg [15:0] accent_s1;
    reg [7:0] character_s1;
    reg [2:0] glyph_x_s1, glyph_y_s1;
    reg [8:0] glyph_y_offset_s1;
    reg text_enable_s1;
    reg [15:0] text_colour_s1;
    reg score_inside_s1;
    reg [5:0] score_xlocal_s1;
    reg [6:0] score_ylocal_s1;
    reg [3:0] score_slot_s1;
    reg [7:0] score_code_s1;
    reg [1:0] score_inst_s1;
    reg [3:0] score_rhythm_s1;
    reg score_present_s1;
    always @(*) begin
        score_inside_s1 = pixel_x >= 10'd8 && pixel_x < 10'd472 &&
                          ((pixel_y >= 9'd39 && pixel_y < 9'd132) ||
                           (pixel_y >= 9'd144 && pixel_y < 9'd237));
        score_slot_s1 = 0;
        score_xlocal_s1 = 0;
        score_ylocal_s1 = 0;
        if (pixel_x < 10'd66) begin
            score_slot_s1 = 0; score_xlocal_s1 = pixel_x - 10'd8;
        end else if (pixel_x < 10'd124) begin
            score_slot_s1 = 1; score_xlocal_s1 = pixel_x - 10'd66;
        end else if (pixel_x < 10'd182) begin
            score_slot_s1 = 2; score_xlocal_s1 = pixel_x - 10'd124;
        end else if (pixel_x < 10'd240) begin
            score_slot_s1 = 3; score_xlocal_s1 = pixel_x - 10'd182;
        end else if (pixel_x < 10'd298) begin
            score_slot_s1 = 4; score_xlocal_s1 = pixel_x - 10'd240;
        end else if (pixel_x < 10'd356) begin
            score_slot_s1 = 5; score_xlocal_s1 = pixel_x - 10'd298;
        end else if (pixel_x < 10'd414) begin
            score_slot_s1 = 6; score_xlocal_s1 = pixel_x - 10'd356;
        end else begin
            score_slot_s1 = 7; score_xlocal_s1 = pixel_x - 10'd414;
        end
        if (pixel_y >= 9'd144) begin
            score_slot_s1 = score_slot_s1 + 4'd8;
            score_ylocal_s1 = pixel_y - 9'd144;
        end else if (pixel_y >= 9'd39) begin
            score_ylocal_s1 = pixel_y - 9'd39;
        end
        score_code_s1 = score_codes_frame[score_slot_s1*8 +: 8];
        score_inst_s1 = score_instruments_frame[score_slot_s1*2 +: 2];
        score_rhythm_s1 = score_rhythms_frame[score_slot_s1*4 +: 4];
        score_present_s1 = score_occupied_frame[score_slot_s1];
    end
    always @(*) begin
        accent_s1 = (mode_frame == 2'd3) ? 16'hfd20 :
                    (mode_frame == 2'd2) ? 16'hf800 :
                    (mode_frame == 2'd1) ? 16'h07e0 : 16'h07ff;
        character_s1 = " ";
        glyph_x_s1 = 0; glyph_y_s1 = 0; text_enable_s1 = 0;
        glyph_y_offset_s1 = 9'd0;
        text_colour_s1 = (pixel_y < 24 && pixel_x < 96) ? accent_s1 : 16'h8cf3;

        if (page_frame == 2'd2) begin
            text_colour_s1 = score_inst_s1 == 2'd2 ? 16'hfc28 :
                             score_inst_s1 == 2'd1 ? 16'h87e0 : 16'h67ff;
            if (pixel_x >= 184 && pixel_x < 280 &&
                pixel_y >= 10 && pixel_y < 17) begin
                character_s1 = text_character(page_text_frame, (pixel_x - 184) >> 3);
                glyph_x_s1 = pixel_x[2:0];
                glyph_y_s1 = (pixel_y - 9'd10) & 7;
                text_enable_s1 = 1;
            end else if (score_inside_s1 && score_present_s1) begin
                if (score_xlocal_s1 >= 18 && score_xlocal_s1 < 38 &&
                    score_ylocal_s1 >= 24 && score_ylocal_s1 < 52) begin
                    character_s1 = "0" + {5'd0, score_code_s1[2:0]};
                    glyph_x_s1 = (score_xlocal_s1 - 6'd18) >> 2;
                    glyph_y_s1 = (score_ylocal_s1 - 7'd24) >> 2;
                    text_enable_s1 = 1;
                end else if (score_code_s1[3] && score_xlocal_s1 >= 7 &&
                             score_xlocal_s1 < 12 && score_ylocal_s1 >= 28 &&
                             score_ylocal_s1 < 35) begin
                    character_s1 = "#";
                    glyph_x_s1 = score_xlocal_s1 - 6'd7;
                    glyph_y_s1 = score_ylocal_s1 - 7'd28;
                    text_enable_s1 = 1;
                end else if (score_xlocal_s1 >= 26 && score_xlocal_s1 < 31 &&
                             score_ylocal_s1 >= 70 && score_ylocal_s1 < 77) begin
                    character_s1 = (score_inst_s1 == 2'd2) ? "D" :
                                   (score_inst_s1 == 2'd1) ? "O" : "P";
                    glyph_x_s1 = score_xlocal_s1 - 6'd26;
                    glyph_y_s1 = score_ylocal_s1 - 7'd70;
                    text_enable_s1 = 1;
                end
            end else if (score_occupied_frame == 0 && pixel_x >= 200 &&
                         pixel_x < 264 && pixel_y >= 125 && pixel_y < 132) begin
                character_s1 = text_character("NO SCORE        ", (pixel_x - 200) >> 3);
                glyph_x_s1 = pixel_x[2:0];
                glyph_y_s1 = (pixel_y - 9'd125) & 7;
                text_enable_s1 = 1;
            end
        end else if (pixel_x >= 16 && pixel_x < 144 && pixel_y >= 5 && pixel_y < 19) begin
            if(mode_frame >= 4) begin
                character_s1 = text_character(mode_text_frame, (pixel_x - 16) >> 3);
                glyph_x_s1 = (pixel_x - 16) & 7;
                glyph_y_s1 = (pixel_y - 8) & 7;
                text_enable_s1 = pixel_y >= 8 && pixel_y < 15;
            end else begin
                character_s1 = text_character(mode_text_frame, (pixel_x - 16) >> 4);
                glyph_x_s1 = ((pixel_x - 16) >> 1) & 7;
                glyph_y_offset_s1 = pixel_y - 9'd5;
                glyph_y_s1 = glyph_y_offset_s1[3:1];
                text_enable_s1 = 1;
            end
        end else if (pixel_x >= 152 && pixel_x < 248 && pixel_y >= 10 && pixel_y < 17) begin
            character_s1 = text_character(page_text_frame, (pixel_x - 152) >> 3);
            glyph_y_offset_s1 = pixel_y - 9'd10;
            glyph_x_s1 = pixel_x[2:0]; glyph_y_s1 = glyph_y_offset_s1[2:0]; text_enable_s1 = 1;
        end else if (pixel_x >= 384 && pixel_x < 464 && pixel_y >= 10 && pixel_y < 17) begin
            character_s1 = text_character("KEY1: NEXT      ", (pixel_x - 384) >> 3);
            glyph_y_offset_s1 = pixel_y - 9'd10;
            glyph_x_s1 = pixel_x[2:0]; glyph_y_s1 = glyph_y_offset_s1[2:0]; text_enable_s1 = 1;
        end else if (pixel_x >= 8 && pixel_x < 120 && pixel_y >= 140 && pixel_y < 147) begin
            character_s1 = text_character("88 KEYS  A0-C8  ", (pixel_x - 8) >> 3);
            glyph_y_offset_s1 = pixel_y - 9'd140;
            glyph_x_s1 = pixel_x[2:0]; glyph_y_s1 = glyph_y_offset_s1[2:0]; text_enable_s1 = 1;
        end else if (pixel_x >= 384 && pixel_x < 464 && pixel_y >= 140 && pixel_y < 147) begin
            character_s1 = text_character(ui_text_frame, (pixel_x - 384) >> 3);
            glyph_y_offset_s1 = pixel_y - 9'd140;
            glyph_x_s1 = pixel_x[2:0]; glyph_y_s1 = glyph_y_offset_s1[2:0]; text_enable_s1 = 1;
        end else if (pixel_y >= 126 && pixel_y < 133) begin
            if (pixel_x >= 16 && pixel_x < 32)
                character_s1 = text_character("24              ", (pixel_x - 16) >> 3);
            else if (pixel_x >= 112 && pixel_x < 136)
                character_s1 = text_character("167             ", (pixel_x - 112) >> 3);
            else if (pixel_x >= 240 && pixel_x < 272)
                character_s1 = text_character("1K              ", (pixel_x - 240) >> 3);
            else if (pixel_x >= 352 && pixel_x < 384)
                character_s1 = text_character("4.7K            ", (pixel_x - 352) >> 3);
            else if (pixel_x >= 440 && pixel_x < 464)
                character_s1 = text_character("12K             ", (pixel_x - 440) >> 3);
            glyph_y_offset_s1 = pixel_y - 9'd126;
            glyph_x_s1 = pixel_x[2:0]; glyph_y_s1 = glyph_y_offset_s1[2:0]; text_enable_s1 = 1;
        end
    end

    reg [7:0] character_d;
    reg [2:0] glyph_x_d, glyph_y_d;
    reg text_enable_d;
    reg [15:0] text_colour_d;
    reg [9:0] pixel_x_d;
    reg [8:0] pixel_y_d;
    reg active_video_d;
    reg score_inside_d, score_present_d;
    reg [5:0] score_xlocal_d;
    reg [6:0] score_ylocal_d;
    reg [3:0] score_slot_d;
    reg [7:0] score_code_d;
    reg [1:0] score_inst_d;
    reg [3:0] score_rhythm_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            character_d <= " ";
            glyph_x_d <= 0; glyph_y_d <= 0;
            text_enable_d <= 0; text_colour_d <= 0;
            pixel_x_d <= 0; pixel_y_d <= 0; active_video_d <= 0;
            score_inside_d <= 0; score_present_d <= 0;
            score_xlocal_d <= 0; score_ylocal_d <= 0;
            score_slot_d <= 0; score_code_d <= 0; score_inst_d <= 0;
            score_rhythm_d <= 0;
        end else begin
            character_d <= character_s1;
            glyph_x_d <= glyph_x_s1;
            glyph_y_d <= glyph_y_s1;
            text_enable_d <= text_enable_s1;
            text_colour_d <= text_colour_s1;
            pixel_x_d <= pixel_x;
            pixel_y_d <= pixel_y;
            active_video_d <= active_video;
            score_inside_d <= score_inside_s1;
            score_present_d <= score_present_s1;
            score_xlocal_d <= score_xlocal_s1;
            score_ylocal_d <= score_ylocal_s1;
            score_slot_d <= score_slot_s1;
            score_code_d <= score_code_s1;
            score_inst_d <= score_inst_s1;
            score_rhythm_d <= score_rhythm_s1;
        end
    end

    // Stage 2: base spectrum/key colour, C-key text, glyph, final colour.
    reg [15:0] accent_s2, colour_base, colour_final;
    reg [7:0] character_final;
    reg [2:0] glyph_x_final, glyph_y_final;
    reg text_enable_final;
    reg [15:0] text_colour_final;
    reg [34:0] glyph_final;
    reg [7:0] level_value, peak_value;
    reg [8:0] bar_top, peak_y;
    reg [3:0] key_offset;
    reg [8:0] glyph_y_offset_s2;
    always @(*) begin
        accent_s2 = (mode_frame == 2'd3) ? 16'hfd20 :
                    (mode_frame == 2'd2) ? 16'hf800 :
                    (mode_frame == 2'd1) ? 16'h07e0 : 16'h07ff;
        colour_base = 16'h0000;
        key_offset = column[30:27];
        glyph_y_offset_s2 = 9'd0;
        level_value = levels_frame[{column[20:16],3'b000} +: 8];
        peak_value = peaks_frame[{column[20:16],3'b000} +: 8];
        bar_top = bar_top_frame[column[20:16]];
        peak_y = peak_y_frame[column[20:16]];

        if (pixel_y_d == 24 || pixel_y_d == 135 || pixel_y_d == 152)
            colour_base = 16'h1945;
        if (pixel_x_d >= 16 && pixel_x_d < 464 && pixel_y_d >= 28 && pixel_y_d <= 122) begin
            if (pixel_y_d == 42 || pixel_y_d == 62 || pixel_y_d == 82 ||
                pixel_y_d == 102 || pixel_y_d == 122 ||
                pixel_x_d == 16 || pixel_x_d == 128 || pixel_x_d == 240 ||
                pixel_x_d == 352 || pixel_x_d == 463)
                colour_base = 16'h10c3;
            if (column[21] && level_value != 0 && pixel_y_d >= bar_top && pixel_y_d < 122) begin
                if (pixel_x_d < 160)
                    colour_base = pixel_y_d < bar_top + 3 ? 16'ha7f0 : 16'h07a6;
                else if (pixel_x_d < 310)
                    colour_base = pixel_y_d < bar_top + 3 ? 16'hbfff : 16'h05fb;
                else
                    colour_base = pixel_y_d < bar_top + 3 ? 16'hc7ff : 16'h03df;
            end
            if (column[21] && peak_value > 4 && pixel_y_d == peak_y)
                colour_base = 16'hdfff;
        end

        // 52 white and 36 black keys; white width=9, black width=6.
        if (pixel_x_d >= 6 && pixel_x_d < 474 && pixel_y_d >= 157 && pixel_y_d < 264) begin
            colour_base = keys_frame[column[6:0]] ? accent_s2 :
                          expected_frame[column[6:0]] ? 16'hffff :
                          guide_frame[column[6:0]] ? 16'h3bff : 16'he73c;
            if (pixel_y_d >= 258)
                colour_base = keys_frame[column[6:0]] ? accent_s2 :
                              expected_frame[column[6:0]] ? 16'hffff :
                              guide_frame[column[6:0]] ? 16'h3bff : 16'had75;
            if (column[15])
                colour_base = 16'h0000;
            if (column[14] && pixel_y_d < 223) begin
                colour_base = keys_frame[column[13:7]] ?
                              ((mode_frame == 2'd3) ? 16'hfd20 :
                               (mode_frame == 2'd2) ? 16'hf820 :
                               (mode_frame == 2'd1) ? 16'h05e0 : 16'h04d6) :
                              expected_frame[column[13:7]] ? 16'hffff :
                              guide_frame[column[13:7]] ? 16'h3bff : 16'h0821;
                if (pixel_y_d >= 217)
                    colour_base = keys_frame[column[13:7]] ? accent_s2 :
                                  expected_frame[column[13:7]] ? 16'hffff :
                                  guide_frame[column[13:7]] ? 16'h3bff : 16'h3186;
            end
        end

        if (column[22] && pixel_y_d >= 246 && pixel_y_d < 253 &&
            key_offset >= 2 && key_offset < 7) begin
            character_final = "0" + column[26:23];
            glyph_y_offset_s2 = pixel_y_d - 9'd246;
            glyph_x_final = key_offset[2:0] - 3'd2;
            glyph_y_final = glyph_y_offset_s2[2:0];
            text_enable_final = 1;
            text_colour_final = 16'h3186;
        end else begin
            character_final = character_d;
            glyph_x_final = glyph_x_d;
            glyph_y_final = glyph_y_d;
            text_enable_final = text_enable_d;
            text_colour_final = text_colour_d;
        end

        glyph_final = font(character_final);
        colour_final = colour_base;
        if (page_frame == 2'd2) begin
            colour_final = 16'h0023;
            if (pixel_y_d == 26 || pixel_y_d == 249)
                colour_final = 16'h1945;
            if (score_inside_d) begin
                colour_final = score_present_d ? 16'h1085 : 16'h0823;
                if (score_xlocal_d == 0 || score_xlocal_d == 57 ||
                    score_ylocal_d == 0 || score_ylocal_d == 92)
                    colour_final = (score_slot_d == 0) ? 16'h67ff : 16'h2988;
                if (score_present_d &&
                    ((score_code_d[7:4] > 4 && score_ylocal_d == 16) ||
                     (score_code_d[7:4] < 4 && score_ylocal_d == 57)) &&
                    score_xlocal_d >= 26 && score_xlocal_d <= 30)
                    colour_final = score_inst_d == 2'd2 ? 16'hfc28 :
                                   score_inst_d == 2'd1 ? 16'h87e0 : 16'h67ff;
                if (score_present_d) begin
                    // Duration is quantised from recorded milliseconds:
                    // short = double underline; long = trailing dashes.
                    if (score_rhythm_d[1:0] == 2'd0 &&
                        (score_ylocal_d == 59 || score_ylocal_d == 63) &&
                        score_xlocal_d >= 18 && score_xlocal_d <= 38)
                        colour_final = 16'hffff;
                    if (score_rhythm_d[1] && score_ylocal_d == 43 &&
                        score_xlocal_d >= 40 &&
                        score_xlocal_d <= (score_rhythm_d[0] ? 55 : 48))
                        colour_final = 16'hffff;
                    // A linked onset marks another note in the same chord.
                    if (score_rhythm_d[2] && score_xlocal_d == 4 &&
                        score_ylocal_d >= 28 && score_ylocal_d <= 48)
                        colour_final = 16'h67ff;
                    // Small top bar marks a long gap before this onset.
                    if (score_rhythm_d[3] && score_ylocal_d == 9 &&
                        score_xlocal_d >= 20 && score_xlocal_d <= 36)
                        colour_final = 16'h87e0;
                end
            end
        end
        if (text_enable_final && glyph_x_final < 5 && glyph_y_final < 7 &&
            glyph_final[34-glyph_y_final*5-glyph_x_final])
            colour_final = text_colour_final;
        if (page_frame == 2'd1)
            colour_final = xy_line[xy_bx_d] ? xy_colour(xy_hue + {1'b0,pixel_x_d[8:2]}) : 16'h0000;
        if (!active_video_d)
            colour_final = 0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin red_565 <= 0; green_565 <= 0; blue_565 <= 0; end
        else begin
            red_565 <= colour_final[15:11];
            green_565 <= colour_final[10:5];
            blue_565 <= colour_final[4:0];
        end
    end
endmodule
