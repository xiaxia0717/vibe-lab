package com.vibelab.phonecam

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.TimeUnit

/**
 * 与 PC 端服务通信的 WebSocket 客户端。
 *
 * 二进制帧格式（首字节为类型标记）：
 *   0x01 + JPEG 数据  —— 视频帧
 *   0x02 + PCM 数据   —— 音频帧（16kHz / 单声道 / 16bit）
 */
class StreamClient(
    private val host: String,
    private val port: Int,
    private val listener: Listener
) {

    interface Listener {
        fun onConnected()
        fun onDisconnected(reason: String)
        fun onRemoteAudio(pcm: ByteArray)
    }

    companion object {
        const val TAG_VIDEO: Byte = 0x01
        const val TAG_AUDIO: Byte = 0x02
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .build()

    private var ws: WebSocket? = null

    @Volatile
    var isConnected: Boolean = false
        private set

    fun connect() {
        val request = Request.Builder().url("ws://$host:$port/ws").build()
        ws = client.newWebSocket(request, object : WebSocketListener() {

            override fun onOpen(webSocket: WebSocket, response: Response) {
                isConnected = true
                listener.onConnected()
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                val data = bytes.toByteArray()
                if (data.isNotEmpty() && data[0] == TAG_AUDIO) {
                    listener.onRemoteAudio(data.copyOfRange(1, data.size))
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                isConnected = false
                listener.onDisconnected(t.message ?: "连接失败")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                isConnected = false
                listener.onDisconnected(if (reason.isBlank()) "连接已断开" else reason)
            }
        })
    }

    fun sendVideo(jpeg: ByteArray) {
        if (!isConnected) return
        val buf = ByteArray(jpeg.size + 1)
        buf[0] = TAG_VIDEO
        System.arraycopy(jpeg, 0, buf, 1, jpeg.size)
        ws?.send(ByteString.of(*buf))
    }

    fun sendAudio(pcm: ByteArray) {
        if (!isConnected) return
        val buf = ByteArray(pcm.size + 1)
        buf[0] = TAG_AUDIO
        System.arraycopy(pcm, 0, buf, 1, pcm.size)
        ws?.send(ByteString.of(*buf))
    }

    fun close() {
        isConnected = false
        try {
            ws?.close(1000, null)
        } catch (_: Exception) {
        }
        ws = null
    }
}
