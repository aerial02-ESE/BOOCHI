#include "pedal_refresh.h"

void smk25_pedal_refresh_observe(smk25_pedal_refresh_t *state,
                                const smk25_control_event_t *event, uint32_t now_ms)
{
    const uint8_t type = event->bytes[0] & 0x3fU;
    if (type == SMK25_EV_ALL_NOTES_OFF ||
        (type == SMK25_EV_TRANSPORT && event->bytes[3] == 0U)) {
        /* Preserve the existing explicit panic/stop safety policy. */
        state->known = false;
    } else if (type == SMK25_EV_SUSTAIN &&
               (event->bytes[1] >> 4) == SMK25_SRC_SMK25) {
        state->event = *event;
        state->known = true;
        state->last_ms = now_ms;
    }
}

bool smk25_pedal_refresh_due(smk25_pedal_refresh_t *state, uint32_t now_ms,
                            uint32_t interval_ms, smk25_control_event_t *out)
{
    if (!state->known || (uint32_t)(now_ms - state->last_ms) < interval_ms)
        return false;
    *out = state->event;
    state->last_ms = now_ms;
    return true;
}
