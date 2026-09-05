// ============================================================
// SP Smart Broadcast — Signaling Server Entry Point
// ============================================================
import 'dotenv/config';
import { createApp } from './app';
import { createWebSocketServer } from './ws/server';
import { logger } from './utils/logger';
import { config } from './config';

async function bootstrap(): Promise<void> {
  const { httpServer } = createApp();

  // Attach the WebSocket signaling server to the same HTTP server
  createWebSocketServer(httpServer);

  httpServer.listen(config.port, config.host, () => {
    logger.info(
      { host: config.host, port: config.port, env: config.nodeEnv },
      '🚀 SP Smart Signaling Server is running'
    );
    logger.info(`   WebSocket endpoint : ws://${config.host}:${config.port}${config.wsPath}`);
    logger.info(`   HTTP REST endpoint : http://${config.host}:${config.port}/api`);
    logger.info(`   Health check       : http://${config.host}:${config.port}/health`);
  });

  // ── Graceful shutdown ─────────────────────────────────────
  const shutdown = (signal: string) => {
    logger.warn({ signal }, 'Received shutdown signal, closing server...');
    httpServer.close(() => {
      logger.info('HTTP server closed');
      process.exit(0);
    });
    // Force-kill if server doesn't close in 10 s
    setTimeout(() => process.exit(1), 10_000);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

bootstrap().catch((err) => {
  logger.error({ err }, 'Fatal error during bootstrap');
  process.exit(1);
});
