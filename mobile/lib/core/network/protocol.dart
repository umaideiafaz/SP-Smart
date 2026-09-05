// ============================================================
// SP Smart — WebSocket Protocol Message Types (Dart)
// ============================================================
// Mirror of server/src/types/protocol.ts
// Kept in sync manually for Phase 1; Phase 5 will add code-gen.
// ============================================================

// ── Enums ────────────────────────────────────────────────────

enum TallyState { pgm, pvw, idle }

enum EncodingPreset {
  lowLatencySd,
  lowLatencyHd,
  qualityHd,
  qualityFhd,
  qualityFhdHigh,
}

extension EncodingPresetExtension on EncodingPreset {
  String toJson() => switch (this) {
        EncodingPreset.lowLatencySd   => 'LOW_LATENCY_SD',
        EncodingPreset.lowLatencyHd   => 'LOW_LATENCY_HD',
        EncodingPreset.qualityHd      => 'QUALITY_HD',
        EncodingPreset.qualityFhd     => 'QUALITY_FHD',
        EncodingPreset.qualityFhdHigh => 'QUALITY_FHD_HIGH',
      };

  static EncodingPreset fromJson(String value) => switch (value) {
        'LOW_LATENCY_SD'   => EncodingPreset.lowLatencySd,
        'LOW_LATENCY_HD'   => EncodingPreset.lowLatencyHd,
        'QUALITY_HD'       => EncodingPreset.qualityHd,
        'QUALITY_FHD'      => EncodingPreset.qualityFhd,
        'QUALITY_FHD_HIGH' => EncodingPreset.qualityFhdHigh,
        _                  => EncodingPreset.lowLatencyHd,
      };
}

extension TallyStateExtension on TallyState {
  String toJson() => name.toUpperCase();
  static TallyState fromJson(String value) => switch (value) {
        'PGM'  => TallyState.pgm,
        'PVW'  => TallyState.pvw,
        _      => TallyState.idle,
      };
}

// ── Outgoing Messages (Client → Server) ──────────────────────

class NetworkInterfaceInfo {
  final String name;
  final String type;
  final bool active;
  final int bandwidthEstimate;

  const NetworkInterfaceInfo({
    required this.name,
    required this.type,
    required this.active,
    required this.bandwidthEstimate,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        'active': active,
        'bandwidthEstimate': bandwidthEstimate,
      };
}

class ClientHelloMessage {
  final String reporterId;
  final String displayName;
  final String authToken;
  final int timestamp;
  final String srtStreamKey;

  const ClientHelloMessage({
    required this.reporterId,
    required this.displayName,
    required this.authToken,
    required this.timestamp,
    required this.srtStreamKey,
  });

  Map<String, dynamic> toJson() => {
        'type': 'CLIENT_HELLO',
        'reporterId': reporterId,
        'displayName': displayName,
        'authToken': authToken,
        'timestamp': timestamp,
        'srtStreamKey': srtStreamKey,
        'capabilities': {'srt': true, 'webrtc': true, 'hevc': true},
      };
}

class ClientStatusMessage {
  final String reporterId;
  final int currentBitrate;
  final int targetBitrate;
  final int rtt;
  final double packetLoss;
  final List<NetworkInterfaceInfo> networkInterfaces;
  final int battery;
  final int signal;
  final EncodingPreset encodingPreset;

  const ClientStatusMessage({
    required this.reporterId,
    required this.currentBitrate,
    required this.targetBitrate,
    required this.rtt,
    required this.packetLoss,
    required this.networkInterfaces,
    required this.battery,
    required this.signal,
    required this.encodingPreset,
  });

  Map<String, dynamic> toJson() => {
        'type': 'CLIENT_STATUS',
        'reporterId': reporterId,
        'currentBitrate': currentBitrate,
        'targetBitrate': targetBitrate,
        'rtt': rtt,
        'packetLoss': packetLoss,
        'networkInterfaces': networkInterfaces.map((i) => i.toJson()).toList(),
        'battery': battery,
        'signal': signal,
        'encodingPreset': encodingPreset.toJson(),
      };
}

class ClientPongMessage {
  final int timestamp;
  const ClientPongMessage({required this.timestamp});
  Map<String, dynamic> toJson() => {'type': 'CLIENT_PONG', 'timestamp': timestamp};
}

class ClientByeMessage {
  final String reporterId;
  final String? reason;
  const ClientByeMessage({required this.reporterId, this.reason});
  Map<String, dynamic> toJson() => {
        'type': 'CLIENT_BYE',
        'reporterId': reporterId,
        if (reason != null) 'reason': reason,
      };
}

// ── Incoming Messages (Server → Client) ──────────────────────

sealed class ServerMessage {
  const ServerMessage();

