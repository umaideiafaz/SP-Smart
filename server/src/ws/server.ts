// ============================================================
// SP Smart — WebSocket Server (Phase 3: dual-path)
// ============================================================
// Two WebSocket paths on the same HTTP server:
//   /ws        → Reporter (Mobile App) connections
//   /ws/studio → Studio Desktop connections
// ============================================================
import { WebSocketServer, WebSocket } from 'ws';
import type { IncomingMessage, Server } from 'http';
import { config } from '../config';
import { logger } from '../utils/logger';
import { reporterRegistry } from '../services/ReporterRegistry';
import { studioRegistry } from '../services/StudioRegistry';
import { ifbSignalingService } from '../services/IFBSignalingService';
import { handleIncomingMessage } from './handler';
import { handleStudioMessage } from './studio_handler';
import { sendRaw } from './utils';

const STUDIO_WS_PATH = `${config.wsPath}/studio`;

export function createWebSocketServer(httpServer: Server): WebSocketServer {
  // ── Reporter WS Server (existing path) ───────────────────
  const wss = new WebSocketServer({
    server: httpServer,
    path:   config.wsPath,
    maxPayload: 256 * 1024,
  });

  // ── Studio WS Server (new path) ──────────────────────────
  const studioWss = new WebSocketServer({
    server: httpServer,
    path:   STUDIO_WS_PATH,
    maxPayload: 256 * 1024,
  });

  wss.on('listening', () => {
    logger.info({ path: config.wsPath }, 'Reporter WebSocket server listening');
  });

  studioWss.on('listening', () => {
    logger.info({ path: STUDIO_WS_PATH }, 'Studio WebSocket server listening');
  });

  // ── Reporter connections ──────────────────────────────────
  wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    const remoteAddr = req.socket.remoteAddress ?? 'unknown';
    logger.info({ remoteAddr }, 'New Reporter WebSocket connection');

    const pendingSession: { reporterId?: string } = {};

    const pingInterval = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) {
        sendRaw(ws, { type: 'SERVER_PING', timestamp: Date.now() });
      }
    }, config.wsHeartbeatIntervalMs);

    const timeoutCheck = setInterval(() => {
      if (!pendingSession.reporterId) return;
      const session = reporterRegistry.get(pendingSession.reporterId);
      if (!session) return;
      const idle = Date.now() - session.lastSeenAt;
      if (idle > config.wsClientTimeoutMs) {
        logger.warn({ reporterId: pendingSession.reporterId, idleMs: idle }, 'Reporter timed out');
        ws.terminate();
      }
    }, config.wsHeartbeatIntervalMs);

    ws.on('message', (data) => {
      if (pendingSession.reporterId) {
        reporterRegistry.updateStatus(pendingSession.reporterId, { lastSeenAt: Date.now() });
      }
      handleIncomingMessage(ws, data as Buffer | string, pendingSession);
    });

    ws.on('close', (code) => {
      clearInterval(pingInterval);
      clearInterval(timeoutCheck);
      if (pendingSession.reporterId) {
        const session = reporterRegistry.get(pendingSession.reporterId);
        if (session) {
          logger.info({ reporterId: pendingSession.reporterId, code }, 'Reporter WS closed');
          // Notify Studio that this reporter left
          ifbSignalingService.onReporterDisconnected(
            pendingSession.reporterId,
            session.displayName,
          );
          reporterRegistry.remove(pendingSession.reporterId);
        }
      }
    });

    ws.on('error', (err) => {
      logger.error({ err, reporterId: pendingSession.reporterId }, 'Reporter WebSocket error');
    });
  });

  // ── Studio connections ────────────────────────────────────
  studioWss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    const remoteAddr = req.socket.remoteAddress ?? 'unknown';
    logger.info({ remoteAddr }, 'New Studio WebSocket connection');

    const pendingStudio: { studioId?: string } = {};

    // Studio also gets heartbeat pings
    const pingInterval = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) {
        sendRaw(ws, { type: 'SERVER_PING', timestamp: Date.now() });
      }
    }, config.wsHeartbeatIntervalMs);

    ws.on('message', (data) => {
      if (pendingStudio.studioId) studioRegistry.touch(pendingStudio.studioId);
      handleStudioMessage(ws, data as Buffer | string, pendingStudio);
    });

    ws.on('close', (code) => {
      clearInterval(pingInterval);
      if (pendingStudio.studioId) {
        logger.info({ studioId: pendingStudio.studioId, code }, 'Studio WS closed');
        studioRegistry.remove(pendingStudio.studioId);
      }
    });

    ws.on('error', (err) => {
      logger.error({ err, studioId: pendingStudio.studioId }, 'Studio WebSocket error');
    });
  });

  wss.on('error', (err) => logger.error({ err }, 'Reporter WSS error'));
  studioWss.on('error', (err) => logger.error({ err }, 'Studio WSS error'));

  return wss;
}
