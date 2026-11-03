#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "practice_protocol.h"
#include "control_event.h"
static practice_plan_t plan;
int main(void)
{
 practice_plan_begin(&plan);
 assert(practice_plan_add(&plan,0,60,0,true,0)==0);
 assert(practice_plan_add(&plan,0,60,1,true,1)==0); // one physical key, two tracks
 assert(practice_plan_add(&plan,0,36,2,true,2)==0); // percussion excluded
 assert(practice_plan_add(&plan,10,20,0,true,3)==0);
 assert(plan.count==1);
 assert(practice_plan_add(&plan,5,61,0,true,4)==PRACTICE_BAD_TIME);
 practice_plan_begin(&plan);
 for(unsigned i=0;i<PRACTICE_DENSITY_LIMIT;i++)assert(practice_plan_add(&plan,i,60,0,true,i)==0);
 assert(practice_plan_add(&plan,PRACTICE_DENSITY_LIMIT,61,0,true,PRACTICE_DENSITY_LIMIT)==PRACTICE_TOO_DENSE);
 assert(practice_plan_add(&plan,2000,61,0,true,241)==0);
 uint8_t frame[22]={0xa5,0x5a,2,16,7,9,0,5,0,2,0,1,0,3,0,0,1,0,60,1,0,0};
 uint16_t crc=smk25_crc16_ccitt_false(frame+2,18);frame[20]=(uint8_t)(crc>>8);frame[21]=(uint8_t)crc;
 practice_parser_t parser={0};practice_feedback_t feedback={0};
 assert(!practice_parser_feed(&parser,0x11,&feedback));
 for(int i=0;i<22;i++)assert(practice_parser_feed(&parser,frame[i],&feedback)==(i==21));
 assert(feedback.hits==2&&feedback.misses==3&&feedback.total==5&&feedback.elapsed_ms==256);
 uint8_t ble[20];practice_feedback_ble(&feedback,13,ble);
 const uint8_t golden[20]={0x50,7,9,13,0,5,0,2,0,1,0,3,0,0,1,0,60,1,0x60,0x7e};
 assert(memcmp(ble,golden,sizeof(golden))==0); // Same independent vector consumed by Android.
 assert(ble[0]==0x50&&ble[1]==7&&ble[3]==13&&ble[7]==2&&ble[11]==3);
 assert(smk25_crc16_ccitt_false(ble,18)==((uint16_t)ble[18]<<8|ble[19]));
 practice_feedback_t rejected={.session=9,.flags=0x84,.last_result=0x85};
 practice_feedback_ble(&rejected,14,ble);
 assert(ble[2]==0x84&&ble[17]==0x85&&ble[4]==0&&ble[5]==0);
 frame[9]^=1;
 for(int i=0;i<22;i++)assert(!practice_parser_feed(&parser,frame[i],&feedback));
 frame[9]^=1;
 for(int i=0;i<22;i++)assert(practice_parser_feed(&parser,frame[i],&feedback)==(i==21));
 puts("PASS practice C: target filters/dedup/density, UART fragmentation/CRC/resync, BLE20 CRC and counters");
 return 0;
}
