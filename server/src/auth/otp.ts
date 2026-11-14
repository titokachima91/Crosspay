import type { PoolClient } from 'pg';
import { CryptoBox } from '../crypto.js';

export interface CreateOtpInput {
  phone: string;
  code: string;
  ttlSeconds?: number;
  resendAfterSeconds?: number;
  maxAttempts?: number;
  now?: Date;
}

export interface OtpChallengeResult {
  id: string;
  codeLength: number;
  resendAfterSeconds: number;
  expiresInSeconds: number;
  expiresAt: Date;
}

export type OtpVerificationResult =
  | { state: 'verified'; challengeId: string }
  | { state: 'invalid'; attemptsRemaining: number }
  | { state: 'too_many_attempts' }
  | { state: 'expired' };

export async function createOtpChallenge(
  client: PoolClient,
  input: CreateOtpInput,
  crypto: CryptoBox,
): Promise<OtpChallengeResult> {
  const now = input.now ?? new Date();
  const ttlSeconds = input.ttlSeconds ?? 300;
  const resendAfterSeconds = input.resendAfterSeconds ?? 60;
  const maxAttempts = input.maxAttempts ?? 5;
  const expiresAt = new Date(now.getTime() + ttlSeconds * 1000);

  // A new code replaces every older unused code for this phone. The old rows
  // stay for audit but can no longer be verified.
  await client.query(
    `UPDATE otp_challenges
     SET superseded_at = $2
     WHERE phone = $1 AND consumed_at IS NULL AND superseded_at IS NULL`,
    [input.phone, now],
  );

  const result = await client.query(
    `INSERT INTO otp_challenges
       (phone, code_hash, max_attempts, expires_at, resend_after_seconds, created_at)
     VALUES ($1, $2, $3, $4, $5, $6)
     RETURNING id`,
    [
      input.phone,
      crypto.hashSensitive(input.code),
      maxAttempts,
      expiresAt,
      resendAfterSeconds,
      now,
    ],
  );

  return {
    id: String(result.rows[0]?.['id']),
    codeLength: input.code.length,
    resendAfterSeconds,
    expiresInSeconds: ttlSeconds,
    expiresAt,
  };
}

/**
 * Verifies the newest unconsumed code for a phone. Returns a result instead of
 * throwing for expected failures so the caller can commit the attempt counter
 * (or family revocation) and then answer with the documented error code.
 *
 * If the result is `invalid` or `too_many_attempts`, the attempt update is
 * already applied in this transaction. The caller must commit.
 */
export async function verifyOtpChallenge(
  client: PoolClient,
  input: { phone: string; code: string; now?: Date },
  crypto: CryptoBox,
): Promise<OtpVerificationResult> {
  const now = input.now ?? new Date();
  const selected = await client.query(
    `SELECT id, code_hash, attempts, max_attempts, expires_at
     FROM otp_challenges
     WHERE phone = $1 AND consumed_at IS NULL AND superseded_at IS NULL
     ORDER BY created_seq DESC
     LIMIT 1
     FOR UPDATE`,
    [input.phone],
  );

  const row = selected.rows[0];
  if (!row) return { state: 'invalid', attemptsRemaining: 0 };

  const challengeId = String(row['id']);
  const attempts = Number(row['attempts']);
  const maxAttempts = Number(row['max_attempts']);
  const expiresAt = row['expires_at'] as Date;

  if (expiresAt.getTime() <= now.getTime()) return { state: 'expired' };
  if (attempts >= maxAttempts) return { state: 'too_many_attempts' };

  const matches = crypto.matchesHash(input.code, String(row['code_hash']));
  if (!matches) {
    const updated = await client.query(
      `UPDATE otp_challenges
       SET attempts = LEAST(attempts + 1, max_attempts)
       WHERE id = $1
       RETURNING attempts, max_attempts`,
      [challengeId],
    );
    const nextAttempts = Number(updated.rows[0]?.['attempts']);
    const limit = Number(updated.rows[0]?.['max_attempts']);
    if (nextAttempts >= limit) return { state: 'too_many_attempts' };
    return { state: 'invalid', attemptsRemaining: limit - nextAttempts };
  }

  const consumed = await client.query(
    `UPDATE otp_challenges
     SET consumed_at = $2
     WHERE id = $1 AND consumed_at IS NULL
     RETURNING id`,
    [challengeId, now],
  );
  if (consumed.rowCount !== 1) return { state: 'invalid', attemptsRemaining: 0 };

  return { state: 'verified', challengeId };
}
