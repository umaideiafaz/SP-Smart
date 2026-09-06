package com.sp_smart.camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Range
import android.view.Surface
import android.view.WindowManager
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * SP Smart — Camera2Manager
 * ============================================================
 * Gerencia o acesso de baixo nível à câmera via Camera2 API.
 *
 * Recursos implementados:
 *  • Seleção de câmera (traseira / frontal)
 *  • Controles manuais: ISO, tempo de exposição, balanço de
 *    branco (temperatura de cor), foco manual e AF contínuo
 *  • Integração com Flutter TextureRegistry (preview via Texture widget)
 *  • Surface separada para o H265Encoder (encode sem cópia)
 *  • Resolução e framerate configuráveis
 *
 * Thread model:
 *  • cameraThread: HandlerThread exclusivo para Camera2 callbacks
 *  • Todas as chamadas públicas são thread-safe
 * ============================================================
 */
@SuppressLint("MissingPermission")
class Camera2Manager(
    private val context:         Context,
    private val textureRegistry: TextureRegistry,
) {
    companion object {
        private const val TAG = "Camera2Manager"
        private const val CAMERA_OPEN_TIMEOUT_SEC = 3L
    }

    // ── Flutter Texture (preview) ─────────────────────────────
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var previewSurface: Surface? = null

    val flutterTextureId: Long
        get() = textureEntry?.id() ?: -1L

    // ── Camera2 handles ───────────────────────────────────────
    private var cameraDevice:  CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var captureRequest: CaptureRequest.Builder? = null

    // ── Encoder surface (fornecida pelo H265Encoder) ──────────
    private var encoderSurface: Surface? = null

    // ── Background thread ─────────────────────────────────────
    private val cameraThread  = HandlerThread("CameraThread").also { it.start() }
    private val cameraHandler = Handler(cameraThread.looper)
    private val cameraOpenLock = Semaphore(1)

    // ── Estado atual ─────────────────────────────────────────
    @Volatile private var isRunning = false
    @Volatile private var isSwitchingCamera = false

    // ── Configurações ──────────────────────────────────────────
    data class CameraConfig(
        val lensFacing:   Int     = CameraCharacteristics.LENS_FACING_BACK,
        val width:        Int     = 1920,
        val height:       Int     = 1080,
        val frameRate:    Int     = 30,
        // Controles manuais (null = AUTO)
        val isoOverride:  Int?    = null,         // ex: 200, 400, 800
        val exposureNs:   Long?   = null,         // tempo de exposição em nanosegundos
        val wbMode:       Int     = CaptureRequest.CONTROL_AWB_MODE_AUTO,
        val focusMode:    Int     = CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO,
        val manualFocus:  Float?  = null,         // 0.0 (infinito) – 1.0 (mínimo)
    )

    private var config = CameraConfig()

    // ─────────────────────────────────────────────────────────
    // API Pública
    // ─────────────────────────────────────────────────────────

    /**
     * Abre a câmera e inicia o preview no Flutter Texture.
     * [encoderSurface] é a surface de entrada do MediaCodec H265.
     *
     * @return flutterTextureId para o widget Texture() no Flutter
     */
    fun open(newConfig: CameraConfig, encoderSurface: Surface): Long {
        config = newConfig
        this.encoderSurface = encoderSurface

        // Cria/registra a surface do Flutter preview
        val entry = textureRegistry.createSurfaceTexture()
        textureEntry = entry
        val st = entry.surfaceTexture()
        st.setDefaultBufferSize(config.width, config.height)
        previewSurface = Surface(st)

        openCameraInternal()
        return entry.id()
    }

    /** Alterna entre as câmeras traseira e frontal sem recriar as Surfaces. */
    @Synchronized
    fun switchCamera(): Boolean {
        if (isSwitchingCamera) return true

        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val targetFacing = if (config.lensFacing == CameraCharacteristics.LENS_FACING_BACK) {
            CameraCharacteristics.LENS_FACING_FRONT
        } else {
            CameraCharacteristics.LENS_FACING_BACK
        }

        val hasTargetCamera = manager.cameraIdList.any { id ->
            manager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == targetFacing
        }
        if (!hasTargetCamera) {
            Log.w(TAG, "No camera available for lens facing $targetFacing")
            return false
        }

        isSwitchingCamera = true
        config = config.copy(lensFacing = targetFacing)
        cameraHandler.post {
            isRunning = false
            try {
                try {
                    captureSession?.stopRepeating()
                    captureSession?.abortCaptures()
                } catch (e: CameraAccessException) {
                    Log.w(TAG, "Capture session already stopping", e)
                } catch (e: IllegalStateException) {
                    Log.w(TAG, "Capture session already closed", e)
                }
                captureSession?.close()
                cameraDevice?.close()
                captureSession = null
                cameraDevice = null
                captureRequest = null
                openCameraInternal()
                Log.i(TAG, "Switching camera to lens facing $targetFacing")
            } catch (e: Exception) {
                isSwitchingCamera = false
                Log.e(TAG, "Failed to switch camera", e)
            }
        }
        return true
    }

    fun cameraInfo(): Map<String, Any> {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = selectCamera(manager, config.lensFacing)
        val sensorOrientation = cameraId?.let {
            manager.getCameraCharacteristics(it)
                .get(CameraCharacteristics.SENSOR_ORIENTATION)
        } ?: 0
        @Suppress("DEPRECATION")
        val displayRotation = (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
            .defaultDisplay.rotation
        val displayDegrees = when (displayRotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        val relativeRotation = if (config.lensFacing == CameraCharacteristics.LENS_FACING_FRONT) {
            (sensorOrientation + displayDegrees) % 360
        } else {
            (sensorOrientation - displayDegrees + 360) % 360
        }
        return mapOf(
            "frontFacing" to (config.lensFacing == CameraCharacteristics.LENS_FACING_FRONT),
            "rotationDegrees" to relativeRotation,
        )
    }

    /**
     * Encerra a câmera e libera todos os recursos.
     */
    fun close() {
        isRunning = false
        captureSession?.stopRepeating()
        captureSession?.close()
        cameraDevice?.close()
        previewSurface?.release()
        textureEntry?.release()
        captureSession = null
        cameraDevice   = null
        previewSurface = null
        textureEntry   = null
        Log.i(TAG, "Camera closed")
    }

    /**
     * Atualiza um ou mais parâmetros manuais sem reabrir a câmera.
     * Os valores null mantêm o controle em AUTO.
     */
    fun updateManualControls(
        iso:       Int?   = config.isoOverride,
        exposureNs: Long? = config.exposureNs,
        wbMode:    Int    = config.wbMode,
        focusMode: Int    = config.focusMode,
        manualFocus: Float? = config.manualFocus,
    ) {
        val session = captureSession ?: return
        val builder = captureRequest ?: return

        config = config.copy(
            isoOverride = iso,
            exposureNs  = exposureNs,
            wbMode      = wbMode,
            focusMode   = focusMode,
            manualFocus = manualFocus,
        )
        applyManualControls(builder)
        session.setRepeatingRequest(builder.build(), null, cameraHandler)
    }

    // ─────────────────────────────────────────────────────────
    // Internos
    // ─────────────────────────────────────────────────────────

    private fun openCameraInternal() {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = selectCamera(manager, config.lensFacing)

        if (cameraId == null) {
            Log.e(TAG, "No camera found for lens facing ${config.lensFacing}")
            return
        }

        cameraOpenLock.tryAcquire(CAMERA_OPEN_TIMEOUT_SEC, TimeUnit.SECONDS)

        manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                cameraOpenLock.release()
                cameraDevice = device
                Log.i(TAG, "Camera opened: $cameraId")
                createCaptureSession(device)
            }
            override fun onDisconnected(device: CameraDevice) {
                cameraOpenLock.release()
                isSwitchingCamera = false
                device.close()
                cameraDevice = null
                Log.w(TAG, "Camera disconnected")
            }
            override fun onError(device: CameraDevice, error: Int) {
                cameraOpenLock.release()
                isSwitchingCamera = false
                device.close()
                cameraDevice = null
                Log.e(TAG, "Camera error: $error")
            }
        }, cameraHandler)
    }

    private fun createCaptureSession(device: CameraDevice) {
        val surfaces = buildList<Surface> {
            previewSurface?.let { add(it) }
            encoderSurface?.let { add(it) }
        }

        if (surfaces.isEmpty()) {
            Log.e(TAG, "No surfaces for capture session")
            return
        }

        val stateCallback = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                captureSession = session
                isSwitchingCamera = false
                Log.i(TAG, "Capture session configured (${surfaces.size} surfaces)")
                startRepeatingRequest(device, session)
            }
            override fun onConfigureFailed(session: CameraCaptureSession) {
                isSwitchingCamera = false
                Log.e(TAG, "Capture session configuration failed")
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // API 28+: SessionConfiguration com executor (preferido)
            val outputConfigs = surfaces.map { OutputConfiguration(it) }
            val sessionConfig = SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR,
                outputConfigs,
                Executors.newSingleThreadExecutor(),
                stateCallback,
            )
            device.createCaptureSession(sessionConfig)
        } else {
            @Suppress("DEPRECATION")
            device.createCaptureSession(surfaces, stateCallback, cameraHandler)
        }
    }

    private fun startRepeatingRequest(device: CameraDevice, session: CameraCaptureSession) {
        val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)

        previewSurface?.let  { builder.addTarget(it) }
        encoderSurface?.let  { builder.addTarget(it) }

        // Framerate fixo (obrigatório para encode determinístico)
        builder.set(
            CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
            Range(config.frameRate, config.frameRate),
        )

        // Modo de cena: ação (minimiza blur em movimento)
        builder.set(CaptureRequest.CONTROL_SCENE_MODE,
            CaptureRequest.CONTROL_SCENE_MODE_ACTION)

        applyManualControls(builder)

        captureRequest = builder
        session.setRepeatingRequest(builder.build(), null, cameraHandler)
        isRunning = true
        Log.i(TAG, "Repeating capture request started: ${config.width}×${config.height}@${config.frameRate}fps")
    }

    /**
     * Aplica os controles manuais ao builder.
     *
     * Hierarquia de controle:
     *  1. Se iso ou exposureNs não são null → modo manual (3A desativado)
     *  2. Caso contrário → modo AUTO para os controles não especificados
     */
    private fun applyManualControls(builder: CaptureRequest.Builder) {

        // ── Auto-exposição / ISO / Tempo de exposição ─────────
        if (config.isoOverride != null || config.exposureNs != null) {
            // Manual AE
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
            config.isoOverride?.let {
                builder.set(CaptureRequest.SENSOR_SENSITIVITY, it)
            }
            config.exposureNs?.let {
                builder.set(CaptureRequest.SENSOR_EXPOSURE_TIME, it)
            }
        } else {
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        }

        // ── Balanço de Branco ─────────────────────────────────
        builder.set(CaptureRequest.CONTROL_AWB_MODE, config.wbMode)

        // ── Foco ─────────────────────────────────────────────
        if (config.manualFocus != null) {
            builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
            builder.set(CaptureRequest.LENS_FOCUS_DISTANCE, config.manualFocus)
        } else {
            builder.set(CaptureRequest.CONTROL_AF_MODE, config.focusMode)
        }

        // ── Video stabilization (OIS) ────────────────────────
        builder.set(
            CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
            CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON,
        )
    }

    private fun selectCamera(manager: CameraManager, lensFacing: Int): String? {
        for (id in manager.cameraIdList) {
            val chars = manager.getCameraCharacteristics(id)
            if (chars.get(CameraCharacteristics.LENS_FACING) == lensFacing) {
                return id
            }
        }
        return manager.cameraIdList.firstOrNull()
    }
}
