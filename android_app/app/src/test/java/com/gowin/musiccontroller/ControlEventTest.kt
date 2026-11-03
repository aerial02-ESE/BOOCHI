package com.gowin.musiccontroller

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class ControlEventTest {
    @Test fun notePacketsMatchBrowserProtocol() {
        assertArrayEquals(
            byteArrayOf(0x41, 0x1f, 0, 60, 0xff.toByte(), 0xff.toByte(), 0, 0),
            ControlEvent.note(60, 127, true))
        assertArrayEquals(
            byteArrayOf(0x42, 0x1f, 0, 60, 0, 0, 0, 0),
            ControlEvent.note(60, 0, false))
    }

    @Test fun controlPacketsMatchBrowserProtocol() {
        assertArrayEquals(
            byteArrayOf(0x43, 0x1f, 0, 0, 0x80.toByte(), 0, 0, 0),
            ControlEvent.encode(ControlEvent.PITCH_BEND, value = 32768))
        assertArrayEquals(
            byteArrayOf(0x48, 0x1f, 0, 0, 0, 1, 0, 0),
            ControlEvent.encode(ControlEvent.EFFECT_CTRL, value = 1))
        assertArrayEquals(
            byteArrayOf(0x4b, 0x0f, 0, 0xbc.toByte(), 0, 48, 0, 0),
            ControlEvent.keyMap(0, 60, 48))
        assertArrayEquals(
            byteArrayOf(0x4b, 0x1f, 0, 0xbc.toByte(), 0, 72, 0, 0),
            ControlEvent.keyMap(1, 60, 72))
        assertArrayEquals(
            byteArrayOf(0x48, 0x1f, 0, 0, 0x80.toByte(), 0, 5, 0),
            ControlEvent.encode(ControlEvent.EFFECT_CTRL, value = 32768, aux = 5))
    }

    @Test fun notificationRetainsSourceAndSequence() {
        val event = ControlEvent.decode(
            byteArrayOf(0x41, 0x03, 0, 60, 0xff.toByte(), 0xff.toByte(), 0, 7))
        assertEquals(0, event.source)
        assertEquals(3, event.channel)
        assertEquals(7, event.sequence)
    }

    @org.junit.Test fun encodesDisplayPages() {
        for (page in 0..2) {
            org.junit.Assert.assertArrayEquals(
                byteArrayOf(0x4b, 0x1f, 0, 0x21, 0, page.toByte(), 0, 0),
                ControlEvent.displayPage(page)
            )
        }
    }
}

