#pragma once

#include <stdint.h>

#include "esp_err.h"

typedef void (*smk25_usb_midi_packet_cb_t)(uint8_t source, const uint8_t packet[4], void *context);
typedef void (*smk25_usb_midi_disconnect_cb_t)(uint8_t source, void *context);

typedef struct {
    smk25_usb_midi_packet_cb_t packet_cb;
    smk25_usb_midi_disconnect_cb_t disconnect_cb;
    void *context;
} smk25_usb_midi_host_config_t;

/** Starts one native USB Host daemon for the directly connected SMK-25.
 *  The root device maps to ControlEvent source 0. Hub children are ignored. */
esp_err_t smk25_usb_midi_host_start(const smk25_usb_midi_host_config_t *config);
