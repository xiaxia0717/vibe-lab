package com.vibelab.phonecam

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import android.util.Size
import android.view.View
import android.widget.Toast
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

class MainActivity : AppCompatActivity(), StreamClient.Listener {

    companion object {
        private const val TAG = "PhoneCam"
        private const val REQ_PERM = 1001
        private const val PCM_RATE = 16000
        private const val JPEG_QUALITY = 60
    }

    private lateinit var binding: ActivityMainBinding
    private val analyzeExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var client: StreamClient? = null
    private var cameraProvider: ProcessCameraProvider? = null

    @Volatile private var running = false
    @Volatile private var micOn = true
    @Volatile private var speakerOn = true
    @Volatile private var lensFacing = CameraSelector.LENS_FACING_BACK

    private var targetFps = 24
    private var lastFrameAt = 0L
    private var framesInWindow = 0
    private var windowStart = 0L
    private var lastReportedFps = 0
    private val encoding = AtomicBoolean(false)

    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var micThread: Thread? = null
    private val micRunning = AtomicBoolean(false)

    private var wakeLock: PowerManager.WakeLock? = null

    private val videoSize = Size(1280, 720)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.btnStart.setOnClickListener { if (running) stopAll() else ensurePermissionsThenStart() }
        binding.btnSwitch.setOnClickListener { switchLens() }
        binding.btnMic.setOnClickListener { toggleMic() }
        binding.btnSpeaker.setOnClickListener { toggleSpeaker() }

