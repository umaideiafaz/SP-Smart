/**
 * SP Smart — SRT Publisher NDK (Fase 4: Implementação Real)
 * ============================================================
 * Gerencia conexões libsrt em modo Caller com dual-socket
 * para hot-swap atômico durante o failover de rede.
 *
 * ── Fluxo de dados ──────────────────────────────────────────
 *
 *  MediaCodec (Kotlin) → nativeSendPacket (JNI boundary)
 *    → SrtPublisher::send()
 *        → srt_sendmsg2(activeSock, ...)    ← atomic load
 *
 *  HA Failover (switchDestination):
 *    1. srt_create_socket() + connect() → pendingSock
 *    2. epoll wait (SRTS_CONNECTED) com timeout 5s
 *    3. std::atomic_exchange(&activeSock, pendingSock)  ← LOCK-FREE
 *    4. drainAndClose(oldSock, 500ms) em thread separada
 *    5. JNI callback → 'switch_complete' event
 *
 * ── Thread model ─────────────────────────────────────────────
 *  - JNI caller thread: send data packets
 *  - monitorThread_: runs srt_epoll_uwait, reports stats
 *  - switchThread_: executes hot-swap (ephemeral)
 *
 * ── libsrt compilação ────────────────────────────────────────
 *  Source: third_party/srt/ (git submodule de Haivision/srt)
 *  Flags:  -DENABLE_ENCRYPTION=ON -DUSE_ENCLIB=openssl
 *          -DENABLE_APPS=OFF (sem executáveis, apenas biblioteca)
 * ============================================================
 */

#include <jni.h>
#include <android/log.h>
#include <atomic>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <string>
#include <cstring>
#include <vector>
#include <array>
#include <algorithm>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// libsrt headers
#include "srt.h"

#define LOG_TAG "SrtPublisher"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ─────────────────────────────────────────────────────────────
// SrtPublisher — singleton por JVM instance
// ─────────────────────────────────────────────────────────────

namespace {

// Sentinel value: socket não criado / encerrado
static constexpr SRTSOCKET kInvalidSock = SRT_INVALID_SOCK;

// Intervalo de coleta de stats (ms)
static constexpr int kStatsIntervalMs = 1000;

// Timeout de handshake para novo socket durante switch (ms)
static constexpr int kSwitchTimeoutMs = 5000;

// Drenagem do socket antigo após switch (ms)
static constexpr int kDrainDelayMs = 500;

// ─────────────────────────────────────────────────────────────

struct SrtPublisher {
    // Socket ativo — acesso lock-free via atomic
    std::atomic<SRTSOCKET> activeSock{kInvalidSock};

    // Proteção para operações de switch
    std::mutex             switchMtx;
    std::condition_variable switchCv;

    // Thread de monitoramento (stats + watchdog)
    std::thread  monitorThread;
    std::atomic<bool> running{false};

    // Epoll para monitoramento não-bloqueante
    int epollId{-1};

    // Referência à JVM para callbacks na monitorThread
    JavaVM* jvm{nullptr};
    jobject  pluginObjRef{nullptr}; // GlobalRef do SrtEnginePlugin.kt
    jmethodID onStatsMethod{nullptr};
    jmethodID onEventMethod{nullptr};

    // Destino atual (para reconexão automática)
    std::string currentHost;
    int         currentPort{0};
    std::string currentStreamKey;
    int         currentLatencyMs{120};
    std::string currentNode{"primary"};

    // MPEG-TS é compartilhado pelas threads de saída dos MediaCodec H.265/AAC.
    std::mutex muxMtx;
    std::array<uint8_t, 8192> continuity{};
    std::vector<uint8_t> tsPayload;
    int64_t lastTablesPts{-1};

    ~SrtPublisher() { cleanup(); }

