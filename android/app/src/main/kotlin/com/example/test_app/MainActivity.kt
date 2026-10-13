package com.example.test_app

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val sampleRate = 16000
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private var recorder: AudioRecord? = null
    private var recordThread: Thread? = null
    @Volatile private var recording = false
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null

    private var track: AudioTrack? = null
    private val playExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "wavetalk/mic").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )

        MethodChannel(messenger, "wavetalk/audio").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(startAudio())
                "stop" -> {
                    stopAudio()
                    result.success(null)
                }
                "play" -> {
                    val data = call.arguments as? ByteArray
                    if (data != null) playChunk(data)
                    result.success(null)
                }
                "setSpeaker" -> {
                    setSpeaker(call.arguments as? Boolean ?: false)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startAudio(): String? {
        if (recording) return null
        try {
            // خدمة المقدمة: تبقي المكالمة شغالة لما التطبيق يروح بالخلفية
            val svc = Intent(this, CallService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(svc)
            } else {
                startService(svc)
            }

            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            am.isSpeakerphoneOn = false
            volumeControlStream = AudioManager.STREAM_VOICE_CALL

            val minRec = AudioRecord.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            if (minRec <= 0) {
                stopAudio()
                return "الجهاز ما يدعم تسجيل الصوت بهذا الإعداد"
            }
            val recBuf = maxOf(minRec, sampleRate / 5 * 2)

            val rec = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                recBuf
            )
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                rec.release()
                stopAudio()
                return "فشل تشغيل المايك، تأكد من الصلاحية"
            }
            if (AcousticEchoCanceler.isAvailable()) {
                aec = AcousticEchoCanceler.create(rec.audioSessionId)
                aec?.setEnabled(true)
            }
            if (NoiseSuppressor.isAvailable()) {
                ns = NoiseSuppressor.create(rec.audioSessionId)
                ns?.setEnabled(true)
            }
            recorder = rec

            val minPlay = AudioTrack.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            val t = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(maxOf(minPlay, sampleRate * 2))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            t.play()
            track = t

            recording = true
            rec.startRecording()
            recordThread = Thread {
                val buf = ByteArray(sampleRate / 50 * 2)
                try {
                    while (recording) {
                        val n = rec.read(buf, 0, buf.size)
                        if (n > 0) {
                            val chunk = buf.copyOf(n)
                            mainHandler.post { eventSink?.success(chunk) }
                        } else if (n < 0) {
                            break
                        }
                    }
                } catch (e: Exception) {
                }
            }.also { it.start() }
            return null
        } catch (e: Exception) {
            stopAudio()
            return "خطأ بتشغيل الصوت: ${e.message}"
        }
    }

    private fun stopAudio() {
        recording = false
        try {
            recordThread?.join(300)
        } catch (e: Exception) {
        }
        recordThread = null
        try {
            aec?.release()
        } catch (e: Exception) {
        }
        try {
            ns?.release()
        } catch (e: Exception) {
        }
        aec = null
        ns = null
        try {
            recorder?.stop()
        } catch (e: Exception) {
        }
        try {
            recorder?.release()
        } catch (e: Exception) {
        }
        recorder = null
        try {
            track?.stop()
        } catch (e: Exception) {
        }
        try {
            track?.release()
        } catch (e: Exception) {
        }
        track = null
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.isSpeakerphoneOn = false
            am.mode = AudioManager.MODE_NORMAL
            volumeControlStream = AudioManager.USE_DEFAULT_STREAM_TYPE
        } catch (e: Exception) {
        }
        try {
            stopService(Intent(this, CallService::class.java))
        } catch (e: Exception) {
        }
    }

    private fun playChunk(data: ByteArray) {
        val t = track ?: return
        playExecutor.execute {
            try {
                t.write(data, 0, data.size)
            } catch (e: Exception) {
            }
        }
    }

    private fun setSpeaker(on: Boolean) {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.isSpeakerphoneOn = on
        } catch (e: Exception) {
        }
    }

    override fun onDestroy() {
        stopAudio()
        super.onDestroy()
    }
}