package com.ozilane.aluta

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.annotation.RequiresApi
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import kotlin.concurrent.thread

/// Foreground service that captures the device's OWN audio output (playback
/// capture) for the "identify song" feature. Android 10+ only. Records ~N ms of
/// 16-bit mono PCM at 44.1 kHz, writes a WAV, then reports the path back to
/// MainActivity via [onDone] and stops itself.
@RequiresApi(Build.VERSION_CODES.Q)
class AudioCaptureService : Service() {
    companion object {
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        const val EXTRA_DURATION = "durationMs"
        const val EXTRA_OUTPUT = "output"
        private const val CHANNEL_ID = "aluta_capture"
        private const val NOTIF_ID = 6120

        /// Set by MainActivity right before starting the service; invoked (on the
        /// main thread) with the finished WAV path, or null on failure/empty.
        @Volatile
        var onDone: ((String?) -> Unit)? = null
    }

    private var projection: MediaProjection? = null
    private var record: AudioRecord? = null
    @Volatile private var capturing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            finish(null)
            return START_NOT_STICKY
        }
        val code = intent.getIntExtra(EXTRA_CODE, 0)
        @Suppress("DEPRECATION")
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            intent.getParcelableExtra(EXTRA_DATA)
        }
        val durationMs = intent.getIntExtra(EXTRA_DURATION, 9000)
        val output = intent.getStringExtra(EXTRA_OUTPUT)
        if (data == null || output == null) {
            finish(null)
            return START_NOT_STICKY
        }

        // Must be foreground (mediaProjection type) BEFORE using the projection
        // on Android 14+.
        startAsForeground()

        try {
            val mpm =
                getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val proj = mpm.getMediaProjection(code, data)
            projection = proj
            proj.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    capturing = false
                }
            }, Handler(Looper.getMainLooper()))
            startCapture(proj, durationMs, output)
        } catch (e: Exception) {
            finish(null)
        }
        return START_NOT_STICKY
    }

    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(
                CHANNEL_ID, "Song recognition", NotificationManager.IMPORTANCE_LOW
            )
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
        val notif: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Identifying the song playing…")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startCapture(proj: MediaProjection, durationMs: Int, output: String) {
        val sampleRate = 44100
        val cfg = AudioPlaybackCaptureConfiguration.Builder(proj)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = if (minBuf > 0) minBuf * 2 else sampleRate * 2
        val rec = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(bufSize)
            .setAudioPlaybackCaptureConfig(cfg)
            .build()
        record = rec
        capturing = true
        rec.startRecording()

        thread(start = true) {
            val pcm = ByteArrayOutputStream()
            val buf = ByteArray(bufSize)
            val endAt = System.currentTimeMillis() + durationMs
            try {
                while (capturing && System.currentTimeMillis() < endAt) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n > 0) pcm.write(buf, 0, n)
                }
            } catch (_: Exception) {
            }
            var ok = false
            try {
                val bytes = pcm.toByteArray()
                if (bytes.isNotEmpty()) {
                    writeWav(File(output), bytes, sampleRate, 1, 16)
                    ok = true
                }
            } catch (_: Exception) {
                ok = false
            }
            finish(if (ok) output else null)
        }
    }

    private fun writeWav(file: File, pcm: ByteArray, sampleRate: Int, channels: Int, bits: Int) {
        val byteRate = sampleRate * channels * bits / 8
        val blockAlign = channels * bits / 8
        val dataLen = pcm.size
        val raf = RandomAccessFile(file, "rw")
        try {
            raf.setLength(0)
            raf.writeBytes("RIFF")
            raf.write(intLE(36 + dataLen))
            raf.writeBytes("WAVE")
            raf.writeBytes("fmt ")
            raf.write(intLE(16))
            raf.write(shortLE(1)) // PCM
            raf.write(shortLE(channels))
            raf.write(intLE(sampleRate))
            raf.write(intLE(byteRate))
            raf.write(shortLE(blockAlign))
            raf.write(shortLE(bits))
            raf.writeBytes("data")
            raf.write(intLE(dataLen))
            raf.write(pcm)
        } finally {
            raf.close()
        }
    }

    private fun intLE(v: Int) = byteArrayOf(
        (v and 0xff).toByte(),
        ((v shr 8) and 0xff).toByte(),
        ((v shr 16) and 0xff).toByte(),
        ((v shr 24) and 0xff).toByte()
    )

    private fun shortLE(v: Int) = byteArrayOf(
        (v and 0xff).toByte(),
        ((v shr 8) and 0xff).toByte()
    )

    private fun finish(path: String?) {
        capturing = false
        try {
            record?.stop()
        } catch (_: Exception) {
        }
        try {
            record?.release()
        } catch (_: Exception) {
        }
        record = null
        try {
            projection?.stop()
        } catch (_: Exception) {
        }
        projection = null

        val cb = onDone
        onDone = null
        Handler(Looper.getMainLooper()).post { cb?.invoke(path) }

        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        capturing = false
        super.onDestroy()
    }
}
