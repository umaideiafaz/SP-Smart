// ============================================================
// SP Smart — SRT Engine (com suporte a switchDestination)
// ============================================================
// Adições para Alta Disponibilidade:
//   switchDestination()  — troca URL de destino SRT em voo
//   SrtActiveNode        — qual nó SRT está sendo usado
//   failoverStats        — contagem de comutações realizadas
// ============================================================

library sp_smart_srt;

import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


// ── Estados ───────────────────────────────────────────────────
enum SrtConnectionState {
  idle,
  connecting,
  connected,
  streaming,
  switching,     // NOVO: comutando destino (drena buffer antes de trocar)
  disconnected,
  error,
}

// ── Nó SRT Ativo ─────────────────────────────────────────────
enum SrtActiveNode { primary, backup, none }

// ── Informações do destino atual ─────────────────────────────
class SrtDestination {
  final String host;
  final int port;
  final String streamKey;
  final int latencyMs;
  final SrtActiveNode node;

  const SrtDestination({
    required this.host,
    required this.port,
    required this.streamKey,
    this.latencyMs = 120,
    this.node = SrtActiveNode.none,
  });

  /// URL completa para exibição/log.
  String get url => 'srt://$host:$port?streamid=$streamKey';

  @override
  String toString() => '${node.name.toUpperCase()} → $url';
}

// ── Stats de Link SRT ────────────────────────────────────────
class SrtStats {
  final int sendBitrateKbps;
  final int rttMs;
  final double packetLossPercent;
  final int retransmittedPackets;
  final int droppedPackets;
  final int sendBufferFillPercent;
  final SrtActiveNode activeNode;

  const SrtStats({
    required this.sendBitrateKbps,
    required this.rttMs,
    required this.packetLossPercent,
    required this.retransmittedPackets,
    required this.droppedPackets,
    required this.sendBufferFillPercent,
    this.activeNode = SrtActiveNode.none,
  });

  factory SrtStats.fromMap(Map<dynamic, dynamic> map) => SrtStats(
        sendBitrateKbps: (map['sendBitrateKbps'] as num?)?.toInt() ?? 0,
        rttMs: (map['rttMs'] as num?)?.toInt() ?? 0,
        packetLossPercent: (map['packetLossPercent'] as num?)?.toDouble() ?? 0.0,
        retransmittedPackets: (map['retransmittedPackets'] as num?)?.toInt() ?? 0,
        droppedPackets: (map['droppedPackets'] as num?)?.toInt() ?? 0,
        sendBufferFillPercent: (map['sendBufferFillPercent'] as num?)?.toInt() ?? 0,
        activeNode: _parseNode(map['activeNode'] as String? ?? ''),
      );

  static SrtActiveNode _parseNode(String s) => switch (s) {
        'primary' => SrtActiveNode.primary,
        'backup'  => SrtActiveNode.backup,
        _         => SrtActiveNode.none,
      };

  @override
  String toString() =>
      'SrtStats(${activeNode.name} | ${sendBitrateKbps}kbps | '
      'rtt=${rttMs}ms | loss=${packetLossPercent.toStringAsFixed(2)}%)';
}

// ─────────────────────────────────────────────────────────────
// SrtEngine
// ─────────────────────────────────────────────────────────────

/// API Flutter-side para o motor SRT nativo.
///
/// ─── Method Channel: 'sp.smart/srt' ─────────────────────────
/// connect(Map)              — abre socket SRT no destino primário
/// disconnect()              — encerra conexão atual
/// switchDestination(Map)    — NOVO: troca o destino sem parar encoder
/// setTargetBitrate(Map)     — altera bitrate do encoder
/// getStats()                — retorna SrtStats instantâneo
///
/// ─── Event Channel: 'sp.smart/srt/events' ────────────────────
/// { event: 'state_changed',    state: String }
/// { event: 'stats',            ...SrtStats fields }
/// { event: 'switch_complete',  node: String, url: String }
/// { event: 'error',            code: int, message: String }
class SrtEngine {
  static const _methodChannel = MethodChannel('sp.smart/srt');
  static const _eventChannel  = EventChannel('sp.smart/srt/events');

  // ── Estado ────────────────────────────────────────────────
  SrtConnectionState _state = SrtConnectionState.idle;
  SrtConnectionState get state => _state;

  SrtActiveNode _activeNode = SrtActiveNode.none;
  SrtActiveNode get activeNode => _activeNode;

  SrtDestination? _currentDestination;
  SrtDestination? get currentDestination => _currentDestination;

  int _failoverCount = 0;
  int get failoverCount => _failoverCount;

  // ── Streams ───────────────────────────────────────────────
  final _stateCtrl   = StreamController<SrtConnectionState>.broadcast();
  final _statsCtrl   = StreamController<SrtStats>.broadcast();
  final _switchCtrl  = StreamController<SrtDestination>.broadcast();

  Stream<SrtConnectionState> get stateStream  => _stateCtrl.stream;
  Stream<SrtStats>           get statsStream  => _statsCtrl.stream;
  /// Emite cada vez que switchDestination completa com sucesso.
  Stream<SrtDestination>     get switchStream => _switchCtrl.stream;

  StreamSubscription<dynamic>? _eventSubscription;

