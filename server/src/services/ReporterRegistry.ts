// ============================================================
// SP Smart — Reporter Registry (in-memory session store)
// ============================================================
// In a multi-node deployment, swap this for a Redis-backed store.
// ============================================================
import { EventEmitter } from 'events';
import type { ReporterSession } from '../models/ReporterSession';
import { logger } from '../utils/logger';

export declare interface ReporterRegistry {
  on(event: 'reporter:connected', listener: (session: ReporterSession) => void): this;
  on(event: 'reporter:disconnected', listener: (session: ReporterSession) => void): this;
  on(event: 'reporter:status', listener: (session: ReporterSession) => void): this;
}

export class ReporterRegistry extends EventEmitter {
  /** reporterId → session */
  private readonly sessions = new Map<string, ReporterSession>();

  add(session: ReporterSession): void {
    if (this.sessions.has(session.reporterId)) {
      logger.warn(
        { reporterId: session.reporterId },
        'ReporterRegistry: overwriting existing session (reconnect)'
      );
      this.remove(session.reporterId);
    }
    this.sessions.set(session.reporterId, session);
    logger.info({ reporterId: session.reporterId, displayName: session.displayName }, 'Reporter registered');
    this.emit('reporter:connected', session);
  }

  remove(reporterId: string): void {
    const session = this.sessions.get(reporterId);
    if (!session) return;

    if (session.pingIntervalHandle) {
      clearInterval(session.pingIntervalHandle);
    }
    session.state = 'DISCONNECTED';
    this.sessions.delete(reporterId);
    logger.info({ reporterId }, 'Reporter removed from registry');
    this.emit('reporter:disconnected', session);
  }

  get(reporterId: string): ReporterSession | undefined {
    return this.sessions.get(reporterId);
  }

  getAll(): ReporterSession[] {
    return Array.from(this.sessions.values());
  }

  count(): number {
    return this.sessions.size;
  }

  updateStatus(reporterId: string, session: Partial<ReporterSession>): void {
    const existing = this.sessions.get(reporterId);
    if (!existing) return;
    Object.assign(existing, session, { lastSeenAt: Date.now() });
    this.emit('reporter:status', existing);
  }
}

// Singleton
export const reporterRegistry = new ReporterRegistry();
