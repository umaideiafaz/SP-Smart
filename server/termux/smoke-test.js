'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const { fork } = require('node:child_process');
const { WebSocket } = require('ws');

const port = 18080;
const secret = 'sp-smart-test-secret';
const child = fork(require.resolve('./server'), [], {
  env: {
    ...process.env,
    HOST: '127.0.0.1',
    PORT: String(port),
    AUTH_SECRET: secret,
    SRT_PUBLIC_HOST: 'srt.example.com',
    SRT_PORT: '8890',
  },
  silent: true,
});

async function main() {
  await waitForHealth();
  assert.equal(await unauthorizedUpgradeStatus(), 401);

  const reporterId = 'smoke-reporter';
  const timestamp = Date.now();
  const authToken = crypto
    .createHmac('sha256', secret)
    .update(`${reporterId}:${timestamp}`)
    .digest('hex');

  const reporter = await connectClient('/ws', {
    type: 'CLIENT_HELLO',
    reporterId,
    displayName: 'Smoke Test',
    authToken,
    timestamp,
    srtStreamKey: 'smoke',
  });
  assert.equal(reporter.welcome.type, 'SERVER_WELCOME');
  assert.equal(reporter.welcome.reporterId, reporterId);
  assert.match(reporter.welcome.srtIngestUrl, /^srt:\/\/srt\.example\.com:8890/);

  const studioId = 'smoke-studio';
  const studioTimestamp = Date.now();
  const studio = await connectClient('/ws/studio', {
    type: 'STUDIO_HELLO',
    studioId,
    authToken: crypto
      .createHmac('sha256', secret)
      .update(`${studioId}:${studioTimestamp}`)
      .digest('hex'),
    timestamp: studioTimestamp,
  });
  assert.equal(studio.welcome.type, 'SERVER_STUDIO_WELCOME');

  const offer = 'v=0\r\na=smoke-offer:unaltered\r\n';
  const relayedOffer = nextMessage(studio.ws);
  reporter.ws.send(JSON.stringify({
    type: 'CLIENT_IFB_REQUEST',
    reporterId,
    sdpOffer: offer,
  }));
  assert.equal((await relayedOffer).sdpOffer, offer);

  const answer = 'v=0\r\na=smoke-answer:unaltered\r\n';
  const relayedAnswer = nextMessage(reporter.ws);
  studio.ws.send(JSON.stringify({
    type: 'STUDIO_IFB_ANSWER',
    targetReporterId: reporterId,
    sdpAnswer: answer,
  }));
  assert.equal((await relayedAnswer).sdpAnswer, answer);
  reporter.ws.close();
  studio.ws.close();
  console.log('Termux signaling smoke test passed');
}

function waitForHealth() {
  return new Promise((resolve, reject) => {
    let attempts = 0;
    const tryOnce = () => {
      const request = http.get(`http://127.0.0.1:${port}/health`, (response) => {
        response.resume();
        if (response.statusCode === 200) resolve();
        else retry();
      });
      request.on('error', retry);
    };
    const retry = () => {
      if (++attempts > 30) reject(new Error('Server did not become healthy'));
      else setTimeout(tryOnce, 100);
    };
    tryOnce();
  });
}

function unauthorizedUpgradeStatus() {
  return new Promise((resolve, reject) => {
    const request = http.request({
      host: '127.0.0.1',
      port,
      path: '/ws',
      headers: { Connection: 'Upgrade', Upgrade: 'websocket' },
    });
    request.on('response', (response) => {
      response.resume();
      resolve(response.statusCode);
    });
    request.on('error', reject);
    request.end();
  });
}

function connectClient(path, hello) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`, {
      headers: { Authorization: `Bearer ${secret}` },
    });
    ws.once('open', () => ws.send(JSON.stringify(hello)));
    ws.once('message', (raw) => {
      resolve({ ws, welcome: JSON.parse(raw.toString()) });
    });
    ws.once('error', reject);
  });
}

function nextMessage(ws) {
  return new Promise((resolve) => {
    ws.once('message', (raw) => resolve(JSON.parse(raw.toString())));
  });
}

main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => child.kill('SIGTERM'));
