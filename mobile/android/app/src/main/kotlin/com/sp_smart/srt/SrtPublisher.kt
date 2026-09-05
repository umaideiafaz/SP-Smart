package com.sp_smart.srt

import android.content.Context
import android.util.Log
import com.sp_smart.camera.Camera2Manager
import com.sp_smart.camera.H265Encoder
import io.flutter.view.TextureRegistry

/**
 * SP Smart — SrtPublisher (Kotlin Wrapper)
 * ============================================================
 * Camada de orquestração do uplink de vídeo.
 * Conecta: Camera2Manager → H265Encoder → JNI SRT (C++).
 * 
 * Expõe as funções nativas JNI e gerencia o ciclo de vida
 * dos objetos multimídia.
 * ============================================================
 */
class SrtPublisher(
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    private val onEventCallback: (String, String) -> Unit
) {
    companion object {
        private const val TAG = "SrtPublisherKT"
        
        init {
            try {
                System.loadLibrary("srt_jni")
                Log.i(TAG, "Native library srt_jni loaded")
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "Failed to load srt_jni", e)
            }
        }
    }

    private var cameraManager: Camera2Manager? = null
    private var encoder: H265Encoder? = null
    
    // ID da textura Flutter para a UI (BroadcastScreen)
    var textureId: Long = -1L
        private set

    init {
        // Registra esta instância no C++ para receber eventos assíncronos (stats, failover complete)
        nativeInit()
    }

    // ─────────────────────────────────────────────────────────
    // Operações do Publisher
    // ─────────────────────────────────────────────────────────

    fun startPipeline(
        host: String, port: Int, streamKey: String, passphrase: String,
        latencyMs: Int, node: String,
        width: Int = 1920, height: Int = 1080, fps: Int = 30, bitrateKbps: Int = 2000
    ): Boolean {
        Log.i(TAG, "Starting pipeline: $width x $height @ $fps fps -> $host:$port")

        // 1. Inicia SRT via JNI
        val connected = nativeConnect(
            host, port, streamKey, passphrase, latencyMs, node
        )
        if (!connected) {
            Log.e(TAG, "Failed to connect SRT socket")
            return false
        }

        // 2. Inicia H.265 Encoder
        encoder = H265Encoder(width, height, fps, bitrateKbps) { data, size, pts ->
            // Callback: Envia cada pacote H.265 para a libsrt C++
            nativeSendPacket(data, size, pts)
        }
        encoder?.start()

        val surface = encoder?.inputSurface
        if (surface == null) {
            Log.e(TAG, "Encoder failed to provide input surface")
            stopPipeline()
            return false
        }

        // 3. Inicia Camera2 apontando para a Surface do Encoder (e Flutter Texture)
        cameraManager = Camera2Manager(context, textureRegistry)
        val config = Camera2Manager.CameraConfig(width = width, height = height, frameRate = fps)
        
        textureId = cameraManager?.open(config, surface) ?: -1L

        return textureId != -1L
    }

    fun stopPipeline() {
        Log.i(TAG, "Stopping pipeline")
        cameraManager?.close()
        cameraManager = null

        encoder?.stop()
        encoder = null

        nativeDisconnect()
    }

    // ── Callbacks Nativos ────────────────────────────────────

    /**
     * Chamado pelo C++ (srt_publisher.cpp) a partir da thread de monitoramento.
     */
    @Suppress("unused") // Chamado via JNI
    fun onNativeEvent(eventType: String, data: String) {
        onEventCallback(eventType, data)
    }

    // ─────────────────────────────────────────────────────────
    // Declarações JNI
    // ─────────────────────────────────────────────────────────
    private external fun nativeInit()
    external fun nativeConnect(
        host: String, port: Int, streamKey: String, passphrase: String,
        latencyMs: Int, node: String
    ): Boolean
    external fun nativeSwitchDestination(
        host: String, port: Int, streamKey: String, passphrase: String,
        latencyMs: Int, node: String
    ): Boolean
    external fun nativeDisconnect()
    external fun nativeSendPacket(data: ByteArray, size: Int, pts: Long)
    external fun nativeSetTargetBitrate(bitrateKbps: Int)
}
