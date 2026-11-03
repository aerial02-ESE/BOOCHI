package com.gowin.musiccontroller

object SppFrame {
    private fun crc(bytes: ByteArray, length: Int): Int {
        var value = 0xffff
        for (i in 2 until (length + 4)) {
            value = value xor ((bytes[i].toInt() and 255) shl 8)
            repeat(8) {
                value = ((value shl 1) xor (if (value and 0x8000 != 0) 0x1021 else 0)) and 0xffff
            }
        }
        return value
    }

    fun encode(payload: ByteArray): ByteArray {
        require(payload.size == 8 || payload.size == 20)
        val bytes = ByteArray(payload.size + 6)
        bytes[0] = 0xa5.toByte()
        bytes[1] = 0x5a
        bytes[2] = 1
        bytes[3] = payload.size.toByte()
        payload.copyInto(bytes, 4)
        val checksum = crc(bytes, payload.size)
        bytes[payload.size + 4] = (checksum shr 8).toByte()
        bytes[payload.size + 5] = checksum.toByte()
        return bytes
    }

    class Decoder {
        private val bytes = ByteArray(26)
        private var used = 0

        fun accept(byte: Byte): ByteArray? {
            bytes[used++] = byte
            while (used >= 4) {
                val length = bytes[3].toInt() and 255
                if (bytes[0] == 0xa5.toByte() && bytes[1] == 0x5a.toByte() &&
                    bytes[2] == 1.toByte() && (length == 8 || length == 20)) {
                    if (used < length + 6) return null
                    val checksum = ((bytes[length + 4].toInt() and 255) shl 8) or
                        (bytes[length + 5].toInt() and 255)
                    if (crc(bytes, length) == checksum) {
                        val payload = bytes.copyOfRange(4, length + 4)
                        bytes.copyInto(bytes, 0, length + 6, used)
                        used -= length + 6
                        return payload
                    }
                }
                bytes.copyInto(bytes, 0, 1, used)
                used--
            }
            return null
        }
    }
}
