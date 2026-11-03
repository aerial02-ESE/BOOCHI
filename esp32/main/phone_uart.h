#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "control_event.h"

typedef bool (*music_phone_command_cb_t)(const uint8_t bytes[8], void *context);

esp_err_t music_phone_uart_start(music_phone_command_cb_t callback, void *context);
void music_phone_uart_publish(const smk25_control_event_t *event);
void music_phone_uart_publish_raw(const uint8_t *payload, size_t length);
