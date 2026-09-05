// ============================================================
// SP Smart — Shared Message Protocol Types
// ============================================================
// All WebSocket messages exchanged between App ↔ Server follow
// this discriminated-union pattern, making exhaustive handling
// trivial in both TypeScript and Dart (via code-gen).
// ============================================================

// ── Tally State ──────────────────────────────────────────────
export type TallyState = 'PGM' | 'PVW' | 'IDLE';

// ── Direction ───────────────────────────────────────────────
export type MessageDirection = 'server→client' | 'client→server' | 'bidirectional';

// ── WebRTC helpers (avoid dependency on @types/webrtc) ───────
export interface RTCIceCandidateInit {
  candidate?: string;
  sdpMid?: string | null;
  sdpMLineIndex?: number | null;
  usernameFragment?: string | null;
}

// ============================================================
// Messages: CLIENT → SERVER
// ============================================================

/** Reporter app authenticates and registers its SRT stream */
export interface ClientHelloMessage {
  type: 'CLIENT_HELLO';
  reporterId: string;   // UUID assigned by the app on first launch
  displayName: string;  // e.g. "Reporter São Paulo"
  authToken: string;    // HMAC-SHA256 of (reporterId + timestamp) using AUTH_SECRET
  timestamp: number;    // Unix ms — used to prevent replay attacks (±30 s window)
  srtStreamKey: string; // Stream key expected by MediaMTX, e.g. "reporter-sp-001"
  capabilities: {
    srt: boolean;
    webrtc: boolean;
    hevc: boolean;
  };
}

/** Reporter sends periodic status updates */
export interface ClientStatusMessage {
  type: 'CLIENT_STATUS';
  reporterId: string;
  currentBitrate: number; // kbps
  targetBitrate: number;  // kbps
  rtt: number;            // ms
  packetLoss: number;     // 0.0 – 1.0
  networkInterfaces: NetworkInterfaceInfo[];
  battery: number;        // 0–100 %
  signal: number;         // RSSI or arbitrary 0–5 bars
  encodingPreset: EncodingPreset;
}

/** Reporter requests an IFB (Interruptible FoldBack) mix */
export interface ClientIFBRequestMessage {
  type: 'CLIENT_IFB_REQUEST';
  reporterId: string;
  // WebRTC SDP offer from the app's IFB receiver
  sdpOffer: string;
}

/** Reporter forwards an ICE candidate for WebRTC signaling */
export interface ClientICECandidateMessage {
  type: 'CLIENT_ICE_CANDIDATE';
  reporterId: string;
  candidate: RTCIceCandidateInit;
  /** 'ifb' = IFB audio/video return; future-proof for other WebRTC sessions */
  sessionType?: 'ifb';
}

/** Reporter disconnecting gracefully */
export interface ClientByeMessage {
  type: 'CLIENT_BYE';
  reporterId: string;
  reason?: string;
}

// ============================================================
// Messages: SERVER → CLIENT
// ============================================================

/** Server acknowledges the hello and provides session info */
export interface ServerWelcomeMessage {
  type: 'SERVER_WELCOME';
  sessionId: string;    // UUID for this session
  reporterId: string;
  srtIngestUrl: string; // srt://<host>:<port>?streamid=<key>
  serverTime: number;   // Unix ms for clock sync
}

/** Server rejects the connection */
export interface ServerRejectMessage {
  type: 'SERVER_REJECT';
  reason: string;
  code: ServerRejectCode;
}

/** Studio sends Tally state change */
export interface ServerTallyMessage {
  type: 'SERVER_TALLY';
  reporterId: string;
  state: TallyState;
  // Optional: color override for custom indicators
  color?: { r: number; g: number; b: number };
}

/** Studio requests a bitrate change */
export interface ServerBitrateCommandMessage {
  type: 'SERVER_BITRATE_CMD';
  reporterId: string;
  targetBitrate: number;       // kbps
  maxBitrate: number;          // kbps ceiling
  minBitrate: number;          // kbps floor
  encodingPreset: EncodingPreset;
}

/**
 * Server forwards the Studio's SDP answer to the mobile.
 * The mobile applied this answer to complete WebRTC negotiation.
 */
export interface ServerIFBAnswerMessage {
  type: 'SERVER_IFB_ANSWER';
  reporterId: string;
  sdpAnswer: string;
}

/** Server forwards an ICE candidate from Studio → Mobile */
export interface ServerICECandidateMessage {
  type: 'SERVER_ICE_CANDIDATE';
  reporterId: string;
  candidate: RTCIceCandidateInit;
  sessionType?: 'ifb';
}

/** Server notifies mobile that IFB session was terminated by Studio */
export interface ServerIFBHangupMessage {
  type: 'SERVER_IFB_HANGUP';
  reporterId: string;
  reason?: string;
}

/** Generic error from server */
export interface ServerErrorMessage {
  type: 'SERVER_ERROR';
  code: string;
  message: string;
}

