package com.gowin.musiccontroller

import android.os.Handler
import android.os.Looper
import android.os.SystemClock

/** 手机端定时回放音符与 CC64；不把定时精度当作 FPGA 脱机演奏。 */
class ScorePlayer(private val sendNote: (Int, Int, Boolean) -> Boolean,
                  private val sendPedal: (Int) -> Boolean,
                  private val onProgress: (String) -> Unit,
                  private val flushEvents: () -> Boolean = { true }) {
    private data class Action(val at: Int, val note: Int, val velocity: Int,
                              val on: Boolean, val token: Int, val pedal: Int? = null)
    private val handler = Handler(Looper.getMainLooper())
    // The FPGA sees one phone channel. A later Note On at the same pitch
    // supersedes the earlier one; its stale Note Off must not release it.
    private val activeNotes = mutableMapOf<Int, Int>() // pitch -> note token
    private var actions = emptyList<Action>()
    private var index = 0
    private var originMs = 0L
    private val next = Runnable { runNext() }
    var playing = false
        private set

    fun play(score: MusicScore) {
        stop()
        if (!sendPedal(0)) {
            onProgress("蓝牙未连接，无法开始播放")
            return
        }
        actions = (score.notes.flatMapIndexed { token, note ->
            listOf(Action(note.at, note.note, note.velocity, true, token),
                Action(note.at + note.duration, note.note, 0, false, token))
        } + score.pedals.map { Action(it.at, 0, 0, false, -1, it.value) })
            .sortedWith(compareBy<Action> { it.at }.thenBy {
                when { it.pedal != null && it.pedal < 64 -> 0
                       !it.on && it.pedal == null -> 1
                       it.pedal != null -> 2
                       else -> 3 }
            })
        if (actions.isEmpty()) {
            onProgress("乐谱没有音符")
            return
        }
        playing = true
        index = 0
        originMs = SystemClock.elapsedRealtime()
        onProgress("正在播放：${score.title}")
        scheduleNext()
    }

    private fun scheduleNext() {
        if (!playing) return
        if (index == actions.size) {
            sendPedal(0)
            playing = false
            actions = emptyList()
            onProgress("播放完成")
            return
        }
        val delay = (originMs + actions[index].at - SystemClock.elapsedRealtime()).coerceAtLeast(0)
        handler.postDelayed(next, delay)
    }

    private fun runNext() {
        if (!playing) return
        val time = actions[index].at
        // Deliver every event on the same MIDI tick together to the BLE
        // coalescing window, instead of scheduling a separate UI callback.
        while (index < actions.size && actions[index].at == time) {
            val action = actions[index++]
            var accepted = true
            if (action.pedal != null) {
                accepted = sendPedal(action.pedal)
            } else if (action.on) {
                if (activeNotes.containsKey(action.note))
                    accepted = sendNote(action.note, 0, false)
                if (accepted) {
                    activeNotes[action.note] = action.token
                    accepted = sendNote(action.note, action.velocity, true)
                }
            } else {
                if (activeNotes[action.note] == action.token) {
                    activeNotes.remove(action.note)
                    accepted = sendNote(action.note, 0, false)
                }
            }
            if (!accepted) {
                playing = false
                actions = emptyList()
                activeNotes.clear()
                sendPedal(0)
                onProgress("蓝牙发送积压或断连，播放已停止")
                return
            }
        }
        if (!flushEvents()) {
            playing = false
            actions = emptyList()
            activeNotes.clear()
            sendPedal(0)
            onProgress("蓝牙批量发送失败，播放已停止")
            return
        }
        scheduleNext()
    }

    fun stop() {
        handler.removeCallbacks(next)
        if (playing) {
            sendPedal(0)
            activeNotes.keys.toList().forEach { sendNote(it, 0, false) }
            flushEvents()
            onProgress("已停止播放")
        }
        playing = false
        actions = emptyList()
        activeNotes.clear()
    }
}
