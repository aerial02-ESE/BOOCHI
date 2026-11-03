#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "pedal_refresh.h"

int main(void)
{
    smk25_pedal_refresh_t state = {0};
    smk25_control_event_t event,out;
    assert(!smk25_pedal_refresh_due(&state,1000,200,&out));
    smk25_control_event_pack(&event,SMK25_EV_SUSTAIN,0,7,1,0,64,65535,0,40);
    smk25_pedal_refresh_observe(&state,&event,1000);
    assert(!smk25_pedal_refresh_due(&state,1199,200,&out));
    assert(smk25_pedal_refresh_due(&state,1200,200,&out));
    assert(memcmp(event.bytes,out.bytes,8)==0);
    // A lost UART pedal-up is repaired by repeating the last ordered state.
    smk25_control_event_pack(&event,SMK25_EV_SUSTAIN,0,7,1,0,64,0,0,41);
    smk25_pedal_refresh_observe(&state,&event,1250);
    assert(smk25_pedal_refresh_due(&state,1450,200,&out));
    assert(out.bytes[4]==0 && out.bytes[5]==0);
    // Another source must never overwrite the SMK pedal owner.
    smk25_control_event_pack(&event,SMK25_EV_SUSTAIN,2,0,0,0,64,65535,0,42);
    smk25_pedal_refresh_observe(&state,&event,1460);
    assert(smk25_pedal_refresh_due(&state,1650,200,&out));
    assert(out.bytes[1]==7 && out.bytes[4]==0 && out.bytes[5]==0);
    // Panic/stop must not resurrect a previously latched pedal position.
    smk25_control_event_pack(&event,SMK25_EV_ALL_NOTES_OFF,2,0,0,0,0,0,0,43);
    smk25_pedal_refresh_observe(&state,&event,1700);
    assert(!smk25_pedal_refresh_due(&state,2000,200,&out));
    // Unsigned elapsed arithmetic remains correct across timestamp wrap.
    smk25_control_event_pack(&event,SMK25_EV_SUSTAIN,0,0,0,0,64,65535,0,44);
    smk25_pedal_refresh_observe(&state,&event,0xfffffff0U);
    assert(!smk25_pedal_refresh_due(&state,0x50U,200,&out));
    assert(smk25_pedal_refresh_due(&state,0xc0U,200,&out));
    puts("PASS pedal refresh: ordered down/up recovery, source isolation, panic and timer wrap");
    return 0;
}
