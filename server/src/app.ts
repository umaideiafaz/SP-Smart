// ============================================================
// SP Smart — Express App Factory
// ============================================================
import express, { type Request, type Response, type NextFunction } from 'express';
import { createServer, type Server } from 'http';
import cors from 'cors';
import { config } from './config';
import { logger } from './utils/logger';
import { tallyRouter } from './routes/api/tally';
import { bitrateRouter } from './routes/api/bitrate';
import { reportersRouter } from './routes/api/reporters';
import { syncRouter } from './routes/api/sync';

export function createApp(): { app: express.Application; httpServer: Server } {
  const app = express();

  // ── CORS ──────────────────────────────────────────────────
  const allowedOrigins = config.corsOrigins.includes('*') ? true : config.corsOrigins;
  app.use(cors({ origin: allowedOrigins, methods: ['GET', 'POST', 'PUT', 'DELETE'] }));

  // ── Body Parsing ──────────────────────────────────────────
  app.use(express.json({ limit: '1mb' }));

  // ── Request Logging ───────────────────────────────────────
  if (config.isDev) {
    app.use((req: Request, _res: Response, next: NextFunction) => {
      logger.debug({ method: req.method, url: req.url }, 'HTTP request');
      next();
    });
  }

  // ── Health Check (used by mobile app's TCP probe + monitoring) ──
  app.get('/health', (_req: Request, res: Response) => {
    res.json({
      status: 'ok',
      service: 'sp-smart-server',
      timestamp: new Date().toISOString(),
      env: config.nodeEnv,
      connectedReporters: require('./services/ReporterRegistry').reporterRegistry.count(),
      uptime: process.uptime(),
    });
  });

  // ── API Routes ────────────────────────────────────────────
  app.use('/api/tally', tallyRouter);
  app.use('/api/bitrate', bitrateRouter);
  app.use('/api/reporters', reportersRouter);
  app.use('/api/sync', syncRouter);

  // ── 404 ───────────────────────────────────────────────────
  app.use((_req: Request, res: Response) => {
    res.status(404).json({ error: 'Not found' });
  });

  // ── Global Error Handler ──────────────────────────────────
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
    logger.error({ err }, 'Unhandled Express error');
    res.status(500).json({ error: 'Internal server error' });
  });

  const httpServer = createServer(app);
  return { app, httpServer };
}
