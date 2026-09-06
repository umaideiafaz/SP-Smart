package com.sp_smart.audio

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Process
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sqrt

/** Captura PCM sem processamento para controle e medição real do microfone. */
class AudioInputManager(
    private val context: Context,
    private val onEvent: (String, String) -> Unit,
    private val onEncodedPacket: (ByteArray, Int, Long) -> Unit,
) {
    enum class Source(val wireName: String) {
        DEFAULT("default"),
        EXTERNAL("external"),
        BLUETOOTH("bluetooth"),
    }

    companion object {
        private const val SAMPLE_RATE = 48_000
        private const val METER_INTERVAL_NS = 50_000_000L
    }

    private val running = AtomicBoolean(false)
    @Volatile private var muted = false
    @Volatile private var gain = 1.0f
    @Volatile private var source = Source.DEFAULT
    private var recorder: AudioRecord? = null
    private var captureThread: Thread? = null

    @Synchronized
    fun start() {
        if (running.get()) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        try {
            openAndStart(source)
        } catch (error: Throwable) {
            running.set(false)
            recorder?.release()
            recorder = null
            onEvent(
                "audio_error",
                JSONObject().put("message", error.message ?: "Audio input failed").toString(),
            )
        }
    }

    @Synchronized
    fun stop() {
        running.set(false)
        try { recorder?.stop() } catch (_: IllegalStateException) {}
        captureThread?.join(750)
        recorder?.release()
        recorder = null
        captureThread = null
    }

    @Synchronized
    fun selectSource(wireName: String): Boolean {
        val next = Source.entries.firstOrNull { it.wireName == wireName } ?: return false
        if (next == source && running.get()) return true
        source = next
        stop()
        start()
        return running.get()
    }

    fun setMuted(value: Boolean) { muted = value }
    fun setGain(value: Float) { gain = value.coerceIn(0f, 2f) }

    fun availableSources(): List<Map<String, Any>> {
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val inputs = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        return Source.entries.map { candidate ->
            mapOf(
                "id" to candidate.wireName,
                "available" to when (candidate) {
                    Source.DEFAULT -> true
                    Source.EXTERNAL -> inputs.any(::isExternal)
                    Source.BLUETOOTH -> inputs.any(::isBluetooth)
                },
            )
        }
    }

    private fun openAndStart(selected: Source) {
        val channelMask = AudioFormat.CHANNEL_IN_STEREO
        val minBytes = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBytes <= 0) return

        val record = AudioRecord.Builder()
            .setAudioSource(MediaRecorder.AudioSource.UNPROCESSED)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(channelMask)
                    .build(),
            )
            .setBufferSizeInBytes(max(minBytes * 2, SAMPLE_RATE / 5 * 4))
            .build()

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return
        }

        val preferred = preferredDevice(selected)
        if (selected != Source.DEFAULT && preferred == null) {
            record.release()
            throw IllegalStateException("Requested audio input is not connected")
        }
        if (preferred != null && !record.setPreferredDevice(preferred)) {
            record.release()
            throw IllegalStateException("Android rejected the requested audio input")
        }
        recorder = record
        running.set(true)
        record.startRecording()
        captureThread = thread(name = "AudioInputMeter", isDaemon = true) {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            captureLoop(record)
        }
    }

    private fun captureLoop(record: AudioRecord) {
        val samples = ShortArray(2048)
        var lastMeterAt = 0L
        var capturedFrames = 0L
        val codec = createAacEncoder()
        val bufferInfo = MediaCodec.BufferInfo()
        try {
            while (running.get()) {
                val count = record.read(samples, 0, samples.size, AudioRecord.READ_BLOCKING)
                if (count <= 0) continue

                val currentGain = if (muted) 0f else gain
                var sumL = 0.0
                var sumR = 0.0
                var frames = 0
                var index = 0
                while (index + 1 < count) {
                    val left = (samples[index] * currentGain).coerceIn(-32768f, 32767f)
                    val right = (samples[index + 1] * currentGain).coerceIn(-32768f, 32767f)
                    samples[index] = left.toInt().toShort()
                    samples[index + 1] = right.toInt().toShort()
                    sumL += left * left
                    sumR += right * right
                    frames++
                    index += 2
                }

                queuePcm(codec, samples, count, capturedFrames)
                capturedFrames += frames
                drainAac(codec, bufferInfo)

                val now = System.nanoTime()
                if (now - lastMeterAt >= METER_INTERVAL_NS && frames > 0) {
                    lastMeterAt = now
                    val rmsL = sqrt(sumL / frames) / 32768.0
                    val rmsR = sqrt(sumR / frames) / 32768.0
                    onEvent(
                        "audio_levels",
                        JSONObject()
                            .put("left", normalizedDb(rmsL))
                            .put("right", normalizedDb(rmsR))
                            .put("muted", muted)
                            .put("gain", gain.toDouble())
                            .put("source", source.wireName)
                            .toString(),
                    )
                }
            }
        } finally {
            try { codec.stop() } catch (_: IllegalStateException) {}
            codec.release()
        }
    }

    private fun createAacEncoder(): MediaCodec {
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            SAMPLE_RATE,
            2,
        ).apply {
            setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192)
        }
        return MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }
    }

    private fun queuePcm(
        codec: MediaCodec,
        samples: ShortArray,
        sampleCount: Int,
        capturedFrames: Long,
    ) {
        val inputIndex = codec.dequeueInputBuffer(10_000)
        if (inputIndex < 0) return
        val input = codec.getInputBuffer(inputIndex) ?: return
        input.clear()
        val shortsToWrite = minOf(sampleCount, input.remaining() / 2)
        input.asShortBuffer().put(samples, 0, shortsToWrite)
        codec.queueInputBuffer(
            inputIndex,
            0,
            shortsToWrite * 2,
            capturedFrames * 1_000_000L / SAMPLE_RATE,
            0,
        )
    }

    private fun drainAac(codec: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            val outputIndex = codec.dequeueOutputBuffer(info, 0)
            if (outputIndex < 0) return
            val output = codec.getOutputBuffer(outputIndex)
            val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
            if (output != null && info.size > 0 && !isConfig) {
                output.position(info.offset)
                output.limit(info.offset + info.size)
                val packet = ByteArray(info.size + 7)
                writeAdtsHeader(packet, packet.size)
                output.get(packet, 7, info.size)
                onEncodedPacket(packet, packet.size, info.presentationTimeUs)
            }
            codec.releaseOutputBuffer(outputIndex, false)
        }
    }

    private fun writeAdtsHeader(packet: ByteArray, frameLength: Int) {
        val aacLcProfile = 1
        val sampleRateIndex48k = 3
        val channels = 2
        packet[0] = 0xFF.toByte()
        packet[1] = 0xF1.toByte()
        packet[2] = (
            (aacLcProfile shl 6) or
                (sampleRateIndex48k shl 2) or
                (channels shr 2)
            ).toByte()
        packet[3] = (((channels and 3) shl 6) or (frameLength shr 11)).toByte()
        packet[4] = ((frameLength shr 3) and 0xFF).toByte()
        packet[5] = (((frameLength and 7) shl 5) or 0x1F).toByte()
        packet[6] = 0xFC.toByte()
    }

    /** Converte -60..0 dBFS em 0..1 para o medidor. */
    private fun normalizedDb(rms: Double): Double {
        if (rms <= 0.000001) return 0.0
        val db = 20.0 * ln(rms) / ln(10.0)
        return ((db + 60.0) / 60.0).coerceIn(0.0, 1.0)
    }

    private fun preferredDevice(selected: Source): AudioDeviceInfo? {
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val inputs = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        return when (selected) {
            Source.DEFAULT -> inputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
            Source.EXTERNAL -> inputs.firstOrNull(::isExternal)
            Source.BLUETOOTH -> inputs.firstOrNull(::isBluetooth)
        }
    }

    private fun isExternal(device: AudioDeviceInfo): Boolean = when (device.type) {
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET -> true
        else -> false
    }

    private fun isBluetooth(device: AudioDeviceInfo): Boolean = when (device.type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET -> true
        else -> false
    }
}