        binding.spinnerQuality.setOnItemSelectedListener(object :
            android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: android.widget.AdapterView<*>?, v: View?, pos: Int, id: Long) {
                if (!running) return
                mainHandler.post {
                    stopCamera()
                    startCamera()
                }
            }
            override fun onNothingSelected(p: android.widget.AdapterView<*>?) {}
        })

        binding.spinnerFps.setOnItemSelectedListener(object :
            android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: android.widget.AdapterView<*>?, v: View?, pos: Int, id: Long) {
                targetFps = when (pos) {
                    0 -> 15
                    1 -> 24
                    else -> 30
                }
            }
            override fun onNothingSelected(p: android.widget.AdapterView<*>?) {}
        })

        updateUi()
        setStatus("未连接", StatusColor.IDLE)
        binding.tvLog.text = "点「启动」开始，手机将作为电脑的摄像头与麦克风"
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

        if (need.isEmpty()) {
            startAll()
        } else {
            ActivityCompat.requestPermissions(this, need.toTypedArray(), REQ_PERM)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERM) return
        val ok = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        if (ok) startAll() else {
            toast("需要摄像头和麦克风权限才能工作")
            binding.tvLog.text = "权限被拒绝，无法启动"
        }
    }

    // ---------------------------------------------------------------- 启停

    private fun startAll() {
        acquireWakeLock()
        connectServer()
        startCamera()
        startMic()
        startAudioPlayback()
        running = true
        updateUi()
        binding.tvLog.text = "运行中 — 请保持本应用在前台"
    }

    private fun stopAll() {
        running = false
        stopCamera()
        stopMic()
        stopAudioPlayback()
        client?.close()
        client = null
        releaseWakeLock()
        updateUi()
        setStatus("已停止", StatusColor.IDLE)
        binding.tvFps.text = "-- fps"
        binding.tvLog.text = "已停止"
    }

    private fun updateUi() {
        binding.btnStart.text = if (running) "停止" else "启动"
        binding.btnStart.setBackgroundResource(
            if (running) R.drawable.bg_btn_danger else R.drawable.bg_btn_primary
        )
        binding.btnMic.text = if (micOn) "麦克风 开" else "麦克风 关"
        binding.btnMic.setBackgroundResource(
            if (micOn) R.drawable.bg_btn_on else R.drawable.bg_btn_off
        )
        binding.btnSpeaker.text = if (speakerOn) "扬声器 开" else "扬声器 关"
        binding.btnSpeaker.setBackgroundResource(
            if (speakerOn) R.drawable.bg_btn_on else R.drawable.bg_btn_off
        )
    }

    // ---------------------------------------------------------------- 连接

    private fun connectServer() {
        val host = binding.etHost.text.toString().trim().ifBlank { "127.0.0.1" }
        val port = binding.etPort.text.toString().trim().toIntOrNull() ?: 8080
        client?.close()
        val c = StreamClient(host, port, this)
        client = c
        setStatus("连接中…", StatusColor.WARN)
        c.connect()
    }

    override fun onConnected() {
        mainHandler.post {
            setStatus("已连接", StatusColor.OK)
            binding.tvLog.text = "已连接电脑，画面正在传输"
        }
    }

    override fun onDisconnected(reason: String) {
        mainHandler.post {
            setStatus("已断开", StatusColor.ERROR)
            binding.tvLog.text = "连接断开：$reason"
        }
    }

    override fun onRemoteAudio(pcm: ByteArray) {
        if (!speakerOn) return
        try {
            audioTrack?.write(pcm, 0, pcm.size)
        } catch (_: Exception) {
        }
    }

    // ---------------------------------------------------------------- 摄像头

    private fun currentSize(): Size = when (binding.spinnerQuality.selectedItemPosition) {
        0 -> Size(640, 480)
        1 -> Size(1280, 720)
        else -> Size(1920, 1080)
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            try {
                val provider = future.get()
                cameraProvider = provider
                provider.unbindAll()

                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(binding.previewView.surfaceProvider)
                }

                val size = currentSize()
                val resolutionSelector = ResolutionSelector.Builder()
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
                    .setResolutionSelector(resolutionSelector)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .build()

                analysis.setAnalyzer(analyzeExecutor) { proxy -> handleFrame(proxy) }

                val selector = CameraSelector.Builder()
                    .requireLensFacing(lensFacing)
                    .build()

                provider.bindToLifecycle(this, selector, preview, analysis)
                Log.i(TAG, "相机已启动 ${size.width}x${size.height}")
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
            mainHandler.postDelayed({ startCamera() }, 250)
        }
        binding.tvLog.text = if (lensFacing == CameraSelector.LENS_FACING_FRONT)
            "已切换到前置摄像头" else "已切换到后置摄像头"
    }

    /** 把一帧 YUV 转成 JPEG 推出去。 */
    private fun handleFrame(proxy: ImageProxy) {
        try {
            val now = System.currentTimeMillis()
            val interval = 1000L / targetFps
            if (now - lastFrameAt < interval) return
            lastFrameAt = now

            if (!running || !encoding.compareAndSet(false, true)) return

            val jpeg = rgbaToJpeg(proxy) ?: return
            client?.sendVideo(jpeg)

            framesInWindow++
            if (windowStart == 0L) windowStart = now
            if (now - windowStart >= 1000) {
                lastReportedFps = framesInWindow
                framesInWindow = 0
                windowStart = now
                mainHandler.post { binding.tvFps.text = "$lastReportedFps fps" }
            }
        } catch (e: Exception) {
            Log.e(TAG, "帧处理异常", e)
        } finally {
            encoding.set(false)
            proxy.close()
        }
    }

    private fun rgbaToJpeg(proxy: ImageProxy): ByteArray? {
        val width = proxy.width
        val height = proxy.height
        return try {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bitmap.copyPixelsFromBuffer(proxy.planes[0].buffer)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            bitmap.recycle()
            out.toByteArray()
        } catch (e: Exception) {
            Log.e(TAG, "JPEG 编码失败", e)
            null
        }
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
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord 未初始化")
            return
        }
        audioRecord = record
        micRunning.set(true)
        record.startRecording()

        micThread = Thread {
            val buf = ByteArray(bufSize)
            while (micRunning.get()) {
                val n = record.read(buf, 0, buf.size)
                if (n > 0 && micOn) {
                    client?.sendAudio(buf.copyOf(n))
                }
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
        binding.tvLog.text = if (micOn) "麦克风已开启" else "麦克风已关闭"
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
        val dot = when (color) {
            StatusColor.OK -> R.drawable.dot_green
            StatusColor.WARN -> R.drawable.dot_amber
            StatusColor.ERROR -> R.drawable.dot_red
            StatusColor.IDLE -> R.drawable.dot_gray
        }
        binding.dotStatus.setImageResource(dot)
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    // ---------------------------------------------------------------- 生命周期

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.SCREEN_DIM_WAKE_LOCK, "PhoneCam::stream")
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
        super.onDestroy()
        stopAll()
        analyzeExecutor.shutdown()
    }
}