/** Heartbeat ping from server */
export interface ServerPingMessage {
  type: 'SERVER_PING';
  timestamp: number;
}

/** Heartbeat pong expected back from client */
export interface ClientPongMessage {
  type: 'CLIENT_PONG';
  timestamp: number;
}

// ============================================================
// Messages: STUDIO → SERVER  (Studio Desktop role)
// ============================================================

/**
 * Studio Desktop authenticates with the signaling server.
 * Uses the same AUTH_SECRET as reporters but with a dedicated studioId.
 */
export interface StudioHelloMessage {
  type: 'STUDIO_HELLO';
  studioId: string;
  authToken: string;
  timestamp: number;
  capabilities: {
    webrtc: boolean;
    ndi: boolean;
    audioCapture: boolean;
  };
}

/**
 * Studio answers the mobile's SDP offer.
 * Flow: Mobile OFFERS → Server routes → Studio ANSWERS.
 */
export interface StudioIFBAnswerMessage {
  type: 'STUDIO_IFB_ANSWER';
  targetReporterId: string;
  sdpAnswer: string;
}

/** Studio initiates IFB push to a reporter (Studio-driven mode) */
export interface StudioIFBOfferMessage {
  type: 'STUDIO_IFB_OFFER';
  targetReporterId: string;
  sdpOffer: string;
}

/** Studio forwards an ICE candidate for a reporter's session */
export interface StudioICECandidateMessage {
  type: 'STUDIO_ICE_CANDIDATE';
  targetReporterId: string;
  candidate: RTCIceCandidateInit;
}

/** Studio hangs up IFB for a reporter */
export interface StudioIFBHangupMessage {
  type: 'STUDIO_IFB_HANGUP';
  targetReporterId: string;
  reason?: string;
}

// ============================================================
// Messages: SERVER → STUDIO
// ============================================================

/** Server acknowledges Studio connection */
export interface ServerStudioWelcomeMessage {
  type: 'SERVER_STUDIO_WELCOME';
  studioId: string;
  sessionId: string;
  serverTime: number;
}

/** Server forwards a reporter's SDP offer to the Studio */
export interface ServerReporterOfferMessage {
  type: 'SERVER_REPORTER_OFFER';
  reporterId: string;
  displayName: string;
  sdpOffer: string;
}

/** Server forwards a reporter's ICE candidate to the Studio */
export interface ServerReporterICEMessage {
  type: 'SERVER_REPORTER_ICE';
  reporterId: string;
  candidate: RTCIceCandidateInit;
}

/** Server notifies Studio that a reporter disconnected */
export interface ServerReporterLeftMessage {
  type: 'SERVER_REPORTER_LEFT';
  reporterId: string;
  displayName: string;
}

// ============================================================
// Supporting types
// ============================================================

export interface NetworkInterfaceInfo {
  name: string;        // e.g. "wlan0", "rmnet0"
  type: 'wifi' | 'cellular' | 'ethernet' | 'unknown';
  active: boolean;
  bandwidthEstimate: number; // kbps
}

export type EncodingPreset =
  | 'LOW_LATENCY_SD'    // 480p, ~1 Mbps, <200 ms
  | 'LOW_LATENCY_HD'    // 720p, ~3 Mbps, <200 ms
  | 'QUALITY_HD'        // 720p, ~5 Mbps, <500 ms
  | 'QUALITY_FHD'       // 1080p, ~8 Mbps, <500 ms
  | 'QUALITY_FHD_HIGH'; // 1080p, ~15 Mbps, <1 s

export type ServerRejectCode =
  | 'INVALID_TOKEN'
  | 'REPLAY_ATTACK'
  | 'REPORTER_ALREADY_CONNECTED'
  | 'SERVER_FULL'
  | 'UNKNOWN';

// ── Union types for switch exhaustion ──────────────────────
export type ClientMessage =
  | ClientHelloMessage
  | ClientStatusMessage
  | ClientIFBRequestMessage
  | ClientICECandidateMessage
  | ClientByeMessage
  | ClientPongMessage;

export type ServerMessage =
  | ServerWelcomeMessage
  | ServerRejectMessage
  | ServerTallyMessage
  | ServerBitrateCommandMessage
  | ServerIFBAnswerMessage
  | ServerICECandidateMessage
  | ServerIFBHangupMessage
  | ServerErrorMessage
  | ServerPingMessage;

export type StudioMessage =
  | StudioHelloMessage
  | StudioIFBAnswerMessage
  | StudioIFBOfferMessage
  | StudioICECandidateMessage
  | StudioIFBHangupMessage;

export type ServerToStudioMessage =
  | ServerStudioWelcomeMessage
  | ServerReporterOfferMessage
  | ServerReporterICEMessage
  | ServerReporterLeftMessage
  | ServerPingMessage;

export type AnyMessage = ClientMessage | ServerMessage | StudioMessage | ServerToStudioMessage;
