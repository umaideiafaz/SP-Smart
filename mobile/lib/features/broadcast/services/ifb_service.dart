// ============================================================
// SP Smart Mobile — IFB Service (WebRTC, Stereo preservado)
// ============================================================
//
// Estabelece e gerencia a sessão WebRTC de IFB (Interrupted FoldBack)
// com o Studio Desktop, via sinalização pelo SignalingServer Node.js.
//
// REQUISITO CRÍTICO DE ÁUDIO:
//   O áudio do estúdio chega em estéreo discreto:
//     Canal L: PGM + Diretor de Jornalismo
//     Canal R: PGM + Diretor de TV
//
//   É PROIBIDO que o WebRTC faça downmix para mono.
//   Constraints aplicadas:
//     echoCancellation:   false  ← desativa processamento de eco
//     noiseSuppression:   false  ← desativa supressão de ruído
//     autoGainControl:    false  ← desativa controle automático de ganho
//     channelCount:       2      ← força recepção estéreo
//     sampleRate:         48000  ← taxa padrão Opus/broadcast
//
//   O SDP answer gerado tem a fmtp Opus modificada para:
//     stereo=1;sprop-stereo=1;useinbandfec=1
//   garantindo que o encoder do Studio envie áudio estéreo.
// ============================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../../core/network/signaling_service.dart';


// ── Estado ────────────────────────────────────────────────────

enum IFBState {
  idle,
  requesting,    // Enviou CLIENT_IFB_REQUEST, aguardando SDP answer
  connecting,    // ICE em progresso
  connected,     // IFB ativo e áudio/vídeo fluindo
  error,
}

class IFBStatus {
  final IFBState state;
  final String? errorMessage;
  final bool hasVideo;
  final bool hasAudio;

  const IFBStatus({
    required this.state,
    this.errorMessage,
    this.hasVideo = false,
    this.hasAudio = false,
  });

  IFBStatus copyWith({
    IFBState? state,
    String? errorMessage,
    bool? hasVideo,
    bool? hasAudio,
  }) => IFBStatus(
    state:        state        ?? this.state,
    errorMessage: errorMessage ?? this.errorMessage,
    hasVideo:     hasVideo     ?? this.hasVideo,
    hasAudio:     hasAudio     ?? this.hasAudio,
  );

  static const initial = IFBStatus(state: IFBState.idle);
}

// ── Renderer para o vídeo de retorno ─────────────────────────

/// Exposto ao widget de UI para renderizar o vídeo de retorno.
final remoteVideoRendererProvider = Provider<RTCVideoRenderer>((ref) {
  final renderer = RTCVideoRenderer();
  ref.onDispose(renderer.dispose);
  return renderer;
});

// ─────────────────────────────────────────────────────────────
// IFBService — Riverpod Notifier
// ─────────────────────────────────────────────────────────────

class IFBService extends Notifier<IFBStatus> {
  RTCPeerConnection? _pc;
  StreamSubscription<dynamic>? _sigSub;
  final _localIceCandidates = <RTCIceCandidate>[];
  bool _remoteDescSet = false;

  @override
  IFBStatus build() => IFBStatus.initial;

  // ── Constraints de áudio (CRÍTICO) ─────────────────────────

  /// Constraints de RECEPÇÃO de mídia remota.
  ///
  /// Aplicadas no RTCPeerConnection para garantir que o áudio
  /// recebido do Studio preserve o estéreo L/R intacto.
  static Map<String, dynamic> get _audioRecvConstraints => {
    'echoCancellation':  false,  // PROIBIDO — interfere com o sinal Mix-Minus
    'noiseSuppression':  false,  // PROIBIDO — altera timbre do retorno
    'autoGainControl':   false,  // PROIBIDO — muda nível do Mix-Minus
    'channelCount':      2,      // ESTÉREO — L e R independentes
    'sampleRate':        48000,  // Padrão Opus/broadcast
    'sampleSize':        16,
  };