    void cleanup() {
        running.store(false);
        if (monitorThread.joinable()) monitorThread.join();

        SRTSOCKET s = activeSock.exchange(kInvalidSock);
        if (s != kInvalidSock) srt_close(s);

        if (epollId >= 0) {
            srt_epoll_release(epollId);
            epollId = -1;
        }

        if (jvm && pluginObjRef) {
            JNIEnv* env;
            if (jvm->GetEnv((void**)&env, JNI_VERSION_1_6) == JNI_OK) {
                env->DeleteGlobalRef(pluginObjRef);
            }
            pluginObjRef = nullptr;
        }
    }
};

static SrtPublisher* gPublisher = nullptr;
static std::mutex    gPublisherMtx;

SrtPublisher* getOrCreatePublisher() {
    std::lock_guard<std::mutex> lk(gPublisherMtx);
    if (!gPublisher) {
        gPublisher = new SrtPublisher();
    }
    return gPublisher;
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

/**
 * Cria e configura um socket SRT para broadcast em modo Caller.
 * Retorna SRT_INVALID_SOCK em caso de erro.
 */
SRTSOCKET createSocket(
    const char* host, int port, const char* streamKey,
    const char* passphrase, int latencyMs) {
    SRTSOCKET s = srt_create_socket();
    if (s == kInvalidSock) {
        LOGE("srt_create_socket failed: %s", srt_getlasterror_str());
        return kInvalidSock;
    }

    // Configurações de latência (120ms padrão — adequado para 4G/5G)
    srt_setsockopt(s, 0, SRTO_RCVLATENCY, &latencyMs, sizeof(latencyMs));
    srt_setsockopt(s, 0, SRTO_PEERLATENCY, &latencyMs, sizeof(latencyMs));

    // Stream ID (identificador do stream no MediaMTX)
    if (streamKey && strlen(streamKey) > 0) {
        srt_setsockopt(s, 0, SRTO_STREAMID, streamKey, (int)strlen(streamKey));
    }

    // Criptografia SRT AES-256. As duas opcoes precisam ser aplicadas antes
    // de srt_connect(); a passphrase nunca e escrita nos logs.
    const size_t passphraseLength = passphrase ? strlen(passphrase) : 0;
    if (passphraseLength < 10 || passphraseLength > 79) {
        LOGE("Invalid SRT passphrase length: %zu", passphraseLength);
        srt_close(s);
        return kInvalidSock;
    }
    int pbKeyLen = 32;
    if (srt_setsockopt(s, 0, SRTO_PBKEYLEN, &pbKeyLen, sizeof(pbKeyLen)) == SRT_ERROR ||
        srt_setsockopt(s, 0, SRTO_PASSPHRASE, passphrase,
                       (int)passphraseLength) == SRT_ERROR) {
        LOGE("Failed to configure SRT AES-256: %s", srt_getlasterror_str());
        srt_close(s);
        return kInvalidSock;
    }

    // Payload size: 1316 bytes = múltiplo de MPEG-TS packet (188 × 7)
    int payloadSize = 1316;
    srt_setsockopt(s, 0, SRTO_PAYLOADSIZE, &payloadSize, sizeof(payloadSize));

    // Max bandwidth automático (SRT gerencia internamente)
    int64_t maxBw = -1; // -1 = sem limite (SRT usa cálculo interno)
    srt_setsockopt(s, 0, SRTO_MAXBW, &maxBw, sizeof(maxBw));

    // Input bandwidth: estimativa inicial (será ajustado pelo bitrate do encoder)
    int64_t inputBw = 8000000LL; // 8 Mbps
    srt_setsockopt(s, 0, SRTO_INPUTBW, &inputBw, sizeof(inputBw));

    // Overhead: 25% do inputBw para retransmissão
    int oheadPct = 25;
    srt_setsockopt(s, 0, SRTO_OHEADBW, &oheadPct, sizeof(oheadPct));

    // Timeout de conexão: 3s
    int connTimeout = 3000;
    srt_setsockopt(s, 0, SRTO_CONNTIMEO, &connTimeout, sizeof(connTimeout));

    // Resolve o hostname DNS no Android antes do srt_connect. AF_INET preserva
    // o transporte IPv4 ja validado no hardware, sem exigir IP cru na UI.
    struct addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    char portText[6]{};
    std::snprintf(portText, sizeof(portText), "%d", port);
    struct addrinfo* resolved = nullptr;
    const int dnsResult = getaddrinfo(host, portText, &hints, &resolved);
    if (dnsResult != 0 || resolved == nullptr) {
        LOGE("SRT DNS resolution failed for %s: %s", host,
             dnsResult == 0 ? "no address" : gai_strerror(dnsResult));
        srt_close(s);
        return kInvalidSock;
    }

    LOGI("Connecting SRT socket → %s:%d streamid=%s latency=%dms", host, port, streamKey, latencyMs);
    int r = srt_connect(s, resolved->ai_addr, resolved->ai_addrlen);
    freeaddrinfo(resolved);
    if (r == SRT_ERROR) {
        LOGE("srt_connect failed: %s", srt_getlasterror_str());
        srt_close(s);
        return kInvalidSock;
    }

    LOGI("SRT socket connected (%s:%d)", host, port);
    return s;
}

// ─────────────────────────────────────────────────────────────
// MPEG-TS mux mínimo: HEVC + AAC-LC
// ─────────────────────────────────────────────────────────────

static constexpr uint16_t kPmtPid = 0x1000;
static constexpr uint16_t kVideoPid = 0x0100;
static constexpr uint16_t kAudioPid = 0x0101;
static constexpr size_t kTsPacketSize = 188;
static constexpr size_t kSrtPayloadSize = 1316; // 7 pacotes TS

uint32_t mpegCrc32(const uint8_t* data, size_t size) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < size; ++i) {
        crc ^= static_cast<uint32_t>(data[i]) << 24;
        for (int bit = 0; bit < 8; ++bit) {
            crc = (crc & 0x80000000u) ? (crc << 1) ^ 0x04C11DB7u : crc << 1;
        }
    }
    return crc;
}

