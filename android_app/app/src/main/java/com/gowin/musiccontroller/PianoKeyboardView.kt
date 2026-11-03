package com.gowin.musiccontroller

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View

/** 自适应屏幕宽度的 13 音琴键；一个 View 处理多指触控。 */
class PianoKeyboardView(context: Context, private val onNote: (Int, Boolean) -> Unit) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pointerNotes = mutableMapOf<Int, Int>()
    private val noteRefs = mutableMapOf<Int, Int>()
    private val whiteNames = arrayOf("C", "D", "E", "F", "G", "A", "B", "C")
    private val blackNames = arrayOf("C♯", "D♯", "F♯", "G♯", "A♯")
    private var startNote = 60
    private val density = resources.displayMetrics.density

    val hasHeldNotes: Boolean get() = noteRefs.isNotEmpty()

    init {
        minimumHeight = (174 * density + 0.5f).toInt()
        contentDescription = "虚拟琴键，可同时按多个音"
    }

    fun selectOctave(note: Int) {
        require(note in PianoKeyLayout.minWindowStart..PianoKeyLayout.maxWindowStart &&
            note % 12 == 0)
        if (startNote == note) return
        releaseAll()
        startNote = note
        invalidate()
    }

    fun releaseAll(sendNoteOff: Boolean = true) {
        if (sendNoteOff) noteRefs.keys.toList().forEach { onNote(it, false) }
        noteRefs.clear()
        pointerNotes.clear()
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec),
            resolveSize(minimumHeight, heightMeasureSpec))
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val keyWidth = width / 8f
        val gap = 1.1f * density
        val radius = 4f * density
        val whiteHeight = height.toFloat()
        for (i in PianoKeyLayout.whiteOffsets.indices) {
            val note = startNote + PianoKeyLayout.whiteOffsets[i]
            paint.color = when {
                !PianoKeyLayout.isPlayable(note) -> Color.rgb(96, 111, 124)
                noteRefs.containsKey(note) -> Color.rgb(54, 218, 198)
                else -> Color.rgb(226, 239, 247)
            }
            canvas.drawRoundRect(RectF(i * keyWidth + gap, 0f,
                (i + 1) * keyWidth - gap, whiteHeight), radius, radius, paint)
            paint.color = Color.rgb(16, 42, 59)
            paint.textAlign = Paint.Align.CENTER
            paint.textSize = 11f * resources.displayMetrics.scaledDensity
            val label = if (i == 0 || i == 7)
                whiteNames[i] + (note / 12 - 1) else whiteNames[i]
            canvas.drawText(label, (i + 0.5f) * keyWidth,
                whiteHeight - 14f * density, paint)
        }
        val blackWidth = keyWidth * PianoKeyLayout.blackWidthRatio
        val blackHeight = height * PianoKeyLayout.blackHeightRatio
        for (i in PianoKeyLayout.blackOffsets.indices) {
            val note = startNote + PianoKeyLayout.blackOffsets[i]
            val center = PianoKeyLayout.blackBoundaries[i] * keyWidth
            paint.color = when {
                !PianoKeyLayout.isPlayable(note) -> Color.rgb(60, 71, 82)
                noteRefs.containsKey(note) -> Color.rgb(24, 159, 148)
                else -> Color.rgb(33, 51, 69)
            }
            canvas.drawRoundRect(RectF(center - blackWidth / 2f, 0f,
                center + blackWidth / 2f, blackHeight), radius, radius, paint)
            paint.color = Color.WHITE
            paint.textAlign = Paint.Align.CENTER
            paint.textSize = 9f * resources.displayMetrics.scaledDensity
            canvas.drawText(blackNames[i], center, blackHeight - 12f * density, paint)
        }
    }

    private fun setPointerNote(pointerId: Int, note: Int?) {
        val previous = pointerNotes[pointerId]
        if (previous == note) return
        if (previous != null) {
            val remaining = (noteRefs[previous] ?: 1) - 1
            if (remaining == 0) {
                noteRefs.remove(previous)
                onNote(previous, false)
            } else noteRefs[previous] = remaining
            pointerNotes.remove(pointerId)
        }
        if (note != null) {
            val count = noteRefs[note] ?: 0
            noteRefs[note] = count + 1
            pointerNotes[pointerId] = note
            if (count == 0) onNote(note, true)
        }
        invalidate()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                val i = event.actionIndex
                setPointerNote(event.getPointerId(i),
                    PianoKeyLayout.noteAt(startNote, width.toFloat(), height.toFloat(),
                        event.getX(i), event.getY(i)))
            }
            MotionEvent.ACTION_MOVE -> {
                for (i in 0 until event.pointerCount)
                    setPointerNote(event.getPointerId(i),
                        PianoKeyLayout.noteAt(startNote, width.toFloat(), height.toFloat(),
                            event.getX(i), event.getY(i)))
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                setPointerNote(event.getPointerId(event.actionIndex), null)
                if (event.actionMasked == MotionEvent.ACTION_UP)
                    parent?.requestDisallowInterceptTouchEvent(false)
            }
            MotionEvent.ACTION_CANCEL -> {
                releaseAll()
                parent?.requestDisallowInterceptTouchEvent(false)
            }
        }
        return true
    }
}
