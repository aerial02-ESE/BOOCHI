#include "midi_bridge.h"

#include <string.h>

#define OWNER_NONE 0xFFU

static uint8_t program_to_instrument(uint8_t program)
{
    /* General MIDI programs 32..39 are basses. The MVP maps all others to piano. */
    return (program >= 32U && program <= 39U) ? SMK25_INST_BASS : SMK25_INST_PIANO;
}

static void emit(const smk25_midi_bridge_t *bridge, smk25_control_event_t *out, uint8_t type, uint8_t channel,
                 uint8_t instrument, uint8_t id, uint16_t value)
{
    smk25_control_event_pack(out, type, bridge->source, channel,
                             instrument, 0, id, value, 0, 0);
}

void smk25_midi_bridge_init(smk25_midi_bridge_t *bridge, uint8_t source)
{
    memset(bridge, 0, sizeof(*bridge));
    bridge->source = source & 0x0FU;
    memset(bridge->note_owner, OWNER_NONE, sizeof(bridge->note_owner));
    memset(bridge->mapped_note_owner, OWNER_NONE, sizeof(bridge->mapped_note_owner));
    for (unsigned i = 0; i < 128; ++i) {
        bridge->note_map[i] = (uint8_t)i;
    }
}

bool smk25_midi_bridge_set_note_map(smk25_midi_bridge_t *bridge,
                                    uint8_t input_note, uint8_t output_note)
{
    if (bridge == NULL || input_note > 127U || output_note > 127U) {
        return false;
    }
    bridge->note_map[input_note] = output_note;
    return true;
}

bool smk25_midi_bridge_usb_packet(smk25_midi_bridge_t *bridge,
                                  const uint8_t packet[4],
                                  smk25_control_event_t *event_out)
{
    if (bridge == NULL || packet == NULL || event_out == NULL) {
        return false;
    }

    const uint8_t status = packet[1];
    const uint8_t command = status >> 4;
    const uint8_t channel = status & 0x0FU;
    const uint8_t data0 = packet[2] & 0x7FU;
    const uint8_t data1 = packet[3] & 0x7FU;
    const uint8_t mapped = bridge->note_map[data0];
    uint8_t instrument = program_to_instrument(bridge->program[channel]);

    if (status < 0x80U || command == 0x0FU) {
        ++bridge->ignored_packets;
        return false;
    }

    switch (command) {
    case 0x08: { /* Note Off */
        const uint8_t owner = bridge->note_owner[channel][data0];
        const uint8_t released_note = bridge->mapped_note_owner[channel][data0];
        if (owner != OWNER_NONE) {
            instrument = owner;
        }
        bridge->note_owner[channel][data0] = OWNER_NONE;
        bridge->mapped_note_owner[channel][data0] = OWNER_NONE;
        emit(bridge, event_out, SMK25_EV_NOTE_OFF, channel, instrument,
             released_note == OWNER_NONE ? mapped : released_note, smk25_scale7(data1));
        return true;
    }
    case 0x09: /* Note On; velocity zero is a Note Off by MIDI convention. */
        if (data1 == 0U) {
            const uint8_t owner = bridge->note_owner[channel][data0];
            const uint8_t released_note = bridge->mapped_note_owner[channel][data0];
            if (owner != OWNER_NONE) {
                instrument = owner;
            }
            bridge->note_owner[channel][data0] = OWNER_NONE;
            bridge->mapped_note_owner[channel][data0] = OWNER_NONE;
            emit(bridge, event_out, SMK25_EV_NOTE_OFF, channel, instrument,
                 released_note == OWNER_NONE ? mapped : released_note, 0);
        } else {
            bridge->note_owner[channel][data0] = instrument;
            bridge->mapped_note_owner[channel][data0] = mapped;
            emit(bridge, event_out, SMK25_EV_NOTE_ON, channel, instrument,
                 mapped, smk25_scale7(data1));
        }
        return true;
    case 0x0A: /* Polyphonic key pressure: id is the affected MIDI note. */
        emit(bridge, event_out, SMK25_EV_PRESSURE, channel, instrument, mapped, smk25_scale7(data1));
        return true;
    case 0x0B: /* Control Change */
        if (data0 == 1U) {
            emit(bridge, event_out, SMK25_EV_MODULATION, channel, instrument, data0, smk25_scale7(data1));
            return true;
        }
        if (data0 == 64U) {
            emit(bridge, event_out, SMK25_EV_SUSTAIN, channel, instrument, data0, smk25_scale7(data1));
            return true;
        }
        if (data0 == 120U || data0 == 123U) {
            smk25_midi_bridge_all_notes_off(bridge, event_out);
            return true;
        }
        ++bridge->unsupported_messages;
        return false;
    case 0x0C: /* Program Change */
        bridge->program[channel] = data0;
        instrument = program_to_instrument(data0);
        emit(bridge, event_out, SMK25_EV_PROGRAM, channel, instrument, data0, 0);
        return true;
    case 0x0D: /* Channel pressure: id zero denotes channel-wide pressure. */
        emit(bridge, event_out, SMK25_EV_PRESSURE, channel, instrument, 0, smk25_scale7(data0));
        return true;
    case 0x0E: {
        const uint16_t bend14 = (uint16_t)data0 | ((uint16_t)data1 << 7);
        emit(bridge, event_out, SMK25_EV_PITCH_BEND, channel, instrument, 0, smk25_scale14(bend14));
        return true;
    }
    default:
        ++bridge->unsupported_messages;
        return false;
    }
}

void smk25_midi_bridge_all_notes_off(smk25_midi_bridge_t *bridge,
                                     smk25_control_event_t *event_out)
{
    memset(bridge->note_owner, OWNER_NONE, sizeof(bridge->note_owner));
    memset(bridge->mapped_note_owner, OWNER_NONE, sizeof(bridge->mapped_note_owner));
    emit(bridge, event_out, SMK25_EV_ALL_NOTES_OFF, 0, SMK25_INST_PIANO, 0, 0);
}
