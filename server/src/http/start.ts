import 'dotenv/config';
import type { FastifyServerOptions } from 'fastify';
import { createPoolFromEnv } from '../db/pool.js';
import { CryptoBox } from '../crypto.js';
import { DisabledSmsSender } from '../providers/sms.js';
import { buildServer } from './server.js';

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function positiveInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) throw new Error(`${name} must be a positive integer`);
  return value;
}

const jwtSecret = Buffer.from(required('JWT_SECRET'), 'base64');
if (jwtSecret.length < 32) {
  throw new Error('JWT_SECRET must be at least 32 bytes, base64 encoded');
}

const pool = createPoolFromEnv();
const crypto = CryptoBox.fromBase64(required('DATA_ENCRYPTION_KEY'));
const limitTimezone = process.env['LIMIT_TIMEZONE'] ?? 'UTC';
try {
  new Intl.DateTimeFormat('en-US', { timeZone: limitTimezone }).format(new Date());
} catch {
  throw new Error('LIMIT_TIMEZONE must be a valid IANA time zone');
}

const corsOrigins = (process.env['CORS_ORIGINS'] ?? '')
  .split(',')
  .map((origin) => origin.trim())
  .filter((origin) => origin.length > 0);

const logger: FastifyServerOptions['logger'] = {
  level: process.env['LOG_LEVEL'] ?? 'info',
  redact: {
    paths: ['req.headers.authorization', 'req.headers["x-idempotency-key"]'],
    censor: '[redacted]',
  },
};

const app = await buildServer(
  {
    pool,
    crypto,
    smsSender: new DisabledSmsSender(),
    jwtSecret,
    accessTokenTtlSeconds: positiveInt('ACCESS_TOKEN_TTL_SECONDS', 900),
    refreshTokenTtlSeconds: positiveInt('REFRESH_TOKEN_TTL_SECONDS', 30 * 24 * 60 * 60),
    idempotencyTtlSeconds: positiveInt('IDEMPOTENCY_TTL_SECONDS', 86_400),
    limitTimezone,
  },
  { logger, corsOrigins },
);

const port = positiveInt('PORT', 3000);
const host = process.env['HOST'] ?? '0.0.0.0';

await app.listen({ port, host });

async function shutdown(signal: string): Promise<void> {
  app.log.info({ signal }, 'shutting down');
  await app.close();
  await pool.end();
  process.exit(0);
}

process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));
