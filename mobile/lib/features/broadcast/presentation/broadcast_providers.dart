// ============================================================
// SP Smart Mobile — Broadcast UI Providers (Fase 5)
// ============================================================
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sp_smart/core/network/protocol.dart';
import 'package:sp_smart/core/network/signaling_service.dart';

/// Provider que escuta o messageStream do SignalingService
/// e extrai o estado atual do Tally (PGM, PVW, IDLE).
final tallyStateProvider = StreamProvider<TallyState>((ref) async* {
  final sigService = ref.watch(signalingServiceProvider);
  if (sigService == null) {
    yield TallyState.idle;
    return;
  }

  // Emite o estado inicial
  yield TallyState.idle;

  // Escuta mensagens do tipo Tally
  await for (final msg in sigService.messageStream) {
    if (msg is ServerTallyMessage) {
      yield msg.state;
    }
  }
});

/// Mock Provider para Bateria (Para fins de UI/Arquitetura)
/// Em produção, utilizaria o pacote 'battery_plus'.
final batteryLevelProvider = StreamProvider<int>((ref) async* {
  yield 85; // Valor estático inicial
  // Em prod: yield* Battery().onBatteryStateChanged...
});
