import 'dotenv/config';
import type { FastifyServerOptions } from 'fastify';
import { createPoolFromEnv } from '../db/pool.js';
import { CryptoBox } from '../crypto.js';
import { DisabledSmsSender, type SmsSender } from '../providers/sms.js';
import { HttpSmsSender } from '../providers/http-sms.js';
import {
  DisabledPaymentProvider,
  SandboxPaymentProvider,
  type PaymentProvider,
} from '../providers/payments.js';
import {
  DisabledPricingProvider,
  SandboxPricingProvider,
  type PricingProvider,
} from '../providers/pricing.js';
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

/**
 * The sandbox provider is the reference pricing source until Product/Finance
 * approve a live one. It is opt-in: without PRICING_PROVIDER=sandbox the API
 * keeps returning an honest 503, exactly as before.
 */
function buildPricingProvider(): PricingProvider {
  const kind = (process.env['PRICING_PROVIDER'] ?? 'disabled').trim().toLowerCase();
  if (kind === 'disabled') return new DisabledPricingProvider();
  if (kind !== 'sandbox') {
    throw new Error(`PRICING_PROVIDER must be "disabled" or "sandbox", got "${kind}"`);
  }

  const baseUrl = process.env['SANDBOX_PRICING_URL'] ?? process.env['SANDBOX_FACADE_URL'];
  if (!baseUrl) {
    throw new Error('SANDBOX_PRICING_URL is required when PRICING_PROVIDER=sandbox');
  }
  const apiKey = process.env['SANDBOX_PRICING_KEY'] ?? process.env['SANDBOX_API_KEY_CROSSPAY'];
  if (!apiKey) {
    throw new Error('SANDBOX_PRICING_KEY is required when PRICING_PROVIDER=sandbox');
  }

  return new SandboxPricingProvider({
    baseUrl,
    apiKey,
    timeoutMs: positiveInt('PRICING_TIMEOUT_MS', 5_000),
  });
}

/**
 * SMS is opt-in. Without a provider the API returns SMS_NOT_CONFIGURED and
 * never logs or returns the code. `http` targets a compatible gateway such as
 * the sandbox `/v1/send-sms` route.
 */
function buildSmsSender(): SmsSender {
  const kind = (process.env['SMS_PROVIDER'] ?? 'disabled').trim().toLowerCase();
  if (kind === 'disabled') return new DisabledSmsSender();
  if (kind !== 'http') {
    throw new Error(`SMS_PROVIDER must be "disabled" or "http", got "${kind}"`);
  }
  const url = process.env['SMS_API_URL'];
  if (!url) throw new Error('SMS_API_URL is required when SMS_PROVIDER=http');
  return new HttpSmsSender({
    url,
    apiKey: process.env['SMS_API_KEY'],
    senderId: process.env['SMS_SENDER_ID'],
    timeoutMs: positiveInt('SMS_TIMEOUT_MS', 5_000),
  });
}

/**
 * Payment providers are opt-in. "sandbox" targets the provider primitives in
 * kachi-fintech-sandbox; production adapters must implement the same
 * interface without pretending a payment succeeded.
 */
function buildPaymentProvider(): PaymentProvider {
  const kind = (process.env['PAYMENT_PROVIDER'] ?? 'disabled').trim().toLowerCase();
  if (kind === 'disabled') return new DisabledPaymentProvider();
  if (kind !== 'sandbox') {
    throw new Error(`PAYMENT_PROVIDER must be "disabled" or "sandbox", got "${kind}"`);
  }
  const baseUrl = process.env['SANDBOX_PAYMENTS_URL'] ?? process.env['SANDBOX_FACADE_URL'];
  if (!baseUrl) {
    throw new Error('SANDBOX_PAYMENTS_URL is required when PAYMENT_PROVIDER=sandbox');
  }
  const apiKey = process.env['SANDBOX_PAYMENTS_KEY'] ?? process.env['SANDBOX_API_KEY_CROSSPAY'];
  if (!apiKey) {
    throw new Error('SANDBOX_PAYMENTS_KEY is required when PAYMENT_PROVIDER=sandbox');
  }
  return new SandboxPaymentProvider({
    baseUrl,
    apiKey,
    timeoutMs: positiveInt('PAYMENTS_TIMEOUT_MS', 5_000),
  });
}

const app = await buildServer(
  {
    pool,
    crypto,
    smsSender: buildSmsSender(),
    pricingProvider: buildPricingProvider(),
    paymentProvider: buildPaymentProvider(),
    jwtSecret,
    accessTokenTtlSeconds: positiveInt('ACCESS_TOKEN_TTL_SECONDS', 900),
    refreshTokenTtlSeconds: positiveInt('REFRESH_TOKEN_TTL_SECONDS', 30 * 24 * 60 * 60),
    idempotencyTtlSeconds: positiveInt('IDEMPOTENCY_TTL_SECONDS', 86_400),
    limitTimezone,
    collectionPushTimeoutSeconds: positiveInt('COLLECTION_PUSH_TIMEOUT_SECONDS', 120),
    collectionPollIntervalSeconds: positiveInt('COLLECTION_POLL_INTERVAL_SECONDS', 5),
    paymentCallbackUrl: process.env['PAYMENT_CALLBACK_URL'],
    paymentWebhookSecret: process.env['PAYMENT_WEBHOOK_SECRET']
      ? Buffer.from(process.env['PAYMENT_WEBHOOK_SECRET'], 'utf8')
      : null,
    paymentWebhookMaxSkewSeconds: positiveInt('PAYMENT_WEBHOOK_MAX_SKEW_SECONDS', 300),
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
