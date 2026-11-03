package com.gowin.musiccontroller

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URL
import javax.net.ssl.HttpsURLConnection

object ScoreRepository {
    private const val maxBytes = 524_288

    fun readBytesBounded(stream: InputStream): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val n = stream.read(buffer)
            if (n < 0) break
            require(output.size() + n <= maxBytes) { "乐谱文件超过 512 KB" }
            output.write(buffer, 0, n)
        }
        return output.toByteArray()
    }

    fun readBounded(stream: InputStream): String =
        readBytesBounded(stream).toString(Charsets.UTF_8)

    fun downloadBytes(urlText: String): ByteArray {
        val url = URL(urlText.trim())
        require(url.protocol.equals("https", ignoreCase = true)) { "只允许 HTTPS 乐谱地址" }
        val connection = url.openConnection() as HttpsURLConnection
        connection.connectTimeout = 10_000
        connection.readTimeout = 10_000
        connection.instanceFollowRedirects = false // 不允许跳转到明文 HTTP。
        try {
            require(connection.responseCode == 200) {
                "下载失败：HTTP ${connection.responseCode}"
            }
            return connection.inputStream.use { readBytesBounded(it) }
        } finally {
            connection.disconnect()
        }
    }
}
