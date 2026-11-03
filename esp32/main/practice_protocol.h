#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define PRACTICE_MAX_TARGETS 4096U
#define PRACTICE_COUNTDOWN_MS 2000U
#define PRACTICE_LOOKAHEAD_MS 1000U
#define PRACTICE_DENSITY_SPAN_MS 1200U
#define PRACTICE_DENSITY_LIMIT 56U
typedef struct {uint32_t at_ms;uint16_t record_index;uint8_t note;} practice_target_t;
typedef struct {
 practice_target_t targets[PRACTICE_MAX_TARGETS];
 uint16_t count,left;
 uint32_t seen_at,last_record_at;
 uint8_t seen[16];
 bool had_record;
} practice_plan_t;
enum {PRACTICE_OK=0,PRACTICE_BAD_TIME=1,PRACTICE_TOO_MANY=2,PRACTICE_TOO_DENSE=3,PRACTICE_EMPTY=4,PRACTICE_NO_RETURN=5};
void practice_plan_begin(practice_plan_t *plan);
int practice_plan_add(practice_plan_t *plan,uint32_t at,uint8_t note,uint8_t instrument,bool on,uint16_t record);
typedef struct {uint8_t session,flags,last_note,last_result;uint16_t total,hits,wrong,misses;uint32_t elapsed_ms;} practice_feedback_t;
typedef struct {uint8_t bytes[22];uint8_t used;} practice_parser_t;
bool practice_parser_feed(practice_parser_t *parser,uint8_t byte,practice_feedback_t *feedback);
void practice_feedback_ble(const practice_feedback_t *feedback,uint8_t sequence,uint8_t output[20]);
