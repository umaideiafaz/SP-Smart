'use strict';

// SP Smart - signaling enxuto para Termux/Android ARM64.
// O Cloudflare Tunnel termina TLS e encaminha para http://127.0.0.1:8080.
// Este processo apenas autentica e retransmite envelopes; SDP e ICE nunca sao
// interpretados, reescritos ou armazenados.

const crypto = require('node:crypto');
const http = require('node:http');
const { WebSocket, WebSocketServer } = require('ws');

const HOST = process.env.HOST || '127.0.0.1';
const PORT = parsePort(process.env.PORT || '8080');
const AUTH_SECRET = process.env.AUTH_SECRET || '';
const SRT_PUBLIC_HOST = process.env.SRT_PUBLIC_HOST || '';
const SRT_PORT = parsePort(process.env.SRT_PORT || '8890');
const MAX_CLOCK_SKEW_MS = 30_000;
const HEARTBEAT_MS = 5_000;
const CLIENT_TIMEOUT_MS = 15_000;

if (AUTH_SECRET.length < 10 || AUTH_SECRET.length > 79) {
  throw new Error('AUTH_SECRET deve ter entre 10 e 79 caracteres');
}
if (!/^[A-Za-z0-9._~-]+$/.test(AUTH_SECRET)) {
  throw new Error('AUTH_SECRET deve usar apenas letras, numeros e . _ ~ -');
}
if (!/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i.test(SRT_PUBLIC_HOST)) {
  throw new Error('SRT_PUBLIC_HOST deve ser um hostname DNS com alcance UDP direto');
}

const reporters = new Map();
const studios = new Map();

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: true, reporters: reporters.size, studios: studios.size }));
    return;
  }
  res.writeHead(404).end();
});

const reporterWss = new WebSocketServer({ noServer: true, maxPayload: 256 * 1024 });
const studioWss = new WebSocketServer({ noServer: true, maxPayload: 256 * 1024 });

server.on('upgrade', (req, socket, head) => {
  const pathname = safePathname(req.url);
  if (pathname !== '/ws' && pathname !== '/ws/studio') {
    rejectUpgrade(socket, 404, 'Not Found');
    return;
  }
  if (!hasValidBearer(req.headers.authorization)) {
    rejectUpgrade(socket, 401, 'Unauthorized');
    return;
  }

  const selected = pathname === '/ws' ? reporterWss : studioWss;
  selected.handleUpgrade(req, socket, head, (ws) => {
    selected.emit('connection', ws, req);
  });
});

reporterWss.on('connection', (ws) => bindReporter(ws));
studioWss.on('connection', (ws) => bindStudio(ws));

function bindReporter(ws) {
  const session = { id: null, displayName: '', lastSeenAt: Date.now() };

  ws.on('message', (raw, isBinary) => {
    if (isBinary) return closePolicy(ws, 'JSON text required');
    const message = parseMessage(raw);
    if (!message) return send(ws, { type: 'SERVER_ERROR', code: 'BAD_JSON', message: 'Invalid message' });
    session.lastSeenAt = Date.now();

    if (!session.id) {
      if (message.type !== 'CLIENT_HELLO') return closePolicy(ws, 'CLIENT_HELLO required');
      if (!validHello(message.reporterId, message.timestamp, message.authToken)) {
        send(ws, { type: 'SERVER_REJECT', code: 'INVALID_TOKEN', reason: 'Authentication failed' });
        return ws.close(1008, 'Authentication failed');
      }
      if (reporters.has(message.reporterId)) {
        send(ws, { type: 'SERVER_REJECT', code: 'REPORTER_ALREADY_CONNECTED', reason: 'Reporter already connected' });
        return ws.close(1008, 'Reporter already connected');
      }
      session.id = message.reporterId;
      session.displayName = String(message.displayName || 'Reporter').slice(0, 128);
      reporters.set(session.id, { ws, session });
      send(ws, {
        type: 'SERVER_WELCOME',
        sessionId: crypto.randomUUID(),
        reporterId: session.id,
        srtIngestUrl: `srt://${SRT_PUBLIC_HOST}:${SRT_PORT}?streamid=${encodeURIComponent(String(message.srtStreamKey || ''))}`,
        serverTime: Date.now(),
      });
      return;
    }

    switch (message.type) {
      case 'CLIENT_IFB_REQUEST':
        broadcastStudios({
          type: 'SERVER_REPORTER_OFFER',
          reporterId: session.id,
          displayName: session.displayName,
          sdpOffer: message.sdpOffer,
        });
        break;
      case 'CLIENT_ICE_CANDIDATE':
        broadcastStudios({
          type: 'SERVER_REPORTER_ICE',
          reporterId: session.id,
          candidate: message.candidate,
        });
        break;
      case 'CLIENT_STATUS':
        broadcastStudios(message);
        break;
      case 'CLIENT_PONG':
        break;
      case 'CLIENT_BYE':
        ws.close(1000, 'Client bye');
        break;
      default:
        send(ws, { type: 'SERVER_ERROR', code: 'UNKNOWN_TYPE', message: 'Unsupported message type' });
    }
  });

  ws.on('close', () => {
    if (!session.id || reporters.get(session.id)?.ws !== ws) return;
    reporters.delete(session.id);
    broadcastStudios({
      type: 'SERVER_REPORTER_LEFT',
      reporterId: session.id,
      displayName: session.displayName,
    });
  });
  ws.on('error', () => {});
}

