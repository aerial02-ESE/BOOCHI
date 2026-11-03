package com.gowin.musiccontroller

/** 从 BLE 通知重建 Note On/Off。通知尽力送达，因此不是无损录音。 */
class PerformanceRecorder {
    private data class Press(val at: Int, val velocity: Int)
    private var originMs = 0L
    private val held = mutableMapOf<Int, Press>()
    private val completed = mutableListOf<ScoreNote>()
    var active = false
        private set

    val noteCount: Int get() = completed.size

    fun start(nowMs: Long) {
        originMs = nowMs
        held.clear()
        completed.clear()
        active = true
    }

    private fun elapsed(nowMs: Long): Int = (nowMs - originMs).coerceIn(0, 600_000).toInt()

    private fun finish(key: Int, nowMs: Long) {
        val press = held.remove(key) ?: return
        if (completed.size >= 4096) return
        val duration = (elapsed(nowMs) - press.at).coerceIn(1, 30_000)
        completed.add(ScoreNote(press.at, key and 0x7f, press.velocity, duration))
    }

    fun accept(bytes: ByteArray, nowMs: Long) {
        if (!active || bytes.size != 8) return
        val event = try { ControlEvent.decode(bytes) } catch (_: IllegalArgumentException) { return }
        if (event.type == ControlEvent.ALL_NOTES_OFF) {
            held.keys.toList().forEach { finish(it, nowMs) }
            return
        }
        if (event.type != ControlEvent.NOTE_ON && event.type != ControlEvent.NOTE_OFF) return
        val key = (event.source shl 15) or (event.channel shl 7) or event.id
        if (event.type == ControlEvent.NOTE_OFF || event.value == 0) {
            finish(key, nowMs)
        } else {
            finish(key, nowMs) // 重复 Note On 先结束旧音，防止挂音。
            if (completed.size < 4096)
                held[key] = Press(elapsed(nowMs),
                    ((event.value.toLong() * 127 + 32767) / 65535).toInt().coerceIn(1, 127))
        }
    }

    fun stop(nowMs: Long, title: String): MusicScore {
        held.keys.toList().forEach { finish(it, nowMs) }
        active = false
        return MusicScore(title.take(80), completed.sortedBy { it.at }.toList())
    }
}
