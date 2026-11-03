package com.gowin.musiccontroller

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.io.EOFException
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

@SuppressLint("MissingPermission") // MainActivity requests Bluetooth permission.
class SppClient(context: Context, private val listener: Listener) {
    interface Listener {
        fun onStatus(status: String, ready: Boolean)
        fun onLog(message: String)
        fun onEvent(bytes: ByteArray)
        fun onScoreUploaded()
    }

    private val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
    private val main = Handler(Looper.getMainLooper())
    private val sppUuid = UUID.fromString("00001101-0000-1000-8000-00805f9b34fb")

    private class Link(val socket: BluetoothSocket) {
        val writer = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(32))
        @Volatile var ready = false
        @Volatile var uploading = false
        var uploadCrc: ByteArray? = null
    }

    @Volatile private var link: Link? = null
    val isReady get() = link?.ready == true
    val isBluetoothEnabled get() = adapter?.isEnabled == true
    val isBluetoothAvailable get() = adapter != null

    private val heartbeat = object : Runnable {
        override fun run() {
            val current = link ?: return
            if (!current.ready) return
            if (!current.uploading) send(ByteArray(8).also { it[0] = 0x40 })
            if (link === current) main.postDelayed(this, 500)
        }
    }

    fun scanAndConnect() {
        disconnect()
        try {
            val device = adapter?.bondedDevices?.firstOrNull { it.name == "JDY-31-SPP" }
            if (device == null) {
                listener.onStatus("请先在手机蓝牙设置中配对 JDY-31-SPP", false)
                return
            }
            val current = Link(device.createRfcommSocketToServiceRecord(sppUuid))
            link = current
            listener.onStatus("正在连接 JDY-31-SPP…", false)
            Thread({ receive(current) }, "JDY31-SPP").start()
        } catch (e: IOException) {
            listener.onStatus("无法创建串口连接", false)
        } catch (e: SecurityException) {
            listener.onStatus("缺少蓝牙权限", false)
        }
    }

    private fun receive(current: Link) {
        try {
            current.socket.connect()
            val input = current.socket.inputStream
            main.post {
                if (link === current) {
                    current.ready = true
                    listener.onStatus("已连接 JDY-31-SPP", true)
                    main.post(heartbeat)
                }
            }
            val decoder = SppFrame.Decoder()
            val chunk = ByteArray(128)
            while (link === current) {
                val count = input.read(chunk)
                if (count < 0) throw EOFException("蓝牙连接已关闭")
                for (i in 0 until count) decoder.accept(chunk[i])?.let { bytes ->
                    main.post { if (link === current) deliver(current, bytes) }
                }
            }
        } catch (e: IOException) {
            fail(current, e.message ?: "连接中断")
        } catch (e: SecurityException) {
            fail(current, "缺少蓝牙权限")
        }
    }

    private fun deliver(current: Link, bytes: ByteArray) {
        if (bytes.size != 8 || bytes[0] != 0x52.toByte() || bytes[1] != 1.toByte()) {
            listener.onEvent(bytes)
            return
        }
        val expected = current.uploadCrc ?: return
        if (bytes[4] != expected[0] || bytes[5] != expected[1]) return
        current.uploadCrc = null
        current.uploading = false
        if (bytes[2] == 1.toByte()) listener.onScoreUploaded()
        else listener.onLog("设备拒绝保存曲谱，请重新上传")
    }

    private fun fail(current: Link, message: String) {
        main.post {
            if (link === current) {
                disconnect()
                listener.onLog(message)
            }
        }
    }

    fun disconnect() {
        main.removeCallbacks(heartbeat)
        val old = link
        link = null
        old?.writer?.shutdownNow()
        try { old?.socket?.close() } catch (_: IOException) { }
        listener.onStatus("蓝牙未连接", false)
    }

    fun send(bytes: ByteArray) = sendBatch(listOf(bytes))
    fun sendPair(first: ByteArray, second: ByteArray) = sendBatch(listOf(first, second))
    fun flushPending() = isReady

    private fun enqueue(current: Link, job: () -> Unit): Boolean {
        return try {
            current.writer.execute {
                try { job() }
                catch (e: IOException) { fail(current, e.message ?: "串口写入失败") }
                catch (_: InterruptedException) { Thread.currentThread().interrupt() }
            }
            true
        } catch (_: RejectedExecutionException) {
            fail(current, "串口发送队列已满，已断开以释放琴键")
            false
        }
    }

    fun sendBatch(events: List<ByteArray>): Boolean {
        val current = link ?: return false
        if (!current.ready || current.uploading || events.isEmpty() || events.any { it.size != 8 })
            return false
        val frames = events.map(SppFrame::encode)
        return enqueue(current) {
            val output = current.socket.outputStream
            for (frame in frames) output.write(frame)
        }
    }

    fun uploadScore(score: MusicScore): Boolean {
        val current = link ?: return false
        if (!current.ready || current.uploading) return false
        val packets = ScoreTransfer.encode(score)
        current.uploading = true
        val expected = packets.last().copyOfRange(4, 6)
        current.uploadCrc = expected
        listener.onLog("正在通过蓝牙串口发送曲谱")
        val accepted = enqueue(current) {
            val output = current.socket.outputStream
            for (packet in packets) {
                output.write(SppFrame.encode(packet))
                Thread.sleep(20) // 14 bytes require about 15 ms at 9600 8N1.
            }
            main.postDelayed({
                if (link === current && current.uploadCrc === expected) {
                    current.uploadCrc = null
                    current.uploading = false
                    listener.onLog("没有收到设备的曲谱保存确认")
                }
            }, 5000)
        }
        if (!accepted) {
            current.uploadCrc = null
            current.uploading = false
        }
        return accepted
    }
}
