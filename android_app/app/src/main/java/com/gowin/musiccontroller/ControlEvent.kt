package com.gowin.musiccontroller

/** 与 ../docs/手机协议.md 完全一致；BLE 中只传 8 字节事件，不传 UART 帧。 */
object ControlEvent {
    const val NOTE_ON = 1
    const val NOTE_OFF = 2
    const val PITCH_BEND = 3
    const val PRESSURE = 4
    const val MODULATION = 5
    const val SUSTAIN = 6
    const val EFFECT_CTRL = 8
    const val ALL_NOTES_OFF = 9
    const val PARAM_CTRL = 11

    fun encode(type: Int, id: Int = 0, value: Int = 0, aux: Int = 0,
               source: Int = 1): ByteArray {
        require(type in 0..63 && id in 0..255 && value in 0..65535 &&
                aux in 0..255 && source in 0..15)
        return byteArrayOf((0x40 or type).toByte(), ((source shl 4) or 15).toByte(),
            0, id.toByte(), (value ushr 8).toByte(), value.toByte(), aux.toByte(), 0)
    }

    fun note(note: Int, velocity: Int, on: Boolean): ByteArray {
        require(note in 0..127 && velocity in 0..127)
        return encode(if (on) NOTE_ON else NOTE_OFF, note,
            if (on) velocity * 65535 / 127 else 0)
    }

    fun scalePercent(percent: Int): Int = percent.coerceIn(0, 100) * 65535 / 100

    fun displayPage(page: Int): ByteArray {
        require(page in 0..2)
        return encode(PARAM_CTRL, id = 0x21, value = page)
    }

    fun timbreMode(mode: Int, split: Boolean): ByteArray {
        require(mode in 0..11 && (!split || mode != 3))
        return encode(PARAM_CTRL, id = 0x20, value = mode, aux = if (split) 1 else 0)
    }

    /** source 0 在 ESP32 映射 SMK-25；source 1 转发给 FPGA 映射直连 88 键。 */
    fun keyMap(source: Int, inputNote: Int, outputNote: Int): ByteArray {
        require(source in 0..1 && inputNote in 0..127 && outputNote in 0..127)
        return encode(PARAM_CTRL, id = 0x80 or inputNote, value = outputNote, source = source)
    }

    data class Decoded(val type: Int, val source: Int, val channel: Int,
                       val id: Int, val value: Int, val aux: Int, val sequence: Int)

    fun decode(bytes: ByteArray): Decoded {
        require(bytes.size == 8 && (bytes[0].toInt() and 0xC0) == 0x40)
        val b1 = bytes[1].toInt() and 0xFF
        return Decoded(bytes[0].toInt() and 0x3F, b1 ushr 4, b1 and 15,
            bytes[3].toInt() and 0xFF,
            ((bytes[4].toInt() and 0xFF) shl 8) or (bytes[5].toInt() and 0xFF),
            bytes[6].toInt() and 0xFF, bytes[7].toInt() and 0xFF)
    }
}
