#pragma once

#include <stdint.h>

#include "control_event.h"

typedef enum {
    MUSIC_PHONE_INVALID = 0,
    MUSIC_PHONE_EVENT,
    MUSIC_PHONE_KEYMAP,
} music_phone_command_kind_t;

typedef struct {
    uint8_t source;
    uint8_t input_note;
    uint8_t output_note;
} music_phone_keymap_t;

/* Parse exactly one untrusted 8-byte BLE command. Sequence is assigned later
 * by the unique UART sender. Virtual notes reserve source 1 / channel 15. */
music_phone_command_kind_t music_phone_command_decode(
    const uint8_t bytes[SMK25_CONTROL_EVENT_SIZE],
    smk25_control_event_t *event_out,
    music_phone_keymap_t *keymap_out);
