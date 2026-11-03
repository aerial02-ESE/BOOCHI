#include "protocol_vectors.h"

#include <string.h>

#include "control_event.h"

esp_err_t smk25_protocol_self_test(void)
{
    /* docs/protocol-v1-golden-vectors.json: keyboard_piano_note_on_c4_max_velocity */
    static const uint8_t expected_event[8] = {0x41, 0x10, 0x00, 0x3C, 0xFF, 0xFF, 0x00, 0x2A};
    static const uint8_t expected_frame[14] = {
        0xA5, 0x5A, 0x01, 0x08, 0x41, 0x10, 0x00, 0x3C,
        0xFF, 0xFF, 0x00, 0x2A, 0xA7, 0xD6,
    };
    smk25_control_event_t event;
    uint8_t frame[SMK25_UART_FRAME_SIZE];
    smk25_control_event_pack(&event, SMK25_EV_NOTE_ON, 1, 0, SMK25_INST_PIANO,
                             0, 60, 65535, 0, 42);
    if (memcmp(event.bytes, expected_event, sizeof(expected_event)) != 0) {
        return ESP_FAIL;
    }
    smk25_uart_frame_encode(&event, frame);
    return memcmp(frame, expected_frame, sizeof(expected_frame)) == 0 ? ESP_OK : ESP_FAIL;
}
