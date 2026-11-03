package com.gowin.musiccontroller

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class SppFrameTest {
    private val note = byteArrayOf(0x41, 0, 0, 0x3c, 0x80.toByte(), 0, 0, 0)

    @Test fun firmwareGoldenVector() {
        assertArrayEquals(
            byteArrayOf(0xa5.toByte(), 0x5a, 1, 8) + note + byteArrayOf(0x4c, 0x7d),
            SppFrame.encode(note)
        )
    }

    @Test fun resyncsAfterNoiseAndBadCrc() {
        val decoder = SppFrame.Decoder()
        val good = SppFrame.encode(note)
        val bad = good.copyOf().also { it[13] = 0 }
        val received = (byteArrayOf(1, 2) + bad + good + good).asSequence().mapNotNull(decoder::accept).toList()
        assertEquals(2, received.size)
        received.forEach { assertArrayEquals(note, it) }
    }

    @Test fun acceptsPracticeFeedbackAndControlEventsOnOneStream() {
        val feedback = ByteArray(20) { (it * 3).toByte() }
        val decoder = SppFrame.Decoder()
        val received = (SppFrame.encode(feedback) + SppFrame.encode(note))
            .asSequence().mapNotNull(decoder::accept).toList()
        assertEquals(2, received.size)
        assertArrayEquals(feedback, received[0])
        assertArrayEquals(note, received[1])
    }
}