void appendSectionPacket(
    SrtPublisher* pub,
    uint16_t pid,
    const std::vector<uint8_t>& section
) {
    std::array<uint8_t, kTsPacketSize> packet{};
    packet.fill(0xFF);
    uint8_t& cc = pub->continuity[pid];
    packet[0] = 0x47;
    packet[1] = static_cast<uint8_t>(0x40 | ((pid >> 8) & 0x1F));
    packet[2] = static_cast<uint8_t>(pid & 0xFF);
    packet[3] = static_cast<uint8_t>(0x10 | (cc++ & 0x0F));
    packet[4] = 0x00; // pointer_field
    std::copy(section.begin(), section.end(), packet.begin() + 5);
    pub->tsPayload.insert(pub->tsPayload.end(), packet.begin(), packet.end());
}

std::vector<uint8_t> withCrc(std::vector<uint8_t> section) {
    const uint32_t crc = mpegCrc32(section.data(), section.size());
    section.push_back(static_cast<uint8_t>(crc >> 24));
    section.push_back(static_cast<uint8_t>(crc >> 16));
    section.push_back(static_cast<uint8_t>(crc >> 8));
    section.push_back(static_cast<uint8_t>(crc));
    return section;
}

void appendProgramTables(SrtPublisher* pub) {
    const auto pat = withCrc({
        0x00, 0xB0, 0x0D, // PAT, section_length=13
        0x00, 0x01,       // transport_stream_id
        0xC1, 0x00, 0x00, // version/current, section numbers
        0x00, 0x01,       // program_number
        static_cast<uint8_t>(0xE0 | (kPmtPid >> 8)),
        static_cast<uint8_t>(kPmtPid),
    });
    appendSectionPacket(pub, 0x0000, pat);

    const auto pmt = withCrc({
        0x02, 0xB0, 0x17, // PMT, section_length=23
        0x00, 0x01,       // program_number
        0xC1, 0x00, 0x00,
        static_cast<uint8_t>(0xE0 | (kVideoPid >> 8)),
        static_cast<uint8_t>(kVideoPid), // PCR_PID
        0xF0, 0x00,                  // program_info_length
        0x24,                        // HEVC stream_type
        static_cast<uint8_t>(0xE0 | (kVideoPid >> 8)),
        static_cast<uint8_t>(kVideoPid),
        0xF0, 0x00,
        0x0F,                        // AAC ADTS stream_type
        static_cast<uint8_t>(0xE0 | (kAudioPid >> 8)),
        static_cast<uint8_t>(kAudioPid),
        0xF0, 0x00,
    });
    appendSectionPacket(pub, kPmtPid, pmt);
}

