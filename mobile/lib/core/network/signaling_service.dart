// ============================================================
// SP Smart — Signaling Service com Failover Automático
// ============================================================
//
// Arquitetura de failover:
//
//   [PRIMARY] ──────────────────────────────────────┐
//       │                                           │
//       │ heartbeat perdido / timeout / erro         │
//       ▼                                           │
//   [FAILOVER_PENDING]  ──── delay 500ms ───────────┤
//       │                                           │
//       ▼                                           │
//   [BACKUP] ───────────── heartbeat OK ────────────┤
//       │                                           │
//       │ primary volta (probe a cada 30s)           │
//       ▼                                           │
//   [PRIMARY_RECOVERY] ── reconecta Primary ────────┘
//
// O SRT é comutado via SrtEngine.switchDestination() de forma
// independente — o vídeo nunca para durante a troca de sinalização.
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:logger/logger.dart';
import 'package:sp_smart/core/network/protocol.dart';
import 'package:sp_smart/core/config/app_config.dart';


// ── Estado da Conexão ────────────────────────────────────────
enum SignalingState {
  disconnected,
  connecting,
  authenticating,
  connected,
  failoverPending,  // primary falhou, aguardando switch para backup
  reconnecting,     // tentando mesmo nó com backoff
  probing,          // verificando se primary voltou (background)
  error,
}

// ── Nó Ativo ─────────────────────────────────────────────────
enum ActiveNode { primary, backup }

// ── Evento de Failover (exposto para a UI) ────────────────────
class FailoverEvent {
  final ActiveNode from;
  final ActiveNode to;
  final String reason;
  final DateTime occurredAt;

  const FailoverEvent({
    required this.from,
    required this.to,
    required this.reason,
    required this.occurredAt,
  });
}

// ── Configurações de Timing ──────────────────────────────────
const _kConnectTimeoutSec        = 6;     // timeout de conexão WS
const _kHeartbeatIntervalSec     = 4;     // frequência do ping local
const _kHeartbeatTimeoutSec      = 12;    // sem pong → considera morto
const _kFailoverDelayMs          = 500;   // espera antes de comutar
const _kPrimaryProbeIntervalSec  = 30;    // intervalo de sondagem do primary
const _kReconnectInitialMs       = 1000;
const _kReconnectMaxMs           = 30000;
const _kReconnectBackoffFactor   = 1.5;
const _kMaxReconnectSameNode     = 3;     // tentativas no mesmo nó antes de failover

// ─────────────────────────────────────────────────────────────

/// Serviço central de sinalização com failover automático.
///
/// Expõe:
///  - [stateStream]         estado da conexão
///  - [activeNodeStream]    qual nó está ativo agora
///  - [messageStream]       mensagens tipadas do servidor
///  - [failoverEventStream] eventos de comutação (para log/UI)
class SignalingService {
  SignalingService(this._ref);

  final Ref _ref;
  final _log = Logger(printer: PrettyPrinter(methodCount: 0));

  // ── Nó e Config Ativos ────────────────────────────────────
  List<ServerEndpoint> _endpoints = [];
  int _activeIndex = 0;       // índice em _endpoints
  ServerEndpoint? get activeEndpoint =>
      _endpoints.isNotEmpty ? _endpoints[_activeIndex] : null;
  ActiveNode get activeNode =>
      _activeIndex == 0 ? ActiveNode.primary : ActiveNode.backup;

  // ── Canal WS ─────────────────────────────────────────────
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  // ── Timers ────────────────────────────────────────────────
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _heartbeatWatchdog;
  Timer? _primaryProbeTimer;
  Timer? _failoverTimer;

  // ── Contadores ───────────────────────────────────────────
  int _reconnectAttempts = 0;
  int _reconnectDelayMs  = _kReconnectInitialMs;

  // ── Streams ───────────────────────────────────────────────
  final _stateCtrl    = StreamController<SignalingState>.broadcast();
  final _nodeCtrl     = StreamController<ActiveNode>.broadcast();
  final _msgCtrl      = StreamController<ServerMessage>.broadcast();
  final _failoverCtrl = StreamController<FailoverEvent>.broadcast();

  /// Stream separado para mensagens de sinalização WebRTC/IFB.
  /// O IFBService se inscreve aqui; o messageStream principal
  /// continua servindo Tally, Bitrate e Welcome.
  final _ifbMsgCtrl   = StreamController<Map<String, dynamic>>.broadcast();

