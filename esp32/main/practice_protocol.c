#include "practice_protocol.h"
#include "control_event.h"
#include <string.h>
void practice_plan_begin(practice_plan_t *p){memset(p,0,sizeof(*p));p->seen_at=UINT32_MAX;}
int practice_plan_add(practice_plan_t *p,uint32_t at,uint8_t note,uint8_t inst,bool on,uint16_t record)
{
 if(at>600000U||(p->had_record&&at<p->last_record_at))return PRACTICE_BAD_TIME;
 p->had_record=true;p->last_record_at=at;
 if(!on||inst==2U||note<21U||note>108U)return PRACTICE_OK;
 if(p->seen_at!=at){memset(p->seen,0,sizeof(p->seen));p->seen_at=at;}
 const uint8_t mask=(uint8_t)(1U<<(note&7U));
 if(p->seen[note>>3]&mask)return PRACTICE_OK;
 if(p->count>=PRACTICE_MAX_TARGETS)return PRACTICE_TOO_MANY;
 while(p->left<p->count&&at-p->targets[p->left].at_ms>PRACTICE_DENSITY_SPAN_MS)++p->left;
 if((unsigned)(p->count-p->left)>=PRACTICE_DENSITY_LIMIT)return PRACTICE_TOO_DENSE;
 p->seen[note>>3]|=mask;
 p->targets[p->count++]=(practice_target_t){.at_ms=at,.record_index=record,.note=note};
 return PRACTICE_OK;
}
static uint16_t get16(const uint8_t *p){return(uint16_t)((uint16_t)p[0]<<8|p[1]);}
static void put16(uint8_t *p,uint16_t v){p[0]=(uint8_t)(v>>8);p[1]=(uint8_t)v;}
static void resync(practice_parser_t *p)
{
 for(unsigned i=1;i<p->used;i++)if(p->bytes[i]==0xa5U&&(i+1U==p->used||p->bytes[i+1U]==0x5aU)){
  memmove(p->bytes,p->bytes+i,p->used-i);p->used=(uint8_t)(p->used-i);return;
 }
 p->used=0;
}
bool practice_parser_feed(practice_parser_t *p,uint8_t byte,practice_feedback_t *out)
{
 if(p->used==0U&&byte!=0xa5U)return false;
 p->bytes[p->used++]=byte;
 if(p->used>=2U&&p->bytes[1]!=0x5aU){resync(p);return false;}
 if(p->used>=4U&&(p->bytes[2]!=2U||p->bytes[3]!=16U)){resync(p);return false;}
 if(p->used<22U)return false;
 if(smk25_crc16_ccitt_false(p->bytes+2,18)!=get16(p->bytes+20)){resync(p);return false;}
 const uint8_t *b=p->bytes+4;
 practice_feedback_t f={.session=b[0],.flags=b[1],.total=get16(b+2),.hits=get16(b+4),
  .wrong=get16(b+6),.misses=get16(b+8),.elapsed_ms=(uint32_t)b[10]<<24|(uint32_t)b[11]<<16|(uint32_t)b[12]<<8|b[13],
  .last_note=b[14],.last_result=b[15]};
 p->used=0;
 if(f.total>PRACTICE_MAX_TARGETS||(uint32_t)f.hits+f.misses>f.total||f.flags&0xe0U||f.last_note>108U)return false;
 *out=f;return true;
}
void practice_feedback_ble(const practice_feedback_t *f,uint8_t sequence,uint8_t out[20])
{
 out[0]=0x50;out[1]=f->session;out[2]=f->flags;out[3]=sequence;
 put16(out+4,f->total);put16(out+6,f->hits);put16(out+8,f->wrong);put16(out+10,f->misses);
 out[12]=(uint8_t)(f->elapsed_ms>>24);out[13]=(uint8_t)(f->elapsed_ms>>16);
 out[14]=(uint8_t)(f->elapsed_ms>>8);out[15]=(uint8_t)f->elapsed_ms;
 out[16]=f->last_note;out[17]=f->last_result;
 put16(out+18,smk25_crc16_ccitt_false(out,18));
}
