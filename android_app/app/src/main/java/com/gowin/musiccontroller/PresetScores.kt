package com.gowin.musiccontroller

/** 内置的简化示范旋律；与下载曲谱使用同一种 MusicScore 格式。 */
object PresetScores {
    private fun melody(title: String, beatMs: Int, steps: List<Pair<Int, Int>>): MusicScore {
        var timeMs = 0
        val notes = steps.map { (pitch, beats) ->
            val lengthMs = beatMs * beats
            val note = ScoreNote(timeMs, pitch, 90, lengthMs * 9 / 10)
            timeMs += lengthMs
            note
        }
        return MusicScore(title, notes)
    }

    val all: List<MusicScore> by lazy {
        listOf(
            melody("小星星（简化）", 460, listOf(
                60 to 1, 60 to 1, 67 to 1, 67 to 1, 69 to 1, 69 to 1, 67 to 2,
                65 to 1, 65 to 1, 64 to 1, 64 to 1, 62 to 1, 62 to 1, 60 to 2,
                67 to 1, 67 to 1, 65 to 1, 65 to 1, 64 to 1, 64 to 1, 62 to 2,
                67 to 1, 67 to 1, 65 to 1, 65 to 1, 64 to 1, 64 to 1, 62 to 2,
                60 to 1, 60 to 1, 67 to 1, 67 to 1, 69 to 1, 69 to 1, 67 to 2,
                65 to 1, 65 to 1, 64 to 1, 64 to 1, 62 to 1, 62 to 1, 60 to 2
            )),
            melody("欢乐颂（简化）", 420, listOf(
                64 to 1, 64 to 1, 65 to 1, 67 to 1, 67 to 1, 65 to 1, 64 to 1, 62 to 1,
                60 to 1, 60 to 1, 62 to 1, 64 to 1, 64 to 2, 62 to 2,
                64 to 1, 64 to 1, 65 to 1, 67 to 1, 67 to 1, 65 to 1, 64 to 1, 62 to 1,
                60 to 1, 60 to 1, 62 to 1, 64 to 1, 62 to 2, 60 to 2
            )),
            melody("C 大调音阶练习", 360, listOf(
                60 to 1, 62 to 1, 64 to 1, 65 to 1, 67 to 1, 69 to 1, 71 to 1, 72 to 2,
                71 to 1, 69 to 1, 67 to 1, 65 to 1, 64 to 1, 62 to 1, 60 to 2
            ))
        )
    }
}