  Stream<SignalingState>          get stateStream        => _stateCtrl.stream;
  Stream<ActiveNode>              get activeNodeStream   => _nodeCtrl.stream;
  Stream<ServerMessage>           get messageStream      => _msgCtrl.stream;
  Stream<FailoverEvent>           get failoverEventStream => _failoverCtrl.stream;
  Stream<Map<String, dynamic>>    get ifbMessageStream   => _ifbMsgCtrl.stream;

  SignalingState _state = SignalingState.disconnected;
  SignalingState get state => _state;

  // ── Informações da Sessão ─────────────────────────────────
  String? sessionId;
  String? srtIngestUrl;

  // ── Último timestamp de pong recebido ────────────────────
  DateTime _lastPongAt = DateTime.now();

  // ─────────────────────────────────────────────────────────
  // API PÚBLICA
  // ─────────────────────────────────────────────────────────

  /// Inicia a conexão com a lista de endpoints configurados.
  /// Sempre começa pelo Primary (índice 0).
  Future<void> connect(List<ServerEndpoint> endpoints) async {
    if (endpoints.isEmpty) {
      _log.e('connect() chamado com lista de endpoints vazia!');
      return;
    }
    _endpoints = endpoints;
    _activeIndex = 0;
    _reconnectAttempts = 0;
    _reconnectDelayMs = _kReconnectInitialMs;

    _setState(SignalingState.connecting);
    await _doConnect(_endpoints[_activeIndex]);
  }

  void sendHello({
    required String reporterId,
    required String displayName,
    required String authToken,
    required int timestamp,
    required String srtStreamKey,
  }) {
    _send(ClientHelloMessage(
      reporterId: reporterId,
      displayName: displayName,
      authToken: authToken,
      timestamp: timestamp,
      srtStreamKey: srtStreamKey,
    ).toJson());
  }

  void sendStatus(ClientStatusMessage message) => _send(message.toJson());

  void sendPong(int ts) => _send(ClientPongMessage(timestamp: ts).toJson());

  void sendBye(String reporterId, {String? reason}) {
    _send(ClientByeMessage(reporterId: reporterId, reason: reason).toJson());
    disconnect();
  }

  /// Envia o SDP offer de IFB para o servidor.
  /// O servidor encaminha ao Studio Desktop conectado.
  Future<void> sendIFBRequest(String reporterId, String sdpOffer) async {
    _send({
      'type':      'CLIENT_IFB_REQUEST',
      'reporterId': reporterId,
      'sdpOffer':   sdpOffer,
    });
    _log.i('[IFB] SDP offer sent for $reporterId (${sdpOffer.length} bytes)');
  }

  /// Envia um ICE candidate gerado pelo RTCPeerConnection.
  /// [sessionType] deve ser 'ifb' para sessões de IFB.
  void sendIceCandidate(
    String reporterId,
    dynamic candidate, {
    String sessionType = 'ifb',
  }) {
    _send({
      'type':       'CLIENT_ICE_CANDIDATE',
      'reporterId':  reporterId,
      'sessionType': sessionType,
      'candidate': {
        'candidate':     candidate.candidate ?? '',
        'sdpMid':        candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      },
    });
  }

  /// Notifica o servidor (e o Studio) que o repórter encerrou o IFB.
  void sendIFBHangup(String reporterId, {String? reason}) {
    _send({
      'type':       'CLIENT_BYE',       // Reutiliza CLIENT_BYE com reason IFB
      'reporterId':  reporterId,
      'reason':      reason ?? 'IFB_HANGUP',
    });
  }

  /// Forçar failover manual (ex: botão na UI de operador).
  void forceFailover({String reason = 'Manual failover'}) {
    _triggerFailover(reason: reason);
  }

  void disconnect() {
    _clearAllTimers();
    _closeChannel();
    _setState(SignalingState.disconnected);
  }

  void dispose() {
    disconnect();
    _stateCtrl.close();
    _nodeCtrl.close();
    _msgCtrl.close();
    _failoverCtrl.close();
    _ifbMsgCtrl.close();
  }

  // ─────────────────────────────────────────────────────────
  // CONEXÃO
  // ─────────────────────────────────────────────────────────

  Future<void> _doConnect(ServerEndpoint endpoint) async {
    _log.i('Conectando ao nó ${endpoint.label}: ${endpoint.wsUrl}');
    try {
      final uri = Uri.parse(endpoint.wsUrl);
      _channel = IOWebSocketChannel.connect(
        uri,
        connectTimeout: const Duration(seconds: _kConnectTimeoutSec),
      );

      _subscription = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      _setState(SignalingState.authenticating);
    } catch (e) {
      _log.e('Falha de conexão no nó ${endpoint.label}', error: e);
      _handleConnectionFailure();
    }
  }

