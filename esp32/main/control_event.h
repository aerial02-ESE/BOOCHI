#pragma once

#include <stddef.h>
#include <stdint.h>

#define SMK25_CONTROL_EVENT_SIZE 8
#define SMK25_UART_FRAME_SIZE 14

enum smk25_event_type {
    SMK25_EV_NOP = 0x00,
    SMK25_EV_NOTE_ON = 0x01,
    SMK25_EV_NOTE_OFF = 0x02,
    SMK25_EV_PITCH_BEND = 0x03,
    SMK25_EV_PRESSURE = 0x04,
    SMK25_EV_MODULATION = 0x05,
    SMK25_EV_SUSTAIN = 0x06,
    SMK25_EV_PROGRAM = 0x07,
    SMK25_EV_EFFECT_CTRL = 0x08,
    SMK25_EV_ALL_NOTES_OFF = 0x09,
    SMK25_EV_TRANSPORT = 0x0A,
    SMK25_EV_PARAM_CTRL = 0x0B,
    SMK25_EV_SCORE_VIEW = 0x0C, /* UART-only score preview; never reaches synth */
    SMK25_EV_SCORE_LED = 0x0D,  /* UART-only timed LED guidance */
};

enum smk25_instrument {
    SMK25_INST_PIANO = 0,
    SMK25_INST_BASS = 1,
    SMK25_INST_DRUM = 2,
};

enum smk25_source {
    SMK25_SRC_SMK25 = 0,
    SMK25_SRC_88KEY = 1,
    SMK25_SRC_PHONE = 2,
    SMK25_SRC_SCORE = 3,
};

typedef struct {
    uint8_t bytes[SMK25_CONTROL_EVENT_SIZE];
} smk25_control_event_t;

uint16_t smk25_crc16_ccitt_false(const uint8_t *data, size_t length);
uint16_t smk25_scale7(uint8_t value);
uint16_t smk25_scale14(uint16_t value);
void smk25_control_event_pack(smk25_control_event_t *event,
                              uint8_t type, uint8_t source, uint8_t channel,
                              uint8_t instrument, uint8_t flags, uint8_t id,
                              uint16_t value, uint8_t aux, uint8_t seq);
size_t smk25_uart_frame_encode(const smk25_control_event_t *event,
                               uint8_t frame[SMK25_UART_FRAME_SIZE]);
