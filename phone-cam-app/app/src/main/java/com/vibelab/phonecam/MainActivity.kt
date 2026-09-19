package com.vibelab.phonecam

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import android.util.Size
import android.view.HapticFeedbackConstants
import android.view.Surface
import android.view.View
import android.view.WindowManager
import android.view.animation.AnimationUtils
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.vibelab.phonecam.databinding.ActivityMainBinding
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 主界面：一个预览 + 一个启动按钮 + 三个开关。
 *
 * 地址、端口、画质等全部走「设置」页，主界面不出现，做到打开就能用。
 */
class MainActivity : AppCompatActivity(), StreamClient.Listener {

    companion object {
        private const val TAG = "PhoneCam"
        private const val REQ_PERM = 1001
        private const val PCM_RATE = 16000
        private const val JPEG_QUALITY = 60
        private const val RECONNECT_DELAY_MS = 2500L
    }

    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: Prefs
    private val analyzeExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var client: StreamClient? = null
    private var cameraProvider: ProcessCameraProvider? = null

    /** 留着引用，屏幕旋转时要改它们的 targetRotation。 */
    private var previewUseCase: Preview? = null
    private var analysisUseCase: ImageAnalysis? = null

    @Volatile private var running = false
    @Volatile private var micOn = true
    @Volatile private var speakerOn = true
    @Volatile private var lensFacing = CameraSelector.LENS_FACING_BACK
    @Volatile private var destroyed = false

    /** 局域网自动发现出来的电脑地址 */
    @Volatile private var discoveredHost: String? = null
    @Volatile private var discovering = false
    private var failCount = 0
    private var reconnectTask: Runnable? = null

    private var targetFps = 24
    private var framesInWindow = 0
    private var rawFrames = 0
    private var windowStart = 0L
    private var encodeMsAcc = 0L

    /** 下一帧最早可以发的时间（累积式限速，见 handleFrame）。 */
    private var nextSendAt = 0L
    private var lastRotationDeg = -1
    private val encoding = AtomicBoolean(false)

    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var micThread: Thread? = null
    private val micRunning = AtomicBoolean(false)

    private var wakeLock: PowerManager.WakeLock? = null
    private var reconnectScheduled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        prefs = Prefs(this)
        applyPrefs()

        binding.btnStart.setOnClickListener { onStartClicked() }
        binding.btnSwitch.setOnClickListener { withTap { switchLens() } }
        binding.btnMic.setOnClickListener { withTap { toggleMic() } }
        binding.btnSpeaker.setOnClickListener { withTap { toggleSpeaker() } }
        binding.btnSettings.setOnClickListener { withTap {
            startActivity(Intent(this, SettingsActivity::class.java))
        } }

        updateUi()
        setStatus("未启动", StatusColor.IDLE)
        binding.tvLog.text = "准备就绪"