  factory ServerMessage.fromJson(Map<String, dynamic> json) {
    return switch (json['type'] as String?) {
      'SERVER_WELCOME'      => ServerWelcomeMessage.fromJson(json),
      'SERVER_REJECT'       => ServerRejectMessage.fromJson(json),
      'SERVER_TALLY'        => ServerTallyMessage.fromJson(json),
      'SERVER_BITRATE_CMD'  => ServerBitrateCommandMessage.fromJson(json),
      'SERVER_IFB_ANSWER'   => ServerIFBAnswerMessage.fromJson(json),
      'SERVER_ICE_CANDIDATE'=> ServerICECandidateMessage.fromJson(json),
      'SERVER_IFB_HANGUP'   => ServerIFBHangupMessage.fromJson(json),
      'SERVER_ERROR'        => ServerErrorMessage.fromJson(json),
      'SERVER_PING'         => ServerPingMessage.fromJson(json),
      _                     => UnknownServerMessage(json),
    };
  }
}

final class ServerWelcomeMessage extends ServerMessage {
  final String sessionId;
  final String reporterId;
  final String srtIngestUrl;
  final int serverTime;

  const ServerWelcomeMessage({
    required this.sessionId,
    required this.reporterId,
    required this.srtIngestUrl,
    required this.serverTime,
  });

  factory ServerWelcomeMessage.fromJson(Map<String, dynamic> j) =>
      ServerWelcomeMessage(
        sessionId: j['sessionId'] as String,
        reporterId: j['reporterId'] as String,
        srtIngestUrl: j['srtIngestUrl'] as String,
        serverTime: j['serverTime'] as int,
      );
}

final class ServerRejectMessage extends ServerMessage {
  final String reason;
  final String code;
  const ServerRejectMessage({required this.reason, required this.code});
  factory ServerRejectMessage.fromJson(Map<String, dynamic> j) =>
      ServerRejectMessage(reason: j['reason'] as String, code: j['code'] as String);
}

final class ServerTallyMessage extends ServerMessage {
  final String reporterId;
  final TallyState state;
  const ServerTallyMessage({required this.reporterId, required this.state});
  factory ServerTallyMessage.fromJson(Map<String, dynamic> j) => ServerTallyMessage(
        reporterId: j['reporterId'] as String,
        state: TallyStateExtension.fromJson(j['state'] as String),
      );
}

final class ServerBitrateCommandMessage extends ServerMessage {
  final String reporterId;
  final int targetBitrate;
  final int maxBitrate;
  final int minBitrate;
  final EncodingPreset encodingPreset;

  const ServerBitrateCommandMessage({
    required this.reporterId,
    required this.targetBitrate,
    required this.maxBitrate,
    required this.minBitrate,
    required this.encodingPreset,
  });

  factory ServerBitrateCommandMessage.fromJson(Map<String, dynamic> j) =>
      ServerBitrateCommandMessage(
        reporterId: j['reporterId'] as String,
        targetBitrate: j['targetBitrate'] as int,
        maxBitrate: j['maxBitrate'] as int,
        minBitrate: j['minBitrate'] as int,
        encodingPreset: EncodingPresetExtension.fromJson(j['encodingPreset'] as String),
      );
}

final class ServerIFBAnswerMessage extends ServerMessage {
  final String reporterId;
  final String sdpAnswer;
  const ServerIFBAnswerMessage({required this.reporterId, required this.sdpAnswer});
  factory ServerIFBAnswerMessage.fromJson(Map<String, dynamic> j) =>
      ServerIFBAnswerMessage(
          reporterId: j['reporterId'] as String, sdpAnswer: j['sdpAnswer'] as String);
}

final class ServerICECandidateMessage extends ServerMessage {
  final String reporterId;
  final Map<String, dynamic> candidate;
  const ServerICECandidateMessage({required this.reporterId, required this.candidate});
  factory ServerICECandidateMessage.fromJson(Map<String, dynamic> j) =>
      ServerICECandidateMessage(
          reporterId: j['reporterId'] as String,
          candidate: j['candidate'] as Map<String, dynamic>);
}

final class ServerIFBHangupMessage extends ServerMessage {
  final String reporterId;
  final String? reason;
  const ServerIFBHangupMessage({required this.reporterId, this.reason});
  factory ServerIFBHangupMessage.fromJson(Map<String, dynamic> j) =>
      ServerIFBHangupMessage(
        reporterId: j['reporterId'] as String,
        reason: j['reason'] as String?,
      );
}

final class ServerErrorMessage extends ServerMessage {
  final String code;
  final String message;
  const ServerErrorMessage({required this.code, required this.message});
  factory ServerErrorMessage.fromJson(Map<String, dynamic> j) =>
      ServerErrorMessage(code: j['code'] as String, message: j['message'] as String);
}

final class ServerPingMessage extends ServerMessage {
  final int timestamp;
  const ServerPingMessage({required this.timestamp});
  factory ServerPingMessage.fromJson(Map<String, dynamic> j) =>
      ServerPingMessage(timestamp: j['timestamp'] as int);
}

final class UnknownServerMessage extends ServerMessage {
  final Map<String, dynamic> raw;
  const UnknownServerMessage(this.raw);
}
