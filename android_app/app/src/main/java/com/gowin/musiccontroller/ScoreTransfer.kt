package com.gowin.musiccontroller

/** Offline score upload v1: 8-byte events; ESP32 validates count and CRC before Flash commit. */
object ScoreTransfer {
    const val RECORD = 0x4c
    const val CONTROL = 0x4e
    const val MAX_EVENTS = 8192

    private data class Action(val at: Int, val note: Int, val velocity: Int,
                              val instrument: Int, val on: Boolean, val token: Int)

    fun control(operation: Int, count: Int = 0, crc: Int = 0): ByteArray {
        require(operation in 0..4 && count in 0..MAX_EVENTS && crc in 0..65535)
        return byteArrayOf(CONTROL.toByte(), operation.toByte(),
            (count ushr 8).toByte(), count.toByte(),
            (crc ushr 8).toByte(), crc.toByte(), 0, 0)
    }

    fun encode(score: MusicScore): List<ByteArray> {
        val pedals = score.pedals.sortedBy { it.at }
        val songEnd = score.notes.maxOfOrNull { it.at + it.duration } ?: 0
        fun releaseAt(nominal: Int): Int {
            var down = false
            for (pedal in pedals) {
                if (pedal.at >= nominal) break
                down = pedal.value >= 64
            }
            if (!down) return nominal
            return pedals.firstOrNull { it.at >= nominal && it.value < 64 }?.at ?: songEnd
        }
        val actions = score.notes.flatMapIndexed { token, note ->
            listOf(Action(note.at, note.note, note.velocity, note.instrument, true, token),
                Action(releaseAt(note.at + note.duration), note.note, 0,
                    note.instrument, false, token))
        }.sortedWith(compareBy<Action> { it.at }.thenBy { if (it.on) 1 else 0 })
        val active = HashMap<Int, Int>()
        val records = ArrayList<ByteArray>(actions.size)
        fun append(action: Action) {
            require(action.at in 0..600_000) { "乐谱时长超过 10 分钟" }
            require(records.size < MAX_EVENTS) { "本地乐谱超过 8192 个事件" }
            records.add(byteArrayOf(RECORD.toByte(),
                ((action.instrument shl 6) or (if (action.on) 0x20 else 0) or
                    (action.at ushr 16)).toByte(),
                (action.at ushr 8).toByte(), action.at.toByte(),
                action.note.toByte(), action.velocity.toByte(), 0, 0))
        }
        for (action in actions) {
            val key = action.instrument * 128 + action.note
            if (action.on) {
                if (active.containsKey(key)) append(action.copy(on = false, velocity = 0))
                active[key] = action.token
                append(action)
            } else if (active[key] == action.token) {
                active.remove(key)
                append(action)
            }
        }
        require(records.isNotEmpty()) { "乐谱没有音符" }
        var crc = 0xffff
        records.forEach { record -> record.forEach { value ->
            crc = crc xor ((value.toInt() and 0xff) shl 8)
            repeat(8) { crc = if (crc and 0x8000 != 0)
                ((crc shl 1) xor 0x1021) and 0xffff else (crc shl 1) and 0xffff }
        } }
        return listOf(control(0, records.size)) + records + listOf(control(1, crc = crc))
    }
}
