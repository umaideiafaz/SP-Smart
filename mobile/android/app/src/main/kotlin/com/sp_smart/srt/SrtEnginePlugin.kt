package com.sp_smart.srt

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.texture.TextureRegistry
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject

/**
 * SP Smart — SRT Engine Android Plugin (Fase 4 - Full Integration)
 */
class SrtEnginePlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    
    private lateinit var context: Context
    private lateinit var textureRegistry: TextureRegistry

    // Instância real do orquestrador
    private var publisher: SrtPublisher? = null

    // Destino atual (para envio em fallback se necessário)
    private var currentHost: String = ""
    private var currentPort: Int = 8890
    private var currentStreamKey: String = ""
    private var currentNode: String = "primary"

    // ── FlutterPlugin ─────────────────────────────────────────
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textureRegistry = binding.textureRegistry
        
        methodChannel = MethodChannel(binding.binaryMessenger, "sp.smart/srt")
        methodChannel.setMethodCallHandler(this)
        
        eventChannel = EventChannel(binding.binaryMessenger, "sp.smart/srt/events")
        eventChannel.setStreamHandler(this)
        
        // Inicializa o publisher
        publisher = SrtPublisher(context, textureRegistry) { eventType, data ->
            handleNativeEvent(eventType, data)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        publisher?.stopPipeline()
        publisher = null
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    // ── MethodCallHandler ─────────────────────────────────────
    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "connect"            -> handleConnect(call, result)
            "disconnect"         -> handleDisconnect(result)
            "switchDestination"  -> handleSwitchDestination(call, result)
            "setTargetBitrate"   -> handleSetBitrate(call, result)
            "getTextureId"       -> result.success(publisher?.textureId ?: -1L)
            else                 -> result.notImplemented()
        }
    }

    // ── connect ───────────────────────────────────────────────
    private fun handleConnect(call: MethodCall, result: Result) {
        val host      = call.argument<String>("host") ?: return result.error("INVALID_ARG", "host required", null)
        val port      = call.argument<Int>("port") ?: 8890
        val streamKey = call.argument<String>("streamKey") ?: ""
        val latencyMs = call.argument<Int>("latencyMs") ?: 120
        val node      = call.argument<String>("node") ?: "primary"

        currentHost = host
        currentPort = port
        currentStreamKey = streamKey
        currentNode = node

        val success = publisher?.startPipeline(host, port, streamKey, latencyMs, node) == true
        
        if (success) {
            // Emite que estamos conectando (o C++ emitirá streaming depois)
            sendEvent(mapOf("event" to "state_changed", "state" to "connecting"))
            result.success(true)
        } else {
            result.error("CONNECT_FAILED", "Failed to start pipeline", null)
        }
    }

    // ── switchDestination ──────────────────────────────────────
    private fun handleSwitchDestination(call: MethodCall, result: Result) {
        val newHost      = call.argument<String>("host") ?: return result.error("INVALID_ARG", "host required", null)
        val newPort      = call.argument<Int>("port") ?: 8890
        val newStreamKey = call.argument<String>("streamKey") ?: ""
        val latencyMs    = call.argument<Int>("latencyMs") ?: 120
        val newNode      = call.argument<String>("node") ?: "backup"

        sendEvent(mapOf("event" to "state_changed", "state" to "switching"))

        // Chama JNI para hot-swap lock-free
        val success = publisher?.nativeSwitchDestination(newHost, newPort, newStreamKey, latencyMs, newNode) == true

        if (success) {
            currentHost = newHost
            currentPort = newPort
            currentStreamKey = newStreamKey
            currentNode = newNode
            result.success(true)
        } else {
            result.error("SWITCH_FAILED", "Failed to initiate switch", null)
        }
    }

    // ── disconnect ────────────────────────────────────────────
    private fun handleDisconnect(result: Result) {
        publisher?.stopPipeline()
        result.success(null)
    }

    // ── setTargetBitrate ──────────────────────────────────────
    private fun handleSetBitrate(call: MethodCall, result: Result) {
        val bitrateKbps = call.argument<Int>("bitrateKbps") ?: return result.error("INVALID_ARG", "bitrate", null)
        publisher?.nativeSetTargetBitrate(bitrateKbps)
        result.success(null)
    }

    // ── EventChannel.StreamHandler ────────────────────────────
    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) { eventSink = sink }
    override fun onCancel(arguments: Any?) { eventSink = null }

    private fun sendEvent(data: Map<String, Any?>) {
        eventSink?.success(data)
    }

    private fun handleNativeEvent(eventType: String, jsonString: String) {
        try {
            val map = mutableMapOf<String, Any?>("event" to eventType)
            
            if (jsonString.isNotEmpty()) {
                // Apenas converte a string JSON simples do C++ em um Map para o Flutter
                val jsonObject = JSONObject(jsonString)
                val keys = jsonObject.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    map[key] = jsonObject.get(key)
                }
            }
            sendEvent(map)
        } catch (e: Exception) {
            // Se não for JSON (ex: payload de erro simples), passa como string
            sendEvent(mapOf("event" to eventType, "data" to jsonString))
        }
    }
}