        if (prefs.autoStart) {
            mainHandler.postDelayed({ ensurePermissionsThenStart() }, 350)
        }
    }

    /** 读取配置（进入设置页返回后也要重新读）。 */
    private fun applyPrefs() {
        targetFps = when (prefs.fpsIndex) {
            0 -> 15
            1 -> 24
            else -> 30
        }
        micOn = prefs.micDefault
        speakerOn = prefs.speakerDefault
        if (!running) {
            lensFacing = if (prefs.preferFront)
                CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK
        }
        val q = when (prefs.qualityIndex) {
            0 -> "480p"
            1 -> "720p"
            else -> "1080p"
        }
        binding.tvQualityInfo.text = "$q · ${targetFps}fps"
        updateUi()
    }

    override fun onResume() {
        super.onResume()
        if (!running) applyPrefs()
    }

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int =
        binding.previewView.display?.rotation
            ?: windowManager.defaultDisplay?.rotation
            ?: Surface.ROTATION_0

    /**
     * 把采集方向对齐当前屏幕方向。
     *
     * 手机横过来当摄像头用是常态 —— 方向不对，对方看到的画面就是歪的。
     * 主界面已经不锁竖屏了，所以这里跟着屏幕走即可。
     */
    private fun applyTargetRotation() {
        val rotation = displayRotation()
        try {
            previewUseCase?.targetRotation = rotation
            analysisUseCase?.targetRotation = rotation
            Log.i(TAG, "applyTargetRotation -> $rotation " +
                    "(preview=${previewUseCase?.targetRotation} " +
                    "analysis=${analysisUseCase?.targetRotation})")
        } catch (e: Exception) {
            Log.w(TAG, "设置采集方向失败: ${e.message}")
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        Log.i(TAG, "onConfigurationChanged orientation=${newConfig.orientation}")
        applyTargetRotation()
    }

    private fun withTap(action: () -> Unit) {
        try {
            binding.root.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
        } catch (_: Exception) {
        }
        action()
    }

    // ---------------------------------------------------------------- 权限

    private fun ensurePermissionsThenStart() {
        val need = mutableListOf<String>()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) need += Manifest.permission.CAMERA
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) need += Manifest.permission.RECORD_AUDIO

        if (need.isEmpty()) startAll()
        else ActivityCompat.requestPermissions(this, need.toTypedArray(), REQ_PERM)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERM) return
        val ok = grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        if (ok) {
            startAll()
        } else {
            setStatus("缺少权限", StatusColor.ERROR)
            binding.tvLog.text = "需要摄像头和麦克风权限才能工作"
        }
    }

    // ---------------------------------------------------------------- 启停

    private fun onStartClicked() {
        withTap { }
        if (running) stopAll() else ensurePermissionsThenStart()
    }

    private fun startAll() {
        if (running) return
        running = true

        acquireWakeLock()
        // 关键：必须用窗口标志保持屏幕常亮。
        // 旧的 SCREEN_DIM_WAKE_LOCK 在 Android 13 上已失效，
        // 屏幕一休眠 Activity 就 onStop，CameraX 跟着解绑 -> 画面直接断。
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // 重置限速状态，免得继承上次残留的截止时间
        nextSendAt = 0L
        windowStart = 0L
        framesInWindow = 0
        rawFrames = 0
        encodeMsAcc = 0L
        binding.placeholder.visibility = View.GONE
        binding.btnStart.startAnimation(
            AnimationUtils.loadAnimation(this, R.anim.press)
        )

        startCamera()
        startMic()
        startAudioPlayback()
        connectServer()

        updateUi()
        binding.tvLog.text = "正在连接电脑…"
    }

    private fun stopAll() {
        running = false
        cancelReconnect()
        stopCamera()
        stopMic()
        stopAudioPlayback()
        client?.close()
        client = null
        releaseWakeLock()
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        binding.placeholder.visibility = View.VISIBLE
        binding.tvFps.text = "-- fps"
        updateUi()
        setStatus("已停止", StatusColor.IDLE)
        binding.tvLog.text = "已停止"
    }

    private fun updateUi() {
        if (running) {
            binding.tvStartLabel.text = "停 止"
            binding.icStart.setImageResource(R.drawable.ic_stop)
            binding.btnStart.setBackgroundResource(R.drawable.bg_btn_danger)
        } else {
            binding.tvStartLabel.text = "启 动"
            binding.icStart.setImageResource(R.drawable.ic_play)
            binding.btnStart.setBackgroundResource(R.drawable.bg_btn_primary)
        }

        binding.icMic.setImageResource(
            if (micOn) R.drawable.ic_mic else R.drawable.ic_mic_off
        )
        binding.btnMic.setBackgroundResource(
            if (micOn) R.drawable.bg_btn_on else R.drawable.bg_btn_off
        )
        binding.tvMicLabel.text = if (micOn) "麦克风" else "已静音"

        binding.icSpeaker.setImageResource(
            if (speakerOn) R.drawable.ic_speaker else R.drawable.ic_speaker_off
        )
        binding.btnSpeaker.setBackgroundResource(
            if (speakerOn) R.drawable.bg_btn_on else R.drawable.bg_btn_off
        )
        binding.tvSpeakerLabel.text = if (speakerOn) "扬声器" else "已关闭"
    }

    // ---------------------------------------------------------------- 连接

    private fun connectServer() {
        setStatus("连接中…", StatusColor.WARN)
        val c = StreamClient(currentHost(), prefs.port, this)
        client = c
        c.connect()
    }

    /** 这次该连哪个地址：自动发现的 > 上次成功的 > 用户设置的。 */
    private fun currentHost(): String =
        discoveredHost ?: prefs.lastGoodHost ?: prefs.host

    /**
     * 连不上时在后台找一下电脑（局域网广播）。
     *
     * 这样 WiFi 模式下不用手填 IP，路由器换地址也不怕。
     * 找不到就清掉记住的地址，下次回到用户设置的地址重试。
     */
    private fun startDiscovery() {
        if (discovering || destroyed) return
        discovering = true
        Thread {
            val found = Discovery.find(2500)
            mainHandler.post {
                discovering = false
                if (destroyed || !running) return@post

                if (found.isNullOrBlank()) {
                    if (prefs.lastGoodHost != null) {
                        prefs.lastGoodHost = null
                        binding.tvLog.text = "没找到电脑，改用设置的地址重试…"
                    }
                    return@post
                }
                if (found == currentHost()) return@post

                discoveredHost = found
                prefs.lastGoodHost = found
                binding.tvLog.text = "已自动找到电脑: $found"
                cancelReconnect()
                client?.close()
                connectServer()
            }
        }.start()
    }

    override fun onConnected() {
        prefs.everConnected = true
        failCount = 0
        prefs.lastGoodHost = currentHost()
        mainHandler.post {
            cancelReconnect()
            setStatus("已连接", StatusColor.OK)
            binding.tvLog.text = "已连接电脑，画面正在传输"
            try {
                val v = getSystemService(VIBRATOR_SERVICE) as? Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    v?.vibrate(VibrationEffect.createOneShot(25, 80))
                } else {
                    @Suppress("DEPRECATION") v?.vibrate(25)
                }
            } catch (_: Exception) {
            }
        }
    }

    override fun onDisconnected(reason: String) {
        mainHandler.post {
            if (!running) {
                setStatus("已停止", StatusColor.IDLE)
                return@post
            }
            failCount++
            setStatus("重连中…", StatusColor.WARN)
            binding.tvLog.text = "连接断开，正在自动重连…"
            // 连不上就试着在局域网里找一下电脑（WiFi 模式免填 IP）
            startDiscovery()
            scheduleReconnect()
        }
    }

    /** 断线后自动重连，不用用户管。 */
    private fun scheduleReconnect() {
        if (reconnectScheduled || destroyed || !running) return
        reconnectScheduled = true
        val task = Runnable {
            reconnectTask = null
            reconnectScheduled = false
            if (running && !destroyed) {
                client?.close()
                connectServer()
            }
        }
        reconnectTask = task
        mainHandler.postDelayed(task, RECONNECT_DELAY_MS)
    }

    /**
     * 取消还没执行的重连。
     *
     * 必须的：自动发现找到电脑后会主动重连，如果不把排队的重连取消掉，
     * 它过一会儿又会把刚建好的连接掐掉，出现"连上-断开-连上"的抖动。
     */
    private fun cancelReconnect() {
        reconnectTask?.let { mainHandler.removeCallbacks(it) }
        reconnectTask = null
        reconnectScheduled = false
    }

    override fun onRemoteAudio(pcm: ByteArray) {
        if (!speakerOn) return
        try {
            audioTrack?.write(pcm, 0, pcm.size)
        } catch (_: Exception) {
        }
    }

    // ---------------------------------------------------------------- 摄像头

    private fun currentSize(): Size = when (prefs.qualityIndex) {
        0 -> Size(640, 480)
        1 -> Size(1280, 720)
        else -> Size(1920, 1080)
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            if (!running) return@addListener
            try {
                val provider = future.get()
                cameraProvider = provider
                provider.unbindAll()

                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(binding.previewView.surfaceProvider)
                }

                val size = currentSize()
                val selector = ResolutionSelector.Builder()
                    .setAspectRatioStrategy(
                        AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY
                    )
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            size,
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                        )
                    )
                    .build()

                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(selector)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .build()
                    .also { it.setAnalyzer(analyzeExecutor) { p -> handleFrame(p) } }

                previewUseCase = preview
                analysisUseCase = analysis
                applyTargetRotation()

                val camSelector = CameraSelector.Builder()
                    .requireLensFacing(lensFacing)
                    .build()

                provider.bindToLifecycle(this, camSelector, preview, analysis)
            } catch (e: Exception) {
                Log.e(TAG, "相机启动失败", e)
                mainHandler.post { binding.tvLog.text = "相机启动失败：${e.message}" }
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun stopCamera() {
        try {
            cameraProvider?.unbindAll()
        } catch (_: Exception) {
        }
    }

    private fun switchLens() {
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK)
            CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK
        if (running) {
            stopCamera()
            mainHandler.postDelayed({ if (running) startCamera() }, 200)
        }
        binding.tvLog.text = if (lensFacing == CameraSelector.LENS_FACING_FRONT)
            "已切换到前置摄像头" else "已切换到后置摄像头"
    }

    private fun handleFrame(proxy: ImageProxy) {
        try {
            val now = System.currentTimeMillis()
            rawFrames++
            // 用「累积截止时间」限速，而不是「距上一帧不足 interval 就丢」。
            // 相机出帧间隔约 33ms，而 24fps 的窗口是 41ms —— 用后者会把
            // 每帧都判成"太早"，实际变成发一帧丢一帧，帧率被压到 15fps。
            // 累积式允许偶尔补发，长期平均刚好落在目标帧率上。
            val interval = 1000L / targetFps
            if (now < nextSendAt) return
            nextSendAt = maxOf(nextSendAt + interval, now)

            if (!running || !encoding.compareAndSet(false, true)) return

            val deg = proxy.imageInfo.rotationDegrees
            if (deg != lastRotationDeg) {
                lastRotationDeg = deg
                Log.i(TAG, "rotationDegrees -> $deg")
            }

            val t0 = System.currentTimeMillis()
            val jpeg = rgbaToJpeg(proxy)
            encodeMsAcc += System.currentTimeMillis() - t0
            if (jpeg != null) client?.sendVideo(jpeg)

            framesInWindow++
            if (windowStart == 0L) windowStart = now
            if (now - windowStart >= 1000) {
                val sent = framesInWindow
                val raw = rawFrames
                val avgMs = if (sent > 0) encodeMsAcc.toDouble() / sent else 0.0
                framesInWindow = 0
                rawFrames = 0
                encodeMsAcc = 0L
                windowStart = now
                mainHandler.post { binding.tvFps.text = "$sent fps" }
                // 诊断：raw = 相机实际出帧数，sent = 真正发出去的。
                // 两者差距大说明限速/编码在拖；raw 本身就低说明是相机（暗光降帧）。
                Log.i(TAG, "stats raw=$raw sent=$sent encode=" +
                        String.format(java.util.Locale.US, "%.1f", avgMs) + "ms")
            }
        } catch (e: Exception) {
            Log.e(TAG, "帧处理异常", e)
        } finally {
            encoding.set(false)
            proxy.close()
        }
    }

    /**
     * 把一帧转成 JPEG。
     *
     * **必须按 `rotationDegrees` 旋转**：CameraX 的 ImageAnalysis 给的是
     * 传感器原始方向的像素，不会替你转。忽略它的话，画面方向就只取决于
     * 手机物理怎么摆 —— 竖着拿推出去的画面就是侧翻 90° 的。
     */
    private fun rgbaToJpeg(proxy: ImageProxy): ByteArray? = try {
        val src = Bitmap.createBitmap(proxy.width, proxy.height, Bitmap.Config.ARGB_8888)
        src.copyPixelsFromBuffer(proxy.planes[0].buffer)

        val deg = proxy.imageInfo.rotationDegrees
        val out = ByteArrayOutputStream()
        if (deg == 0) {
            src.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            src.recycle()
        } else {
            val matrix = Matrix().apply { postRotate(deg.toFloat()) }
            val rotated = Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, true)
            src.recycle()
            rotated.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            rotated.recycle()
        }
        out.toByteArray()
    } catch (e: Exception) {
        Log.e(TAG, "JPEG 编码失败", e)
        null
    }

    // ---------------------------------------------------------------- 麦克风

    private fun startMic() {
        val minBuf = AudioRecord.getMinBufferSize(
            PCM_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = maxOf(minBuf, 4096)
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                PCM_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, bufSize
            )
        } catch (e: Exception) {
            Log.e(TAG, "AudioRecord 创建失败", e)
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) return

        audioRecord = record
        micRunning.set(true)
        record.startRecording()

        micThread = Thread {
            val buf = ByteArray(bufSize)
            while (micRunning.get()) {
                val n = record.read(buf, 0, buf.size)
                if (n > 0 && micOn) client?.sendAudio(buf.copyOf(n))
            }
        }.also { it.priority = Thread.MAX_PRIORITY; it.start() }
    }

    private fun stopMic() {
        micRunning.set(false)
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (_: Exception) {
        }
        audioRecord = null
        micThread = null
    }

    // ---------------------------------------------------------------- 扬声器

    private fun startAudioPlayback() {
        if (audioTrack != null) return
        val minBuf = AudioTrack.getMinBufferSize(
            PCM_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(PCM_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(minBuf * 4, 16384))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        track.play()
        audioTrack = track
    }

    private fun stopAudioPlayback() {
        try {
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {
        }
        audioTrack = null
    }

    // ---------------------------------------------------------------- 开关

    private fun toggleMic() {
        micOn = !micOn
        updateUi()
        binding.tvLog.text = if (micOn) "麦克风已开启" else "麦克风已静音"
    }

    private fun toggleSpeaker() {
        speakerOn = !speakerOn
        updateUi()
        binding.tvLog.text = if (speakerOn) "扬声器已开启" else "扬声器已关闭"
    }

    // ---------------------------------------------------------------- 状态

    private enum class StatusColor { IDLE, OK, WARN, ERROR }

    private fun setStatus(text: String, color: StatusColor) {
        binding.tvStatus.text = text
        binding.dotStatus.setImageResource(
            when (color) {
                StatusColor.OK -> R.drawable.dot_green
                StatusColor.WARN -> R.drawable.dot_amber
                StatusColor.ERROR -> R.drawable.dot_red
                StatusColor.IDLE -> R.drawable.dot_gray
            }
        )
    }

    // ---------------------------------------------------------------- 生命周期

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        // 只保 CPU 不休眠；屏幕常亮交给 FLAG_KEEP_SCREEN_ON 管。
        // SCREEN_DIM_WAKE_LOCK 自 API 17 起已废弃，在 Android 13 上不生效。
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PhoneCam::stream")
        wakeLock?.setReferenceCounted(false)
        wakeLock?.acquire(4 * 60 * 60 * 1000L)
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    override fun onDestroy() {
        destroyed = true
        super.onDestroy()
        stopAll()
        analyzeExecutor.shutdown()
    }
}
