package com.gowin.musiccontroller

import java.util.ArrayDeque

/** 有界 Standard MIDI File (SMF 0/1) 读取器；提取音符与 CC64 踏板。 */
class MidiFile private constructor(
    private val ppq: Int,
    private val tracks: List<Track>,
    private val tempo: List<TempoPoint>
) {
    data class TrackInfo(val index: Int, val name: String, val noteCount: Int) {
        val label: String get() = "轨道 ${index + 1} · $name · $noteCount 个音符"
    }

    private data class Edge(val tick: Long, val channel: Int, val note: Int,
                            val velocity: Int, val on: Boolean, val order: Int,
                            val instrument: Int)
    private data class PedalEdge(val tick: Long, val channel: Int, val value: Int,
                                 val order: Int)
    private data class Track(val name: String, val edges: List<Edge>,
                             val pedals: List<PedalEdge>)
    private data class TempoEvent(val tick: Long, val microsPerQuarter: Int, val order: Int)
    private data class TempoPoint(val tick: Long, val microsPerQuarter: Int,
                                  val elapsedMicros: Long)
    private data class NoteOn(val tick: Long, val velocity: Int, val instrument: Int)

    val playableTracks: List<TrackInfo> = tracks.mapIndexedNotNull { index, track ->
        val count = track.edges.count { it.on }
        if (count == 0) null else TrackInfo(index, track.name.ifBlank { "未命名" }, count)
    }

    private fun microsAt(tick: Long): Long {
        var low = 0
        var high = tempo.lastIndex
        while (low < high) {
            val middle = (low + high + 1) / 2
            if (tempo[middle].tick <= tick) low = middle else high = middle - 1
        }
        val point = tempo[low]
        return point.elapsedMicros + (tick - point.tick) * point.microsPerQuarter / ppq
    }

    /** 合并全部音符轨道；仍在各自轨道内匹配 Note On/Off，避免同通道串轨释放。 */
    fun toScoreAll(title: String): MusicScore =
        scoreFromTracks(playableTracks.map { it.index }, title)

    /** 将所选音符轨道转换成现有 BLE 乐谱；未闭合的 Note On 不会留下长音。 */
    fun toScore(trackIndex: Int, title: String): MusicScore =
        scoreFromTracks(listOf(trackIndex), title)

    private fun scoreFromTracks(indices: List<Int>, title: String): MusicScore {
        require(indices.isNotEmpty() && indices.all { it in tracks.indices }) {
            "没有可播放的音符轨道"
        }
        val notes = ArrayList<ScoreNote>()
        val pedalEvents = ArrayList<PedalEdge>()
        for (index in indices) {
            pedalEvents.addAll(tracks[index].pedals)
            val pressed = Array(16 * 128) { ArrayDeque<NoteOn>() }
            for (edge in tracks[index].edges) {
                val queue = pressed[edge.channel * 128 + edge.note]
                if (edge.on) {
                    queue.addLast(NoteOn(edge.tick, edge.velocity, edge.instrument))
                } else if (!queue.isEmpty()) {
                    val start = queue.removeFirst()
                    val at = microsAt(start.tick) / 1_000
                    val end = microsAt(edge.tick) / 1_000
                    require(at in 0..600_000 && end <= 600_000) { "乐谱超过 10 分钟播放上限" }
                    val duration = (end - at).coerceAtLeast(1)
                    require(duration <= 30_000) { "单个音符超过 30 秒上限" }
                    require(notes.size < 4096) { "所选轨道超过 4096 个音符上限" }
                    notes.add(ScoreNote(at.toInt(), edge.note, start.velocity,
                                        duration.toInt(), start.instrument))
                }
            }
        }
        // SMF type 1 may keep CC64 in a controller-only track. Include it
        // when its MIDI channel belongs to the selected notes.
        val selectedChannels = indices.flatMap { index ->
            tracks[index].edges.filter { it.on }.map { it.channel }
        }.toSet()
        tracks.forEachIndexed { index, track ->
            if (index !in indices && track.edges.none { it.on }) {
                pedalEvents.addAll(track.pedals.filter { it.channel in selectedChannels })
            }
        }
        require(notes.isNotEmpty()) { "没有完整的音符起止事件" }
        require(pedalEvents.size <= 4096) { "所选轨道踏板事件过多" }
        val pedals = pedalEvents.sortedWith(compareBy<PedalEdge> { it.tick }.thenBy { it.order })
            .map {
                val at = microsAt(it.tick) / 1_000
                require(at in 0..600_000) { "踏板事件超过 10 分钟播放上限" }
                ScorePedal(at.toInt(), it.value)
            }
        return MusicScore(title.take(80), notes.sortedWith(compareBy<ScoreNote> { it.at }
            .thenBy { it.note }), pedals)
    }

    private class Cursor(private val data: ByteArray, var position: Int = 0,
                         private val end: Int = data.size) {
        fun remaining() = end - position
        fun u8(): Int {
            require(position < end) { "MIDI 文件意外结束" }
            return data[position++].toInt() and 0xff
        }
        fun u16(): Int = (u8() shl 8) or u8()
        fun u32(): Long = (u8().toLong() shl 24) or (u8().toLong() shl 16) or
            (u8().toLong() shl 8) or u8().toLong()
        fun variable(): Long {
            var value = 0L
            repeat(4) {
                val byte = u8()
                value = (value shl 7) or (byte and 0x7f).toLong()
                if (byte and 0x80 == 0) return value
            }
            throw IllegalArgumentException("MIDI 变长整数超过 4 字节")
        }
        fun bytes(length: Int): ByteArray {
            require(length >= 0 && length <= remaining()) { "MIDI 区块长度无效" }
            val result = data.copyOfRange(position, position + length)
            position += length
            return result
        }
        fun skip(length: Int) {
            require(length >= 0 && length <= remaining()) { "MIDI 区块长度无效" }
            position += length
        }
        fun tag(): String = bytes(4).toString(Charsets.US_ASCII)
        fun slice(length: Int): Cursor {
            require(length >= 0 && length <= remaining()) { "MIDI 轨道长度无效" }
            val part = Cursor(data, position, position + length)
            position += length
            return part
        }
    }

    companion object {
        fun isMidi(data: ByteArray): Boolean = data.size >= 4 &&
            data[0] == 'M'.code.toByte() && data[1] == 'T'.code.toByte() &&
            data[2] == 'h'.code.toByte() && data[3] == 'd'.code.toByte()

        fun parse(data: ByteArray): MidiFile {
            require(data.size <= 524_288) { "MIDI 文件超过 512 KB" }
            val input = Cursor(data)
            require(input.remaining() >= 14 && input.tag() == "MThd") { "不是标准 MIDI 文件" }
            val headerLength = input.u32()
            require(headerLength in 6..1024) { "MIDI 文件头长度无效" }
            val format = input.u16()
            val count = input.u16()
            val division = input.u16()
            input.skip(headerLength.toInt() - 6)
            require(format in 0..1 && count in 1..64 && (format != 0 || count == 1)) {
                "仅支持 SMF 0/1，最多 64 条轨道"
            }
            require(division in 1..0x7fff) { "暂不支持 SMPTE 时间格式" }

            val tracks = ArrayList<Track>()
            val tempoEvents = ArrayList<TempoEvent>()
            var eventOrder = 0
            while (tracks.size < count && input.remaining() >= 8) {
                val tag = input.tag()
                val length = input.u32()
                require(length <= input.remaining()) { "MIDI 区块长度无效" }
                if (tag != "MTrk") {
                    input.skip(length.toInt())
                    continue
                }
                val track = input.slice(length.toInt())
                val edges = ArrayList<Edge>()
                val pedals = ArrayList<PedalEdge>()
                var name = ""
                var tick = 0L
                var runningStatus = 0
                val program = IntArray(16)
                while (track.remaining() > 0) {
                    tick += track.variable()
                    require(tick <= 1_000_000_000L) { "MIDI 时间位置过大" }
                    var status = track.u8()
                    var firstData = -1
                    if (status < 0x80) {
                        require(runningStatus in 0x80..0xef) { "MIDI 运行状态无效" }
                        firstData = status
                        status = runningStatus
                    } else if (status in 0x80..0xef) {
                        runningStatus = status
                    } else {
                        runningStatus = 0
                    }
                    when (status) {
                        0xff -> {
                            val kind = track.u8()
                            val size = track.variable()
                            require(size <= track.remaining()) { "MIDI 元事件长度无效" }
                            when (kind) {
                                0x03 -> name = track.bytes(size.toInt()).toString(Charsets.UTF_8)
                                    .filter { it >= ' ' }.take(40)
                                0x51 -> {
                                    require(size == 3L) { "MIDI 速度事件长度无效" }
                                    val value = (track.u8() shl 16) or
                                        (track.u8() shl 8) or track.u8()
                                    require(value > 0) { "MIDI 速度必须大于零" }
                                    tempoEvents.add(TempoEvent(tick, value, eventOrder++))
                                }
                                0x2f -> { track.skip(size.toInt()); break }
                                else -> track.skip(size.toInt())
                            }
                        }
                        0xf0, 0xf7 -> {
                            val size = track.variable()
                            require(size <= track.remaining()) { "MIDI SysEx 长度无效" }
                            track.skip(size.toInt())
                        }
                        in 0x80..0xef -> {
                            val command = status and 0xf0
                            val channel = status and 0x0f
                            val first = if (firstData >= 0) firstData else track.u8()
                            require(first < 0x80) { "MIDI 音符数据无效" }
                            val second = if (command == 0xc0 || command == 0xd0) -1 else track.u8()
                            require(second < 0x80) { "MIDI 事件数据无效" }
                            if (command == 0xc0) {
                                program[channel] = first
                            } else if (command == 0x80 || command == 0x90) {
                                val instrument = when {
                                    channel == 9 -> 2
                                    program[channel] in 16..23 -> 1
                                    else -> 0
                                }
                                edges.add(Edge(tick, channel, first, second,
                                    command == 0x90 && second != 0, eventOrder++, instrument))
                            } else if (command == 0xb0 && first == 64) {
                                pedals.add(PedalEdge(tick, channel, second, eventOrder++))
                            }
                        }
                        else -> throw IllegalArgumentException("暂不支持 MIDI 系统事件 0x${status.toString(16)}")
                    }
                }
                tracks.add(Track(name, edges, pedals))
            }
            require(tracks.size == count) { "MIDI 轨道不完整" }
            val points = ArrayList<TempoPoint>()
            var lastTick = 0L
            var elapsed = 0L
            var currentTempo = 500_000
            points.add(TempoPoint(0, currentTempo, 0))
            for (event in tempoEvents.sortedWith(compareBy<TempoEvent> { it.tick }.thenBy { it.order })) {
                elapsed += (event.tick - lastTick) * currentTempo / division
                lastTick = event.tick
                currentTempo = event.microsPerQuarter
                if (points.last().tick == lastTick) points[points.lastIndex] =
                    TempoPoint(lastTick, currentTempo, elapsed)
                else points.add(TempoPoint(lastTick, currentTempo, elapsed))
            }
            return MidiFile(division, tracks, points)
        }
    }
}
