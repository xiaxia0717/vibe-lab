package com.vibelab.phonecam

import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException

/**
 * 局域网自动发现：手机广播问一句，电脑回自己的地址。
 *
 * 好处：WiFi 模式下不用手填电脑 IP，路由器 DHCP 换地址也不怕。
 * 故意不用 mDNS —— 那要引入第三方库，这里用裸 UDP 就够。
 */
object Discovery {
    private const val TAG = "Discovery"

    /** 和服务端 `DISCOVERY_PORT` 必须一致。 */
    private const val PORT = 47823
    private const val REQ = "PHONECAM?"
    private const val PREFIX = "PHONECAM1|"

    /**
     * 找电脑。找到返回它的 IP，找不到返回 null。
     *
     * **会阻塞**，务必在子线程调用。
     */
    fun find(timeoutMs: Int = 2500): String? {
        var sock: DatagramSocket? = null
        try {
            sock = DatagramSocket()
            sock.broadcast = true
            val req = REQ.toByteArray()
            val bcast = InetAddress.getByName("255.255.255.255")
            // 发两次，防丢包
            repeat(2) {
                try {
                    sock.send(DatagramPacket(req, req.size, bcast, PORT))
                } catch (_: Exception) {
                }
                Thread.sleep(120)
            }

            val deadline = System.currentTimeMillis() + timeoutMs
            val buf = ByteArray(256)
            while (System.currentTimeMillis() < deadline) {
                val left = (deadline - System.currentTimeMillis()).toInt().coerceAtLeast(200)
                sock.soTimeout = left
                val pkt = DatagramPacket(buf, buf.size)
                try {
                    sock.receive(pkt)
                } catch (_: SocketTimeoutException) {
                    break
                }
                val text = String(pkt.data, 0, pkt.length)
                if (text.startsWith(PREFIX)) {
                    val ip = pkt.address?.hostAddress
                    if (!ip.isNullOrBlank()) {
                        Log.i(TAG, "找到电脑: $ip  ($text)")
                        return ip
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "发现失败: ${e.message}")
        } finally {
            try {
                sock?.close()
            } catch (_: Exception) {
            }
        }
        return null
    }
}
