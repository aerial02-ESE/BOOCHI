package com.gowin.musiccontroller

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.provider.OpenableColumns
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.net.URL

class MainActivity : Activity(), SppClient.Listener {
    private val bg = Color.rgb(7, 19, 34)
    private val card = Color.rgb(18, 40, 60)
    private val accent = Color.rgb(54, 218, 198)
    private val fg = Color.rgb(233, 244, 255)
    private val muted = Color.rgb(156, 178, 196)
    private lateinit var ble: SppClient
    private lateinit var statusLabel: TextView
    private lateinit var logLabel: TextView
    private lateinit var connectButton: Button
    private lateinit var piano: PianoKeyboardView
    private lateinit var player: ScorePlayer
    private lateinit var scoreStatus: TextView
    private lateinit var recordStatus: TextView
    private lateinit var recordButton: Button
    private lateinit var practiceStatus: TextView
    private lateinit var practiceScore: TextView
    private var pendingUploadScore: MusicScore? = null
    private var uploadedScore: MusicScore? = null
    private var practiceSession: Int? = null
    private var practiceFeedbackAt = 0L
    private var practiceRunning = false
    private var rejectedPracticeSession: Int? = null
    private var loadedScore: MusicScore? = null
    private var recordedScore: MusicScore? = null
    private val recorder = PerformanceRecorder()
    private var learnFromSource: Int? = null
    private var learnInput: EditText? = null
    private var velocity = 90
    private var playbackPedalEnabled = true
    private var octaveStart = 60
    private var lastSequence: Int? = null
    private val uiHandler = Handler(Looper.getMainLooper())
    private var chordProbeRunning = false
    private var chordProbeFinish: Runnable? = null
    private val logs = ArrayDeque<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = bg
        window.navigationBarColor = bg
        ble = SppClient(this, this)
        buildUi()
        player = ScorePlayer({ note, level, on ->
            val accepted = ble.send(ControlEvent.note(note, level, on))
            if (!accepted) onLog("播放音符 $note 未发送；蓝牙断连或发送积压")
            accepted
        }, { position ->
            ble.send(ControlEvent.encode(ControlEvent.SUSTAIN, id = 64,
                value = position * 65535 / 127))
        }, { message -> scoreStatus.text = message }, { ble.flushPending() })
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()

    private fun text(value: String, size: Float, color: Int = fg): TextView = TextView(this).apply {
        this.text = value
        textSize = size
        setTextColor(color)
    }

    private fun button(label: String, action: () -> Unit): Button = Button(this).apply {
        text = label
        isAllCaps = false
        setTextColor(bg)
        backgroundTintList = ColorStateList.valueOf(accent)
        setOnClickListener { action() }
    }

    private fun input(hint: String, initial: String = "", numeric: Boolean = false): EditText =
        EditText(this).apply {
            this.hint = hint
            setText(initial)
            setTextColor(fg)
            setHintTextColor(muted)
            textSize = 15f
            inputType = if (numeric) InputType.TYPE_CLASS_NUMBER else
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            backgroundTintList = ColorStateList.valueOf(accent)
            if (!numeric) setSingleLine(true)
        }

