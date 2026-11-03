package com.gowin.musiccontroller
import org.junit.Assert.*
import org.junit.Test

class AdsrSettingsTest {
    @Test fun packetsHaveTargetAndValidSlopes() {
        val events = AdsrSettings(1200, 1200, 100, 1200).packets(1).map(ControlEvent::decode)
        assertEquals(listOf(16,17,18,19), events.map { it.id })
        assertTrue(events.all { it.aux == 1 && it.type == ControlEvent.PARAM_CTRL })
        assertEquals(65535, events[2].value)
        assertEquals(1, events[1].value)
        assertTrue(events[0].value > 0 && events[3].value > 0)
    }
    @Test fun slowerAttackHasSmallerSlope() {
        val fast = ControlEvent.decode(AdsrSettings(attackMs=1).packets(0)[0]).value
        val slow = ControlEvent.decode(AdsrSettings(attackMs=1000).packets(0)[0]).value
        assertTrue(fast > slow)
    }
}
