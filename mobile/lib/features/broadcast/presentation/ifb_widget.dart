// ============================================================
// SP Smart Mobile — IFB Widget
// ============================================================
// Exibe o retorno de vídeo do estúdio e controles de IFB.
//
// Layout:
//   ┌─────────────────────────────────────────────────────┐
//   │  [Vídeo de Retorno — RTCVideoView]                  │
//   │  ← PGM limpo do switcher em 640×360                 │
//   ├─────────────────────────────────────────────────────┤
//   │  🔊 IFB Ativo   L: PGM+Dir.Jorn  R: PGM+Dir.TV     │
//   │  [Desligar IFB]                                     │
//   └─────────────────────────────────────────────────────┘
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../../core/network/signaling_service.dart';
import '../services/ifb_service.dart';

class IFBWidget extends ConsumerStatefulWidget {
  const IFBWidget({super.key, required this.reporterId});

  final String reporterId;

  @override
  ConsumerState<IFBWidget> createState() => _IFBWidgetState();
}

class _IFBWidgetState extends ConsumerState<IFBWidget> {
  late final RTCVideoRenderer _renderer;

  @override
  void initState() {
    super.initState();
    _renderer = ref.read(remoteVideoRendererProvider);
    _renderer.initialize();
  }

  @override
  void dispose() {
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ifbStatus = ref.watch(iFBServiceProvider);
    final ifbNotifier = ref.read(iFBServiceProvider.notifier);
    final signaling = ref.read(signalingServiceProvider);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        color: Colors.black,
        border: ifbStatus.state == IFBState.connected
            ? Border.all(color: const Color(0xFF00BCD4), width: 2)
            : Border.all(color: Colors.white12, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Vídeo de Retorno ────────────────────────────────
          _VideoReturnView(
            renderer: _renderer,
            ifbStatus: ifbStatus,
          ),

          // ── Barra de Status e Controles ─────────────────────
          _IFBControlBar(
            reporterId: widget.reporterId,
            ifbStatus: ifbStatus,
            onRequest: () => ifbNotifier.requestIFB(
              reporterId: widget.reporterId,
              signaling: signaling!,
              remoteRenderer: _renderer,
            ),
            onHangup: () => ifbNotifier.hangup(
              reporterId: widget.reporterId,
              signaling: signaling!,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Subwidgets
// ─────────────────────────────────────────────────────────────

class _VideoReturnView extends StatelessWidget {
  const _VideoReturnView({required this.renderer, required this.ifbStatus});

  final RTCVideoRenderer renderer;
  final IFBStatus ifbStatus;

  @override
  Widget build(BuildContext context) {
    const aspectRatio = 16.0 / 9.0;

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Vídeo WebRTC
            if (ifbStatus.state == IFBState.connected && ifbStatus.hasVideo)
              RTCVideoView(
                renderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                mirror: false, // Não espelhar vídeo de retorno
              )
            else
              _VideoPlaceholder(state: ifbStatus.state),

            // Overlay: badge de latência baixa
            if (ifbStatus.state == IFBState.connected)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '⚡ RETORNO AO VIVO',
                    style: TextStyle(
                      color: Color(0xFF00BCD4),
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({required this.state});
  final IFBState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0A0A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _iconForState(state),
              size: 32,
              color: _colorForState(state),
            ),
            const SizedBox(height: 8),
            Text(
              _labelForState(state),
              style: TextStyle(
                color: _colorForState(state),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForState(IFBState s) => switch (s) {
        IFBState.idle => Icons.headset_off,
        IFBState.requesting => Icons.sync,
        IFBState.connecting => Icons.wifi_find,
        IFBState.connected => Icons.play_circle_outline,
        IFBState.error => Icons.error_outline,
      };

  Color _colorForState(IFBState s) => switch (s) {
        IFBState.idle => Colors.white24,
        IFBState.requesting => Colors.yellow.shade700,
        IFBState.connecting => Colors.orange.shade400,
        IFBState.connected => const Color(0xFF00BCD4),
        IFBState.error => Colors.red.shade400,
      };

  String _labelForState(IFBState s) => switch (s) {
        IFBState.idle => 'IFB inativo',
        IFBState.requesting => 'Negociando WebRTC...',
        IFBState.connecting => 'Conectando (ICE)...',
        IFBState.connected => 'Aguardando vídeo',
        IFBState.error => 'Erro na conexão',
      };
}

class _IFBControlBar extends StatelessWidget {
  const _IFBControlBar({
    required this.reporterId,
    required this.ifbStatus,
    required this.onRequest,
    required this.onHangup,
  });

  final String reporterId;
  final IFBStatus ifbStatus;
  final VoidCallback onRequest;
  final VoidCallback onHangup;

  @override
  Widget build(BuildContext context) {
    final isActive = ifbStatus.state == IFBState.connected ||
        ifbStatus.state == IFBState.connecting;
    final isLoading = ifbStatus.state == IFBState.requesting ||
        ifbStatus.state == IFBState.connecting;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Canal L/R info ──────────────────────────────────
          if (isActive)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  _ChannelChip(
                      label: 'L',
                      desc: 'PGM + Dir. Jornalismo',
                      color: Colors.blue.shade300),
                  const SizedBox(width: 8),
                  _ChannelChip(
                      label: 'R',
                      desc: 'PGM + Dir. TV',
                      color: Colors.green.shade300),
                ],
              ),
            ),

          // ── Error message ───────────────────────────────────
          if (ifbStatus.state == IFBState.error &&
              ifbStatus.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                ifbStatus.errorMessage!,
                style: TextStyle(color: Colors.red.shade400, fontSize: 11),
              ),
            ),

          // ── Botão principal ─────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: isActive || isLoading
                ? OutlinedButton.icon(
                    onPressed: isLoading ? null : onHangup,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade400,
                      side: BorderSide(color: Colors.red.shade900),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    icon: isLoading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white38),
                          )
                        : const Icon(Icons.headset_off, size: 16),
                    label: Text(isLoading ? 'Conectando...' : 'Desligar IFB'),
                  )
                : FilledButton.icon(
                    onPressed: onRequest,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF006064),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    icon: const Icon(Icons.headset, size: 16),
                    label: const Text('Ativar IFB'),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChannelChip extends StatelessWidget {
  const _ChannelChip(
      {required this.label, required this.desc, required this.color});

  final String label;
  final String desc;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        border: Border.all(color: color.withAlpha(80)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 10, fontWeight: FontWeight.w800)),
          const SizedBox(width: 4),
          Text(desc,
              style: TextStyle(color: color.withAlpha(200), fontSize: 9)),
        ],
      ),
    );
  }
}
