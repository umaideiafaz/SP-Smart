import type { WebSocket } from 'ws';
import { v4 as uuidv4 } from 'uuid';
import type { ClientMessage } from '../types/protocol';
import type { ReporterSession } from '../models/ReporterSession';
import { reporterRegistry } from '../services/ReporterRegistry';
import { validateAuthToken } from '../services/AuthService';
import { ifbSignalingService } from '../services/IFBSignalingService';
import { config } from '../config';
import { logger } from '../utils/logger';
import { sendRaw, parseIncomingMessage } from './utils';

export function handleIncomingMessage(
  ws: WebSocket,
  rawData: Buffer | string,
  pendingSession: { reporterId?: string }
): void {
  const payload = parseIncomingMessage(rawData);
  if (!payload || typeof payload !== 'object') return;

  const msg = payload as ClientMessage;

  switch (msg.type) {
    case 'CLIENT_HELLO':
      handleHello(ws, msg, pendingSession);
      break;

    case 'CLIENT_STATUS': {
      const session = reporterRegistry.get(msg.reporterId);
      if (!session) return;
      reporterRegistry.updateStatus(msg.reporterId, { lastStatus: msg, lastSeenAt: Date.now() });
      logger.debug(
        { reporterId: msg.reporterId, bitrate: msg.currentBitrate, rtt: msg.rtt },
        'Status update received'
      );
      break;
    }

    case 'CLIENT_IFB_REQUEST': {
      const session = reporterRegistry.get(msg.reporterId);
      if (!session) return;
      logger.info({ reporterId: msg.reporterId }, 'IFB SDP offer received — routing to Studio');
      ifbSignalingService.onMobileIFBRequest(msg.reporterId, msg.sdpOffer);
      break;
    }

    case 'CLIENT_ICE_CANDIDATE': {
      const session = reporterRegistry.get(msg.reporterId);
      if (!session) return;
      logger.debug({ reporterId: msg.reporterId, sessionType: msg.sessionType }, 'ICE candidate received');
      ifbSignalingService.onMobileICECandidate(msg.reporterId, msg.candidate);
      break;
    }

    case 'CLIENT_PONG': {
      if (pendingSession.reporterId) {
        reporterRegistry.updateStatus(pendingSession.reporterId, { lastSeenAt: Date.now() });
      }
      break;
    }

    case 'CLIENT_BYE': {
      const session = reporterRegistry.get(msg.reporterId);
      if (session) {
        logger.info({ reporterId: msg.reporterId, reason: msg.reason }, 'Reporter sent BYE');
        ifbSignalingService.onReporterDisconnected(msg.reporterId, session.displayName);
        reporterRegistry.remove(msg.reporterId);
      }
      ws.close(1000, 'Client requested disconnect');
      break;
    }

    default: {
      const unknown = payload as { type?: string };
      logger.warn({ type: unknown.type }, 'Unknown message type received');
      sendRaw(ws, {
        type: 'SERVER_ERROR',
        code: 'UNKNOWN_MESSAGE_TYPE',
        message: `Unknown message type: ${unknown.type ?? 'undefined'}`,
      });
    }
  }
}

// ── Private: Handle CLIENT_HELLO ─────────────────────────────

function handleHello(
  ws: WebSocket,
  msg: Extract<ClientMessage, { type: 'CLIENT_HELLO' }>,
  pendingSession: { reporterId?: string }
): void {
  // 1. Auth
  const valid = validateAuthToken(msg.reporterId, msg.timestamp, msg.authToken);
  if (!valid) {
    sendRaw(ws, { type: 'SERVER_REJECT', reason: 'Authentication failed', code: 'INVALID_TOKEN' });
    ws.close(4001, 'Unauthorized');
    return;
  }

  // 2. Duplicate check
  if (reporterRegistry.get(msg.reporterId)) {
    sendRaw(ws, {
      type: 'SERVER_REJECT',
      reason: 'Reporter already connected',
      code: 'REPORTER_ALREADY_CONNECTED',
    });
    ws.close(4002, 'Already connected');
    return;
  }

  // 3. Build session
  const sessionId = uuidv4();
  const now = Date.now();

  const session: ReporterSession = {
    sessionId,
    reporterId: msg.reporterId,
    displayName: msg.displayName,
    srtStreamKey: msg.srtStreamKey,
    ws,
    state: 'CONNECTED',
    tallyState: 'IDLE',
    encodingPreset: 'LOW_LATENCY_HD',
    lastStatus: null,
    lastSeenAt: now,
    connectedAt: now,
    pingIntervalHandle: null,
  };

  reporterRegistry.add(session);
  pendingSession.reporterId = msg.reporterId;

  // 4. Send welcome
  const srtIngestUrl =
    `srt://${config.host === '0.0.0.0' ? 'SERVER_IP' : config.host}:${config.mediaMtx.srtPort}` +
    `?streamid=${msg.srtStreamKey}`;

  sendRaw(ws, {
    type: 'SERVER_WELCOME',
    sessionId,
    reporterId: msg.reporterId,
    srtIngestUrl,
    serverTime: now,
  });

  logger.info(
    { reporterId: msg.reporterId, displayName: msg.displayName, sessionId, srtIngestUrl },
    'Reporter authenticated and session created'
  );
}
