`timescale 1ns/1ps
module strip_decode #(parameter N=30)(input clk,rst_n,din,output reg[31:0] frames=0);
 integer h=0,bits=0;reg prev=0;reg[23:0]w=0;reg[23:0]pixels[0:N-1];
 always @(posedge clk)begin #1;
  if(!rst_n)begin h=0;bits=0;prev=0;frames=0;end
  else begin
   if(din)h++;
   else if(prev)begin
    if(h!=17&&h!=35)$fatal(1,"bad pulse");
    w={w[22:0],h==35};bits++;
    if(bits%24==0)pixels[bits/24-1]=w;
    if(bits==N*24)begin frames++;bits=0;end
    h=0;
   end
   prev=din;
  end
 end
endmodule
module tb_dual_led88;
 reg clk=0;always #10 clk=~clk;reg rst=0;reg[87:0]keys=0;
 wire a,b;wire[31:0]fa,fb;
 keyboard_ws2812 #(.NUM_LEDS(45),.KEY_COUNT(44),.LED_OFFSET(1),.REFRESH_HZ(250)) lowstrip(.clk(clk),.rst_n(rst),.pressed_keys(keys),.practice_mode(1'b0),.guide_keys(88'd0),.correct_keys(88'd0),.incorrect_keys(88'd0),.dout(a));
 keyboard_ws2812 #(.NUM_LEDS(45),.KEY_START(44),.KEY_COUNT(44),.REVERSE(0),.LED_OFFSET(1),.REFRESH_HZ(250)) highstrip(.clk(clk),.rst_n(rst),.pressed_keys(keys),.practice_mode(1'b0),.guide_keys(88'd0),.correct_keys(88'd0),.incorrect_keys(88'd0),.dout(b));
 strip_decode #(.N(45)) da(clk,rst,a,fa);
 strip_decode #(.N(45)) db(clk,rst,b,fb);
 integer i;
 initial begin
  repeat(5)@(negedge clk);keys={88{1'b1}};rst=1;
  wait(fa==1&&fb==1);@(negedge clk);
  for(i=1;i<45;i++)if(da.pixels[i]==0||db.pixels[i]==0)$fatal(1,"active pixel missing %0d",i);
  if(da.pixels[0]!==0||db.pixels[0]!==0)$fatal(1,"unused near pixels lit");
  keys=88'd1 | (88'd1<<87);
  wait(fa==2&&fb==2);@(negedge clk);
  for(i=0;i<44;i++)if(da.pixels[i]!==0||db.pixels[i]!==0)$fatal(1,"outer key mapping");
  if(da.pixels[44]==0||db.pixels[44]==0)$fatal(1,"farthest pixels not A0/C8");
  keys=(88'd1<<43)|(88'd1<<44);
  wait(fa==3&&fb==3);@(negedge clk);
  for(i=0;i<45;i++)if(i!=1&&(da.pixels[i]!==0||db.pixels[i]!==0))$fatal(1,"inner key mapping");
  if(da.pixels[1]==0||db.pixels[1]==0)$fatal(1,"key44/45 boundary");
  keys=0;
  wait(fa==4&&fb==4);@(negedge clk);
  for(i=0;i<45;i++)if(da.pixels[i]!==0||db.pixels[i]!==0)$fatal(1,"idle LED remained lit");
  $display("PASS dual88 symmetric: W22/P17 45+45, nearest two dark, A0/C8 at far ends and 44/45 at seam");
  $finish;
 end
 initial begin #30_000_000;$fatal(1,"dual strip timeout");end
endmodule
