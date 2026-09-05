// ============================================================
// SP Smart — Server Configuration (validated via Zod)
// ============================================================
import { z } from 'zod';

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'production', 'test']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  HOST: z.string().default('0.0.0.0'),

  WS_PATH: z.string().default('/ws'),
  WS_HEARTBEAT_INTERVAL_MS: z.coerce.number().int().positive().default(5000),
  WS_CLIENT_TIMEOUT_MS: z.coerce.number().int().positive().default(15000),

  CORS_ORIGINS: z.string().default('*'),
  AUTH_SECRET: z.string().min(8, 'AUTH_SECRET must be at least 8 characters'),

  MEDIAMTX_API_URL: z.string().url().default('http://localhost:9997'),
  MEDIAMTX_API_USER: z.string().default('admin'),
  MEDIAMTX_API_PASS: z.string().default('password'),
  SRT_PORT: z.coerce.number().int().positive().default(8890),

  NDI_SOURCE_PREFIX: z.string().default('SP-Smart'),
  LOG_LEVEL: z.enum(['trace', 'debug', 'info', 'warn', 'error', 'fatal']).default('info'),
});

const parsed = envSchema.safeParse(process.env);

if (!parsed.success) {
  console.error('❌  Invalid environment configuration:');
  console.error(parsed.error.flatten().fieldErrors);
  process.exit(1);
}

const env = parsed.data;

export const config = {
  nodeEnv: env.NODE_ENV,
  port: env.PORT,
  host: env.HOST,

  wsPath: env.WS_PATH,
  wsHeartbeatIntervalMs: env.WS_HEARTBEAT_INTERVAL_MS,
  wsClientTimeoutMs: env.WS_CLIENT_TIMEOUT_MS,

  corsOrigins: env.CORS_ORIGINS.split(',').map((o) => o.trim()),
  authSecret: env.AUTH_SECRET,

  mediaMtx: {
    apiUrl: env.MEDIAMTX_API_URL,
    user: env.MEDIAMTX_API_USER,
    pass: env.MEDIAMTX_API_PASS,
    srtPort: env.SRT_PORT,
  },

  ndiSourcePrefix: env.NDI_SOURCE_PREFIX,
  logLevel: env.LOG_LEVEL,

  isProd: env.NODE_ENV === 'production',
  isDev: env.NODE_ENV === 'development',
} as const;
