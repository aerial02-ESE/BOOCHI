`timescale 1ns/1ps
// UART return: A5 5A 02 10 | coherent 16-byte scoreboard | CRC16 big-endian.
module practice_report_tx #(parameter CLK_HZ=50000000,BAUD=1000000)(
 input wire clk,rst_n,input wire[7:0]session,flags,
 input wire[15:0]total,hits,wrong,misses,input wire[23:0]elapsed_ms,
 input wire[7:0]last_note,last_result,output reg tx
);
 localparam WAIT=0,CRC=1,LOAD=2,SEND=3;
 reg[1:0]state;reg[21:0]period_count;reg[127:0]payload;
 reg[15:0]crc;reg[7:0]crc_byte;reg[4:0]crc_index,byte_index;
 reg[2:0]crc_bit;reg[9:0]serial_word;reg[3:0]serial_bit;reg[15:0]baud_count;
 wire[7:0]next_byte=byte_index==0 ? 8'ha5 : byte_index==1 ? 8'h5a :
  byte_index==2 ? 8'h02 : byte_index==3 ? 8'h10 : byte_index==20 ? crc[15:8] :
  byte_index==21 ? crc[7:0] : payload[127:120];
 wire crc_top=crc[15]^crc_byte[7];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=WAIT;tx<=1;period_count<=0;payload<=0;crc<=16'hffff;crc_byte<=0;crc_index<=0;
   crc_bit<=0;byte_index<=0;serial_word<=10'h3ff;serial_bit<=0;baud_count<=0;
  end else case(state)
   WAIT:begin
    tx<=1;
    if(period_count==CLK_HZ/20-1)begin
     period_count<=0;
     payload<={session,flags,total,hits,wrong,misses,8'd0,elapsed_ms,last_note,last_result};
     crc<=16'hffff;crc_index<=0;crc_bit<=0;crc_byte<=8'h02;state<=CRC;
    end else period_count<=period_count+1'b1;
   end
   CRC:begin
    crc<=(crc<<1)^(crc_top ? 16'h1021 : 16'h0000);crc_byte<=crc_byte<<1;
    if(crc_bit==7)begin
     crc_bit<=0;
     if(crc_index>=2)payload<={payload[119:0],payload[127:120]};
     if(crc_index==17)begin byte_index<=0;state<=LOAD;end
     else begin
      crc_index<=crc_index+1'b1;
      // next byte, before incremented index is visible
      // Rotate the snapshot once per payload byte, restoring its order for TX.
      crc_byte<=crc_index==0 ? 8'h10 : crc_index==1 ? payload[127:120] : payload[119:112];
     end
    end else crc_bit<=crc_bit+1'b1;
   end
   LOAD:begin
    serial_word<={1'b1,next_byte,1'b0};serial_bit<=0;baud_count<=0;tx<=0;state<=SEND;
    if(byte_index>=4 && byte_index<20)payload<={payload[119:0],8'd0};
   end
   SEND:begin
    if(baud_count==CLK_HZ/BAUD-1)begin
     baud_count<=0;
     if(serial_bit==9)begin
      tx<=1;
      if(byte_index==21)state<=WAIT;
      else begin byte_index<=byte_index+1'b1;state<=LOAD;end
     end else begin serial_bit<=serial_bit+1'b1;tx<=serial_word[serial_bit+1'b1];end
    end else baud_count<=baud_count+1'b1;
   end
   default:state<=WAIT;
  endcase
 end
endmodule
