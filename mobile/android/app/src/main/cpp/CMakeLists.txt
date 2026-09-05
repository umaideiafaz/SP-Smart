cmake_minimum_required(VERSION 3.22.1)
project(srt_jni C CXX)

# ── C++ Standard ──────────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ─────────────────────────────────────────────────────────────
# OpenSSL (via prefab — empacotado pela Google como AAR)
# ─────────────────────────────────────────────────────────────
# Dependência no build.gradle:
#   implementation "com.android.ndk.thirdparty:openssl:1.1.1q-beta-1"
# ─────────────────────────────────────────────────────────────
find_package(openssl REQUIRED CONFIG)

# ─────────────────────────────────────────────────────────────
# libsrt (compilada a partir do submodule third_party/srt/)
#
# Setup inicial:
#   cd mobile/android/app/src/main/cpp
#   git submodule add https://github.com/Haivision/srt.git third_party/srt
#   git submodule update --init --recursive
# ─────────────────────────────────────────────────────────────

set(SRT_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/srt)

# Flags de compilação do libsrt para Android broadcast
set(ENABLE_APPS         OFF CACHE BOOL "" FORCE)  # Sem executáveis
set(ENABLE_SHARED       OFF CACHE BOOL "" FORCE)  # Apenas .a estática
set(ENABLE_STATIC       ON  CACHE BOOL "" FORCE)
set(ENABLE_ENCRYPTION   ON  CACHE BOOL "" FORCE)  # DTLS/SRTP
set(ENABLE_BONDING      OFF CACHE BOOL "" FORCE)  # Usamos nossa própria lógica

# Usa OpenSSL do NDK prefab em vez de compilar mbedTLS
set(USE_ENCLIB openssl CACHE STRING "" FORCE)

# Desativa features não necessárias para reduzir tamanho do .so
set(ENABLE_CXX11        ON  CACHE BOOL "" FORCE)
set(ENABLE_LOGGING      ON  CACHE BOOL "" FORCE)  # Essencial para debug em produção
set(ENABLE_HEAVY_LOGGING OFF CACHE BOOL "" FORCE) # Verbose demais para release

# Android não tem INET6 por padrão neste caminho simplificado
set(ENABLE_INET_PTON    ON  CACHE BOOL "" FORCE)

if(EXISTS "${SRT_SOURCE_DIR}/CMakeLists.txt")
    add_subdirectory(${SRT_SOURCE_DIR} ${CMAKE_BINARY_DIR}/srt_build)
    set(SRT_FOUND TRUE)
    message(STATUS "SP Smart: libsrt submodule found and configured")
else()
    message(WARNING
        "SP Smart: third_party/srt/ not found!\n"
        "Run: git submodule add https://github.com/Haivision/srt.git "
        "mobile/android/app/src/main/cpp/third_party/srt\n"
        "     git submodule update --init --recursive\n"
        "Falling back to stub-only build."
    )
    set(SRT_FOUND FALSE)
endif()

# ─────────────────────────────────────────────────────────────
# JNI bridge library: srt_jni.so
# ─────────────────────────────────────────────────────────────

add_library(
    srt_jni
    SHARED
    srt_publisher.cpp  # Fase 4: real libsrt publisher (dual-socket)
)

target_include_directories(srt_jni PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# ── Android NDK libraries ─────────────────────────────────────
find_library(log-lib     log)
find_library(android-lib android)
find_library(mediandk    mediandk) # Para MediaCodec via NdkMediaCodec.h (futuro)

if(SRT_FOUND)
    target_include_directories(srt_jni PRIVATE
        ${SRT_SOURCE_DIR}/srtcore
        ${SRT_SOURCE_DIR}
    )
    target_link_libraries(
        srt_jni
        srt_static             # libsrt.a (estática — evita .so extra no APK)
        openssl::crypto
        openssl::ssl
        ${log-lib}
        ${android-lib}
    )
else()
    # Fallback: compila sem libsrt (apenas stubs funcionarão)
    target_link_libraries(srt_jni ${log-lib} ${android-lib})
endif()

# ── Compiler flags (broadcast-grade) ─────────────────────────
target_compile_options(srt_jni PRIVATE
    -O2
    -Wall
    -Wextra
    -fvisibility=hidden   # Oculta símbolos não-JNI (reduz tamanho + evita colisões)
    -fstack-protector-strong
)

# ── Definições ────────────────────────────────────────────────
target_compile_definitions(srt_jni PRIVATE
    # Indica que estamos em um build real (não stub)
    SP_SMART_PHASE4=1
)
