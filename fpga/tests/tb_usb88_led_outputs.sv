`timescale 1ns/1ps
module ws2812_timing_check(input clk, rst, dout);
    integer cycle = 0, rise_at = 0, fall_at = 0, frame_at = 0;
    integer bit_number = 0, completed = 0;
    reg previous = 0;
    always @(posedge clk) begin
        #1;
        if (rst) begin
            cycle++;
            if (dout && !previous) begin
                if (bit_number == 0) begin
                    if (completed != 0 && cycle - frame_at != 833333)
                        $fatal(1, "Incorrect 60Hz frame period");
                    if (cycle - fall_at < 20000)
                        $fatal(1, "Reset low time below 400us");
                    frame_at = cycle;
                end else if (cycle - rise_at != ((bit_number % 24 == 0) ? 66 : 65))
                    $fatal(1, "Unexpected bit interval at %0d", bit_number);
                rise_at = cycle;
            end
            if (!dout && previous) begin
                if (cycle - rise_at != 17 && cycle - rise_at != 35)
                    $fatal(1, "Invalid high pulse");
                fall_at = cycle;
                bit_number++;
                if (bit_number == 45 * 24) begin
                    bit_number = 0;
                    completed++;
                end
            end
            previous = dout;
        end
    end
endmodule

module tb_usb88_led_outputs;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst = 0, valid = 0;
    reg [63:0] event_data = 0;
    wire left_dout, right_dout;
    wire [31:0] left_frames, right_frames;

    tang_mega_60k_spectrum_keys_top #(.USB_PORTS(0), .LED_AUDIO_ENABLE(0)) dut (
        .sys_clk_50m(clk), .sys_rst_n(rst), .key1_n(1'b1), .key2_n(1'b1),
        .esp_uart_rx(1'b1), .ulpi0_clk(clk), .ulpi0_dir(1'b0), .ulpi0_nxt(1'b0),
        .ulpi1_clk(clk), .ulpi1_dir(1'b0), .ulpi1_nxt(1'b0), .ctp_int(1'b1),
        .key_led_dout(left_dout), .key_led_high_dout(right_dout)
    );
    strip_decode #(.N(45)) left_strip(clk, rst, left_dout, left_frames);
    strip_decode #(.N(45)) right_strip(clk, rst, right_dout, right_frames);

    ws2812_timing_check left_timing(clk, rst, left_dout);
    ws2812_timing_check right_timing(clk, rst, right_dout);

    task automatic key(input bit on, input [7:0] pitch);
        @(negedge clk);
        event_data = {on ? 8'h41 : 8'h42, 8'h10, 8'h00, pitch, on ? 16'hffff : 16'h0000, 16'h0000};
        valid = 1;
        do @(posedge clk); while (!dut.usb0_ev50_ready);
        @(negedge clk);
        valid = 0;
        repeat (300) @(negedge clk);
    endtask

    initial begin
        force dut.usb0_ev50_valid = valid;
        force dut.usb0_ev50_data = event_data;
        repeat (8) @(negedge clk);
        rst = 1;
        repeat (300) @(negedge clk);
        key(1, 21);
        key(1, 108);
        wait (left_frames == 1 && right_frames == 1);
        @(negedge clk);
        if (left_strip.pixels[44] == 0 || right_strip.pixels[44] == 0)
            $fatal(1, "USB A0/C8 did not reach both WS2812 outputs");
        for (int i = 0; i < 44; i++)
            if (left_strip.pixels[i] !== 0 || right_strip.pixels[i] !== 0)
                $fatal(1, "Unexpected LED at position %0d", i);
        key(0, 21);
        key(0, 108);
        wait (left_frames == 2 && right_frames == 2);
        @(negedge clk);
        for (int i = 0; i < 45; i++)
            if (left_strip.pixels[i] !== 0 || right_strip.pixels[i] !== 0)
                $fatal(1, "LED held after release at position %0d", i);
        $display("PASS top-level USB88 events drive actual W22/P17 WS2812 data at 60Hz");
        $display("PASS timing: 17/35-clock highs, 65/66-clock bit starts, 1080 bits/frame, >=400us reset and 60Hz frame period");
        $finish;
    end
    initial begin
        #50_000_000;
        $fatal(1, "WS2812 end-to-end timeout");
    end
endmodule