  // ─────────────────────────────────────────────────────────
  // HEARTBEAT LOCAL (app-side ping/watchdog)
  // ─────────────────────────────────────────────────────────

  void _startHeartbeat() {
    _lastPongAt = DateTime.now();

    // Envia ping a cada N segundos
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: _kHeartbeatIntervalSec),
      (_) {
        if (_state == SignalingState.connected) {
          _send({'type': 'CLIENT_PONG', 'timestamp': DateTime.now().millisecondsSinceEpoch});
        }
      },
    );

    // Watchdog: verifica se recebeu pong recente
    _heartbeatWatchdog?.cancel();
    _heartbeatWatchdog = Timer.periodic(
      const Duration(seconds: _kHeartbeatIntervalSec),
      (_) {
        final silence = DateTime.now().difference(_lastPongAt).inSeconds;
        if (silence >= _kHeartbeatTimeoutSec) {
          _log.w('Heartbeat timeout: ${silence}s sem resposta do nó ${activeEndpoint?.label}');
          _triggerFailover(reason: 'Heartbeat timeout (${silence}s)');
        }
      },
    );
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatWatchdog?.cancel();
    _heartbeatTimer = null;
    _heartbeatWatchdog = null;
  }

  // ─────────────────────────────────────────────────────────
  // FAILOVER
  // ─────────────────────────────────────────────────────────

  void _handleConnectionFailure() {
    _reconnectAttempts++;

    // Esgotou tentativas no nó atual → tenta o próximo
    if (_reconnectAttempts >= _kMaxReconnectSameNode && _endpoints.length > 1) {
      _triggerFailover(reason: 'Max retries no nó ${activeEndpoint?.label}');
      return;
    }

    // Ainda tem tentativas → backoff no mesmo nó
    _setState(SignalingState.reconnecting);
    _log.i(
      'Tentativa $_reconnectAttempts/${_kMaxReconnectSameNode} em ${_reconnectDelayMs}ms...',
    );

    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelayMs), () {
      _reconnectDelayMs = (_reconnectDelayMs * _kReconnectBackoffFactor)
          .clamp(0, _kReconnectMaxMs)
          .toInt();
      if (_endpoints.isNotEmpty) _doConnect(_endpoints[_activeIndex]);
    });
  }

  void _triggerFailover({required String reason}) {
    if (_endpoints.length <= 1) {
      _log.w('Failover solicitado mas não há backup configurado.');
      _handleConnectionFailure();
      return;
    }

    final fromNode = activeNode;
    _stopHeartbeat();
    _closeChannel();
    _setState(SignalingState.failoverPending);

    _log.w('FAILOVER: $reason — comutando ${fromNode.name} → próximo nó em ${_kFailoverDelayMs}ms');

    _failoverTimer = Timer(const Duration(milliseconds: _kFailoverDelayMs), () {
      // Avança para o próximo endpoint na lista (circular)
      _activeIndex = (_activeIndex + 1) % _endpoints.length;
      _reconnectAttempts = 0;
      _reconnectDelayMs = _kReconnectInitialMs;

      final toNode = activeNode;
      _log.w('FAILOVER EXECUTADO: ${fromNode.name} → ${toNode.name} (${activeEndpoint?.host})');

      _failoverCtrl.add(FailoverEvent(
        from: fromNode,
        to: toNode,
        reason: reason,
        occurredAt: DateTime.now(),
      ));

      _nodeCtrl.add(toNode);
      _setState(SignalingState.connecting);
      _doConnect(_endpoints[_activeIndex]);

      // Se foi para backup, começa a sondar o primary em background
      if (toNode == ActiveNode.backup) {
        _startPrimaryProbe();
      }
    });
  }

  // ─────────────────────────────────────────────────────────
  // SONDAGEM DO PRIMARY (recovery em background)
  // ─────────────────────────────────────────────────────────

  void _startPrimaryProbe() {
    _primaryProbeTimer?.cancel();
    _primaryProbeTimer = Timer.periodic(
      const Duration(seconds: _kPrimaryProbeIntervalSec),
      (_) async {
        if (activeNode != ActiveNode.backup) {
          _primaryProbeTimer?.cancel();
          return;
        }
        final primary = _endpoints.firstWhere(
          (e) => e.isPrimary,
          orElse: () => _endpoints[0],
        );
        _log.i('[PROBE] Verificando se o Primary voltou: ${primary.host}...');
        final alive = await _probeEndpoint(primary);
        if (alive) {
          _log.i('[PROBE] Primary VIVO — iniciando recovery.');
          _primaryProbeTimer?.cancel();
          _setState(SignalingState.probing);
          await _recoverToPrimary(primary);
        } else {
          _log.d('[PROBE] Primary ainda indisponível.');
        }
      },
    );
  }

  /// Sonda um endpoint via TCP (sem abrir WebSocket completo).
  Future<bool> _probeEndpoint(ServerEndpoint ep) async {
    try {
      final socket = await Socket.connect(
        ep.host,
        ep.signalingPort,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _recoverToPrimary(ServerEndpoint primary) async {
    final fromNode = activeNode;
    _stopHeartbeat();
    _closeChannel();

    // Volta para o índice 0 (primary)
    _activeIndex = 0;
    _reconnectAttempts = 0;
    _reconnectDelayMs = _kReconnectInitialMs;

    _failoverCtrl.add(FailoverEvent(
      from: fromNode,
      to: ActiveNode.primary,
      reason: 'Primary recovery automático',
      occurredAt: DateTime.now(),
    ));

    _nodeCtrl.add(ActiveNode.primary);
    _setState(SignalingState.connecting);
    await _doConnect(primary);
  }

  // ─────────────────────────────────────────────────────────
  // HANDLERS DO WS
  // ─────────────────────────────────────────────────────────

  void _onData(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      final msg = ServerMessage.fromJson(json);

      // Atualiza watchdog a CADA mensagem recebida (não apenas pings)
      _lastPongAt = DateTime.now();

      if (msg is ServerPingMessage) {
        sendPong(msg.timestamp);
        return;
      }

      if (msg is ServerWelcomeMessage) {
        sessionId    = msg.sessionId;
        srtIngestUrl = msg.srtIngestUrl;
        _reconnectAttempts = 0;
        _reconnectDelayMs  = _kReconnectInitialMs;
        _setState(SignalingState.connected);
        _startHeartbeat();
        _log.i(
          'Autenticado no nó ${activeEndpoint?.label}. '
          'Session: ${msg.sessionId} | SRT: ${msg.srtIngestUrl}',
        );
      }

      if (msg is ServerRejectMessage) {
        _log.w('Conexão rejeitada: ${msg.reason} (${msg.code})');
        // Rejeição do server → não retenta, vai direto para failover
        _triggerFailover(reason: 'Server reject: ${msg.code}');
        return;
      }

      // ── Roteamento de mensagens IFB WebRTC ──────────────
      // Estas mensagens são enviadas para o stream dedicado do IFBService
      // e NÃO para o messageStream principal (evita acoplamento).
      if (msg is ServerIFBAnswerMessage ||
          msg is ServerICECandidateMessage ||
          msg is ServerIFBHangupMessage) {
        final rawJson = jsonDecode(raw as String) as Map<String, dynamic>;
        _ifbMsgCtrl.add(rawJson);
        return; // Não duplica no messageStream principal
      }

      _msgCtrl.add(msg);
    } catch (e) {
      _log.e('Erro ao processar mensagem do servidor', error: e);
    }
  }

  void _onError(Object error) {
    _log.e('WebSocket error no nó ${activeEndpoint?.label}', error: error);
    _stopHeartbeat();
    _handleConnectionFailure();
  }

  void _onDone() {
    _log.w('WebSocket fechado pelo nó ${activeEndpoint?.label}');
    _stopHeartbeat();
    _channel = null;
    _subscription = null;

    if (_state != SignalingState.disconnected &&
        _state != SignalingState.failoverPending) {
      _handleConnectionFailure();
    }
  }

  // ─────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────

  void _send(Map<String, dynamic> payload) {
    if (_channel == null || _state != SignalingState.connected) {
      _log.w('Não conectado. Descartando mensagem: ${payload['type']}');
      return;
    }
    try {
      _channel!.sink.add(jsonEncode(payload));
    } catch (e) {
      _log.e('Erro ao enviar mensagem', error: e);
    }
  }

  void _closeChannel() {
    _subscription?.cancel();
    _channel?.sink.close(WebSocketStatus.normalClosure);
    _channel = null;
    _subscription = null;
  }

  void _clearAllTimers() {
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _heartbeatWatchdog?.cancel();
    _primaryProbeTimer?.cancel();
    _failoverTimer?.cancel();
  }

  void _setState(SignalingState next) {
    if (_state == next) return;
    _state = next;
    _stateCtrl.add(next);
    _log.d('Signaling → $next [nó=${activeEndpoint?.label ?? "none"}]');
  }
}

// @riverpod
SignalingService signalingService(Ref ref) {
  final service = SignalingService(ref);
  ref.onDispose(service.dispose);
  return service;
}

final signalingServiceProvider = NotifierProvider<SignalingService, SignalingState>(SignalingService.new);

