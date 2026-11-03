package com.gowin.musiccontroller

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MidiFileTest {
    private fun chunk(tag: String, body: ByteArray): ByteArray {
        val result = ByteArrayOutputStream()
        DataOutputStream(result).use {
            it.write(tag.toByteArray(Charsets.US_ASCII))
            it.writeInt(body.size)
            it.write(body)
        }
        return result.toByteArray()
    }

    private fun midi(vararg tracks: ByteArray, division: Int = 480): ByteArray {
        val header = ByteArrayOutputStream()
        DataOutputStream(header).use {
            it.writeShort(if (tracks.size == 1) 0 else 1)
            it.writeShort(tracks.size)
            it.writeShort(division)
        }
        val result = ByteArrayOutputStream()
        result.write(chunk("MThd", header.toByteArray()))
        tracks.forEach { result.write(chunk("MTrk", it)) }
        return result.toByteArray()
    }

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    @Test fun multiTrackTempoRunningStatusAndDrumTrack() {
        val tempo = bytes(
            0, 0xff, 0x51, 3, 0x07, 0xa1, 0x20, // 120 BPM
            0x83, 0x60, 0xff, 0x51, 3, 0x0f, 0x42, 0x40, // 60 BPM at tick 480
            0, 0xff, 0x2f, 0
        )
        val melody = ByteArrayOutputStream().apply {
            write(bytes(0, 0xff, 3, 6))
            write("Melody".toByteArray())
            write(bytes(0, 0x90, 60, 90, 0, 64, 80)) // running Note On
            write(bytes(0x83, 0x60, 0x80, 60, 0, 0, 64, 0))
            write(bytes(0, 0x90, 67, 100, 0x83, 0x60, 67, 0)) // running velocity-zero Off
            write(bytes(0, 0xff, 0x2f, 0))
        }.toByteArray()
        val drums = bytes(0, 0x99, 36, 100, 0x81, 0x70, 0x89, 36, 0,
            0, 0xff, 0x2f, 0)
        val file = MidiFile.parse(midi(tempo, melody, drums))
        assertEquals(listOf(1, 2), file.playableTracks.map { it.index })
        assertEquals("Melody", file.playableTracks.first().name)
        assertEquals(listOf(
            ScoreNote(0, 60, 90, 500), ScoreNote(0, 64, 80, 500),
            ScoreNote(500, 67, 100, 1000)
        ), file.toScore(1, "测试").notes)
        assertEquals(listOf(ScoreNote(0, 36, 100, 250, 2)), file.toScore(2, "鼓").notes)
        assertEquals(4, file.toScoreAll("全部轨道").notes.size)
    }

    @Test fun programChangeSelectsOrganWithoutChangingPianoTrack() {
        val track = bytes(0, 0xc0, 19, 0, 0x90, 60, 100,
            0x83, 0x60, 0x80, 60, 0,
            0, 0xc0, 0, 0, 0x90, 64, 90,
            0x83, 0x60, 0x80, 64, 0, 0, 0xff, 0x2f, 0)
        val score = MidiFile.parse(midi(track)).toScore(0, "音色")
        assertEquals(listOf(ScoreNote(0, 60, 100, 500, 1),
            ScoreNote(500, 64, 90, 500, 0)), score.notes)
    }

    @Test fun typeZeroAndMalformedFiles() {
        val oneTrack = bytes(0, 0xc0, 5, 0, 0x90, 60, 100,
            0x83, 0x60, 0x90, 60, 0, 0, 0xff, 0x2f, 0)
        val file = MidiFile.parse(midi(oneTrack))
        assertEquals(ScoreNote(0, 60, 100, 500), file.toScore(0, "单轨").notes.single())
        assertThrows(IllegalArgumentException::class.java) { MidiFile.parse(bytes(1, 2, 3)) }
        assertThrows(IllegalArgumentException::class.java) {
            MidiFile.parse(midi(oneTrack, division = 0xe728)) // SMPTE
        }
        assertThrows(IllegalArgumentException::class.java) {
            MidiFile.parse(midi(bytes(0, 60, 100, 0, 0xff, 0x2f, 0)))
        }
    }

    @Test fun sustainControllerIsPreservedAfterNoteOff() {
        val track = bytes(
            0, 0xb0, 64, 127, 0, 0x90, 60, 90,
            0x81, 0x70, 0x80, 60, 0,
            0x81, 0x70, 0xb0, 64, 0,
            0, 0xff, 0x2f, 0
        )
        val score = MidiFile.parse(midi(track)).toScore(0, "踏板测试")
        assertEquals(listOf(ScoreNote(0, 60, 90, 250)), score.notes)
        assertEquals(listOf(ScorePedal(0, 127), ScorePedal(500, 0)), score.pedals)
    }

    @Test fun controllerOnlyTrackCanReleaseSelectedPianoTrack() {
        val piano = bytes(0, 0x90, 60, 90,
            0x81, 0x70, 0x80, 60, 0,
            0, 0xff, 0x2f, 0)
        val controller = bytes(0, 0xb0, 64, 127,
            0x83, 0x60, 0xb0, 64, 0,
            0, 0xff, 0x2f, 0)
        val file = MidiFile.parse(midi(piano, controller))
        assertEquals(listOf(ScorePedal(0, 127), ScorePedal(500, 0)),
            file.toScore(0, "控制轨").pedals)
        assertEquals(2, file.toScoreAll("全部").pedals.size)
    }

    @Test fun realMutopiaMidiCanBeImported() {
        // https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=2247 (Public Domain)
        val data = requireNotNull(javaClass.getResourceAsStream("/mutopia-vocalise1.mid"))
            .use { it.readBytes() }
        val file = MidiFile.parse(data)
        assert(file.playableTracks.isNotEmpty())
        val score = file.toScore(file.playableTracks.first().index, "Vocalise No. 1")
        assert(score.notes.isNotEmpty())
    }
}
