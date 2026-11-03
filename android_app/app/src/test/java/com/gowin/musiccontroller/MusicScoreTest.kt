package com.gowin.musiccontroller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MusicScoreTest {
    @Test fun exampleFormatRoundTrips() {
        val source = """{"version":1,"title":"测试","notes":[{"at":0,"note":60,"velocity":90,"duration":500}]}"""
        val score = MusicScore.parse(source)
        assertEquals("测试", score.title)
        assertEquals(ScoreNote(0, 60, 90, 500), score.notes.single())
        assertEquals(score, MusicScore.parse(score.toJson()))
        val withPedal = score.copy(pedals = listOf(ScorePedal(0, 127), ScorePedal(750, 0)))
        assertEquals(withPedal, MusicScore.parse(withPedal.toJson()))
    }

    @Test fun invalidScoreIsRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            MusicScore.parse("""{"version":1,"notes":[{"at":-1,"note":60,"velocity":90,"duration":500}]}""")
        }
        assertThrows(IllegalArgumentException::class.java) {
            MusicScore.parse("""{"version":2,"notes":[]}""")
        }
    }

    @Test fun notificationRecordingBecomesReplayableScore() {
        val recorder = PerformanceRecorder()
        recorder.start(1_000)
        recorder.accept(ControlEvent.encode(ControlEvent.NOTE_ON, id = 60,
            value = 65535, source = 0), 1_100)
        recorder.accept(ControlEvent.encode(ControlEvent.NOTE_OFF, id = 60,
            source = 0), 1_600)
        val score = recorder.stop(1_700, "实测")
        assertEquals(ScoreNote(100, 60, 127, 500), score.notes.single())
        assertEquals(score, MusicScore.parse(score.toJson()))
    }

    @Test fun bundledScoresArePlayableAndSerializable() {
        assertEquals(3, PresetScores.all.size)
        PresetScores.all.forEach { score ->
            assertEquals(score, MusicScore.parse(score.toJson()))
            assert(score.notes.isNotEmpty())
            assert(score.notes.zipWithNext().all { (a, b) -> a.at < b.at })
        }
    }
}
