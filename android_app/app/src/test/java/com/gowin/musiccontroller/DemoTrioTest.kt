package com.gowin.musiccontroller

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoTrioTest {
    @Test fun bundledMidiHasThreePlayableInstrumentsAndFitsFlashProtocol() {
        val bytes = File("src/main/assets/demo_trio.mid").readBytes()
        val score = MidiFile.parse(bytes).toScoreAll("星夜序曲")
        assertEquals(setOf(0, 1, 2), score.notes.map { it.instrument }.toSet())
        assertTrue(score.notes.size > 500)
        assertTrue(score.notes.maxOf { it.at + it.duration } < 90_000)
        val edges = score.notes.flatMap { note ->
            listOf(Triple(note.at, note.instrument, 1),
                   Triple(note.at + note.duration, note.instrument, -1))
        }.sortedWith(compareBy<Triple<Int, Int, Int>> { it.first }.thenBy { it.third })
        val active = IntArray(3)
        edges.forEach { (_, instrument, change) ->
            active[instrument] += change
            assertTrue(active[0] <= 16 && active[1] <= 8 && active[2] <= 8)
            assertTrue(active.sum() <= 32)
        }
        val packets = ScoreTransfer.encode(score)
        assertTrue(packets.size < ScoreTransfer.MAX_EVENTS + 2)
        assertEquals(ScoreTransfer.CONTROL, packets.first()[0].toInt() and 0xff)
        assertEquals(ScoreTransfer.CONTROL, packets.last()[0].toInt() and 0xff)
    }
}
