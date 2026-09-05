// ============================================================
// SP Smart — Studio Registry
// ============================================================
// Manages connected Studio Desktop instances via WebSocket.
// In a typical deployment there is ONE Studio, but the registry
// supports multiple (e.g. primary + backup control room).
// ============================================================
import { EventEmitter } from 'events';
import type { WebSocket } from 'ws';
import { logger } from '../utils/logger';

export interface StudioSession {
  studioId:    string;
  sessionId:   string;
  ws:          WebSocket;
  connectedAt: number;
  lastSeenAt:  number;
  capabilities: {
    webrtc:        boolean;
    ndi:           boolean;
    audioCapture:  boolean;
  };
}

class StudioRegistry extends EventEmitter {
  private readonly sessions = new Map<string, StudioSession>();

  add(session: StudioSession): void {
    this.sessions.set(session.studioId, session);
    logger.info({ studioId: session.studioId }, '[StudioRegistry] Studio connected');
    this.emit('studio:connected', session);
  }

  remove(studioId: string): void {
    const s = this.sessions.get(studioId);
    if (s) {
      this.sessions.delete(studioId);
      logger.info({ studioId }, '[StudioRegistry] Studio disconnected');
      this.emit('studio:disconnected', s);
    }
  }

  get(studioId: string): StudioSession | undefined {
    return this.sessions.get(studioId);
  }

  /** Returns the first connected Studio (primary use-case). */
  getPrimary(): StudioSession | undefined {
    return this.sessions.values().next().value;
  }

  getAll(): StudioSession[] {
    return Array.from(this.sessions.values());
  }

  touch(studioId: string): void {
    const s = this.sessions.get(studioId);
    if (s) s.lastSeenAt = Date.now();
  }

  count(): number {
    return this.sessions.size;
  }
}

export const studioRegistry = new StudioRegistry();
