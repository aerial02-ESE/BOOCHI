package com.gowin.musiccontroller

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PianoKeyLayoutTest {
    @Test fun entireOctaveFitsInOneWidth() {
        val expected = intArrayOf(60, 62, 64, 65, 67, 69, 71, 72)
        for (i in expected.indices)
            assertEquals(expected[i], PianoKeyLayout.noteAt(60, 800f, 180f,
                i * 100f + 50f, 160f))
    }

    @Test fun blackKeysHavePriorityAboveWhiteKeys() {
        val expected = intArrayOf(61, 63, 66, 68, 70)
        for (i in expected.indices)
            assertEquals(expected[i], PianoKeyLayout.noteAt(60, 800f, 180f,
                PianoKeyLayout.blackBoundaries[i] * 100f, 30f))
    }

    @Test fun lowerRangeAndOutsideBounds() {
        assertEquals(48, PianoKeyLayout.noteAt(48, 800f, 180f, 10f, 160f))
        assertEquals(60, PianoKeyLayout.noteAt(48, 800f, 180f, 790f, 160f))
        assertNull(PianoKeyLayout.noteAt(60, 800f, 180f, 800f, 30f))
    }

    @Test fun octaveStepsCoverAllEightyEightKeys() {
        val visibleNotes = mutableSetOf<Int>()
        for (start in PianoKeyLayout.minWindowStart..PianoKeyLayout.maxWindowStart step 12) {
            for (offset in PianoKeyLayout.whiteOffsets + PianoKeyLayout.blackOffsets) {
                val note = start + offset
                if (PianoKeyLayout.isPlayable(note)) visibleNotes.add(note)
            }
        }
        assertEquals((21..108).toSet(), visibleNotes)
        assertNull(PianoKeyLayout.noteAt(12, 800f, 180f, 50f, 160f))
        assertEquals(21, PianoKeyLayout.noteAt(12, 800f, 180f, 550f, 160f))
        assertEquals(108, PianoKeyLayout.noteAt(96, 800f, 180f, 750f, 160f))
    }
}