void appendPts(std::vector<uint8_t>& pes, int64_t pts90k) {
    const uint64_t pts = static_cast<uint64_t>(pts90k) & 0x1FFFFFFFFULL;
    pes.push_back(static_cast<uint8_t>(0x21 | ((pts >> 29) & 0x0E)));
    pes.push_back(static_cast<uint8_t>(pts >> 22));
    pes.push_back(static_cast<uint8_t>(0x01 | ((pts >> 14) & 0xFE)));
    pes.push_back(static_cast<uint8_t>(pts >> 7));
    pes.push_back(static_cast<uint8_t>(0x01 | ((pts << 1) & 0xFE)));
}

void appendPesPackets(
    SrtPublisher* pub,
    uint16_t pid,
    uint8_t streamId,
    const uint8_t* payload,
    size_t payloadSize,
    int64_t pts90k,
    bool includePcr
) {
    std::vector<uint8_t> pes;
    pes.reserve(payloadSize + 14);
    pes.insert(pes.end(), {0x00, 0x00, 0x01, streamId});
    const size_t length = payloadSize + 8;
    const uint16_t pesLength = streamId == 0xE0 || length > 0xFFFF
        ? 0
        : static_cast<uint16_t>(length);
    pes.push_back(static_cast<uint8_t>(pesLength >> 8));
    pes.push_back(static_cast<uint8_t>(pesLength));
    pes.insert(pes.end(), {0x80, 0x80, 0x05});
    appendPts(pes, pts90k);
    pes.insert(pes.end(), payload, payload + payloadSize);

    size_t offset = 0;
    bool first = true;
    while (offset < pes.size()) {
        std::array<uint8_t, kTsPacketSize> packet{};
        packet.fill(0xFF);
        uint8_t& cc = pub->continuity[pid];
        packet[0] = 0x47;
        packet[1] = static_cast<uint8_t>(
            (first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F)
        );
        packet[2] = static_cast<uint8_t>(pid);

        const bool writePcr = first && includePcr;
        const size_t maxPayload = writePcr ? 176 : 184;
        const size_t bytes = std::min(maxPayload, pes.size() - offset);
        const bool adaptation = writePcr || bytes < 184;
        size_t cursor = 4;

        packet[3] = static_cast<uint8_t>(
            (adaptation ? 0x30 : 0x10) | (cc++ & 0x0F)
        );
        if (adaptation) {
            const size_t adaptationLength = 183 - bytes;
            packet[cursor++] = static_cast<uint8_t>(adaptationLength);
            if (adaptationLength > 0) {
                packet[cursor++] = writePcr ? 0x10 : 0x00;
                size_t used = 1;
                if (writePcr) {
                    const uint64_t pcr = static_cast<uint64_t>(pts90k) & 0x1FFFFFFFFULL;
                    packet[cursor++] = static_cast<uint8_t>(pcr >> 25);
                    packet[cursor++] = static_cast<uint8_t>(pcr >> 17);
                    packet[cursor++] = static_cast<uint8_t>(pcr >> 9);
                    packet[cursor++] = static_cast<uint8_t>(pcr >> 1);
                    packet[cursor++] = static_cast<uint8_t>((pcr & 1) << 7 | 0x7E);
                    packet[cursor++] = 0x00;
                    used += 6;
                }
                while (used++ < adaptationLength) packet[cursor++] = 0xFF;
            }
        }
        std::copy(
            pes.begin() + static_cast<std::ptrdiff_t>(offset),
            pes.begin() + static_cast<std::ptrdiff_t>(offset + bytes),
            packet.begin() + static_cast<std::ptrdiff_t>(cursor)
        );
        pub->tsPayload.insert(pub->tsPayload.end(), packet.begin(), packet.end());
        offset += bytes;
        first = false;
    }
}

