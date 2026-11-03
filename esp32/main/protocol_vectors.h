#pragma once

#include "esp_err.h"

/** Checks the frozen ControlEvent and UART golden vectors at device start-up. */
esp_err_t smk25_protocol_self_test(void);
