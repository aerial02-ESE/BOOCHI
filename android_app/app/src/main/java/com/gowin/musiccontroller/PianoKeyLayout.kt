package com.gowin.musiccontroller

import kotlin.math.abs

/** 一个八度从 C 到下一个 C：八个白键、五个黑键，共 13 个音。 */
object PianoKeyLayout {
    const val minNote = 21  // A0
    const val maxNote = 108 // C8
    const val minWindowStart = 12 // C0–C1；低于 A0 的键置灰
    const val maxWindowStart = 96 // C7–C8
    val whiteOffsets = intArrayOf(0, 2, 4, 5, 7, 9, 11, 12)
    val blackOffsets = intArrayOf(1, 3, 6, 8, 10)
    val blackBoundaries = intArrayOf(1, 2, 4, 5, 6)
    const val blackWidthRatio = 0.58f
    const val blackHeightRatio = 0.60f

    fun isPlayable(note: Int): Boolean = note in minNote..maxNote

    fun noteAt(startNote: Int, width: Float, height: Float, x: Float, y: Float): Int? {
        if (width <= 0f || height <= 0f || x < 0f || x >= width || y < 0f || y >= height)
            return null
        val whiteWidth = width / whiteOffsets.size
        if (y < height * blackHeightRatio) {
            for (i in blackOffsets.indices) {
                if (abs(x - blackBoundaries[i] * whiteWidth) <=
                    whiteWidth * blackWidthRatio / 2f)
                    return (startNote + blackOffsets[i]).takeIf(::isPlayable)
            }
        }
        return (startNote + whiteOffsets[(x / whiteWidth).toInt().coerceIn(0, 7)])
            .takeIf(::isPlayable)
    }
}