function bindStudio(ws) {
  const session = { id: null, lastSeenAt: Date.now() };

  ws.on('message', (raw, isBinary) => {
    if (isBinary) return closePolicy(ws, 'JSON text required');
    const message = parseMessage(raw);
    if (!message) return send(ws, { type: 'SERVER_ERROR', code: 'BAD_JSON', message: 'Invalid message' });
    session.lastSeenAt = Date.now();

    if (!session.id) {
      if (message.type !== 'STUDIO_HELLO') return closePolicy(ws, 'STUDIO_HELLO required');
      if (!validHello(message.studioId, message.timestamp, message.authToken)) {
        return ws.close(1008, 'Authentication failed');
      }
      session.id = message.studioId;
      const previous = studios.get(session.id);
      if (previous && previous.ws !== ws) previous.ws.close(1008, 'Replaced');
      studios.set(session.id, { ws, session });
      send(ws, {
        type: 'SERVER_STUDIO_WELCOME',
        studioId: session.id,
        sessionId: crypto.randomUUID(),
        serverTime: Date.now(),
      });
      return;
    }

    switch (message.type) {
      case 'STUDIO_IFB_ANSWER':
        sendToReporter(message.targetReporterId, {
          type: 'SERVER_IFB_ANSWER',
          reporterId: message.targetReporterId,
          sdpAnswer: message.sdpAnswer,
        });
        break;
      case 'STUDIO_IFB_OFFER':
        sendToReporter(message.targetReporterId, {
          type: 'SERVER_IFB_ANSWER',
          reporterId: message.targetReporterId,
          sdpAnswer: message.sdpOffer,
        });
        break;
      case 'STUDIO_ICE_CANDIDATE':
        sendToReporter(message.targetReporterId, {
          type: 'SERVER_ICE_CANDIDATE',
          reporterId: message.targetReporterId,
          candidate: message.candidate,
          sessionType: 'ifb',
        });
        break;
      case 'STUDIO_IFB_HANGUP':
        sendToReporter(message.targetReporterId, {
          type: 'SERVER_IFB_HANGUP',
          reporterId: message.targetReporterId,
          reason: message.reason,
        });
        break;
      case 'SERVER_TALLY':
      case 'SERVER_BITRATE_CMD':
        sendToReporter(message.reporterId, message);
        break;
      case 'CLIENT_PONG':
        break;
      default:
        send(ws, { type: 'SERVER_ERROR', code: 'UNKNOWN_TYPE', message: 'Unsupported message type' });
    }
  });

  ws.on('close', () => {
    if (session.id && studios.get(session.id)?.ws === ws) studios.delete(session.id);
  });
  ws.on('error', () => {});
}

function validHello(id, timestamp, token) {
  if (typeof id !== 'string' || id.length < 1 || id.length > 128) return false;
  if (!Number.isSafeInteger(timestamp) || Math.abs(Date.now() - timestamp) > MAX_CLOCK_SKEW_MS) return false;
  if (typeof token !== 'string' || !/^[a-f0-9]{64}$/i.test(token)) return false;
  const expected = crypto.createHmac('sha256', AUTH_SECRET).update(`${id}:${timestamp}`).digest('hex');
  return safeEqual(token.toLowerCase(), expected);
}

function hasValidBearer(header) {
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return false;
  const token = header.slice(7);
  return token.length === AUTH_SECRET.length && safeEqual(token, AUTH_SECRET);
}

function safeEqual(left, right) {
  const a = Buffer.from(left, 'utf8');
  const b = Buffer.from(right, 'utf8');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function parseMessage(raw) {
  try {
    const value = JSON.parse(raw.toString('utf8'));
    return value && typeof value === 'object' && !Array.isArray(value) && typeof value.type === 'string'
      ? value
      : null;
  } catch (_) {
    return null;
  }
}

function send(ws, message) {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
}

function sendToReporter(reporterId, message) {
  if (typeof reporterId !== 'string') return;
  const reporter = reporters.get(reporterId);
  if (reporter) send(reporter.ws, message);
}

function broadcastStudios(message) {
  for (const studio of studios.values()) send(studio.ws, message);
}

function closePolicy(ws, reason) {
  ws.close(1008, reason);
}

function safePathname(rawUrl) {
  try {
    return new URL(rawUrl || '/', 'http://localhost').pathname;
  } catch (_) {
    return '';
  }
}

function rejectUpgrade(socket, status, message) {
  socket.write(`HTTP/1.1 ${status} ${message}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  socket.destroy();
}

function parsePort(value) {
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    throw new Error(`Porta alta invalida: ${value}`);
  }
  return port;
}

const heartbeat = setInterval(() => {
  const now = Date.now();
  for (const { ws, session } of [...reporters.values(), ...studios.values()]) {
    if (now - session.lastSeenAt > CLIENT_TIMEOUT_MS) ws.terminate();
    else send(ws, { type: 'SERVER_PING', timestamp: now });
  }
}, HEARTBEAT_MS);
heartbeat.unref();

server.listen(PORT, HOST, () => {
  console.log(`SP Smart signaling ativo em http://${HOST}:${PORT}`);
});

function shutdown() {
  clearInterval(heartbeat);
  for (const { ws } of [...reporters.values(), ...studios.values()]) ws.close(1001, 'Server shutdown');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5_000).unref();
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