void flushTransportStream(SrtPublisher* pub, SRTSOCKET socket) {
    while (pub->tsPayload.size() >= kSrtPayloadSize) {
        SRT_MSGCTRL control = srt_msgctrl_default;
        const int result = srt_sendmsg2(
            socket,
            reinterpret_cast<const char*>(pub->tsPayload.data()),
            static_cast<int>(kSrtPayloadSize),
            &control
        );
        if (result == SRT_ERROR) {
            const int error = srt_getlasterror(nullptr);
            if (error != SRT_ENOCONN && error != SRT_EASYNCRCV) {
                LOGE("MPEG-TS send failed: %s", srt_getlasterror_str());
            }
            return;
        }
        pub->tsPayload.erase(
            pub->tsPayload.begin(),
            pub->tsPayload.begin() + static_cast<std::ptrdiff_t>(kSrtPayloadSize)
        );
    }
}

void muxAndSend(
    SrtPublisher* pub,
    const uint8_t* payload,
    size_t payloadSize,
    int64_t ptsUs,
    bool video
) {
    const SRTSOCKET socket = pub->activeSock.load(std::memory_order_relaxed);
    if (socket == kInvalidSock || !payload || payloadSize == 0) return;

    const int64_t pts90k = std::max<int64_t>(0, ptsUs * 9 / 100);
    std::lock_guard<std::mutex> lock(pub->muxMtx);
    if (pub->lastTablesPts < 0 || pts90k - pub->lastTablesPts >= 45'000) {
        appendProgramTables(pub);
        pub->lastTablesPts = pts90k;
    }
    appendPesPackets(
        pub,
        video ? kVideoPid : kAudioPid,
        video ? 0xE0 : 0xC0,
        payload,
        payloadSize,
        pts90k,
        video
    );
    flushTransportStream(pub, socket);
}

/**
 * Notifica o layer Java via callback on_event (rodando em monitorThread).
 * Usa AttachCurrentThread para obter JNIEnv seguro na thread nativa.
 */
void jniFireEvent(SrtPublisher* pub, const char* eventType, const char* data) {
    if (!pub->jvm || !pub->pluginObjRef || !pub->onEventMethod) return;

    JNIEnv* env;
    bool attached = false;
    int status = pub->jvm->GetEnv((void**)&env, JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        pub->jvm->AttachCurrentThread(&env, nullptr);
        attached = true;
    }

    jstring jType = env->NewStringUTF(eventType);
    jstring jData = env->NewStringUTF(data ? data : "");
    env->CallVoidMethod(pub->pluginObjRef, pub->onEventMethod, jType, jData);
    env->DeleteLocalRef(jType);
    env->DeleteLocalRef(jData);

    if (env->ExceptionCheck()) env->ExceptionClear();
    if (attached) pub->jvm->DetachCurrentThread();
}

/**
 * Coleta srt_bistats e notifica o Java layer com as métricas.
 */
void reportStats(SrtPublisher* pub, SRTSOCKET s) {
    if (s == kInvalidSock) return;

    SRT_TRACEBSTATS st{};
    if (srt_bistats(s, &st, 1 /*clear*/, 0 /*instantaneous*/) == SRT_ERROR) return;

    // Formata como JSON simples para o callback Java
    char buf[256];
    snprintf(buf, sizeof(buf),
        "{\"sendBitrateKbps\":%d,\"rttMs\":%d,\"packetLossPercent\":%.3f,"
        "\"retransmittedPackets\":%d,\"droppedPackets\":%d,"
        "\"sendBufferFillPercent\":%d,\"activeNode\":\"%s\"}",
        (int)(st.mbpsSendRate * 1000.0),  // Mbps → kbps
        (int)st.msRTT,
        st.pktSndLossTotal > 0
            ? 100.0 * st.pktSndLossTotal / (st.pktSentTotal + st.pktSndLossTotal + 1)
            : 0.0,
        (int)st.pktRetransTotal,
        (int)st.pktSndDropTotal,
        (int)(st.byteAvailSndBuf * 100 / (st.byteSndBuf + 1)),
        pub->currentNode.c_str()
    );

    jniFireEvent(pub, "stats", buf);
}

/**
 * Thread de monitoramento: coleta stats periódicas e monitora estado do socket.
 * Se o socket desconectar inesperadamente, emite evento 'error'.
 */
