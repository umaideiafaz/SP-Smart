// ============================================================
// SP Smart Mobile — Broadcast Screen (Fase 5: UI/UX Final)
// ============================================================
// Design "Run and Gun":
// - Câmera em tela cheia (imersão total).
// - HUD Translúcido (Telemetria, SRT stats, Bateria).
// - Borda de tela vermelha acionada pelo Tally (PGM).
// - Botão central de gravação "GO LIVE" para SRT.
// - IFB WebRTC discreto.
// ============================================================
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sp_smart/core/config/app_config.dart';
import 'package:sp_smart/core/network/protocol.dart';
import 'package:sp_smart/core/srt/srt_engine.dart';
import 'package:sp_smart/core/network/signaling_service.dart';
import '../services/ifb_service.dart';
import 'camera_preview_widget.dart';
import 'broadcast_providers.dart';

class BroadcastScreen extends ConsumerWidget {
  const BroadcastScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tallyState = ref.watch(tallyStateProvider).value ?? TallyState.idle;
    final isPgm = tallyState == TallyState.pgm;
    final config = ref.watch(appConfigNotifierProvider).valueOrNull;

    ref.listen<AsyncValue<FailoverEvent>>(failoverEventProvider, (_, next) {
      next.whenData((_) {
        final engine = ref.read(srtEngineProvider);
        final signaling = ref.read(signalingServiceProvider);
        final endpoint = signaling.activeEndpoint;
        if (config == null ||
            endpoint == null ||
            engine.currentDestination == null) {
          return;
        }

        final destination = _destinationFromWelcome(
          signaling: signaling,
          config: config,
          endpoint: endpoint,
        );
        if (destination != null) {
          unawaited(engine.switchDestination(destination));
        }
      });
    });

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── 1. Câmera Full Screen (Fase 4 - Zero Copy) ──────
          const Positioned.fill(
            child: CameraPreviewWidget(),
          ),

          // ── 2. Borda Tally (PGM = Vermelho Vivo) ────────────
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isPgm ? const Color(0xFFE53935) : Colors.transparent,
                    width: isPgm ? 6.0 : 0.0,
                  ),
                ),
              ),
            ),
          ),

          // ── 3. Overlay Escurecido Superior (Legibilidade) ───
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 120,
            child: IgnorePointer(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
              ),
            ),
          ),

          // ── 4. HUD de Telemetria (Topo) ─────────────────────
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _SRTStatusHUD(),
                    _SystemHUD(),
                  ],
                ),
              ),
            ),
          ),

          // ── 5. Controles Inferiores (IFB + GO LIVE) ─────────
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding:
                    const EdgeInsets.only(bottom: 24.0, left: 24, right: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Botão IFB (Esquerda)
                    _IFBToggleButton(reporterId: config?.reporterId ?? ''),

                    // GO LIVE (Centro)
                    const _GoLiveButton(),

                    // Espaçador para simetria (Direita)
                    const SizedBox(width: 56),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// HUD de Status SRT (Latência, Bitrate, Conexão)
// ─────────────────────────────────────────────────────────────
class _SRTStatusHUD extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(srtEngineProvider);
    final isLive = engine.state == SrtConnectionState.streaming;
    final isSwitching = engine.state == SrtConnectionState.switching;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: Colors.black.withAlpha(120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Linha 1: Status SRT
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isLive
                          ? Colors.greenAccent
                          : (isSwitching
                              ? Colors.orangeAccent
                              : Colors.white30),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isLive
                        ? 'SRT LIVE'
                        : (isSwitching ? 'FAILOVER...' : 'SRT OFF'),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w800),
                  ),
                ],
              ),

              // Linha 2: Telemetria Real-Time
              if (isLive || isSwitching) ...[
                const SizedBox(height: 6),
                StreamBuilder<SrtStats>(
                    stream: engine.statsStream,
                    builder: (context, snapshot) {
                      final stats = snapshot.data;
                      final bitrate = stats?.sendBitrateKbps ?? 0;
                      final rtt = stats?.rttMs ?? 0;
                      final node = stats?.activeNode.name.toUpperCase() ?? '';

                      return Text(
                        '${(bitrate / 1000).toStringAsFixed(1)} Mbps • RTT ${rtt}ms\nNó: $node',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      );
                    }),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// HUD do Sistema (Tally Text e Bateria)
// ─────────────────────────────────────────────────────────────
class _SystemHUD extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tallyState = ref.watch(tallyStateProvider).value ?? TallyState.idle;
    final battery = ref.watch(batteryLevelProvider).value ?? 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Bateria
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$battery%',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 4),
            Icon(
              battery > 20 ? Icons.battery_full : Icons.battery_alert,
              color: battery > 20 ? Colors.white : Colors.redAccent,
              size: 16,
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Badge Tally
        if (tallyState != TallyState.idle)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: tallyState == TallyState.pgm
                  ? const Color(0xFFE53935)
                  : const Color(0xFF43A047),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              tallyState == TallyState.pgm ? 'PGM' : 'PVW',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w900),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Botões Inferiores
// ─────────────────────────────────────────────────────────────

class _GoLiveButton extends ConsumerWidget {
  const _GoLiveButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(srtEngineProvider);
    final isStreaming = engine.state == SrtConnectionState.streaming ||
        engine.state == SrtConnectionState.switching;
    final isConnecting = engine.state == SrtConnectionState.connecting;

    return GestureDetector(
      onTap: () async {
        if (isStreaming || isConnecting) {
          await engine.disconnect();
        } else {
          final config = ref.read(appConfigNotifierProvider).valueOrNull;
          final signaling = ref.read(signalingServiceProvider);
          final endpoint = signaling.activeEndpoint;
          if (config == null || endpoint == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Nenhuma rota de servidor ativa')),
            );
            return;
          }

          final dest = _destinationFromWelcome(
            signaling: signaling,
            config: config,
            endpoint: endpoint,
          );
          if (dest == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Destino SRT do servidor inválido')),
            );
            return;
          }
          await engine.connect(dest);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white30, width: 4),
          color: isStreaming
              ? Colors.redAccent
              : (isConnecting ? Colors.orange : Colors.transparent),
        ),
        child: Center(
          child: isConnecting
              ? const CircularProgressIndicator(color: Colors.white)
              : Container(
                  width: isStreaming ? 24 : 54,
                  height: isStreaming ? 24 : 54,
                  decoration: BoxDecoration(
                    color: isStreaming ? Colors.white : Colors.redAccent,
                    borderRadius: BorderRadius.circular(isStreaming ? 4 : 27),
                  ),
                ),
        ),
      ),
    );
  }
}