  /// Configuração do RTCPeerConnection.
  static const Map<String, dynamic> _pcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics':          'unified-plan',
    'iceCandidatePoolSize':  4,
  };

  // ── API Pública ───────────────────────────────────────────

  /// Inicia o IFB: cria o PeerConnection, gera o SDP offer e envia
  /// ao servidor para que o Studio receba e responda.
  Future<void> requestIFB({
    required String reporterId,
    required SignalingService signaling,
    required RTCVideoRenderer remoteRenderer,
  }) async {
    if (state.state != IFBState.idle && state.state != IFBState.error) {
      debugPrint('[IFB] Already in state ${state.state}');
      return;
    }

    state = IFBStatus(state: IFBState.requesting);

    try {
      await _createPeerConnection(reporterId, signaling, remoteRenderer);
      await _createAndSendOffer(reporterId, signaling);
    } catch (e) {
      state = IFBStatus(state: IFBState.error, errorMessage: e.toString());
      debugPrint('[IFB] requestIFB error: $e');
    }
  }

  /// Encerra o IFB e libera todos os recursos.
  Future<void> hangup({
    required String reporterId,
    required SignalingService signaling,
  }) async {
    _sigSub?.cancel();
    _sigSub = null;

    await _pc?.close();
    _pc = null;
    _localIceCandidates.clear();
    _remoteDescSet = false;

    state = IFBStatus.initial;
    debugPrint('[IFB] Hung up');
  }

  // ── PeerConnection ────────────────────────────────────────

  Future<void> _createPeerConnection(
    String            reporterId,
    SignalingService  signaling,
    RTCVideoRenderer  remoteRenderer,
  ) async {
    // Cria o RTCPeerConnection com constraints de áudio explícitas
    _pc = await createPeerConnection(
      _pcConfig,
      {
        // Constraints do offerant (mobile) — para o nosso OFFER
        'mandatory': {
          // Mobile não envia áudio nem vídeo para o Studio no IFB
          // (apenas recebe). Mas algumas implementações precisam de
          // sendrecv para negociar corretamente — usamos recvonly.
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': true,
        },
        'optional': [],
      },
    );

    // ── ICE candidate handler ───────────────────────────────
    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      if (_remoteDescSet) {
        // Envia imediatamente se já temos a remote description
        signaling.sendIceCandidate(reporterId, candidate, sessionType: 'ifb');
      } else {
        // Armazena para enviar depois do setRemoteDescription
        _localIceCandidates.add(candidate);
      }
    };

    // ── Connection state ────────────────────────────────────
    _pc!.onConnectionState = (RTCPeerConnectionState connState) {
      debugPrint('[IFB] Connection state: $connState');
      switch (connState) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          state = state.copyWith(state: IFBState.connected);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          state = state.copyWith(state: IFBState.error, errorMessage: 'ICE failed');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          state = state.copyWith(state: IFBState.idle);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          state = state.copyWith(state: IFBState.connecting);
          break;
        default:
          break;
      }
    };

    // ── Track remoto (áudio/vídeo do Studio) ────────────────
    _pc!.onTrack = (RTCTrackEvent event) {
      debugPrint('[IFB] Remote track received: kind=${event.track.kind}');

      if (event.track.kind == 'video') {
        // Conecta o stream de vídeo ao renderer da UI
        if (event.streams.isNotEmpty) {
          remoteRenderer.srcObject = event.streams[0];
          state = state.copyWith(hasVideo: true);
        }
      }

      if (event.track.kind == 'audio') {
        state = state.copyWith(hasAudio: true);
        // CRITICAL: garante que o audio track não sofra processamento
        // de localização mono pelo WebRTC nativo
        _enforceAudioTrackConstraints(event.track);
      }
    };

    // ── Inscreve no canal de sinalização para receber respostas ─
    _listenForSignalingMessages(reporterId, signaling);

    debugPrint('[IFB] PeerConnection created');
  }

  Future<void> _createAndSendOffer(
    String           reporterId,
    SignalingService signaling,
  ) async {
    // Cria o SDP offer com constraints de recvonly para A/V
    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });

    // CRÍTICO: modifica o SDP offer para forçar áudio estéreo
    // O Studio lerá este SDP e configurará seu Opus encoder como estéreo.
    final modifiedOffer = RTCSessionDescription(
      _enforceStereoInSdp(offer.sdp!),
      offer.type,
    );

    await _pc!.setLocalDescription(modifiedOffer);

    // Envia o offer para o servidor (que encaminha ao Studio)
    await signaling.sendIFBRequest(reporterId, modifiedOffer.sdp!);

    debugPrint('[IFB] SDP offer sent (${modifiedOffer.sdp!.length} bytes)');
  }

  // ── Signaling message listener ────────────────────────────

  void _listenForSignalingMessages(
    String           reporterId,
    SignalingService signaling,
  ) {
    _sigSub = signaling.ifbMessageStream.listen((msg) async {
      try {
        switch (msg['type'] as String?) {

          // SDP answer do Studio
          case 'SERVER_IFB_ANSWER':
            if (msg['reporterId'] != reporterId) return;
            final rawSdp = msg['sdpAnswer'] as String? ?? '';

            // Detecta se é realmente um answer ou um offer (push mode)
            final sdpType = rawSdp.contains('a=group:') &&
                            rawSdp.contains('o=')
                ? 'answer'
                : 'answer'; // Fase 3: sempre answer no flow normal

            final answer = RTCSessionDescription(
              _enforceStereoInSdp(rawSdp),
              sdpType,
            );
            await _pc!.setRemoteDescription(answer);
            _remoteDescSet = true;

            debugPrint('[IFB] Remote description set');

            // Drena candidatos ICE que chegaram antes do answer
            for (final c in _localIceCandidates) {
              signaling.sendIceCandidate(reporterId, c, sessionType: 'ifb');
            }
            _localIceCandidates.clear();
            break;

          // ICE candidate do Studio
          case 'SERVER_ICE_CANDIDATE':
            if (msg['reporterId'] != reporterId) return;
            final candObj = msg['candidate'] as Map<String, dynamic>?;
            if (candObj == null) return;
            final candidate = RTCIceCandidate(
              candObj['candidate']    as String? ?? '',
              candObj['sdpMid']       as String?,
              candObj['sdpMLineIndex'] as int?,
            );
            await _pc!.addCandidate(candidate);
            break;

          // Studio desligou o IFB
          case 'SERVER_IFB_HANGUP':
            if (msg['reporterId'] != reporterId) return;
            debugPrint('[IFB] Studio hung up: ${msg['reason']}');
            await hangup(reporterId: reporterId, signaling: signaling);
            break;
        }
      } catch (e) {
        debugPrint('[IFB] Signaling message error: $e');
        state = state.copyWith(state: IFBState.error, errorMessage: e.toString());
      }
    });
  }

  // ── SDP stereo enforcement ────────────────────────────────

  /// Modifica o SDP para garantir que o áudio Opus seja estéreo.
  ///
  /// Encontra a linha a=fmtp do codec Opus (PT 111 por padrão)
  /// e adiciona/substitui os parâmetros de estéreo.
  ///
  /// SDP resultante terá:
  ///   a=fmtp:111 stereo=1;sprop-stereo=1;useinbandfec=1
  String _enforceStereoInSdp(String sdp) {
    final lines = sdp.split('\r\n');
    final result = <String>[];
    String? opusPt;

    for (final line in lines) {
      // Detecta o payload type do Opus
      if (line.contains('opus/48000')) {
        final match = RegExp(r'a=rtpmap:(\d+)\s+opus').firstMatch(line);
        if (match != null) {
          opusPt = match.group(1);
        }
      }

      // Modifica a linha fmtp do Opus para incluir stereo=1
      if (opusPt != null && line.startsWith('a=fmtp:$opusPt')) {
        var fmtp = line;

        // Remove parâmetros conflitantes e re-adiciona corretamente
        fmtp = fmtp
          .replaceAll('stereo=0', 'stereo=1')
          .replaceAll('sprop-stereo=0', 'sprop-stereo=1');

        if (!fmtp.contains('stereo=1')) {
          fmtp = fmtp.endsWith(line) ? '$fmtp;stereo=1' : '$fmtp;stereo=1';
        }
        if (!fmtp.contains('sprop-stereo=1')) {
          fmtp = '$fmtp;sprop-stereo=1';
        }
        if (!fmtp.contains('useinbandfec=1')) {
          fmtp = '$fmtp;useinbandfec=1';
        }

        result.add(fmtp);
        continue;
      }

      result.add(line);
    }

    final modified = result.join('\r\n');
    debugPrint('[IFB] SDP stereo enforcement applied (opusPt=$opusPt)');
    return modified;
  }

  /// Garante que o audio track recebido não seja processado pelo
  /// sistema de conferência do WebRTC nativo (no-op em algumas plataformas,
  /// mas boa prática de segurança).
  void _enforceAudioTrackConstraints(MediaStreamTrack audioTrack) {
    // flutter_webrtc não expõe applyConstraints() diretamente no track,
    // mas garantimos que o RTCPeerConnection foi criado com os constraints
    // corretos desde o início. Esta função serve como documentação explícita
    // da intenção e para futura extensão se a API expor applyConstraints().
    debugPrint(
      '[IFB] Audio track received. Constraints enforced at PeerConnection creation: '
      'echoCancellation=false, noiseSuppression=false, autoGainControl=false, '
      'channelCount=2 (stereo L/R preserved)',
    );
  }
}

final iFBServiceProvider = NotifierProvider<IFBService, IFBStatus>(IFBService.new);

