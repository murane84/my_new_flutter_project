package com.ozilane.aluta

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Where the singing is in a song, for lyrics that follow it without hand
 * timing. Decodes the audio on the device (nothing leaves the phone) and
 * returns, for every 100 ms, two loudness values: the whole signal and the
 * human-voice band (≈ 300–3400 Hz). Dart finds the voice start / breaks from
 * these. Output: [all0, voice0, all1, voice1, …].
 */
object VocalProfile {
    private class Biquad(val b0: Double, val b1: Double, val b2: Double,
                         val a1: Double, val a2: Double) {
        private var x1 = 0.0; private var x2 = 0.0
        private var y1 = 0.0; private var y2 = 0.0
        fun run(x: Double): Double {
            val y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
        companion object {
            // RBJ cookbook, Q = 0.707.
            fun highPass(fc: Double, sr: Double): Biquad {
                val w = 2 * PI * fc / sr; val a = sin(w) / (2 * 0.707); val c = cos(w)
                val a0 = 1 + a
                return Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0,
                    -2 * c / a0, (1 - a) / a0)
            }
            fun lowPass(fc: Double, sr: Double): Biquad {
                val w = 2 * PI * fc / sr; val a = sin(w) / (2 * 0.707); val c = cos(w)
                val a0 = 1 + a
                return Biquad((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0,
                    -2 * c / a0, (1 - a) / a0)
            }
        }
    }

    fun analyze(ctx: Context, source: Uri?, path: String?): DoubleArray? {
        val ex = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            if (source != null) ex.setDataSource(ctx, source, null) else ex.setDataSource(path!!)
            var track = -1
            var fmt: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                if ((f.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) {
                    track = i; fmt = f; break
                }
            }
            if (track < 0 || fmt == null) return null
            ex.selectTrack(track)
            val mime = fmt.getString(MediaFormat.KEY_MIME)!!
            var sr = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var ch = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(fmt, null, null, 0)
            codec.start()

            var hp = Biquad.highPass(300.0, sr.toDouble())
            var lp = Biquad.lowPass(3400.0, sr.toDouble())
            var frameLen = sr / 10
            val out = ArrayList<Double>(4000)
            var sumAll = 0.0; var sumVoice = 0.0; var n = 0
            val maxFrames = 12 * 60 * 10 // 12 minutes is plenty
            val info = MediaCodec.BufferInfo()
            var inDone = false; var outDone = false
            while (!outDone && out.size / 2 < maxFrames) {
                if (!inDone) {
                    val ii = codec.dequeueInputBuffer(5000)
                    if (ii >= 0) {
                        val buf = codec.getInputBuffer(ii)!!
                        val size = ex.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inDone = true
                        } else {
                            codec.queueInputBuffer(ii, 0, size, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }
                val oi = codec.dequeueOutputBuffer(info, 5000)
                if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    sr = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    ch = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)
                    hp = Biquad.highPass(300.0, sr.toDouble())
                    lp = Biquad.lowPass(3400.0, sr.toDouble())
                    frameLen = sr / 10
                } else if (oi >= 0) {
                    val buf = codec.getOutputBuffer(oi)
                    if (buf != null && info.size > 0) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val sb = buf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                        val count = sb.remaining() / ch
                        for (k in 0 until count) {
                            var m = 0.0
                            for (c in 0 until ch) m += sb.get().toDouble()
                            val x = m / ch / 32768.0
                            val v = lp.run(hp.run(x))
                            sumAll += x * x; sumVoice += v * v; n++
                            if (n >= frameLen) {
                                out.add(sqrt(sumAll / n)); out.add(sqrt(sumVoice / n))
                                sumAll = 0.0; sumVoice = 0.0; n = 0
                            }
                        }
                    }
                    codec.releaseOutputBuffer(oi, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outDone = true
                }
            }
            return out.toDoubleArray()
        } catch (e: Throwable) {
            return null
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            try { ex.release() } catch (_: Throwable) {}
        }
    }
}