void monitorLoop(SrtPublisher* pub) {
    LOGI("Monitor thread started");

    while (pub->running.load()) {
        SRTSOCKET s = pub->activeSock.load();

        if (s == kInvalidSock) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }

        // Verifica estado do socket
        SRT_SOCKSTATUS status = srt_getsockstate(s);
        if (status == SRTS_BROKEN || status == SRTS_NONEXIST || status == SRTS_CLOSED) {
            LOGE("SRT socket broken (state=%d) — emitting error event", (int)status);
            jniFireEvent(pub, "error", "{\"code\":\"SRT_BROKEN\",\"message\":\"Socket disconnected\"}");
            pub->activeSock.store(kInvalidSock);
            jniFireEvent(pub, "state_changed", "disconnected");
            continue;
        }

        if (status == SRTS_CONNECTED) {
            reportStats(pub, s);
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(kStatsIntervalMs));
    }

    LOGI("Monitor thread exited");
}

/**
 * Executa o hot-swap atômico de socket SRT em thread dedicada.
 * Retorna via JNI callback 'switch_complete' ou 'error'.
 */
void switchDestinationThread(
    SrtPublisher* pub,
    std::string newHost, int newPort,
    std::string newStreamKey, std::string passphrase, int latencyMs,
    std::string newNode)
{
    LOGI("SwitchDestination: connecting → %s:%d", newHost.c_str(), newPort);

    SRTSOCKET pendingSock = createSocket(
        newHost.c_str(), newPort, newStreamKey.c_str(), passphrase.c_str(), latencyMs
    );

    if (pendingSock == kInvalidSock) {
        LOGE("SwitchDestination FAILED: cannot connect to %s:%d", newHost.c_str(), newPort);
        jniFireEvent(pub, "error",
            "{\"code\":\"SWITCH_FAILED\",\"message\":\"Cannot connect to new destination\"}");
        return;
    }

    // Aguarda confirmação de SRTS_CONNECTED com timeout
    auto deadline = std::chrono::steady_clock::now()
                  + std::chrono::milliseconds(kSwitchTimeoutMs);
    bool connected = false;
    while (std::chrono::steady_clock::now() < deadline) {
        if (srt_getsockstate(pendingSock) == SRTS_CONNECTED) {
            connected = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    if (!connected) {
        LOGE("SwitchDestination: new socket did not reach CONNECTED within %dms", kSwitchTimeoutMs);
        srt_close(pendingSock);
        jniFireEvent(pub, "error",
            "{\"code\":\"SWITCH_TIMEOUT\",\"message\":\"New socket handshake timeout\"}");
        return;
    }

    // Troca atômica: todos os novos pacotes vão para pendingSock
    SRTSOCKET oldSock = pub->activeSock.exchange(pendingSock);
    {
        std::lock_guard<std::mutex> lock(pub->muxMtx);
        pub->continuity.fill(0);
        pub->tsPayload.clear();
        pub->lastTablesPts = -1;
    }

    // Atualiza destino atual
    pub->currentHost      = newHost;
    pub->currentPort      = newPort;
    pub->currentStreamKey = newStreamKey;
    pub->currentLatencyMs = latencyMs;
    pub->currentNode      = newNode;

    LOGI("SRT switch complete: %s:%d → %s:%d [node=%s]",
         pub->currentHost.c_str(), pub->currentPort,
         newHost.c_str(), newPort, newNode.c_str());

    // Drena e fecha o socket antigo após kDrainDelayMs
    if (oldSock != kInvalidSock) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kDrainDelayMs));
        srt_close(oldSock);
        LOGI("Old SRT socket closed");
    }

    char event[256];
    snprintf(event, sizeof(event),
        "{\"node\":\"%s\",\"url\":\"srt://%s:%d?streamid=%s\"}",
        newNode.c_str(), newHost.c_str(), newPort, newStreamKey.c_str());
    jniFireEvent(pub, "switch_complete", event);
}

} // namespace