  // ─────────────────────────────────────────────────────────
  // Inicialização
  // ─────────────────────────────────────────────────────────

  void initialize() {
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      _handleNativeEvent,
      onError: (e) => _stateCtrl.addError(e),
    );
  }

  // ─────────────────────────────────────────────────────────
  // API Pública
  // ─────────────────────────────────────────────────────────

  /// Inicia a transmissão SRT para o destino primário.
  Future<bool> connect(SrtDestination destination) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('connect', {
        'host':             destination.host,
        'port':             destination.port,
        'streamKey':        destination.streamKey,
        'latencyMs':        destination.latencyMs,
        'node':             destination.node.name,
      });
      if (result == true) {
        _currentDestination = destination;
        _activeNode = destination.node;
      }
      return result ?? false;
    } on PlatformException catch (e) {
      _stateCtrl.addError(e);
      return false;
    }
  }

  /// Troca o destino SRT em voo, sem interromper o encoder.
  ///
  /// Estratégia nativa (implementada na Fase 2):
  ///  1. Abre novo socket SRT para [newDestination] (dual-socket brief period)
  ///  2. Aguarda confirmação de handshake SRT do novo servidor
  ///  3. Drena o buffer do socket antigo e fecha-o
  ///  4. Todos os novos pacotes vão para o novo socket
  ///
  /// Do ponto de vista do encoder, não há interrupção.
  Future<bool> switchDestination(SrtDestination newDestination) async {
    try {
      _setState(SrtConnectionState.switching);
      final result = await _methodChannel.invokeMethod<bool>(
        'switchDestination',
        {
          'host':      newDestination.host,
          'port':      newDestination.port,
          'streamKey': newDestination.streamKey,
          'latencyMs': newDestination.latencyMs,
          'node':      newDestination.node.name,
        },
      );
      if (result == true) {
        _failoverCount++;
        _currentDestination = newDestination;
        _activeNode = newDestination.node;
      }
      return result ?? false;
    } on PlatformException catch (e) {
      _stateCtrl.addError(e);
      _setState(SrtConnectionState.error);
      return false;
    }
  }

  /// Encerra conexão SRT.
  Future<void> disconnect() async {
    try {
      await _methodChannel.invokeMethod<void>('disconnect');
      _currentDestination = null;
      _activeNode = SrtActiveNode.none;
    } on PlatformException catch (e) {
      _stateCtrl.addError(e);
    }
  }

  /// Atualiza o bitrate-alvo do encoder em tempo real.
  Future<void> setTargetBitrate(int bitrateKbps) async {
    try {
      await _methodChannel.invokeMethod<void>('setTargetBitrate', {
        'bitrateKbps': bitrateKbps,
      });
    } on PlatformException catch (e) {
      _stateCtrl.addError(e);
    }
  }

  /// Snapshot instantâneo de estatísticas SRT.
  Future<SrtStats?> getStats() async {
    try {
      final map = await _methodChannel.invokeMapMethod<dynamic, dynamic>('getStats');
      return map != null ? SrtStats.fromMap(map) : null;
    } on PlatformException {
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────
  // Eventos Nativos
  // ─────────────────────────────────────────────────────────

  void _handleNativeEvent(dynamic event) {
    if (event is! Map) return;
    final eventType = event['event'] as String?;

    switch (eventType) {
      case 'state_changed':
        final s = event['state'] as String? ?? 'idle';
        _setState(_parseState(s));

      case 'stats':
        _statsCtrl.add(SrtStats.fromMap(event));

      case 'switch_complete':
        // Nativo confirma que a troca foi bem-sucedida
        final nodeStr = event['node'] as String? ?? '';
        _activeNode = _parseNode(nodeStr);
        if (_currentDestination != null) {
          _switchCtrl.add(_currentDestination!);
        }
        _setState(SrtConnectionState.streaming);

      case 'error':
        _stateCtrl.addError(PlatformException(
          code: event['code']?.toString() ?? 'SRT_ERROR',
          message: event['message'] as String?,
        ));
    }
  }

  void _setState(SrtConnectionState s) {
    if (_state == s) return;
    _state = s;
    _stateCtrl.add(s);
  }

  static SrtConnectionState _parseState(String s) => switch (s) {
        'connecting'   => SrtConnectionState.connecting,
        'connected'    => SrtConnectionState.connected,
        'streaming'    => SrtConnectionState.streaming,
        'switching'    => SrtConnectionState.switching,
        'disconnected' => SrtConnectionState.disconnected,
        'error'        => SrtConnectionState.error,
        _              => SrtConnectionState.idle,
      };

  static SrtActiveNode _parseNode(String s) => switch (s) {
        'primary' => SrtActiveNode.primary,
        'backup'  => SrtActiveNode.backup,
        _         => SrtActiveNode.none,
      };

  void dispose() {
    _eventSubscription?.cancel();
    _stateCtrl.close();
    _statsCtrl.close();
    _switchCtrl.close();
  }
}

SrtEngine srtEngine(Ref ref) {
  final engine = SrtEngine();
  engine.initialize();
  ref.onDispose(engine.dispose);
  return engine;
}

final srtEngineProvider = Provider<SrtEngine>(srtEngine);

