#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "control_event.h"

typedef struct {
    uint8_t source;
    uint8_t program[16];
    uint8_t note_owner[16][128];
    uint8_t note_map[128];
    uint8_t mapped_note_owner[16][128];
    uint32_t ignored_packets;
    uint32_t unsupported_messages;
} smk25_midi_bridge_t;

void smk25_midi_bridge_init(smk25_midi_bridge_t *bridge, uint8_t source);
bool smk25_midi_bridge_usb_packet(smk25_midi_bridge_t *bridge,
                                  const uint8_t packet[4],
                                  smk25_control_event_t *event_out);
void smk25_midi_bridge_all_notes_off(smk25_midi_bridge_t *bridge,
                                     smk25_control_event_t *event_out);
bool smk25_midi_bridge_set_note_map(smk25_midi_bridge_t *bridge,
                                    uint8_t input_note, uint8_t output_note);
