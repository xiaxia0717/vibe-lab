package com.vibelab.phonecam

import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.vibelab.phonecam.databinding.ActivitySettingsBinding

/**
 * 设置页。
 *
 * 所有选项都会即时保存，退出后依然生效。
 * 正常情况下不需要进这里——默认值已经能直接工作。
 */
class SettingsActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySettingsBinding
    private lateinit var prefs: Prefs
    private var loading = true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        prefs = Prefs(this)
        binding.btnBack.setOnClickListener { finish() }

        loadValues()
        bindListeners()
    }

    private fun loadValues() {
        loading = true

        binding.etHost.setText(prefs.host)
        binding.etPort.setText(prefs.port.toString())

        binding.spinnerQuality.setSelection(prefs.qualityIndex.coerceIn(0, 2))
        binding.spinnerFps.setSelection(prefs.fpsIndex.coerceIn(0, 2))

        binding.swAutoStart.isChecked = prefs.autoStart
        binding.swPreferFront.isChecked = prefs.preferFront
        binding.swMic.isChecked = prefs.micDefault
        binding.swSpeaker.isChecked = prefs.speakerDefault

        loading = false
    }

    private fun bindListeners() {
        val watcher = object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) {
                if (loading) return
                val newHost = binding.etHost.text.toString()
                // 用户手改了地址 -> 丢掉之前自动发现记下来的，改用他填的
                if (newHost != prefs.host) prefs.lastGoodHost = null
                prefs.host = newHost
                val p = binding.etPort.text.toString().toIntOrNull()
                if (p != null && p in 1..65535) prefs.port = p
            }
        }
        binding.etHost.addTextChangedListener(watcher)
        binding.etPort.addTextChangedListener(watcher)

        binding.spinnerQuality.onItemSelectedListener =
            SimpleItemSelected { pos -> if (!loading) prefs.qualityIndex = pos }

        binding.spinnerFps.onItemSelectedListener =
            SimpleItemSelected { pos -> if (!loading) prefs.fpsIndex = pos }

        binding.swAutoStart.setOnCheckedChangeListener { _, v ->
            if (!loading) prefs.autoStart = v
        }
        binding.swPreferFront.setOnCheckedChangeListener { _, v ->
            if (!loading) prefs.preferFront = v
        }
        binding.swMic.setOnCheckedChangeListener { _, v ->
            if (!loading) prefs.micDefault = v
        }
        binding.swSpeaker.setOnCheckedChangeListener { _, v ->
            if (!loading) prefs.speakerDefault = v
        }

        binding.btnReset.setOnClickListener {
            prefs.resetToDefaults()
            loadValues()
            Toast.makeText(this, "已恢复默认设置", Toast.LENGTH_SHORT).show()
        }
    }

    /** 只关心 onItemSelected 的简易监听器。 */
    private class SimpleItemSelected(
        private val onSelected: (Int) -> Unit
    ) : android.widget.AdapterView.OnItemSelectedListener {
        override fun onItemSelected(
            parent: android.widget.AdapterView<*>?, view: android.view.View?,
            position: Int, id: Long
        ) = onSelected(position)

        override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {}
    }
}
