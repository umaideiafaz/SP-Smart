// ============================================================
// SP Smart — Reporter Session Model
// ============================================================
import type { WebSocket } from 'ws';
import type { EncodingPreset, TallyState, ClientStatusMessage } from '../types/protocol';

export type ReporterConnectionState =
  | 'AUTHENTICATING'
  | 'CONNECTED'
  | 'STREAMING'
  | 'DISCONNECTED';

export interface ReporterSession {
  /** Internal session UUID */
  sessionId: string;
  /** Reporter UUID (stable across reconnects) */
  reporterId: string;
  /** Human-readable name set by the reporter */
  displayName: string;
  /** Stream key used by MediaMTX */
  srtStreamKey: string;
  /** Live WebSocket reference */
  ws: WebSocket;
  /** Current connection state */
  state: ReporterConnectionState;
  /** Current Tally state broadcast by the studio */
  tallyState: TallyState;
  /** Last known encoding preset */
  encodingPreset: EncodingPreset;
  /** Last status snapshot */
  lastStatus: ClientStatusMessage | null;
  /** Timestamp of last message received (for timeout detection) */
  lastSeenAt: number;
  /** Timestamp of connection establishment */
  connectedAt: number;
  /** Interval handle for heartbeat pings */
  pingIntervalHandle: ReturnType<typeof setInterval> | null;
}
