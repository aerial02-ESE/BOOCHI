#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#define SCORE_RECORD_SIZE 8U
#define SCORE_MAX_RECORDS 8192U
#define SCORE_RECORD_TYPE 0x4CU
#define SCORE_CONTROL_TYPE 0x4EU

typedef struct {
    uint32_t at_ms;
    uint8_t instrument; /* 0 piano, 1 organ, 2 drum */
    bool on;
    uint8_t note;
    uint8_t velocity;
} score_note_event_t;

esp_err_t score_store_init(void);
bool score_store_begin(uint16_t expected);
bool score_store_append(const uint8_t bytes[SCORE_RECORD_SIZE]);
bool score_store_commit(uint16_t expected_crc);
uint16_t score_store_count(void);
bool score_store_get(uint16_t index, score_note_event_t *event);
/* Four display bits: duration class [1:0], simultaneous onset [2],
 * long gap before onset [3]. Valid for Note On record indexes only. */
uint8_t score_store_note_meta(uint16_t index);
