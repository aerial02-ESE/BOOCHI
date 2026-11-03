`timescale 1ns/1ps
module tb_practice_led;
 reg clk=0;always #10 clk=~clk;reg rst=0;
 reg[87:0]keys=(88'd1<<0)|(88'd1<<87);
 wire a,b;wire[31:0]fa,fb;
 keyboard_ws2812 #(.NUM_LEDS(45),.KEY_COUNT(44),.LED_OFFSET(1),.REFRESH_HZ(250)) lowstrip(
 .clk(clk),.rst_n(rst),.pressed_keys(keys),.practice_mode(1'b1),.guide_keys(88'd1<<44),
 .correct_keys(88'd1),.incorrect_keys(88'd1<<87),.dout(a));
 keyboard_ws2812 #(.NUM_LEDS(45),.KEY_START(44),.KEY_COUNT(44),.LED_OFFSET(1),.REVERSE(0),.REFRESH_HZ(250)) highstrip(
 .clk(clk),.rst_n(rst),.pressed_keys(keys),.practice_mode(1'b1),.guide_keys(88'd1<<44),
 .correct_keys(88'd1),.incorrect_keys(88'd1<<87),.dout(b));
 strip_decode #(.N(45)) da(clk,rst,a,fa);strip_decode #(.N(45)) db(clk,rst,b,fb);
 initial begin
  repeat(5)@(negedge clk);rst=1;wait(fa==1&&fb==1);@(negedge clk);
  if(da.pixels[44]!==24'h3f0000)$fatal(1,"correct A0 not green");
  if(db.pixels[44]!==24'h003f00)$fatal(1,"wrong C8 not red");
  if(db.pixels[1]!==24'h000030)$fatal(1,"upcoming key45 not blue");
  if(da.pixels[0]!==0||db.pixels[0]!==0||da.pixels[1]!==0)$fatal(1,"unused pixels lit in practice");
  keys=0;wait(fa==2&&fb==2);@(negedge clk);
  if(da.pixels[44]!==0||db.pixels[44]!==0)$fatal(1,"judgement light held after release");
  $display("PASS practice physical LED decode: correct green, wrong red, blue guide, unused pixels black and release off");$finish;
 end
 initial begin #20_000_000;$fatal(1,"practice LEDs timeout");end
endmodule
