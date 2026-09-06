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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sp_smart/core/config/app_config.dart';
import 'package:sp_smart/core/network/protocol.dart';
import 'package:sp_smart/core/router/app_router.dart';
import 'package:sp_smart/core/srt/srt_engine.dart';
import 'package:sp_smart/core/network/signaling_service.dart';
import '../services/ifb_service.dart';
import 'camera_preview_widget.dart';
import 'broadcast_providers.dart';

class BroadcastScreen extends ConsumerStatefulWidget {
  const BroadcastScreen({super.key});

  @override
  ConsumerState<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends ConsumerState<BroadcastScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(_connectSavedConfiguration);
  }

  Future<void> _connectSavedConfiguration() async {
    final config = await ref.read(appConfigNotifierProvider.future);
    if (config.authSecret.length < 10 || config.primary.host.isEmpty) return;

    final signaling = ref.read(signalingServiceProvider);
    if (signaling.state != SignalingState.disconnected &&
        signaling.state != SignalingState.error) {
      return;
    }

    try {
      await signaling.connect(
        endpoints: config.endpoints,
        reporterId: config.reporterId,
        displayName: config.displayName,
        authSecret: config.authSecret,
        srtStreamKey: config.srtStreamKey,
      );
    } catch (error) {
      debugPrint('[BroadcastScreen] Signaling startup failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
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
            height: 96,
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

          // ── 4. Interface operacional em paisagem ────────────
          SafeArea(
            child: Stack(
              children: [
                Positioned(
                  top: 8,
                  left: 84,
                  right: 100,
                  child: Row(
                    children: [
                      _SRTStatusHUD(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          config?.displayName.isNotEmpty == true
                              ? config!.displayName
                              : 'SP SMART',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const _VideoFormatHUD(),
                      const SizedBox(width: 16),
                      _SystemHUD(),
                    ],
                  ),
                ),
                Positioned(
                  top: 76,
                  bottom: 12,
                  left: 8,
                  width: 68,
                  child: _LeftAudioRail(
                    reporterId: config?.reporterId ?? '',
                  ),
                ),
                const Positioned(
                  top: 0,
                  bottom: 0,
                  right: 0,
                  width: 88,
                  child: _ControlRail(),
                ),
              ],
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

class _VideoFormatHUD extends StatelessWidget {
  const _VideoFormatHUD();

  @override
  Widget build(BuildContext context) => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_outlined, color: Colors.white70, size: 22),
          SizedBox(width: 6),
          Text(
            'HEVC\n1080p30',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              height: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
}

class _LeftAudioRail extends ConsumerStatefulWidget {
  const _LeftAudioRail({required this.reporterId});
  final String reporterId;

  @override
  ConsumerState<_LeftAudioRail> createState() => _LeftAudioRailState();
}

class _LeftAudioRailState extends ConsumerState<_LeftAudioRail> {
  bool _muted = false;
  double _gain = 1;
  String _source = 'default';

  Future<void> _toggleMute() async {
    final next = !_muted;
    await ref.read(srtEngineProvider).setAudioMuted(next);
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _openMicrophonePanel() async {
    final engine = ref.read(srtEngineProvider);
    final sources = await engine.getMicrophoneSources();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xEE171717),
          title: const Text(
            'Entrada de áudio',
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final input in sources)
                  ListTile(
                    leading: Icon(
                      _source == input['id']
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: _source == input['id']
                          ? const Color(0xFF9ADB00)
                          : Colors.white38,
                    ),
                    title: Text(
                      _sourceLabel(input['id'] as String),
                      style: TextStyle(
                        color: input['available'] == true
                            ? Colors.white
                            : Colors.white38,
                      ),
                    ),
                    onTap: input['available'] == true
                        ? () async {
                            final value = input['id'] as String;
                            if (value == 'bluetooth') {
                              final permission =
                                  await Permission.bluetoothConnect.request();
                              if (!permission.isGranted) return;
                            }
                            try {
                              await engine.selectMicrophoneSource(value);
                              if (!mounted) return;
                              setState(() => _source = value);
                              setDialogState(() {});
                            } on PlatformException catch (error) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    error.message ??
                                        'Fonte de microfone indisponível',
                                  ),
                                ),
                              );
                            }
                          }
                        : null,
                  ),
                const Divider(color: Colors.white24),
                Row(
                  children: [
                    const Icon(Icons.mic, color: Colors.white70),
                    Expanded(
                      child: Slider(
                        value: _gain,
                        min: 0,
                        max: 2,
                        divisions: 40,
                        activeColor: const Color(0xFF9ADB00),
                        label: '${(_gain * 100).round()}%',
                        onChanged: (value) {
                          setState(() => _gain = value);
                          setDialogState(() {});
                          unawaited(engine.setMicrophoneGain(value));
                        },
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        '${(_gain * 100).round()}%',
                        textAlign: TextAlign.end,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('FECHAR'),
            ),
          ],
        ),
      ),
    );
  }

  static String _sourceLabel(String id) => switch (id) {
        'external' => 'Microfone externo / USB',
        'bluetooth' => 'Bluetooth',
        _ => 'Microfone padrão',
      };

  @override
  Widget build(BuildContext context) => Container(
        color: Colors.black.withAlpha(150),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 5),
        child: Column(
          children: [
            _IFBToggleButton(reporterId: widget.reporterId),
            IconButton(
              tooltip: _muted ? 'Ativar microfone' : 'Silenciar microfone',
              onPressed: _toggleMute,
              icon: Icon(
                _muted ? Icons.mic_off : Icons.mic,
                color: _muted ? Colors.redAccent : Colors.white,
              ),
            ),
            Expanded(
              child: StreamBuilder<AudioLevels>(
                stream: ref.read(srtEngineProvider).audioLevelsStream,
                initialData: AudioLevels(
                  left: 0,
                  right: 0,
                  muted: _muted,
                  gain: _gain,
                  source: _source,
                ),
                builder: (context, snapshot) {
                  final levels = snapshot.data!;
                  return _StereoMeter(
                    left: levels.left,
                    right: levels.right,
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: _openMicrophonePanel,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Column(
                  children: [
                    const Icon(
                      Icons.tune,
                      color: Color(0xFF9ADB00),
                      size: 20,
                    ),
                    Text(
                      _source == 'default'
                          ? 'MIC'
                          : _source.substring(0, 3).toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

class _StereoMeter extends StatelessWidget {
  const _StereoMeter({required this.left, required this.right});
  final double left;
  final double right;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _MeterChannel(label: 'L', level: left),
          const SizedBox(width: 5),
          _MeterChannel(label: 'R', level: right),
        ],
      );
}

class _MeterChannel extends StatelessWidget {
  const _MeterChannel({required this.label, required this.level});
  final String label;
  final double level;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Expanded(
            child: Container(
              width: 13,
              decoration: BoxDecoration(
                color: Colors.black54,
                border: Border.all(color: Colors.white24),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => Align(
                  alignment: Alignment.bottomCenter,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 45),
                    curve: Curves.linear,
                    width: double.infinity,
                    height: constraints.maxHeight * level.clamp(0, 1),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Color(0xFF55C500),
                          Color(0xFF9ADB00),
                          Color(0xFFFFC400),
                          Color(0xFFFF3D00),
                        ],
                        stops: [0, .65, .85, 1],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ],
      );
}

class _ControlRail extends StatelessWidget {
  const _ControlRail();

  static const _cameraChannel = MethodChannel('sp.smart/srt');

  @override
  Widget build(BuildContext context) => Container(
        color: Colors.black.withAlpha(190),
        child: Column(
          children: [
            const SizedBox(height: 12),
            IconButton(
              tooltip: 'Virar câmera',
              iconSize: 38,
              color: Colors.white,
              onPressed: () async {
                try {
                  final info = await _cameraChannel
                      .invokeMapMethod<dynamic, dynamic>('switchCamera');
                  if (info == null) {
                    throw PlatformException(
                      code: 'CAMERA_SWITCH_EMPTY',
                      message: 'Camera switch returned no state',
                    );
                  }
                  updateCameraPreviewTransform(info);
                } on PlatformException {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      behavior: SnackBarBehavior.floating,
                      content: Text('Não foi possível virar a câmera'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.cameraswitch_outlined),
            ),
            const Spacer(),
            const _GoLiveButton(),
            const Spacer(),
            IconButton(
              tooltip: 'Configurações',
              iconSize: 36,
              color: Colors.white,
              onPressed: () => context.push(Routes.setup),
              icon: const Icon(Icons.settings),
            ),
            const SizedBox(height: 10),
          ],
        ),
      );
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
