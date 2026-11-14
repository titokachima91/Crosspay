import type { Pool } from 'pg';
import { CryptoBox } from '../crypto.js';

export interface RateLimitInput {
  scope: string;
  key: string;
  limit: number;
  windowSeconds: number;
  crypto: CryptoBox;
  now?: Date;
}

export interface RateLimitResult {
  allowed: boolean;
  remaining: number;
  retryAfterSeconds: number;
}

/**
 * Database-backed fixed-window limiter. Safe across multiple API instances,
 * unlike an in-process counter. The key is hashed; phone numbers and account
 * numbers never enter the table.
 */
export async function consumeRateLimit(
  pool: Pool,
  input: RateLimitInput,
): Promise<RateLimitResult> {
  const now = input.now ?? new Date();
  const windowMs = input.windowSeconds * 1000;
  const windowStart = new Date(Math.floor(now.getTime() / windowMs) * windowMs);
  const expiresAt = new Date(windowStart.getTime() + windowMs * 2);

  const result = await pool.query(
    `INSERT INTO rate_limit_buckets (scope, key_hash, window_start, count, expires_at)
     VALUES ($1, $2, $3, 1, $4)
     ON CONFLICT (scope, key_hash, window_start)
     DO UPDATE SET count = rate_limit_buckets.count + 1
     RETURNING count`,
    [input.scope, input.crypto.hashSensitive(input.key), windowStart, expiresAt],
  );

  const count = Number(result.rows[0]?.['count'] ?? 1);
  const resetAt = windowStart.getTime() + windowMs;
  const retryAfterSeconds = Math.max(1, Math.ceil((resetAt - now.getTime()) / 1000));

  return {
    allowed: count <= input.limit,
    remaining: Math.max(0, input.limit - count),
    retryAfterSeconds,
  };
}
