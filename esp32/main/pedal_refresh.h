#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "control_event.h"

/* Single-owner state, used only by the UART sender task. */
typedef struct {
    bool known;
    uint32_t last_ms;
    smk25_control_event_t event;
} smk25_pedal_refresh_t;

void smk25_pedal_refresh_observe(smk25_pedal_refresh_t *state,
                                const smk25_control_event_t *event, uint32_t now_ms);
bool smk25_pedal_refresh_due(smk25_pedal_refresh_t *state, uint32_t now_ms,
                            uint32_t interval_ms, smk25_control_event_t *out);
