package com.sp_smart.camera

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

/**
 * SP Smart — H265Encoder
 * ============================================================
 * Codificador de hardware HEVC (H.265) utilizando MediaCodec API.
 * 
 * Requisitos atendidos:
 *  • H.265/HEVC obrigatório para economia de banda celular.
 *  • Entrada via Surface (zero-copy a partir do Camera2Manager).
 *  • Controle de Bitrate CBR (Constant Bitrate) para broadcast.
 *  • Ajuste dinâmico de bitrate em tempo real.
 *  • Extração de NAL units em formato Annex B (start codes)
 *    para envio direto ao SRT NDK.
 * ============================================================
 */
class H265Encoder(
    private val width: Int,
    private val height: Int,
    private val frameRate: Int,
    private val initialBitrateKbps: Int,
    private val onPacketReady: (ByteArray, Int, Long) -> Unit
) {
    companion object {
        private const val TAG = "H265Encoder"
        private const val MIME_TYPE = MediaFormat.MIMETYPE_VIDEO_HEVC
        private const val TIMEOUT_USEC = 10000L
    }

    private var mediaCodec: MediaCodec? = null
    var inputSurface: Surface? = null
        private set

    @Volatile
    private var isRunning = false
    private var encoderThread: Thread? = null

    /**
     * Inicializa o MediaCodec, configura o formato H.265 e obtém a InputSurface.
     */
    fun start() {
        if (isRunning) return

        try {
            val format = MediaFormat.createVideoFormat(MIME_TYPE, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, initialBitrateKbps * 1000)
                setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2) // Keyframe a cada 2 segundos (GOP)
                
                // Força CBR (Constant Bitrate) - ideal para streaming
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            }

            mediaCodec = MediaCodec.createEncoderByType(MIME_TYPE).apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                inputSurface = createInputSurface()
                start()
            }

            isRunning = true
            encoderThread = Thread { encodeLoop() }
            encoderThread?.start()

            Log.i(TAG, "H.265 Encoder started: ${width}x${height}@${frameRate}fps, ${initialBitrateKbps}kbps")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start H.265 encoder", e)
            stop()
        }
    }

    /**
     * Altera o target bitrate em tempo real (ex: adaptador de rede pede menos banda).
     */
    fun setBitrate(bitrateKbps: Int) {
        try {
            mediaCodec?.let { codec ->
                val params = Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrateKbps * 1000)
                }
                codec.setParameters(params)
                Log.i(TAG, "Bitrate dynamically changed to ${bitrateKbps}kbps")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to change bitrate", e)
        }
    }

    /**
     * Loop principal de captura da saída do encoder.
     */
    private fun encodeLoop() {
        val codec = mediaCodec ?: return
        val bufferInfo = MediaCodec.BufferInfo()

        while (isRunning) {
            try {
                val outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC)

                if (outputBufferIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    continue
                } else if (outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val newFormat = codec.outputFormat
                    Log.i(TAG, "Encoder output format changed: $newFormat")
                } else if (outputBufferIndex >= 0) {
                    val outputBuffer = codec.getOutputBuffer(outputBufferIndex)
                    
                    if (outputBuffer != null && bufferInfo.size > 0) {
                        // Verifica se é codec config (SPS/PPS/VPS)
                        val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        
                        // Ajusta buffer para leitura
                        outputBuffer.position(bufferInfo.offset)
                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)

                        val packetSize = bufferInfo.size
                        val packetData = ByteArray(packetSize)
                        outputBuffer.get(packetData)

                        // Envia para o JNI (SRT)
                        onPacketReady(packetData, packetSize, bufferInfo.presentationTimeUs)
                    }

                    codec.releaseOutputBuffer(outputBufferIndex, false)

                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        Log.i(TAG, "End of stream reached")
                        break
                    }
                }
            } catch (e: Exception) {
                if (isRunning) {
                    Log.e(TAG, "Error in encode loop", e)
                }
            }
        }
    }

    /**
     * Para o encoder e libera a Surface.
     */
    fun stop() {
        isRunning = false
        try {
            encoderThread?.join(500)
        } catch (e: InterruptedException) {
            // ignore
        }
        
        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping MediaCodec", e)
        } finally {
            mediaCodec = null
            inputSurface = null
            Log.i(TAG, "H.265 Encoder stopped")
        }
    }
}