// ─────────────────────────────────────────────────────────────
// JNI OnLoad / OnUnload
// ─────────────────────────────────────────────────────────────

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
    LOGI("SRT JNI library loaded (Phase 4 — real libsrt)");
    srt_startup();
    // Salva JVM para uso nas threads de background
    SrtPublisher* pub = getOrCreatePublisher();
    pub->jvm = vm;
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* /*vm*/, void* /*reserved*/) {
    LOGI("SRT JNI library unloading");
    std::lock_guard<std::mutex> lk(gPublisherMtx);
    if (gPublisher) {
        delete gPublisher;
        gPublisher = nullptr;
    }
    srt_cleanup();
}

// ─────────────────────────────────────────────────────────────
// nativeInit — registra callbacks Java na SrtPublisher
// ─────────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_sp_1smart_srt_SrtPublisher_nativeInit(
    JNIEnv* env, jobject thiz)
{
    SrtPublisher* pub = getOrCreatePublisher();
    pub->pluginObjRef = env->NewGlobalRef(thiz);

    jclass cls = env->GetObjectClass(thiz);
    pub->onEventMethod = env->GetMethodID(cls, "onNativeEvent",
        "(Ljava/lang/String;Ljava/lang/String;)V");

    if (!pub->onEventMethod) {
        LOGE("nativeInit: cannot find onNativeEvent method — events will be lost");
    } else {
        LOGI("nativeInit: JNI callbacks registered");
    }
}

// ─────────────────────────────────────────────────────────────
// nativeConnect
// ─────────────────────────────────────────────────────────────

JNIEXPORT jboolean JNICALL
Java_com_sp_1smart_srt_SrtPublisher_nativeConnect(
    JNIEnv* env, jobject /*thiz*/,
    jstring host, jint port, jstring streamKey, jstring passphrase,
    jint latencyMs, jstring node)
{
    const char* h = env->GetStringUTFChars(host, nullptr);
    const char* k = env->GetStringUTFChars(streamKey, nullptr);
    const char* p = env->GetStringUTFChars(passphrase, nullptr);
    const char* n = env->GetStringUTFChars(node, nullptr);

    SrtPublisher* pub = getOrCreatePublisher();

    // Encerra socket anterior se existir
    SRTSOCKET old = pub->activeSock.exchange(kInvalidSock);
    if (old != kInvalidSock) srt_close(old);

    SRTSOCKET s = createSocket(h, port, k, p, latencyMs);

    pub->currentHost      = h;
    pub->currentPort      = (int)port;
    pub->currentStreamKey = k;
    pub->currentLatencyMs = (int)latencyMs;
    pub->currentNode      = n;

    env->ReleaseStringUTFChars(host, h);
    env->ReleaseStringUTFChars(streamKey, k);
    env->ReleaseStringUTFChars(passphrase, p);
    env->ReleaseStringUTFChars(node, n);

    if (s == kInvalidSock) {
        jniFireEvent(pub, "state_changed", "error");
        return JNI_FALSE;
    }

    pub->activeSock.store(s);
    {
        std::lock_guard<std::mutex> lock(pub->muxMtx);
        pub->continuity.fill(0);
        pub->tsPayload.clear();
        pub->lastTablesPts = -1;
    }
    jniFireEvent(pub, "state_changed", "streaming");

    // Inicia thread de monitoramento se não estiver rodando
    if (!pub->running.load()) {
        if (pub->monitorThread.joinable()) pub->monitorThread.join();
        pub->running.store(true);
        pub->monitorThread = std::thread(monitorLoop, pub);
    }

    return JNI_TRUE;
}

// ─────────────────────────────────────────────────────────────
// nativeSendPacket — hot path: chamado para cada NAL unit H.265
// ─────────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_sp_1smart_srt_SrtPublisher_nativeSendPacket(
    JNIEnv* env, jobject /*thiz*/,
    jbyteArray data, jint size, jlong pts)
{
    SrtPublisher* pub = getOrCreatePublisher();
    if (pub->activeSock.load(std::memory_order_relaxed) == kInvalidSock) return;

    jbyte* buf = env->GetByteArrayElements(data, nullptr);
    if (!buf) return;
    muxAndSend(
        pub,
        reinterpret_cast<const uint8_t*>(buf),
        static_cast<size_t>(size),
        static_cast<int64_t>(pts),
        true
    );
    env->ReleaseByteArrayElements(data, buf, JNI_ABORT);
}

