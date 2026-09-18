package com.vibelab.phonecam

import android.content.Context
import android.content.SharedPreferences

/**
 * 应用配置。
 *
 * 默认值已经和电脑端服务对齐，正常使用完全不需要修改；
 * 需要调整时进入「设置」页改即可，会一直记住。
 */
class Prefs(context: Context) {

    private val sp: SharedPreferences =
        context.getSharedPreferences("phonecam", Context.MODE_PRIVATE)

    /** 电脑地址 */
    var host: String
        get() = sp.getString(KEY_HOST, DEFAULT_HOST) ?: DEFAULT_HOST
        set(v) = sp.edit().putString(KEY_HOST, v.trim().ifBlank { DEFAULT_HOST }).apply()

    /** 端口 */
    var port: Int
        get() = sp.getInt(KEY_PORT, DEFAULT_PORT)
        set(v) = sp.edit().putInt(KEY_PORT, v).apply()

    /** 分辨率档位：0=480p 1=720p 2=1080p */
    var qualityIndex: Int
        get() = sp.getInt(KEY_QUALITY, 1)
        set(v) = sp.edit().putInt(KEY_QUALITY, v).apply()

    /** 帧率档位：0=15 1=24 2=30 */
    var fpsIndex: Int
        get() = sp.getInt(KEY_FPS, 1)
        set(v) = sp.edit().putInt(KEY_FPS, v).apply()

    /** 打开 App 后自动开始 */
    var autoStart: Boolean
        get() = sp.getBoolean(KEY_AUTO_START, false)
        set(v) = sp.edit().putBoolean(KEY_AUTO_START, v).apply()

    /** 默认使用前置摄像头 */
    var preferFront: Boolean
        get() = sp.getBoolean(KEY_PREFER_FRONT, false)
        set(v) = sp.edit().putBoolean(KEY_PREFER_FRONT, v).apply()

    /** 麦克风默认开启 */
    var micDefault: Boolean
        get() = sp.getBoolean(KEY_MIC, true)
        set(v) = sp.edit().putBoolean(KEY_MIC, v).apply()

    /** 扬声器默认开启 */
    var speakerDefault: Boolean
        get() = sp.getBoolean(KEY_SPEAKER, true)
        set(v) = sp.edit().putBoolean(KEY_SPEAKER, v).apply()

    /** 是否已经成功连接过（用于首次引导） */
    var everConnected: Boolean
        get() = sp.getBoolean(KEY_EVER_CONNECTED, false)
        set(v) = sp.edit().putBoolean(KEY_EVER_CONNECTED, v).apply()

    /** 上次成功连上的地址（自动发现出来的），下次优先用它 */
    var lastGoodHost: String?
        get() = sp.getString(KEY_LAST_GOOD_HOST, null)?.takeIf { it.isNotBlank() }
        set(v) = sp.edit().putString(KEY_LAST_GOOD_HOST, v).apply()

    fun resetToDefaults() {
        sp.edit().clear().apply()
    }

    companion object {
        const val DEFAULT_HOST = "127.0.0.1"
        const val DEFAULT_PORT = 8080

        private const val KEY_HOST = "host"
        private const val KEY_PORT = "port"
        private const val KEY_QUALITY = "quality"
        private const val KEY_FPS = "fps"
        private const val KEY_AUTO_START = "auto_start"
        private const val KEY_PREFER_FRONT = "prefer_front"
        private const val KEY_MIC = "mic"
        private const val KEY_SPEAKER = "speaker"
        private const val KEY_EVER_CONNECTED = "ever_connected"
        private const val KEY_LAST_GOOD_HOST = "last_good_host"
    }
}
