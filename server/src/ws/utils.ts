// ============================================================
// SP Smart — WebSocket Utilities
// ============================================================
import type { WebSocket } from 'ws';
import type { ReporterSession } from '../models/ReporterSession';
import type { ServerMessage } from '../types/protocol';
import { logger } from '../utils/logger';

/**
 * Sends a typed server message to a reporter.
 * @returns true if the message was delivered to the socket buffer.
 */
export function sendToReporter(
  session: ReporterSession,
  message: ServerMessage
): boolean {
  if (session.ws.readyState !== 1 /* WebSocket.OPEN */) {
    logger.warn(
      { reporterId: session.reporterId, readyState: session.ws.readyState },
      'Cannot send to reporter: socket not open'
    );
    return false;
  }

  try {
    session.ws.send(JSON.stringify(message));
    return true;
  } catch (err) {
    logger.error(
      { err, reporterId: session.reporterId, messageType: message.type },
      'Failed to send message to reporter'
    );
    return false;
  }
}

/**
 * Sends a raw typed message to any open WebSocket.
 */
export function sendRaw(ws: WebSocket, message: ServerMessage): boolean {
  if (ws.readyState !== 1) return false;
  try {
    ws.send(JSON.stringify(message));
    return true;
  } catch {
    return false;
  }
}

/**
 * Safely parses an incoming WebSocket message buffer.
 * Returns null and logs if the payload is invalid.
 */
export function parseIncomingMessage(raw: string | Buffer): unknown | null {
  try {
    const text = typeof raw === 'string' ? raw : raw.toString('utf8');
    return JSON.parse(text);
  } catch (err) {
    logger.warn({ err }, 'Failed to parse incoming WebSocket message');
    return null;
  }
}
