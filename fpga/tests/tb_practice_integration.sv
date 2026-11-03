`timescale 1ns/1ps
module tb_practice_integration;
 reg clk=0;always #10 clk=~clk;reg rst=0,rx=1;
 reg usb_valid=0;reg[63:0]usb_data=0;
 tang_mega_60k_spectrum_keys_top #(.USB_PORTS(0),.LED_AUDIO_ENABLE(0)) dut(
 .sys_clk_50m(clk),.sys_rst_n(rst),.key1_n(1'b1),.key2_n(1'b1),.esp_uart_rx(rx),
 .ulpi0_clk(clk),.ulpi0_dir(1'b0),.ulpi0_nxt(1'b0),.ulpi1_clk(clk),.ulpi1_dir(1'b0),.ulpi1_nxt(1'b0),.ctp_int(1'b1));
 reg[7:0]seq=0;reg[7:0]frame[0:13];reg[63:0]word;reg[15:0]crc;
 integer i,j;
 integer key_handshakes=0;
 always @(posedge clk)if(rst&&usb_valid&&dut.usb0_ev50_ready)key_handshakes++;
 task automatic tx_byte(input[7:0]b);
  @(negedge clk);rx=0;repeat(50)@(negedge clk);
  for(integer n=0;n<8;n++)begin rx=b[n];repeat(50)@(negedge clk);end
  rx=1;repeat(50)@(negedge clk);
 endtask
 task automatic send_frame(input[55:0]event_prefix);
  word={event_prefix,seq};seq++;
  frame[0]=8'ha5;frame[1]=8'h5a;frame[2]=1;frame[3]=8;
  for(i=0;i<8;i++)frame[4+i]=word>>((7-i)*8);
  crc=16'hffff;
  for(i=2;i<12;i++)begin crc^=frame[i]<<8;for(j=0;j<8;j++)crc=crc[15]?(crc<<1)^16'h1021:crc<<1;end
  frame[12]=crc[15:8];frame[13]=crc[7:0];
  for(i=0;i<14;i++)tx_byte(frame[i]);
  repeat(100)@(negedge clk);
 endtask
 task automatic command(input[5:0]kind,input[7:0]id,input[23:0]value);
  send_frame({2'b01,kind,8'h30,8'h00,id,value[15:0],value[23:16]});
 endtask
 task automatic key(input[7:0]note);
  @(negedge clk);usb_data={8'h41,8'h10,8'h00,note,16'hffff,16'd0};usb_valid=1;
  @(posedge clk);while(!dut.usb0_ev50_ready)@(posedge clk);
  @(negedge clk);usb_valid=0;repeat(2000)@(negedge clk);
 endtask
 initial begin
  force dut.usb0_ev50_valid=usb_valid;force dut.usb0_ev50_data=usb_data;
  repeat(8)@(negedge clk);rst=1;repeat(300)@(negedge clk);
  command(14,0,24'h050001);command(14,2,50);command(15,60,50);command(14,1,0);
  wait(dut.practice_elapsed==40);@(negedge clk);
  if(dut.u_audio_engine.piano_active!=0)$fatal(1,"score target caused automatic sound");
  key(64);wait(dut.practice_elapsed==50);key(60);repeat(20000)@(negedge clk);
  if(key_handshakes!=2||dut.practice_hits!=1||dut.practice_wrong!=1||dut.u_audio_engine.piano_active!=2)
   $fatal(1,"live USB/audio/scoring integration failed %0d/%0d/%0d",dut.practice_hits,dut.practice_wrong,dut.u_audio_engine.piano_active);
  $display("PASS UART/USB practice integration: score has no auto audio, human keys sound and generate correct/wrong results");
  send_frame(56'h4b2f0020000101);
  key(71);key(72);repeat(20000)@(negedge clk);
  if(dut.u_audio_engine.piano_active!=3 || dut.u_audio_engine.bass_active!=1)
   $fatal(1,"UART timbre command did not split the two audio engines");
  $display("PASS UART App timbre integration: B4 piano and C5 organ");
  send_frame(56'h4b2f0021000200);
  repeat(20) @(negedge clk);
  if(dut.u_renderer.page!==2)$fatal(1,"UART page select failed");
  send_frame(56'h4b2f0021000100);
  repeat(20) @(negedge clk);
  if(dut.u_renderer.page!==1)$fatal(1,"UART XY page select failed");
  $display("PASS UART screen selection: score and XY");
  $finish;
 end
 initial begin #100_000_000;$fatal(1,"practice integration timeout");end
endmodule
