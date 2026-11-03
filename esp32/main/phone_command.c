#include "phone_command.h"

#include <string.h>

music_phone_command_kind_t music_phone_command_decode(
    const uint8_t bytes[SMK25_CONTROL_EVENT_SIZE],
    smk25_control_event_t *event_out,
    music_phone_keymap_t *keymap_out)
{
    if (bytes == NULL || event_out == NULL || keymap_out == NULL ||
        (bytes[0] & 0xC0U) != 0x40U || (bytes[2] & 0x0FU) != 0U) {
        return MUSIC_PHONE_INVALID;
    }
    const uint8_t type = bytes[0] & 0x3FU;
    const uint8_t id = bytes[3];
    const uint16_t value = ((uint16_t)bytes[4] << 8) | bytes[5];
    const uint8_t source = bytes[1] >> 4;
    const uint8_t aux = bytes[6];

    if (type == SMK25_EV_PARAM_CTRL && id >= 0x80U) {
        if (source > 1U || value > 127U || aux != 0U) {
            return MUSIC_PHONE_INVALID;
        }
        if (source == 1U) {
            memcpy(event_out->bytes, bytes, SMK25_CONTROL_EVENT_SIZE);
            event_out->bytes[1] = 0x2FU; /* trusted phone control channel */
            event_out->bytes[2] = 0U;
            event_out->bytes[6] = 1U; /* FPGA 88-key map selector */
            event_out->bytes[7] = 0U;
            return MUSIC_PHONE_EVENT;
        }
        keymap_out->source = source;
        keymap_out->input_note = id & 0x7FU;
        keymap_out->output_note = (uint8_t)value;
        return MUSIC_PHONE_KEYMAP;
    }

    switch (type) {
    case SMK25_EV_NOTE_ON:
    case SMK25_EV_NOTE_OFF:
        if (id > 127U || aux != 0U) {
            return MUSIC_PHONE_INVALID;
        }
        break;
    case SMK25_EV_PITCH_BEND:
    case SMK25_EV_PRESSURE:
        if (id != 0U || aux != 0U) {
            return MUSIC_PHONE_INVALID;
        }
        break;
    case SMK25_EV_MODULATION:
        if (id != 1U || aux != 0U) {
            return MUSIC_PHONE_INVALID;
        }
        break;
    case SMK25_EV_SUSTAIN:
        if (id != 64U || aux != 0U) {
            return MUSIC_PHONE_INVALID;
        }
        break;
    case SMK25_EV_ALL_NOTES_OFF:
        if (id != 0U || value != 0U || aux != 0U) {
            return MUSIC_PHONE_INVALID;
        }
        break;
    case SMK25_EV_PARAM_CTRL:
        if (!((id <= 2U && aux == 0U) ||
              (id == 0x21U && value <= 2U && aux == 0U) ||
              (id == 0x20U && value <= 11U &&
               (aux == 0U || (aux == 1U && value != 3U))) ||
              (id >= 0x10U && id <= 0x13U && aux <= 1U &&
               (id == 0x12U || value != 0U)))) {
            return MUSIC_PHONE_INVALID;
        }
        break;
    case SMK25_EV_EFFECT_CTRL:
        if (id != 0U || aux > 5U || (aux == 0U && value > 1U)) {
            return MUSIC_PHONE_INVALID;
        }
        break;
    default:
        return MUSIC_PHONE_INVALID;
    }

    memcpy(event_out->bytes, bytes, SMK25_CONTROL_EVENT_SIZE);
    /* Prevent a BLE client from impersonating the live USB sources/channels. */
    event_out->bytes[1] = 0x2FU; /* source 2, reserved phone channel 15 */
    event_out->bytes[2] = 0U;    /* notes use the FPGA's active timbre mode */
    event_out->bytes[7] = 0U;    /* sender task owns sequence allocation */
    if (type == SMK25_EV_NOTE_ON && value == 0U) {
        event_out->bytes[0] = 0x40U | SMK25_EV_NOTE_OFF;
    }
    return MUSIC_PHONE_EVENT;
}