    private fun card(title: String): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(14), dp(16), dp(16))
        setBackgroundColor(card)
        val lp = LinearLayout.LayoutParams(-1, -2)
        lp.topMargin = dp(12)
        layoutParams = lp
        addView(text(title, 18f), LinearLayout.LayoutParams(-1, -2))
    }

    private fun slider(parent: LinearLayout, title: String, max: Int, start: Int,
                       minValue: Int = 0,
                       onRelease: (Int) -> Unit) {
        val label = text("$title  $start", 14f, muted)
        val labelLp = LinearLayout.LayoutParams(-1, -2)
        labelLp.topMargin = dp(12)
        parent.addView(label, labelLp)
        parent.addView(SeekBar(this).apply {
            this.max = max - minValue
            progress = start - minValue
            progressTintList = ColorStateList.valueOf(accent)
            thumbTintList = ColorStateList.valueOf(accent)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar, progress: Int,
                                               fromUser: Boolean) {
                    label.text = "$title  ${progress + minValue}"
                }
                override fun onStartTrackingTouch(seekBar: SeekBar) = Unit
                override fun onStopTrackingTouch(seekBar: SeekBar) = onRelease(seekBar.progress + minValue)
            })
        }, LinearLayout.LayoutParams(-1, -2))
    }

    private fun buildUi() {
        val root = ScrollView(this).apply { setBackgroundColor(bg); isFillViewport = true }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(20), dp(16), dp(28))
        }
        root.addView(column)
        setContentView(root)

        column.addView(text("电子音乐控制台", 27f))

        val connection = card("蓝牙连接")
        column.addView(connection)
        statusLabel = text("未连接", 15f, muted)
        connection.addView(statusLabel)
        connection.addView(text("连接 GW-MUSIC", 12f, muted))
        connectButton = button("连接 JDY-31", ::startConnection)
        connection.addView(connectButton)
        connection.addView(button("断开连接") { piano.releaseAll(false); ble.disconnect() })

        val keyboard = card("虚拟琴键")
        column.addView(keyboard)
        slider(keyboard, "力度", 127, velocity) { velocity = it.coerceAtLeast(1) }
        val rangeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val lowButton = button("降一个八度") { }
        val highButton = button("升一个八度") { }
        val rangeLabel = text("当前：C4–C5", 14f, muted)
        fun selectRange(start: Int) {
            octaveStart = start.coerceIn(PianoKeyLayout.minWindowStart,
                PianoKeyLayout.maxWindowStart)
            piano.selectOctave(octaveStart)
            rangeLabel.text = "当前：C${octaveStart / 12 - 1}–C${octaveStart / 12}"
            lowButton.isEnabled = octaveStart > PianoKeyLayout.minWindowStart
            highButton.isEnabled = octaveStart < PianoKeyLayout.maxWindowStart
        }
        lowButton.setOnClickListener { selectRange(octaveStart - 12) }
        highButton.setOnClickListener { selectRange(octaveStart + 12) }
        rangeRow.addView(lowButton, LinearLayout.LayoutParams(0, -2, 1f))
        rangeRow.addView(highButton, LinearLayout.LayoutParams(0, -2, 1f))
        keyboard.addView(rangeRow)
        keyboard.addView(rangeLabel)
        piano = PianoKeyboardView(this) { note, on ->
            if (!ble.send(ControlEvent.note(note, velocity, on)))
                onLog("琴键音符 $note 未发送；请检查蓝牙连接")
        }
        val pianoLayout = LinearLayout.LayoutParams(-1, dp(174))
        pianoLayout.topMargin = dp(8)
        keyboard.addView(piano, pianoLayout)
        selectRange(60)
        keyboard.addView(button("复音自检：C4 + E4") { runChordProbe() })
        keyboard.addView(button("32 音复音测试") { runPoly32Probe() })
        keyboard.addView(button("全部静音") {
            if (::player.isInitialized) player.stop()
            piano.releaseAll(false)
            send(ControlEvent.encode(ControlEvent.ALL_NOTES_OFF))
        })

        val expression = card("表达控制")
        val timbres = card("音色模式")
        column.addView(timbres)
        timbres.addView(button("原有模式 · 选择音色") { selectTimbre(split = false) })
        timbres.addView(button("88键分区 · 选择 C5 起音色") { selectTimbre(split = true) })
        timbres.addView(text("分区模式下，C5 以下固定钢琴。", 12f, muted))
        timbres.addView(button("屏幕显示") {
            AlertDialog.Builder(this)
                .setTitle("切换 FPGA 屏幕")
                .setItems(arrayOf("频谱和键盘", "李萨如图形", "曲谱")) { _, page ->
                    send(ControlEvent.displayPage(page))
                }
                .show()
        })
        column.addView(expression)
        slider(expression, "弯音", 65535, 32768) {
            send(ControlEvent.encode(ControlEvent.PITCH_BEND, value = it))
        }
        slider(expression, "调制", 100, 0) {
            send(ControlEvent.encode(ControlEvent.MODULATION, id = 1,
                value = ControlEvent.scalePercent(it)))
        }
        expression.addView(CheckBox(this).apply {
            text = "延音"
            setTextColor(fg)
            buttonTintList = ColorStateList.valueOf(accent)
            setOnCheckedChangeListener { _, checked ->
                send(ControlEvent.encode(ControlEvent.SUSTAIN, id = 64,
                    value = if (checked) 65535 else 0))
            }
        })

        val mixer = card("FPGA 参数")
        column.addView(mixer)
        slider(mixer, "主音量 %", 100, 100) {
            send(ControlEvent.encode(ControlEvent.PARAM_CTRL, id = 0,
                value = ControlEvent.scalePercent(it)))
        }
        slider(mixer, "钢琴音量 %", 100, 100) {
            send(ControlEvent.encode(ControlEvent.PARAM_CTRL, id = 1,
                value = ControlEvent.scalePercent(it)))
        }
        slider(mixer, "管风琴音量 %", 100, 100) {
            send(ControlEvent.encode(ControlEvent.PARAM_CTRL, id = 2,
                value = ControlEvent.scalePercent(it)))
        }
        slider(mixer, "混响量 %", 100, 0) {
            send(ControlEvent.encode(ControlEvent.EFFECT_CTRL, aux = 4,
                value = ControlEvent.scalePercent(it)))
        }
        slider(mixer, "合唱量 %", 100, 0) {
            send(ControlEvent.encode(ControlEvent.EFFECT_CTRL, aux = 5,
                value = ControlEvent.scalePercent(it)))
        }
        mixer.addView(CheckBox(this).apply {
            text = "延时效果"
            setTextColor(fg)
            buttonTintList = ColorStateList.valueOf(accent)
            setOnCheckedChangeListener { _, checked ->
                send(ControlEvent.encode(ControlEvent.EFFECT_CTRL, id = 0,
                    value = if (checked) 1 else 0, aux = 0))
            }
        })
        slider(mixer, "延时毫秒", 160, 63) {
            val samples = (it * 48828 / 1000).coerceIn(1, 8191)
            send(ControlEvent.encode(ControlEvent.EFFECT_CTRL, aux = 1,
                value = samples shl 3))
        }
        slider(mixer, "延时反馈 %", 75, 13) {
            val gain = it * 192 / 75
            send(ControlEvent.encode(ControlEvent.EFFECT_CTRL, aux = 2,
                value = gain shl 8))
        }
        slider(mixer, "延时混合 %", 100, 6) {
            send(ControlEvent.encode(ControlEvent.EFFECT_CTRL, aux = 3,
                value = ControlEvent.scalePercent(it)))
        }

        val envelope = card("ADSR 包络")
        column.addView(envelope)
        envelope.addView(text("松开滑块生效；释放时间在松键或松踏板后起作用", 12f, muted))
        for (target in 0..1) {
            envelope.addView(text(if (target == 0) "钢琴" else "管风琴", 17f))
            val settings = AdsrSettings(sustainPercent = if (target == 0) 38 else 100)
            fun applyEnvelope() { settings.packets(target).forEach { send(it) } }
            slider(envelope, "起音 A（毫秒）", 1200, settings.attackMs, minValue = 1) {
                settings.attackMs = it.coerceAtLeast(1); applyEnvelope()
            }
            slider(envelope, "衰减 D（毫秒）", 1200, settings.decayMs, minValue = 1) {
                settings.decayMs = it.coerceAtLeast(1); applyEnvelope()
            }
            slider(envelope, "保持 S（%）", 100, settings.sustainPercent) {
                settings.sustainPercent = it; applyEnvelope()
            }
            slider(envelope, "释放 R（毫秒）", 1200, settings.releaseMs, minValue = 1) {
                settings.releaseMs = it.coerceAtLeast(1); applyEnvelope()
            }
        }

        val mapping = card("实体键位映射")
        column.addView(mapping)
        mapping.addView(text("选择设备，再输入原音符与目标音符编号（0–127）", 12f, muted))
        var mapSource = 0
        val sourceRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val smkButton = button("多功能琴键") { }
        val keysButton = button("88 键") { }
        lateinit var learnButton: Button
        fun selectSource(source: Int) {
            if (mapSource != source) learnFromSource = null
            mapSource = source
            smkButton.alpha = if (source == 0) 1f else 0.55f
            keysButton.alpha = if (source == 1) 1f else 0.55f
            learnButton.isEnabled = source == 0
            learnButton.alpha = if (source == 0) 1f else 0.45f
        }
        smkButton.setOnClickListener { selectSource(0) }
        keysButton.setOnClickListener { selectSource(1) }
        sourceRow.addView(smkButton, LinearLayout.LayoutParams(0, -2, 1f))
        sourceRow.addView(keysButton, LinearLayout.LayoutParams(0, -2, 1f))
        mapping.addView(sourceRow)
        val mapRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val fromNote = input("原音符", "60", true)
        val toNote = input("目标音符", "60", true)
        learnInput = fromNote
        mapRow.addView(fromNote, LinearLayout.LayoutParams(0, -2, 1f))
        mapRow.addView(toNote, LinearLayout.LayoutParams(0, -2, 1f))
        mapping.addView(mapRow)
        learnButton = button("按实体键识别原音符") {
            if (!ble.isReady) onLog("请先连接蓝牙")
            else {
                learnFromSource = mapSource
                onLog("请按一次选中设备上的琴键")
            }
        }
        mapping.addView(learnButton)
        mapping.addView(text("88 键无回传通道，请手动输入原音符编号。", 12f, muted))
        selectSource(0)
        mapping.addView(button("应用映射") {
            val sourceNote = fromNote.text.toString().toIntOrNull()
            val targetNote = toNote.text.toString().toIntOrNull()
            if (sourceNote == null || sourceNote !in 0..127 ||
                targetNote == null || targetNote !in 0..127) {
                onLog("音符编号必须为 0–127")
            } else if (ble.send(ControlEvent.keyMap(mapSource, sourceNote, targetNote))) {
                onLog("映射命令已发送；设备重启后恢复默认")
            } else onLog("请先连接蓝牙")
        })

        val scoreCard = card("乐谱")
        column.addView(scoreCard)
        scoreCard.addView(text("内置曲谱", 14f, muted))
        PresetScores.all.forEach { preset ->
            scoreCard.addView(button(preset.title) { showScore(preset) })
        }
        scoreCard.addView(button("三音色演示曲（钢琴·管风琴·鼓）") {
            runCatching {
                val bytes = assets.open("demo_trio.mid").use { it.readBytes() }
                MidiFile.parse(bytes).toScoreAll("星夜序曲（三音色演示）")
            }.onSuccess { showScore(it) }
                .onFailure { onLog("内置演示曲读取失败：${it.message}") }
        })
        val scoreUrl = input("https://…/score.mid 或 score.json")
        scoreCard.addView(scoreUrl, LinearLayout.LayoutParams(-1, -2))
        scoreCard.addView(button("在线下载乐谱") {
            val url = scoreUrl.text.toString().trim()
            if (url.isEmpty()) onLog("请输入 HTTPS 乐谱地址")
            else downloadScore(url)
        })
        scoreCard.addView(button("打开本地乐谱（MIDI / JSON）") {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*" // 文件管理器可能把 .json 标记为 text/plain。
            }, 201)
        })
        scoreStatus = text("未加载乐谱", 14f, muted)
        scoreCard.addView(scoreStatus)
        scoreCard.addView(CheckBox(this).apply {
            text = "回放延音踏板"
            isChecked = playbackPedalEnabled
            setTextColor(fg)
            buttonTintList = ColorStateList.valueOf(accent)
            setOnCheckedChangeListener { _, checked ->
                if (::player.isInitialized && player.playing) player.stop()
                playbackPedalEnabled = checked
            }
        })
        val scoreRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        scoreRow.addView(button("播放乐谱") {
            val selected = loadedScore
            when {
                selected == null -> onLog("请先加载乐谱")
                !ble.isReady -> onLog("请先连接蓝牙")
                else -> player.play(selected.copy(pedals =
                    if (playbackPedalEnabled) selected.pedals else emptyList()))
            }
        }, LinearLayout.LayoutParams(0, -2, 1f))
        scoreRow.addView(button("停止播放") { player.stop() },
            LinearLayout.LayoutParams(0, -2, 1f))
        scoreCard.addView(scoreRow)
        scoreCard.addView(button("上传曲谱到设备") {
            val selected = loadedScore
            when {
                selected == null -> onLog("请先加载乐谱")
                !ble.isReady -> onLog("请先连接蓝牙")
                player.playing || piano.hasHeldNotes -> onLog("请先停止手机演奏")
                practiceRunning -> onLog("请先停止跟弹再上传曲谱")
                else -> try {
                    if (!ble.uploadScore(selected.copy(pedals =
                            if (playbackPedalEnabled) selected.pedals else emptyList())))
                        onLog("蓝牙正在发送，请稍后重试上传")
                    else pendingUploadScore=selected
                } catch (e: IllegalArgumentException) {
                    onLog(e.message ?: "曲谱不能转换为本地播放格式")
                }
            }
        })
        val localRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        localRow.addView(button("开始跟弹") {
            startPractice()
        }, LinearLayout.LayoutParams(0, -2, 1f))
        localRow.addView(button("停止跟弹") {
            if (!ble.send(ScoreTransfer.control(3))) onLog("蓝牙未就绪")
        }, LinearLayout.LayoutParams(0, -2, 1f))
        scoreCard.addView(localRow)
        val practiceCard=card("跟弹实时计分")
        column.addView(practiceCard)
        practiceCard.addView(text("88键 · 时间容差 ±150毫秒 · 蓝灯提示，正确绿灯，错音红灯",12f,muted))
        practiceStatus=text("等待设备回传成绩",16f,accent)
        practiceScore=text("正确 0  · 错音 0  · 漏音 0\n整曲正确率 0.0%",18f)
        practiceCard.addView(practiceStatus);practiceCard.addView(practiceScore)

        val recordCard = card("演奏事件记录")
        column.addView(recordCard)
        recordCard.addView(text("记录蓝牙通知中的音符，不录制声音；通知可能丢失。", 12f, muted))
        recordStatus = text("尚未记录", 14f, muted)
        recordCard.addView(recordStatus)
        recordButton = button("开始记录") { toggleRecording() }
        recordCard.addView(recordButton)
        recordCard.addView(button("回放本次记录") {
            val selected = recordedScore
            when {
                selected == null -> onLog("请先完成一次记录")
                !ble.isReady -> onLog("请先连接蓝牙")
                else -> player.play(selected.copy(pedals =
                    if (playbackPedalEnabled) selected.pedals else emptyList()))
            }
        })
        recordCard.addView(button("导出记录为 JSON 乐谱") { exportRecording() })

        val monitor = card("事件监视")
        column.addView(monitor)
        monitor.addView(text("通知可能丢失；这里只显示控制事件，不是音频录制。", 12f, muted))
        logLabel = text("等待连接…", 12f, fg)
        monitor.addView(logLabel)
    }

    private fun showScore(score: MusicScore) {
        player.stop()
        loadedScore = score
        scoreStatus.text = "${score.title} · ${score.notes.size} 个音符 · ${score.pedals.size} 次踏板"
        onLog("乐谱已加载：${score.title}")
    }

    override fun onScoreUploaded() {
        uploadedScore=pendingUploadScore;pendingUploadScore=null
        practiceStatus.text="曲谱已存入设备，可以开始跟弹"
    }

    private fun startPractice() {
        if(!ble.isReady){onLog("请先连接蓝牙");return}
        if(player.playing||piano.hasHeldNotes){onLog("请先停止手机演奏");return}
        if(practiceRunning){onLog("当前跟弹尚未结束，请先停止");return}
        val selected=loadedScore
        if(selected!=null&&uploadedScore!==selected){onLog("请先上传当前曲谱到设备");return}
        try { if(selected!=null) PracticePlan.targets(selected) }
        catch(e:IllegalArgumentException){onLog(e.message?:"当前曲谱不能跟弹");return}
        val id=((practiceSession?:((SystemClock.elapsedRealtime()/10).toInt()))+1) and 255
        if(!ble.send(ScoreTransfer.control(4,id))){onLog("蓝牙忙，请稍后开始");return}
        practiceSession=id;practiceFeedbackAt=0;practiceRunning=true;rejectedPracticeSession=null
        practiceStatus.text="等待FPGA开始 · 需要 Y22 → ESP32 GPIO27 回传线"
        uiHandler.postDelayed({
            if(practiceSession==id&&practiceFeedbackAt==0L)
                practiceStatus.text="未收到FPGA成绩，请检查Y22→GPIO27回传接线和24号FPGA位流"
        },5000)
    }

    private fun showPractice(bytes:ByteArray) {
        val p=PracticeTelemetry.decode(bytes)
        if(practiceSession!=null&&p.session!=practiceSession)return
        if(rejectedPracticeSession==p.session&&!p.espRejected)return
        if(p.espRejected)rejectedPracticeSession=p.session
        practiceFeedbackAt=SystemClock.elapsedRealtime()
        if(p.active||p.finished||p.error||p.result==6)practiceRunning=p.active
        practiceStatus.text=when {
            p.espRejected&&p.result==0x85 -> "未收到FPGA开始确认，请检查Y22→GPIO27回传线"
            p.espRejected -> "设备曲谱预检失败（${p.result-128}），未开始演奏"
            p.error -> "跟弹已中止：缓存或通信异常，请重新开始"
            p.finished -> "演奏完成"
            p.active&&p.elapsedMs<2000 -> "准备 · ${((2000-p.elapsedMs)+999)/1000}"
            p.active -> "正在跟弹 · ${"%.1f".format(p.progress)}% 已判定"
            p.result==6 -> "已停止，保留本次成绩"
            else -> "FPGA回传已连接，等待开始"
        }
        practiceScore.text="正确 ${p.hits}  · 错音 ${p.wrong}  · 漏音 ${p.misses}\n"+
            "当前命中率 ${"%.1f".format(p.liveAccuracy)}%\n"+
            "整曲正确率 ${"%.1f".format(p.songAccuracy)}%  · 目标 ${p.total}"
    }

    private fun runChordProbe() {
        if (!ble.isReady || piano.hasHeldNotes || player.playing || chordProbeRunning) {
            onLog("复音自检前请连接蓝牙并停止当前演奏")
            return
        }
        chordProbeRunning = true
        if (!ble.sendPair(ControlEvent.note(60, 90, true),
                          ControlEvent.note(64, 90, true))) {
            chordProbeRunning = false
            ble.send(ControlEvent.encode(ControlEvent.ALL_NOTES_OFF))
            onLog("复音自检未能发送两个按键")
            return
        }
        onLog("复音自检：C4、E4 同时保持 2 秒；观察是否同时发声")
        val finish = Runnable {
            ble.sendPair(ControlEvent.note(60, 0, false),
                         ControlEvent.note(64, 0, false))
            chordProbeRunning = false
            chordProbeFinish = null
        }
        chordProbeFinish = finish
        uiHandler.postDelayed(finish, 2000)
    }

    private fun runPoly32Probe() {
        if (!ble.isReady || player.playing || piano.hasHeldNotes || chordProbeRunning) {
            onLog("请连接蓝牙并停止当前演奏后测试")
            return
        }
        chordProbeRunning = true
        val notes = (36..67).toList()
        if (!ble.sendBatch(notes.map { ControlEvent.note(it, 45, true) })) {
            chordProbeRunning = false
            ble.send(ControlEvent.encode(ControlEvent.ALL_NOTES_OFF))
            onLog("32音测试发送失败")
            return
        }
        onLog("32音测试：保持36–67音符两秒；当前音色由KEY1选择")
        val finish = Runnable {
            val released = ble.sendBatch(notes.map { ControlEvent.note(it, 0, false) })
            if (!released) ble.send(ControlEvent.encode(ControlEvent.ALL_NOTES_OFF))
            chordProbeRunning = false
            chordProbeFinish = null
        }
        chordProbeFinish = finish
        uiHandler.postDelayed(finish, 2000)
    }

    private fun downloadScore(url: String) {
        scoreStatus.text = "正在下载乐谱…"
        Thread {
            val result = runCatching {
                val name = URL(url).path.substringAfterLast('/').ifBlank { "在线乐谱.mid" }
                parseImportedScore(ScoreRepository.downloadBytes(url), name)
            }
            runOnUiThread {
                if (isDestroyed) return@runOnUiThread
                result.onSuccess(::showImportedScore).onFailure {
                    scoreStatus.text = "下载失败"
                    onLog("乐谱下载失败：${it.message}")
                }
            }
        }.start()
    }

    private data class ImportedScore(val title: String, val json: MusicScore? = null,
                                     val midi: MidiFile? = null)

    private fun parseImportedScore(data: ByteArray, filename: String): ImportedScore {
        val title = filename.substringBeforeLast('.').ifBlank { "未命名乐谱" }.take(80)
        return if (MidiFile.isMidi(data)) ImportedScore(title, midi = MidiFile.parse(data))
        else ImportedScore(title, json = MusicScore.parse(data.toString(Charsets.UTF_8)))
    }

    private fun showImportedScore(imported: ImportedScore) {
        imported.json?.let { showScore(it); return }
        val midi = imported.midi ?: return
        val tracks = midi.playableTracks
        if (tracks.isEmpty()) {
            onLog("MIDI 文件没有可播放的音符轨道")
            return
        }
        fun select(index: Int) {
            val trackName = tracks.first { it.index == index }.name
            runCatching { midi.toScore(index, "${imported.title} · $trackName") }
                .onSuccess(::showScore)
                .onFailure { onLog("MIDI 导入失败：${it.message}") }
        }
        if (tracks.size == 1) select(tracks.single().index)
        else AlertDialog.Builder(this).setTitle("选择 MIDI 播放轨道")
            .setItems((listOf("全部轨道（和弦/复音）") + tracks.map { it.label }).toTypedArray()) { _, which ->
                if (which == 0) runCatching { midi.toScoreAll("${imported.title} · 全部轨道") }
                    .onSuccess(::showScore)
                    .onFailure { onLog("MIDI 导入失败：${it.message}") }
                else select(tracks[which - 1].index)
            }.setNegativeButton("取消", null).show()
    }

    private fun localFilename(uri: android.net.Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (column >= 0) return cursor.getString(column) ?: "本地乐谱"
                }
            }
        return uri.lastPathSegment ?: "本地乐谱"
    }

    private fun toggleRecording() {
        val now = SystemClock.elapsedRealtime()
        if (recorder.active) {
            val title = "演奏记录 " +
                SimpleDateFormat("MM-dd HH:mm", Locale.CHINA).format(Date())
            recordedScore = recorder.stop(now, title)
            recordButton.text = "开始记录"
            recordStatus.text = "已记录 ${recordedScore!!.notes.size} 个音符；可回放或导出"
        } else if (!ble.isReady) {
            onLog("请先连接蓝牙再记录")
        } else {
            recorder.start(now)
            recordedScore = null
            recordButton.text = "停止记录"
            recordStatus.text = "正在记录蓝牙音符通知…"
        }
    }

    private fun exportRecording() {
        if (recordedScore == null) {
            onLog("请先完成一次记录")
            return
        }
        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_TITLE, "高云演奏记录.json")
        }, 202)
    }

    @Deprecated("Activity result API is sufficient without an AndroidX dependency here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val uri = data?.data ?: return
        if (resultCode != RESULT_OK) return
        when (requestCode) {
            201 -> Thread {
                val result = runCatching {
                    val source = contentResolver.openInputStream(uri)
                        ?: error("无法打开乐谱文件")
                    val filename = localFilename(uri)
                    source.use { parseImportedScore(ScoreRepository.readBytesBounded(it), filename) }
                }
                runOnUiThread {
                    if (isDestroyed) return@runOnUiThread
                    result.onSuccess(::showImportedScore)
                        .onFailure { onLog("乐谱读取失败：${it.message}") }
                }
            }.start()
            202 -> {
                val json = recordedScore?.toJson() ?: return
                Thread {
                    val result = runCatching {
                        val target = contentResolver.openOutputStream(uri, "wt")
                            ?: error("无法写入目标文件")
                        target.use { it.write(json.toByteArray(Charsets.UTF_8)) }
                    }
                    runOnUiThread {
                        if (isDestroyed) return@runOnUiThread
                        result.onSuccess { onLog("演奏记录已导出") }
                            .onFailure { onLog("导出失败：${it.message}") }
                    }
                }.start()
            }
        }
    }

    private fun requiredPermissions(): Array<String> = if (Build.VERSION.SDK_INT >= 31) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun startConnection() {
        if (!ble.isBluetoothAvailable) {
            Toast.makeText(this, "本机不支持低功耗蓝牙", Toast.LENGTH_SHORT).show()
            return
        }
        val missing = requiredPermissions().filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), 100)
        else ble.scanAndConnect()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>,
                                            grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 100) {
            if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
                ble.scanAndConnect()
            else onLog("未获得蓝牙权限，无法扫描")
        }
    }

    private fun selectTimbre(split: Boolean) {
        val names = arrayOf("钢琴", "管风琴", "鼓", "原有分配模式", "长笛", "单簧管",
            "小提琴", "小号", "尼龙吉他", "电钢琴", "电贝斯", "钟琴")
        val modes = names.indices.filter { !split || it != 3 }
        AlertDialog.Builder(this)
            .setTitle(if (split) "选择 C5 起的音色" else "选择原有模式音色")
            .setItems(modes.map { names[it] }.toTypedArray()) { _, index ->
                send(ControlEvent.timbreMode(modes[index], split))
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun send(bytes: ByteArray) {
        if (!ble.send(bytes)) onLog("蓝牙未就绪或正在上传曲谱，命令未发送")
    }

    override fun onStatus(status: String, ready: Boolean) {
        statusLabel.text = status
        statusLabel.setTextColor(if (ready) accent else muted)
        connectButton.isEnabled = !ready
        if (!ready) {
            learnFromSource = null
            piano.releaseAll(false)
            if (::player.isInitialized) player.stop()
            if (recorder.active) toggleRecording()
        } else lastSequence = null
    }

    override fun onLog(message: String) {
        val time = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())
        logs.addFirst("$time  $message")
        while (logs.size > 18) logs.removeLast()
        logLabel.text = logs.joinToString("\n")
    }

    override fun onEvent(bytes: ByteArray) {
        try {
            if(bytes.size==20&&(bytes[0].toInt() and 255)==0x50){showPractice(bytes);return}
            val event = ControlEvent.decode(bytes)
            val previous = lastSequence
            if (previous != null && event.sequence != ((previous + 1) and 255))
                onLog("通知序号跳变 $previous → ${event.sequence}")
            lastSequence = event.sequence
            if (learnFromSource == event.source && event.type == ControlEvent.NOTE_ON &&
                event.value > 0) {
                learnInput?.setText(event.id.toString())
                learnFromSource = null
                onLog("已识别原音符 ${event.id}；可填写目标音符后应用")
            }
            if (recorder.active) {
                recorder.accept(bytes, SystemClock.elapsedRealtime())
                recordStatus.text = "正在记录：${recorder.noteCount} 个完整音符"
            }
            if (event.type != 0)
                onLog("源${event.source} 通道${event.channel} 类型${event.type} " +
                    "编号${event.id} 数值${event.value}")
        } catch (_: IllegalArgumentException) {
            onLog("收到无效的 8 字节通知")
        }
    }

    override fun onPause() {
        super.onPause()
        chordProbeFinish?.let { uiHandler.removeCallbacks(it); it.run() }
        if (piano.hasHeldNotes) piano.releaseAll()
        if (::player.isInitialized) player.stop()
    }

    override fun onDestroy() {
        if (::player.isInitialized) player.stop()
        ble.disconnect()
        super.onDestroy()
    }
}
