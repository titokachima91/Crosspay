import type { PoolClient } from 'pg';
import { CryptoBox } from './crypto.js';

export type IdempotencyStatus = 'in_progress' | 'succeeded' | 'failed';

export interface BeginIdempotentInput {
  userId: string;
  scope: string;
  key: string;
  requestHash: string;
  ttlSeconds?: number;
  now?: Date;
}

export type IdempotencyOutcome =
  | { state: 'acquired'; id: string }
  | {
      state: 'replay';
      id: string;
      status: 'succeeded' | 'failed';
      responseStatus: number;
      responseBody: unknown;
      resourceType: string | null;
      resourceId: string | null;
    };

export class IdempotencyKeyReusedError extends Error {
  readonly code = 'IDEMPOTENCY_KEY_REUSED';
  constructor() {
    super('This idempotency key was already used with a different request body');
    this.name = 'IdempotencyKeyReusedError';
  }
}

export class IdempotencyInProgressError extends Error {
  readonly code = 'IDEMPOTENCY_IN_PROGRESS';
  constructor() {
    super('The original request is still in progress; retry shortly');
    this.name = 'IdempotencyInProgressError';
  }
}

export class IdempotencyCompletionError extends Error {
  readonly code = 'IDEMPOTENCY_COMPLETION_FAILED';
  constructor(message: string) {
    super(message);
    this.name = 'IdempotencyCompletionError';
  }
}

interface IdempotencyRow {
  id: string;
  request_hash: string;
  status: IdempotencyStatus;
  response_status: number | null;
  response_body_encrypted: Buffer | null;
  resource_type: string | null;
  resource_id: string | null;
}

const DEFAULT_TTL_SECONDS = 86_400;

function mapRow(row: Record<string, unknown>): IdempotencyRow {
  return {
    id: String(row['id']),
    request_hash: String(row['request_hash']),
    status: row['status'] as IdempotencyStatus,
    response_status: row['response_status'] === null ? null : Number(row['response_status']),
    response_body_encrypted:
      row['response_body_encrypted'] === null
        ? null
        : Buffer.from(row['response_body_encrypted'] as Buffer),
    resource_type: row['resource_type'] === null ? null : String(row['resource_type']),
    resource_id: row['resource_id'] === null ? null : String(row['resource_id']),
  };
}

/**
 * Starts an idempotent operation inside the caller's transaction. The insert
 * waits on the unique index when a concurrent request uses the same key, so
 * only one request can ever acquire the key. If the first transaction rolls
 * back, the waiting request acquires it instead.
 */
export async function beginIdempotent(
  client: PoolClient,
  input: BeginIdempotentInput,
  crypto: CryptoBox,
): Promise<IdempotencyOutcome> {
  const now = input.now ?? new Date();
  const ttlSeconds = input.ttlSeconds ?? DEFAULT_TTL_SECONDS;
  const expiresAt = new Date(now.getTime() + ttlSeconds * 1000);

  const inserted = await client.query(
    `INSERT INTO idempotency_keys
       (user_id, scope, key, request_hash, created_at, expires_at)
     VALUES ($1, $2, $3, $4, $5, $6)
     ON CONFLICT (user_id, scope, key) DO NOTHING
     RETURNING id`,
    [input.userId, input.scope, input.key, input.requestHash, now, expiresAt],
  );

  if (inserted.rowCount === 1) {
    return { state: 'acquired', id: String(inserted.rows[0]?.['id']) };
  }

  const existing = await client.query(
    `SELECT id, request_hash, status, response_status, response_body_encrypted,
            resource_type, resource_id
     FROM idempotency_keys
     WHERE user_id = $1 AND scope = $2 AND key = $3
     FOR UPDATE`,
    [input.userId, input.scope, input.key],
  );

  const row = existing.rows[0];
  if (!row) {
    throw new IdempotencyCompletionError('Idempotency row disappeared during conflict handling');
  }
  const record = mapRow(row);

  if (record.request_hash !== input.requestHash) {
    throw new IdempotencyKeyReusedError();
  }
  if (record.status === 'in_progress') {
    throw new IdempotencyInProgressError();
  }
  if (record.response_status === null) {
    throw new IdempotencyCompletionError('Completed idempotency row has no response status');
  }

  return {
    state: 'replay',
    id: record.id,
    status: record.status,
    responseStatus: record.response_status,
    responseBody:
      record.response_body_encrypted === null
        ? null
        : JSON.parse(crypto.decrypt(record.response_body_encrypted)),
    resourceType: record.resource_type,
    resourceId: record.resource_id,
  };
}

export interface CompleteIdempotentInput {
  id: string;
  status: 'succeeded' | 'failed';
  responseStatus: number;
  responseBody?: unknown;
  resourceType?: string;
  resourceId?: string;
  now?: Date;
}

/** Completes the idempotency row in the same transaction as the business write. */
export async function completeIdempotent(
  client: PoolClient,
  input: CompleteIdempotentInput,
  crypto: CryptoBox,
): Promise<void> {
  const encryptedBody =
    input.responseBody === undefined ? null : crypto.encrypt(JSON.stringify(input.responseBody));

  const result = await client.query(
    `UPDATE idempotency_keys
     SET status = $2,
         response_status = $3,
         response_body_encrypted = $4,
         resource_type = $5,
         resource_id = $6,
         completed_at = $7
     WHERE id = $1 AND status = 'in_progress'`,
    [
      input.id,
      input.status,
      input.responseStatus,
      encryptedBody,
      input.resourceType ?? null,
      input.resourceId ?? null,
      input.now ?? new Date(),
    ],
  );

  if (result.rowCount !== 1) {
    throw new IdempotencyCompletionError('Idempotency row is missing or already completed');
  }
}

/** Removes completed keys after their retention window. Never removes in-flight work. */
export async function pruneIdempotency(client: PoolClient, now = new Date()): Promise<number> {
  const result = await client.query(
    `DELETE FROM idempotency_keys
     WHERE expires_at < $1 AND status <> 'in_progress'`,
    [now],
  );
  return result.rowCount ?? 0;
}
