import { randomBytes } from 'node:crypto';
import type { PoolClient } from 'pg';
import { CryptoBox } from '../crypto.js';

export class RefreshTokenInvalidError extends Error {
  readonly code = 'REFRESH_TOKEN_INVALID';
  constructor() {
    super('The refresh token is invalid');
    this.name = 'RefreshTokenInvalidError';
  }
}

export class RefreshTokenExpiredError extends Error {
  readonly code = 'REFRESH_TOKEN_EXPIRED';
  constructor() {
    super('The refresh token has expired');
    this.name = 'RefreshTokenExpiredError';
  }
}

export type RotateRefreshTokenResult =
  | ({
      state: 'rotated';
      userId: string;
      previousId: string;
    } & IssuedRefreshToken)
  | {
      state: 'reused';
      userId: string;
      familyId: string;
    };

export interface IssuedRefreshToken {
  id: string;
  token: string;
  familyId: string;
  expiresAt: Date;
}

export async function issueRefreshToken(
  client: PoolClient,
  input: {
    userId: string;
    crypto: CryptoBox;
    ttlSeconds?: number;
    familyId?: string;
    now?: Date;
  },
): Promise<IssuedRefreshToken> {
  const now = input.now ?? new Date();
  const ttlSeconds = input.ttlSeconds ?? 30 * 24 * 60 * 60;
  const expiresAt = new Date(now.getTime() + ttlSeconds * 1000);
  const token = randomBytes(32).toString('base64url');

  const result = await client.query(
    `INSERT INTO refresh_tokens
       (user_id, token_hash, family_id, expires_at, created_at)
     VALUES ($1, $2, COALESCE($3::uuid, gen_random_uuid()), $4, $5)
     RETURNING id, family_id`,
    [input.userId, input.crypto.hashToken(token), input.familyId ?? null, expiresAt, now],
  );

  return {
    id: String(result.rows[0]?.['id']),
    token,
    familyId: String(result.rows[0]?.['family_id']),
    expiresAt,
  };
}

export async function revokeRefreshFamily(
  client: PoolClient,
  familyId: string,
  now = new Date(),
): Promise<number> {
  const result = await client.query(
    `UPDATE refresh_tokens
     SET revoked_at = $2
     WHERE family_id = $1 AND revoked_at IS NULL`,
    [familyId, now],
  );
  return result.rowCount ?? 0;
}

/**
 * Enforces one active session per account after a new sign-in. The family that
 * just issued the new session is kept; every other unrevoked family is revoked.
 * The old device keeps only its short-lived access token until it expires, then
 * its refresh fails and it signs out.
 */
export async function revokeOtherRefreshFamilies(
  client: PoolClient,
  input: { userId: string; keepFamilyId: string; now?: Date },
): Promise<number> {
  const result = await client.query(
    `UPDATE refresh_tokens
     SET revoked_at = $3
     WHERE user_id = $1
       AND family_id <> $2
       AND revoked_at IS NULL`,
    [input.userId, input.keepFamilyId, input.now ?? new Date()],
  );
  return result.rowCount ?? 0;
}

/**
 * Rotates a refresh token. A token may be used once. Reusing the previous
 * token revokes the entire family and returns `state: 'reused'`; the caller
 * MUST commit the transaction and answer 401. Invalid or expired tokens throw
 * and the caller rolls back.
 */
export async function rotateRefreshToken(
  client: PoolClient,
  input: { token: string; crypto: CryptoBox; ttlSeconds?: number; now?: Date },
): Promise<RotateRefreshTokenResult> {
  const now = input.now ?? new Date();
  const tokenHash = input.crypto.hashToken(input.token);

  // Resolve the owner first, then lock the user row before the token row.
  // Support session revocation locks the user row first; a consistent order
  // prevents both a deadlock and a refresh that slips a new token past the
  // revocation sweep.
  const owner = await client.query<{ user_id: string }>(
    `SELECT user_id FROM refresh_tokens WHERE token_hash = $1`,
    [tokenHash],
  );
  const ownerId = owner.rows[0]?.user_id;
  if (!ownerId) throw new RefreshTokenInvalidError();
  await client.query(`SELECT id FROM users WHERE id = $1 FOR UPDATE`, [ownerId]);

  const selected = await client.query(
    `SELECT id, user_id, family_id, expires_at, revoked_at
     FROM refresh_tokens
     WHERE token_hash = $1
     FOR UPDATE`,
    [tokenHash],
  );

  const row = selected.rows[0];
  if (!row) throw new RefreshTokenInvalidError();

  const previousId = String(row['id']);
  const userId = String(row['user_id']);
  const familyId = String(row['family_id']);
  const expiresAt = row['expires_at'] as Date;

  if (row['revoked_at'] !== null) {
    await revokeRefreshFamily(client, familyId, now);
    return { state: 'reused', userId, familyId };
  }
  if (expiresAt.getTime() <= now.getTime()) throw new RefreshTokenExpiredError();

  const next = await issueRefreshToken(client, {
    userId,
    crypto: input.crypto,
    ttlSeconds: input.ttlSeconds,
    familyId,
    now,
  });

  const rotated = await client.query(
    `UPDATE refresh_tokens
     SET revoked_at = $2, replaced_by_id = $3, last_used_at = $2
     WHERE id = $1 AND revoked_at IS NULL`,
    [previousId, now, next.id],
  );
  if (rotated.rowCount !== 1) throw new RefreshTokenInvalidError();

  return { state: 'rotated', ...next, userId, previousId };
}
