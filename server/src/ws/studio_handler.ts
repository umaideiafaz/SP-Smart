// ============================================================
// SP Smart — Studio WebSocket Handler
// ============================================================
// Handles messages from the Studio Desktop application.
// The Studio connects to ws://<host>/ws/studio (separate path).
// ============================================================
import type { WebSocket } from 'ws';
import { v4 as uuidv4 } from 'uuid';
import { studioRegistry } from '../services/StudioRegistry';
import { ifbSignalingService } from '../services/IFBSignalingService';
import { validateAuthToken } from '../services/AuthService';
import { logger } from '../utils/logger';
import { sendRaw, parseIncomingMessage } from './utils';
import type { StudioMessage } from '../types/protocol';

export function handleStudioMessage(
  ws: WebSocket,
  rawData: Buffer | string,
  pendingStudio: { studioId?: string },
): void {
  const payload = parseIncomingMessage(rawData);
  if (!payload || typeof payload !== 'object') return;

  const msg = payload as StudioMessage;

  switch (msg.type) {

    case 'STUDIO_HELLO':
      handleStudioHello(ws, msg, pendingStudio);
      break;

    case 'STUDIO_IFB_ANSWER': {
      if (!pendingStudio.studioId) return;
      logger.debug(
        { studioId: pendingStudio.studioId, target: msg.targetReporterId },
        '[Studio] SDP answer received → routing to mobile',
      );
      ifbSignalingService.onStudioIFBAnswer(msg.targetReporterId, msg.sdpAnswer);
      break;
    }

    case 'STUDIO_IFB_OFFER': {
      if (!pendingStudio.studioId) return;
      logger.debug(
        { studioId: pendingStudio.studioId, target: msg.targetReporterId },
        '[Studio] SDP offer (push mode) → routing to mobile',
      );
      ifbSignalingService.onStudioIFBOffer(msg.targetReporterId, msg.sdpOffer);
      break;
    }

    case 'STUDIO_ICE_CANDIDATE': {
      if (!pendingStudio.studioId) return;
      ifbSignalingService.onStudioICECandidate(msg.targetReporterId, msg.candidate);
      break;
    }

    case 'STUDIO_IFB_HANGUP': {
      if (!pendingStudio.studioId) return;
      logger.info(
        { studioId: pendingStudio.studioId, target: msg.targetReporterId },
        '[Studio] IFB hangup',
      );
      ifbSignalingService.onStudioIFBHangup(msg.targetReporterId, msg.reason);
      break;
    }

    default: {
      const unknown = payload as { type?: string };
      logger.warn({ type: unknown.type }, '[Studio] Unknown message type');
      sendRaw(ws, {
        type:    'SERVER_ERROR',
        code:    'UNKNOWN_MESSAGE_TYPE',
        message: `Unknown studio message type: ${unknown.type ?? 'undefined'}`,
      });
    }
  }
}

// ── Private ──────────────────────────────────────────────────

function handleStudioHello(
  ws: WebSocket,
  msg: Extract<StudioMessage, { type: 'STUDIO_HELLO' }>,
  pendingStudio: { studioId?: string },
): void {
  // Authenticate using same HMAC mechanism as reporters
  const valid = validateAuthToken(msg.studioId, msg.timestamp, msg.authToken);
  if (!valid) {
    sendRaw(ws, { type: 'SERVER_ERROR', code: 'INVALID_TOKEN', message: 'Studio authentication failed' });
    ws.close(4001, 'Unauthorized');
    return;
  }

  const sessionId = uuidv4();

  studioRegistry.add({
    studioId:     msg.studioId,
    sessionId,
    ws,
    connectedAt:  Date.now(),
    lastSeenAt:   Date.now(),
    capabilities: msg.capabilities,
  });

  pendingStudio.studioId = msg.studioId;

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  sendRaw(ws, {
    type:       'SERVER_STUDIO_WELCOME',
    studioId:   msg.studioId,
    sessionId,
    serverTime: Date.now(),
  } as any);

  logger.info(
    { studioId: msg.studioId, sessionId, capabilities: msg.capabilities },
    '[Studio] Authenticated and registered',
  );
}
