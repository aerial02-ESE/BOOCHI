package com.gowin.musiccontroller

data class AdsrSettings(var attackMs: Int = 5, var decayMs: Int = 105,
                        var sustainPercent: Int = 38, var releaseMs: Int = 168) {
    fun packets(target: Int): List<ByteArray> {
        require(target in 0..1)
        val sustain = ControlEvent.scalePercent(sustainPercent)
        fun slope(span: Int, ms: Int): Int =
            ((span.toLong() * 1000 + 48828L * ms.coerceIn(1, 1200) / 2) /
                (48828L * ms.coerceIn(1, 1200))).toInt().coerceIn(1, 65535)
        return listOf(slope(65535, attackMs), slope(65535 - sustain, decayMs),
            sustain, slope(65535, releaseMs)).mapIndexed { index, value ->
            ControlEvent.encode(ControlEvent.PARAM_CTRL, id = 0x10 + index,
                value = value, aux = target)
        }
    }
}
