// ============================================================
// SP Smart — Tally Service
// ============================================================
// Manages and distributes Tally (PGM/PVW/IDLE) state changes.
// The studio triggers state changes via the REST API; this
// service fans out the change to the correct reporter via WS.
// ============================================================
import { EventEmitter } from 'events';
import type { TallyState } from '../types/protocol';
import { reporterRegistry } from './ReporterRegistry';
import { sendToReporter } from '../ws/utils';
import { logger } from '../utils/logger';

export declare interface TallyService {
  on(event: 'tally:changed', listener: (reporterId: string, state: TallyState) => void): this;
}

export class TallyService extends EventEmitter {
  /**
   * Sets the tally state for a specific reporter and pushes
   * the update to the reporter's WebSocket connection.
   */
  setTally(reporterId: string, state: TallyState): boolean {
    const session = reporterRegistry.get(reporterId);
    if (!session) {
      logger.warn({ reporterId, state }, 'TallyService: reporter not found');
      return false;
    }

    const prev = session.tallyState;
    if (prev === state) {
      logger.debug({ reporterId, state }, 'TallyService: no state change, skipping');
      return true;
    }

    reporterRegistry.updateStatus(reporterId, { tallyState: state });

    const sent = sendToReporter(session, {
      type: 'SERVER_TALLY',
      reporterId,
      state,
    });

    if (sent) {
      logger.info({ reporterId, prev, state }, 'Tally updated');
      this.emit('tally:changed', reporterId, state);
    }

    return sent;
  }

  /**
   * Broadcasts a tally state to ALL connected reporters.
   * Useful for "ALL CLEAR" or emergency scenarios.
   */
  broadcastTally(state: TallyState): void {
    const reporters = reporterRegistry.getAll();
    logger.info({ state, count: reporters.length }, 'Broadcasting tally to all reporters');
    for (const session of reporters) {
      this.setTally(session.reporterId, state);
    }
  }

  getTally(reporterId: string): TallyState | null {
    return reporterRegistry.get(reporterId)?.tallyState ?? null;
  }
}

export const tallyService = new TallyService();
