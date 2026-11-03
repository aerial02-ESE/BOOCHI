`timescale 1ns / 1ps

// 480 x 272 parallel RGB timing for RFHM-EP4306-DCT.
// The data sheet's 24-bit RGB table specifies:
//   DCLK: 8..12 MHz (9 MHz typical)
//   H: 4 sync + 43 back porch + 480 active + 4 front porch = 531 clocks
//   V: 4 sync + 12 back porch + 272 active + 4 front porch = 292 lines
// The 50 MHz board oscillator is divided by five, giving a legal 10 MHz
// pixel clock and 64.4 Hz refresh. Pixel coordinates advance on the falling
// edge of the generated clock so RGB data is stable before its rising edge.
module lcd_rgb_timing (
    input  wire       clk_50m,
    input  wire       rst_n,
    output reg        lcd_pclk,
    output reg        lcd_hsync,
    output reg        lcd_vsync,
    output reg        lcd_de,
    output reg        active_video,
    output reg [9:0]  pixel_x,
    output reg [8:0]  pixel_y,
    output reg        frame_toggle
);

    localparam [9:0] H_SYNC   = 10'd4;
    localparam [9:0] H_BACK   = 10'd43;
    localparam [9:0] H_ACTIVE = 10'd480;
    localparam [9:0] H_FRONT  = 10'd4;
    localparam [9:0] H_TOTAL  = H_SYNC + H_BACK + H_ACTIVE + H_FRONT;

    localparam [8:0] V_SYNC   = 9'd4;
    localparam [8:0] V_BACK   = 9'd12;
    localparam [8:0] V_ACTIVE = 9'd272;
    localparam [8:0] V_FRONT  = 9'd4;
    localparam [8:0] V_TOTAL  = V_SYNC + V_BACK + V_ACTIVE + V_FRONT;

    reg [2:0] clk_div;
    reg [9:0] h_count;
    reg [8:0] v_count;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            clk_div      <= 3'd0;
            lcd_pclk     <= 1'b0;
            h_count      <= 10'd0;
            v_count      <= 9'd0;
            frame_toggle <= 1'b0;
        end else begin
            case (clk_div)
                3'd4: begin
                    // Rising edge of the 10 MHz clock.
                    clk_div  <= 3'd0;
                    lcd_pclk <= 1'b1;
                end
                3'd1: begin
                    // Falling edge: advance timing and change the RGB source.
                    clk_div  <= 3'd2;
                    lcd_pclk <= 1'b0;
                    if (h_count == H_TOTAL - 1'b1) begin
                        h_count <= 10'd0;
                        if (v_count == V_TOTAL - 1'b1) begin
                            v_count      <= 9'd0;
                            frame_toggle <= ~frame_toggle;
                        end else begin
                            v_count <= v_count + 1'b1;
                        end
                    end else begin
                        h_count <= h_count + 1'b1;
                    end
                end
                default: begin
                    clk_div <= clk_div + 1'b1;
                end
            endcase
        end
    end

    always @(*) begin
        // The timing illustration in the supplied panel data sheet shows
        // negative HSYNC and VSYNC pulses.
        lcd_hsync    = (h_count >= H_SYNC);
        lcd_vsync    = (v_count >= V_SYNC);
        active_video = (h_count >= (H_SYNC + H_BACK)) &&
                       (h_count <  (H_SYNC + H_BACK + H_ACTIVE)) &&
                       (v_count >= (V_SYNC + V_BACK)) &&
                       (v_count <  (V_SYNC + V_BACK + V_ACTIVE));
        lcd_de       = active_video;

        if (active_video) begin
            pixel_x = h_count - H_SYNC - H_BACK;
            pixel_y = v_count - V_SYNC - V_BACK;
        end else begin
            pixel_x = 10'd0;
            pixel_y = 9'd0;
        end
    end

endmodule