JNIEXPORT void JNICALL
Java_com_sp_1smart_srt_SrtPublisher_nativeSendAudioPacket(
    JNIEnv* env, jobject /*thiz*/,
    jbyteArray data, jint size, jlong pts)
{
    SrtPublisher* pub = getOrCreatePublisher();
    if (pub->activeSock.load(std::memory_order_relaxed) == kInvalidSock) return;

    jbyte* buf = env->GetByteArrayElements(data, nullptr);
    if (!buf) return;
    muxAndSend(
        pub,
        reinterpret_cast<const uint8_t*>(buf),
        static_cast<size_t>(size),
        static_cast<int64_t>(pts),
        false
    );
    env->ReleaseByteArrayElements(data, buf, JNI_ABORT);
}

// ─────────────────────────────────────────────────────────────
// nativeSwitchDestination — dual-socket atomic hot-swap
// ─────────────────────────────────────────────────────────────

JNIEXPORT jboolean JNICALL
Java_com_sp_1smart_srt_SrtPublisher_nativeSwitchDestination(
    JNIEnv* env, jobject /*thiz*/,
    jstring newHost, jint newPort, jstring newStreamKey, jstring passphrase,
    jint latencyMs, jstring newNode)
{
    const char* h = env->GetStringUTFChars(newHost, nullptr);
    const char* k = env->GetStringUTFChars(newStreamKey, nullptr);
    const char* p = env->GetStringUTFChars(passphrase, nullptr);
    const char* n = env->GetStringUTFChars(newNode, nullptr);

    std::string sHost(h), sKey(k), sPassphrase(p), sNode(n);
    int sPort    = (int)newPort;
    int sLatency = (int)latencyMs;

    env->ReleaseStringUTFChars(newHost, h);
    env->ReleaseStringUTFChars(newStreamKey, k);
    env->ReleaseStringUTFChars(passphrase, p);
    env->ReleaseStringUTFChars(newNode, n);

    SrtPublisher* pub = getOrCreatePublisher();

    // Executa o switch em thread separada (não bloqueia o encoder)
    std::thread(switchDestinationThread, pub,
        sHost, sPort, sKey, sPassphrase, sLatency, sNode).detach();

    return JNI_TRUE;
}

// ─────────────────────────────────────────────────────────────
// nativeDisconnect
// ─────────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_sp_1smart_srt_SrtPublisher_nativeDisconnect(
    JNIEnv* /*env*/, jobject /*thiz*/)
{
    SrtPublisher* pub = getOrCreatePublisher();
    pub->running.store(false);

    SRTSOCKET s = pub->activeSock.exchange(kInvalidSock);
    if (s != kInvalidSock) {
        srt_close(s);
        LOGI("SRT socket closed via nativeDisconnect");
    }
    {
        std::lock_guard<std::mutex> lock(pub->muxMtx);
        pub->tsPayload.clear();
        pub->lastTablesPts = -1;
    }

    jniFireEvent(pub, "state_changed", "disconnected");
}

// ─────────────────────────────────────────────────────────────
// nativeSetTargetBitrate — ajusta bandwidth ceiling do SRT
// ─────────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_sp_1smart_srt_SrtPublisher_nativeSetTargetBitrate(
    JNIEnv* /*env*/, jobject /*thiz*/, jint bitrateKbps)
{
    SrtPublisher* pub = getOrCreatePublisher();
    SRTSOCKET s = pub->activeSock.load();
    if (s == kInvalidSock) return;

    // SRTO_INPUTBW: largura de banda esperada do uplink
    int64_t inputBw = (int64_t)bitrateKbps * 1000LL; // kbps → bps
    srt_setsockopt(s, 0, SRTO_INPUTBW, &inputBw, sizeof(inputBw));

    LOGI("nativeSetTargetBitrate: %d kbps → SRTO_INPUTBW=%lld bps", bitrateKbps, (long long)inputBw);
}

} // extern "C"
