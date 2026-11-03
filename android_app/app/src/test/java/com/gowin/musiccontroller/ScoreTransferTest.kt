package com.gowin.musiccontroller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ScoreTransferTest {
    @Test fun bytesAndCrcMatchIndependentReference() {
        val packets = ScoreTransfer.encode(MusicScore("单音",
            listOf(ScoreNote(0, 60, 127, 500))))
        assertEquals(listOf(0x4c, 0x20, 0, 0, 60, 127, 0, 0),
            packets[1].map { it.toInt() and 255 })
        assertEquals(listOf(0x4c, 0, 0x01, 0xf4, 60, 0, 0, 0),
            packets[2].map { it.toInt() and 255 })
        assertEquals(0xe200, ((packets.last()[4].toInt() and 255) shl 8) or
            (packets.last()[5].toInt() and 255))
    }

    @Test fun chordIsTimestampedTogetherAndHasValidCrc() {
        val score = MusicScore("和弦", listOf(
            ScoreNote(100, 60, 90, 500, 0),
            ScoreNote(100, 64, 90, 500, 1),
            ScoreNote(100, 36, 90, 500, 2)))
        val packets = ScoreTransfer.encode(score)
        assertEquals(8, packets.size) // begin + 6 events + commit
        assertEquals(6, ((packets.first()[2].toInt() and 255) shl 8) or
            (packets.first()[3].toInt() and 255))
        for (i in 1..3) {
            val record = packets[i]
            assertEquals(100, ((record[1].toInt() and 31) shl 16) or
                ((record[2].toInt() and 255) shl 8) or (record[3].toInt() and 255))
            assertTrue((record[1].toInt() and 0x20) != 0)
        }
        assertEquals(0, packets[1][1].toInt() ushr 6 and 3)
        assertEquals(1, packets[2][1].toInt() ushr 6 and 3)
        assertEquals(2, packets[3][1].toInt() ushr 6 and 3)
    }

    @Test fun overlappingSamePitchHasNoStaleOff() {
        val packets = ScoreTransfer.encode(MusicScore("重叠", listOf(
            ScoreNote(0, 60, 90, 500), ScoreNote(200, 60, 80, 500))))
        assertEquals(6, packets.size) // begin, on, replacement off+on, final off, commit
        assertEquals(200, ((packets[2][2].toInt() and 255) shl 8) or
            (packets[2][3].toInt() and 255))
        assertEquals(0, packets[2][1].toInt() and 0x20)
        assertEquals(0x20, packets[3][1].toInt() and 0x20)
    }

    @Test fun sustainExtendsStoredOffUntilPedalRelease() {
        val packets = ScoreTransfer.encode(MusicScore("延音",
            listOf(ScoreNote(0, 60, 90, 250)),
            listOf(ScorePedal(0, 127), ScorePedal(500, 0))))
        assertEquals(500, ((packets[2][2].toInt() and 255) shl 8) or
            (packets[2][3].toInt() and 255))
    }
}
