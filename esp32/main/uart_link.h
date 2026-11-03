#pragma once

#include <stdbool.h>

#include "esp_err.h"

#include "control_event.h"

esp_err_t smk25_uart_link_init(void);
bool smk25_uart_link_is_enabled(void);
esp_err_t smk25_uart_link_send(const smk25_control_event_t *event);
