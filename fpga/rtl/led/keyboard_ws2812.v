`timescale 1ns / 1ps

// Parameterized USB88 key segment; direction is independent for each strip.
// Registered NRZ output, GRB/MSB first. No frame RAM or audio backpressure.
module keyboard_ws2812 #(
    parameter integer NUM_LEDS = 30,
    parameter integer KEY_START = 0,
    parameter integer KEY_COUNT = 30,
    parameter integer REVERSE = 1,
    parameter integer LED_OFFSET = 0,
    parameter integer CLK_HZ = 50_000_000,
    parameter integer REFRESH_HZ = 60,
    // WS2812B-V5 timing at 50 MHz: 0=.34/.96 us, 1=.70/.60 us.
    parameter integer BIT_CYCLES = 65,
    parameter integer T0H_CYCLES = 17,
    parameter integer T1H_CYCLES = 35,
    parameter integer RESET_US = 400
) (
    input wire clk,
    input wire rst_n,
    input wire [87:0] pressed_keys,
    input wire practice_mode,
    input wire [87:0] guide_keys, correct_keys, incorrect_keys,
    output reg dout
);
    localparam integer FRAME_CYCLES = CLK_HZ / REFRESH_HZ;
    localparam integer RESET_CYCLES = (CLK_HZ / 1_000_000) * RESET_US;
    localparam integer FRAME_W = $clog2(FRAME_CYCLES+1);
    localparam integer RESET_W = $clog2(RESET_CYCLES+1);
    localparam integer BIT_W = $clog2(BIT_CYCLES+1);
    localparam RESET=0, IDLE=1, LOAD=2, SEND=3;
    reg [1:0] state;
    reg [FRAME_W-1:0] frame_count;
    reg [RESET_W-1:0] reset_count;
    reg [BIT_W-1:0] bit_count;
    reg [$clog2(NUM_LEDS)-1:0] led_index;
    reg [4:0] bit_index;
    // One 2-bit color code per usable LED avoids four wide snapshot/mux trees.
    reg [2*KEY_COUNT-1:0] color_snapshot;
    reg practice_snapshot;
    integer i;
    reg [23:0] word_grb;
    reg [7:0] hue, hue_snapshot;
    reg hue_divide;
    wire frame_tick = frame_count == FRAME_CYCLES-1;
    wire [9:0] color_position = {2'b0,hue_snapshot} + (led_index*10'd6);
    wire [9:0] wrapped_position = color_position >= 384 ? color_position-10'd384 :
                                 color_position >= 192 ? color_position-10'd192 : color_position;
    wire [6:0] active_index = led_index - LED_OFFSET;
    wire [6:0] local_index = REVERSE ? KEY_COUNT-1-active_index : active_index;
    wire [1:0] color_code = color_snapshot >> (local_index*2);

    // Constant RGB sum=63 (~quarter-channel brightness), smooth 192-step wheel.
    function [23:0] color_wheel(input [7:0] position);
        reg [7:0] red,green,blue;
        begin
            red=0;green=0;blue=0;
            if(position<64) begin red=63-position;green=position;end
            else if(position<128) begin green=127-position;blue=position-64;end
            else begin blue=191-position;red=position-128;end
            color_wheel={green,red,blue};
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            frame_count<=0;hue<=0;hue_divide<=0;
        end else if(frame_tick) begin
            frame_count<=0;hue_divide<=!hue_divide;
            if(hue_divide) hue <= hue==191 ? 8'd0 : hue+1'b1;
        end else frame_count<=frame_count+1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=RESET;dout<=0;reset_count<=0;bit_count<=0;
            led_index<=0;bit_index<=23;color_snapshot<=0;
            hue_snapshot<=0;word_grb<=0;
            practice_snapshot<=0;
        end else case(state)
            RESET: begin
                dout<=0;
                if(reset_count==RESET_CYCLES-1) begin reset_count<=0;state<=IDLE;end
                else reset_count<=reset_count+1'b1;
            end
            IDLE: begin
                dout<=0;
                if(frame_tick) begin
                    hue_snapshot<=hue;
                    practice_snapshot<=practice_mode;
                    for(i=0;i<KEY_COUNT;i=i+1)begin
                        if(practice_mode===1'b1)begin
                            if(pressed_keys[KEY_START+i]&&incorrect_keys[KEY_START+i])color_snapshot[2*i+:2]<=3;
                            else if(pressed_keys[KEY_START+i]&&correct_keys[KEY_START+i])color_snapshot[2*i+:2]<=2;
                            else if(guide_keys[KEY_START+i])color_snapshot[2*i+:2]<=1;
                            else color_snapshot[2*i+:2]<=0;
                        end else color_snapshot[2*i+:2]<=pressed_keys[KEY_START+i] ? 1 : 0;
                    end
                    led_index<=0;bit_index<=23;state<=LOAD;
                end
            end
            LOAD: begin
                word_grb<=0;
                if(led_index>=LED_OFFSET && led_index<LED_OFFSET+KEY_COUNT)begin
                    if(practice_snapshot===1'b1)begin
                        case(color_code)
                            3:word_grb<=24'h003f00;
                            2:word_grb<=24'h3f0000;
                            1:word_grb<=24'h000030;
                            default:word_grb<=0;
                        endcase
                    end else if(color_code!=0)word_grb<=color_wheel(wrapped_position[7:0]);
                end
                bit_count<=0;dout<=1;state<=SEND;
            end
            SEND: begin
                if(bit_count == (word_grb[bit_index] ? T1H_CYCLES : T0H_CYCLES)-1)
                    dout<=0;
                if(bit_count==BIT_CYCLES-1) begin
                    bit_count<=0;
                    if(bit_index!=0) begin bit_index<=bit_index-1'b1;dout<=1;end
                    else if(led_index==NUM_LEDS-1) begin state<=RESET;reset_count<=0;end
                    else begin led_index<=led_index+1'b1;bit_index<=23;state<=LOAD;end
                end else bit_count<=bit_count+1'b1;
            end
            default: begin state<=RESET;dout<=0;reset_count<=0;end
        endcase
    end

    // synthesis translate_off
    initial begin
        if(RESET_CYCLES<1 || T0H_CYCLES<1 || T1H_CYCLES<=T0H_CYCLES ||
           T1H_CYCLES>=BIT_CYCLES || FRAME_CYCLES<=NUM_LEDS*24*BIT_CYCLES+NUM_LEDS+RESET_CYCLES ||
           LED_OFFSET<0 || LED_OFFSET+KEY_COUNT>NUM_LEDS || KEY_START+KEY_COUNT>88)
            $fatal(1,"keyboard_ws2812: invalid timing/refresh parameters");
    end
    // synthesis translate_on
endmodule
