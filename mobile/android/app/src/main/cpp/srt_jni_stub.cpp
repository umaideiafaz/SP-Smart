/**
 * SP Smart — SRT JNI Stub (Atualizado para Alta Disponibilidade)
 *
 * Adições para Fase 1.5 (HA):
 *   nativeSwitchDestination() — stub para hot-swap de socket SRT
 *
 * Implementação real na Fase 2:
 *   srt_publisher.cpp    — gestão de sockets libsrt + dual-socket bonding
 *   h265_encoder.cpp     — MediaCodec H.265/HEVC hardware encoder
 *   network_bonder.cpp   — multipath WiFi + cellular
 *
 * ─── Estratégia de switchDestination (Fase 2) ─────────────────
 *
 *  void SrtPublisher::switchDestination(host, port, streamKey, latencyMs) {
 *    // 1. Cria novo socket
 *    SRTSOCKET newSock = srt_create_socket();
 *    srt_setsockopt(newSock, 0, SRTO_LATENCY, &latencyMs, sizeof(latencyMs));
 *    srt_setsockopt(newSock, 0, SRTO_STREAMID, streamKey, strlen(streamKey));
 *
 *    // 2. Conecta ao novo destino (non-blocking)
 *    srt_connect(newSock, newAddr, sizeof(newAddr));
 *
 *    // 3. Aguarda SRTS_CONNECTED (poll com timeout de 5s)
 *    SRT_EPOLL_EVENT evts[2];
 *    srt_epoll_wait(epollId, evts, &n, nullptr, &m, 5000);
 *
 *    // 4. Troca atômica: novos pacotes → newSock
 *    std::atomic_exchange(&activeSock, newSock);
 *
 *    // 5. Drena e fecha socket antigo (thread separada)
 *    drainAndClose(oldSock, 500ms);
 *
 *    // 6. Sinaliza Java layer → 'switch_complete' event
 *  }
 */

#include <jni.h>
#include <android/log.h>
#include <string>

#define LOG_TAG "SrtJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
    LOGI("SRT JNI library loaded (Phase 1 stub — HA ready)");
    // Phase 2: srt_startup();
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* /*vm*/, void* /*reserved*/) {
    // Phase 2: srt_cleanup();
}

// ── connect ───────────────────────────────────────────────────
JNIEXPORT jboolean JNICALL
Java_com_sp_smart_srt_SrtPublisher_nativeConnect(
    JNIEnv* env, jobject /*thiz*/,
    jstring host, jint port, jstring streamKey, jint latencyMs)
{
    const char* h = env->GetStringUTFChars(host, nullptr);
    const char* k = env->GetStringUTFChars(streamKey, nullptr);
    LOGI("nativeConnect: %s:%d streamid=%s latency=%dms (stub)", h, port, k, latencyMs);
    env->ReleaseStringUTFChars(host, h);
    env->ReleaseStringUTFChars(streamKey, k);
    return JNI_TRUE;
}

// ── switchDestination — HA hot-swap ───────────────────────────
JNIEXPORT jboolean JNICALL
Java_com_sp_smart_srt_SrtPublisher_nativeSwitchDestination(
    JNIEnv* env, jobject /*thiz*/,
    jstring newHost, jint newPort, jstring newStreamKey, jint latencyMs)
{
    const char* h = env->GetStringUTFChars(newHost, nullptr);
    const char* k = env->GetStringUTFChars(newStreamKey, nullptr);
    LOGW("nativeSwitchDestination: → %s:%d streamid=%s latency=%dms (stub)", h, newPort, k, latencyMs);
    env->ReleaseStringUTFChars(newHost, h);
    env->ReleaseStringUTFChars(newStreamKey, k);
    // Phase 2: SrtPublisher::switchDestination(h, newPort, k, latencyMs);
    return JNI_TRUE;
}

// ── disconnect ────────────────────────────────────────────────
JNIEXPORT void JNICALL
Java_com_sp_smart_srt_SrtPublisher_nativeDisconnect(
    JNIEnv* /*env*/, jobject /*thiz*/)
{
    LOGI("nativeDisconnect (stub)");
    // Phase 2: SrtPublisher::disconnect();
}

// ── sendPacket ────────────────────────────────────────────────
JNIEXPORT void JNICALL
Java_com_sp_smart_srt_SrtPublisher_nativeSendPacket(
    JNIEnv* /*env*/, jobject /*thiz*/,
    jbyteArray /*data*/, jint /*size*/, jlong /*pts*/)
{
    // Phase 2: Forward encoded H.265 NAL units → active SRT socket
}

// ── setTargetBitrate ──────────────────────────────────────────
JNIEXPORT void JNICALL
Java_com_sp_smart_srt_SrtPublisher_nativeSetTargetBitrate(
    JNIEnv* /*env*/, jobject /*thiz*/, jint bitrateKbps)
{
    LOGI("nativeSetTargetBitrate: %d kbps (stub)", bitrateKbps);
    // Phase 2: srt_setsockopt(activeSock, 0, SRTO_MAXBW, &bps, sizeof(bps))
}

// ── getStats ──────────────────────────────────────────────────
JNIEXPORT jobject JNICALL
Java_com_sp_smart_srt_SrtPublisher_nativeGetStats(
    JNIEnv* /*env*/, jobject /*thiz*/)
{
    // Phase 2: Call srt_bistats() → SRT_TRACEBSTATS → Java HashMap
    return nullptr;
}

} // extern "C"
