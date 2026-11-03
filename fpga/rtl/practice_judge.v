`timescale 1ns/1ps
// 64 rolling onsets, two 16-bit words each: 2048 bits in block RAM.
// Full song remains in ESP Flash. Target times are relative to START, ms.
module practice_judge #(
 parameter integer CLK_HZ=50000000,
 parameter integer WINDOW_MS=150,
 parameter integer GUIDE_MS=300
)(
 input wire clk,rst_n,panic,
 input wire command_valid,output wire command_ready,input wire[63:0] command_data,
 input wire key_valid,output wire key_ready,input wire[6:0] key_note,
 output reg active,display_mode,
 output wire[7:0] flags,output reg[7:0] session,
 output reg[15:0] total,hits,wrong,misses,
 output reg[23:0] elapsed_ms,
 output reg[7:0] last_note,last_result,
 output reg[87:0] guide,correct,incorrect
);
 localparam IDLE=0,READ_LO=1,CAP_LO=2,READ_HI=3,CAP_HI=4,APPLY=5,WRITE_LO=6,WRITE_HI=7,CALC=8,CHECK=9,
  CLEAR=10,FREE_READ=11,FREE_CAP=12,FREE_CHECK=13;
 reg[3:0]state;
 reg[15:0]targets[0:127] /* synthesis syn_ramstyle="block_ram" */;
 reg[15:0]read_word,low_word;
 reg[5:0]scan,write_ptr,best_index;
 reg[31:0]pending_target;
 reg[15:0]received;
 reg[23:0]final_at,last_target_time,key_at,scan_at;
 reg[6:0]pending_note;
 reg scan_key,found,finished,error,prepared,scan_due;
 reg[24:0]best_distance;
 reg[87:0]guide_work;
 reg[31:0]ms_count;
 reg[31:0]entry;
 reg[24:0]distance_q;
 reg[15:0]best_high;
 wire[23:0]entry_at=entry[23:0];
 wire[6:0]entry_note=entry[30:24];
 wire signed[24:0]delta=$signed({1'b0,key_at})-$signed({1'b0,entry_at});
 wire[24:0]distance=delta[24] ? -delta : delta;
 wire free_read=state==FREE_READ || state==FREE_CAP || state==FREE_CHECK;
 wire[6:0]read_address=free_read ? {write_ptr,1'b1} : {scan,(state==READ_HI || state==CAP_HI)};
 wire expire=state==CHECK && !scan_key && entry[31] && scan_at>entry_at+WINDOW_MS;
 wire ram_write=state==CLEAR || state==WRITE_LO || state==WRITE_HI || expire || (state==APPLY&&found);
 wire[6:0]write_address=state==CLEAR ? {scan,1'b1} : expire ? {scan,1'b1} :
  state==APPLY ? {best_index,1'b1} : {write_ptr,state==WRITE_HI};
 wire[15:0]write_data=state==CLEAR ? 16'd0 : expire ? {1'b0,entry[30:16]} :
  state==APPLY ? {1'b0,best_high[14:0]} : state==WRITE_HI ? pending_target[31:16] : pending_target[15:0];
 wire[23:0]incoming_time={command_data[15:8],command_data[31:16]};
 wire trusted=command_data[63:62]==1 && command_data[55:52]==3;
 wire[5:0]kind=command_data[61:56];
 reg[87:0]guide_next;
 assign flags={3'd0,prepared,display_mode,error,finished,active};
 assign command_ready=state==IDLE;
 assign key_ready=state==IDLE && !command_valid;
 always @* begin
  guide_next=guide_work;
  if(entry[31] && entry_note>=21 && entry_note<=108 &&
     entry_at<=scan_at+GUIDE_MS && entry_at+WINDOW_MS>=scan_at)
    guide_next[entry_note-21]=1;
 end
 always @(posedge clk)begin
  read_word<=targets[read_address];
  if(ram_write)targets[write_address]<=write_data;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=CLEAR;active<=0;display_mode<=0;session<=0;total<=0;hits<=0;wrong<=0;misses<=0;
   elapsed_ms<=0;last_note<=0;last_result<=0;guide<=0;correct<=0;incorrect<=0;
   scan<=0;write_ptr<=0;best_index<=0;best_high<=0;pending_target<=0;received<=0;
   final_at<=0;last_target_time<=0;key_at<=0;scan_at<=0;pending_note<=0;
   scan_key<=0;found<=0;finished<=0;error<=0;prepared<=0;scan_due<=0;
   best_distance<=25'h1ffffff;guide_work<=0;ms_count<=0;low_word<=0;entry<=0;distance_q<=0;
  end else if(panic)begin
   state<=CLEAR;scan<=0;active<=0;display_mode<=0;guide<=0;correct<=0;incorrect<=0;
   error<=prepared;finished<=0;last_result<=7;
  end else begin
   if(active)begin
    if(ms_count==CLK_HZ/1000-1)begin ms_count<=0;elapsed_ms<=elapsed_ms+1'b1;scan_due<=1;end
    else ms_count<=ms_count+1'b1;
   end
   case(state)
    IDLE:begin
     if(command_valid&&trusted)begin
      if(kind==14)case(command_data[39:32])
       0:begin
        active<=0;display_mode<=1;prepared<=1;finished<=0;error<=0;
        total<=command_data[31:16];session<=command_data[15:8];hits<=0;wrong<=0;misses<=0;
        state<=CLEAR;scan<=0;write_ptr<=0;received<=0;elapsed_ms<=0;ms_count<=0;scan_due<=0;
        guide<=0;correct<=0;incorrect<=0;last_note<=0;last_result<=4;last_target_time<=0;
       end
       1:if(prepared&&!error&&total!=0)begin active<=1;elapsed_ms<=0;ms_count<=0;scan_due<=1;end
       2:final_at<=incoming_time;
       3:begin active<=0;display_mode<=0;state<=CLEAR;scan<=0;guide<=0;last_result<=6;end
       default:begin error<=1;active<=0;last_result<=7;end
      endcase
      else if(kind==15)begin
       if(!prepared || received>=total || command_data[39] ||
          command_data[38:32]<21 || command_data[38:32]>108 ||
          (received!=0 && incoming_time<last_target_time))begin
        error<=1;active<=0;guide<=0;last_result<=7;
       end else begin
        pending_target<={1'b1,command_data[38:32],incoming_time};
        last_target_time<=incoming_time;state<=FREE_READ;
       end
      end
     end else if(key_valid&&key_ready&&active&&key_note>=21&&key_note<=108)begin
      pending_note<=key_note;key_at<=elapsed_ms;scan_key<=1;scan<=0;found<=0;
      best_distance<=25'h1ffffff;state<=READ_LO;
     end else if(active&&scan_due)begin
      scan_due<=0;scan_key<=0;scan<=0;scan_at<=elapsed_ms;guide_work<=0;state<=READ_LO;
     end else if(active && elapsed_ms>final_at+WINDOW_MS && received==total && {1'b0,hits}+{1'b0,misses}=={1'b0,total})begin
      active<=0;finished<=1;guide<=0;last_result<=5;
     end else if(active && elapsed_ms>final_at+1000 && received!=total)begin
      active<=0;error<=1;guide<=0;last_result<=7;
     end
    end
    CLEAR:if(scan==63)begin scan<=0;state<=IDLE;end else scan<=scan+1'b1;
    FREE_READ:state<=FREE_CAP;
    FREE_CAP:state<=FREE_CHECK;
    FREE_CHECK:if(read_word[15])begin error<=1;active<=0;guide<=0;last_result<=7;state<=IDLE;end else state<=WRITE_LO;
    WRITE_LO:state<=WRITE_HI;
    WRITE_HI:begin write_ptr<=write_ptr+1'b1;received<=received+1'b1;state<=IDLE;end
    READ_LO:state<=CAP_LO;
    CAP_LO:begin low_word<=read_word;state<=READ_HI;end
    READ_HI:state<=CAP_HI;
    CAP_HI:begin entry<={read_word,low_word};state<=CALC;end
    CALC:begin distance_q<=distance;state<=CHECK;end
    CHECK:begin
     if(scan_key)begin
      if(entry[31]&&entry_note==pending_note&&distance_q<=WINDOW_MS&&(!found||distance_q<best_distance))begin
       found<=1;best_index<=scan;best_high<=entry[31:16];best_distance<=distance_q;
      end
     end else begin
      guide_work<=guide_next;
      if(expire)begin
       misses<=misses+1'b1;last_note<={1'b0,entry_note};last_result<=3;
      end
     end
     if(scan==63)begin
      if(scan_key)state<=APPLY;
      else begin guide<=guide_next;state<=IDLE;end
     end else begin scan<=scan+1'b1;state<=READ_LO;end
    end
    APPLY:begin
     last_note<={1'b0,pending_note};
     if(found)begin
      hits<=hits+1'b1;correct[pending_note-21]<=1;incorrect[pending_note-21]<=0;last_result<=1;
     end else begin
      if(wrong!=65535)wrong<=wrong+1'b1;
      incorrect[pending_note-21]<=1;correct[pending_note-21]<=0;last_result<=2;
     end
     state<=IDLE;
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