/// O WSS pode estar no Cloudflare, mas o SRT precisa usar o DNS UDP direto
/// anunciado pelo nó autenticado no SERVER_WELCOME.
SrtDestination? _destinationFromWelcome({
  required SignalingService signaling,
  required AppConfig config,
  required ServerEndpoint endpoint,
}) {
  final uri = Uri.tryParse(signaling.srtIngestUrl ?? '');
  if (uri == null || uri.scheme != 'srt' || uri.host.isEmpty) return null;
  return SrtDestination(
    host: uri.host,
    port: uri.port > 0 ? uri.port : endpoint.srtPort,
    streamKey: uri.queryParameters['streamid'] ?? config.srtStreamKey,
    passphrase: config.authSecret,
    node: endpoint.isPrimary ? SrtActiveNode.primary : SrtActiveNode.backup,
  );
}

class _IFBToggleButton extends ConsumerWidget {
  const _IFBToggleButton({required this.reporterId});
  final String reporterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ifbStatus = ref.watch(iFBServiceProvider);
    final ifbNotifier = ref.read(iFBServiceProvider.notifier);
    final signaling = ref.read(signalingServiceProvider);

    final isActive = ifbStatus.state == IFBState.connected;
    final isLoading = ifbStatus.state == IFBState.requesting ||
        ifbStatus.state == IFBState.connecting;

    return GestureDetector(
      onTap: () {
        if (isLoading) return;
        if (reporterId.isEmpty || signaling.state != SignalingState.connected) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sinalização ainda não autenticada')),
          );
          return;
        }
        if (isActive) {
          ifbNotifier.hangup(reporterId: reporterId, signaling: signaling);
        } else {
          // Aqui ativamos só o áudio (vídeo de retorno oculto para focar na câmera local)
          ifbNotifier.requestIFB(
              reporterId: reporterId,
              signaling: signaling,
              remoteRenderer: ref.read(remoteVideoRendererProvider));
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color:
                  isActive ? Colors.blueAccent.withAlpha(200) : Colors.black45,
              shape: BoxShape.circle,
              border: Border.all(
                  color: isActive ? Colors.blueAccent : Colors.white24),
            ),
            child: isLoading
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Icon(
                    isActive ? Icons.headset_mic : Icons.headset_off,
                    color: isActive ? Colors.white : Colors.white54,
                  ),
          ),
        ),
      ),
    );
  }
}
