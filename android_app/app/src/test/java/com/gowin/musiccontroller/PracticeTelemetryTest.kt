package com.gowin.musiccontroller
import org.junit.Assert.*
import org.junit.Test
class PracticeTelemetryTest {
    private fun golden():ByteArray = "5007090d0005000200010003000001003c01607e".chunked(2).map{it.toInt(16).toByte()}.toByteArray()
    @Test fun decodeNativeGoldenAndWholeSongAccuracy(){
        val p=PracticeTelemetry.decode(golden())
        assertEquals(5,p.total);assertEquals(2,p.hits);assertEquals(1,p.wrong);assertEquals(3,p.misses)
        assertEquals(256L,p.elapsedMs);assertEquals(100.0,p.progress,0.001)
        assertEquals(100.0/3,p.songAccuracy,0.001)
    }
    @Test fun corruptedSnapshotRejected(){
        val bytes=golden();bytes[6]=7
        assertThrows(IllegalArgumentException::class.java){PracticeTelemetry.decode(bytes)}
    }
    @Test fun missedNotificationsDoNotLoseScores(){
        val first=PracticeTelemetry.decode(golden())
        val later=first.copy(hits=4,misses=1)
        assertEquals(4,later.hits);assertEquals(400.0/6,later.songAccuracy,0.001)
    }
    @Test fun targetFilterAndSameKeyChordDedup(){
        val score=MusicScore("练习",listOf(ScoreNote(0,60,90,100),ScoreNote(0,60,90,100,1),
            ScoreNote(0,36,90,100,2),ScoreNote(100,108,90,100)))
        assertEquals(listOf(0 to 60,100 to 108),PracticePlan.targets(score))
    }
    @Test fun overDenseSongRejectedBeforeStart(){
        val score=MusicScore("过密",(0..56).map{ScoreNote(it,60,90,1)})
        assertThrows(IllegalArgumentException::class.java){PracticePlan.targets(score)}
    }
    @Test fun practiceCommandSeparateFromAutoPlayback(){
        val packet=ScoreTransfer.control(4,17)
        assertEquals(4,packet[1].toInt());assertEquals(17,packet[3].toInt())
    }
    @Test fun deliveredAcceptanceMidiImportsAndKeepsBoundaryKeysAndChord(){
        val bytes=javaClass.getResourceAsStream("/practice_acceptance.mid")!!.use { it.readBytes() }
        val targets=PracticePlan.targets(MidiFile.parse(bytes).toScoreAll("跟弹验收"))
        assertEquals(15,targets.size)
        assertEquals(listOf(0 to 21,2000 to 80,4000 to 81,6000 to 108),targets.take(4))
        assertEquals(listOf(14000 to 60,14000 to 64,14000 to 67),targets.takeLast(3))
    }
}
