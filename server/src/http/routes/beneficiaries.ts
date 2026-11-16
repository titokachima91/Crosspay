import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import type { PoolClient } from 'pg';
import { requireUserId } from '../auth.js';
import {
  conflict,
  notFound,
  serviceUnavailable,
  unprocessable,
} from '../errors.js';
import { parseBody, requireIdempotencyKey } from '../validation.js';
import { runIdempotent } from '../idempotent-route.js';

const accountSchema = z
  .string()
  .trim()
  .min(4)
  .max(64)
  .regex(/^[A-Za-z0-9+][A-Za-z0-9+ -]*$/, 'Unsupported account characters');

const beneficiarySchema = z.object({
  railId: z.string().trim().min(1).max(64),
  name: z.string().trim().min(1).max(200),
  accountOrPhone: accountSchema,
});

const idSchema = z.object({ id: z.string().uuid() });

interface BeneficiaryRow {
  id: string;
  name: string;
  rail_id: string;
  account_or_phone_encrypted: Buffer;
  name_verified: boolean;
}

interface BeneficiaryResponse {
  id: string;
  name: string;
  railId: string;
  accountOrPhone: string;
  kycVerified: boolean;
}

function toResponse(row: BeneficiaryRow, ctx: AppContext): BeneficiaryResponse {
  return {
    id: row.id,
    name: row.name,
    railId: row.rail_id,
    accountOrPhone: ctx.crypto.decrypt(Buffer.from(row.account_or_phone_encrypted)),
    kycVerified: row.name_verified,
  };
}

function normalizeAccount(account: string): string {
  return account.replace(/[\s-]/g, '');
}

function last4(account: string): string {
  const value = account.replace(/[^A-Za-z0-9]/g, '').slice(-4);
  return value.length > 0 ? value : '0000';
}

async function assertRail(client: PoolClient, railId: string): Promise<void> {
  const result = await client.query(
    `SELECT id FROM payout_rails WHERE id = $1 AND active`,
    [railId],
  );
  if (result.rowCount !== 1) {
    throw unprocessable('INVALID_RAIL', 'The payout rail is not available');
  }
}

async function assertNoDuplicate(
  client: PoolClient,
  input: { userId: string; railId: string; accountHash: string; excludeId?: string },
): Promise<void> {
  const duplicate = await client.query(
    `SELECT id
     FROM beneficiaries
     WHERE user_id = $1
       AND rail_id = $2
       AND account_hash = $3
       AND deleted_at IS NULL
       AND ($4::uuid IS NULL OR id <> $4::uuid)
     LIMIT 1`,
    [input.userId, input.railId, input.accountHash, input.excludeId ?? null],
  );
  if (duplicate.rowCount) {
    throw conflict('BENEFICIARY_EXISTS', 'This recipient is already saved');
  }
}

const beneficiaryColumns = `id, name, rail_id, account_or_phone_encrypted, name_verified`;

export function registerBeneficiaryRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get('/beneficiaries', async (request) => {
    const userId = requireUserId(request);
    const result = await ctx.pool.query<BeneficiaryRow>(
      `SELECT ${beneficiaryColumns}
       FROM beneficiaries
       WHERE user_id = $1 AND deleted_at IS NULL
       ORDER BY created_at DESC, id DESC`,
      [userId],
    );
    return { beneficiaries: result.rows.map((row) => toResponse(row, ctx)) };
  });

  app.post('/beneficiaries/check', async (request) => {
    requireUserId(request);
    throw serviceUnavailable(
      'NAME_CHECK_NOT_CONFIGURED',
      'Destination name checks are not connected yet',
    );
  });

  app.post('/beneficiaries', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const body = parseBody(beneficiarySchema, request.body);
    const normalized = normalizeAccount(body.accountOrPhone);
    const accountHash = ctx.crypto.hashSensitive(normalized);

    const result = await runIdempotent<BeneficiaryResponse>(
      ctx,
      { userId, scope: 'beneficiary.create', key, requestBody: request.body },
      async (client) => {
        await assertRail(client, body.railId);
        await assertNoDuplicate(client, {
          userId,
          railId: body.railId,
          accountHash,
        });

        const inserted = await client.query<BeneficiaryRow>(
          `INSERT INTO beneficiaries
             (user_id, rail_id, name, account_or_phone_encrypted,
              account_last4, account_hash)
           VALUES ($1, $2, $3, $4, $5, $6)
           RETURNING ${beneficiaryColumns}`,
          [
            userId,
            body.railId,
            body.name,
            ctx.crypto.encrypt(normalized),
            last4(normalized),
            accountHash,
          ],
        );

        return {
          status: 201,
          body: toResponse(inserted.rows[0] as BeneficiaryRow, ctx),
          resourceType: 'beneficiary',
          resourceId: inserted.rows[0]?.id ?? '',
        };
      },
    );

    if (result.replayed) reply.header('Idempotency-Replay', 'true');
    return reply.code(result.status).send(result.body);
  });

  app.patch('/beneficiaries/:id', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const { id } = parseBody(idSchema, request.params);
    const body = parseBody(beneficiarySchema, request.body);
    const normalized = normalizeAccount(body.accountOrPhone);
    const accountHash = ctx.crypto.hashSensitive(normalized);

    const result = await runIdempotent<BeneficiaryResponse>(
      ctx,
      {
        userId,
        scope: 'beneficiary.update',
        key,
        requestBody: { id, body: request.body },
      },
      async (client) => {
        const existing = await client.query<BeneficiaryRow>(
          `SELECT ${beneficiaryColumns}
           FROM beneficiaries
           WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL
           FOR UPDATE`,
          [id, userId],
        );
        if (!existing.rowCount) {
          throw notFound('BENEFICIARY_NOT_FOUND', 'Recipient not found');
        }

        await assertRail(client, body.railId);
        await assertNoDuplicate(client, {
          userId,
          railId: body.railId,
          accountHash,
          excludeId: id,
        });

        const updated = await client.query<BeneficiaryRow>(
          `UPDATE beneficiaries
           SET rail_id = $3,
               name = $4,
               account_or_phone_encrypted = $5,
               account_last4 = $6,
               account_hash = $7
           WHERE id = $1 AND user_id = $2
           RETURNING ${beneficiaryColumns}`,
          [
            id,
            userId,
            body.railId,
            body.name,
            ctx.crypto.encrypt(normalized),
            last4(normalized),
            accountHash,
          ],
        );

        return {
          status: 200,
          body: toResponse(updated.rows[0] as BeneficiaryRow, ctx),
          resourceType: 'beneficiary',
          resourceId: id,
        };
      },
    );

    if (result.replayed) reply.header('Idempotency-Replay', 'true');
    return reply.code(result.status).send(result.body);
  });

  app.delete('/beneficiaries/:id', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const { id } = parseBody(idSchema, request.params);

    const result = await runIdempotent<null>(
      ctx,
      {
        userId,
        scope: 'beneficiary.delete',
        key,
        requestBody: { id },
      },
      async (client) => {
        const existing = await client.query(
          `SELECT id, deleted_at
           FROM beneficiaries
           WHERE id = $1 AND user_id = $2
           FOR UPDATE`,
          [id, userId],
        );
        if (!existing.rowCount) {
          throw notFound('BENEFICIARY_NOT_FOUND', 'Recipient not found');
        }

        if (existing.rows[0]?.['deleted_at'] === null) {
          await client.query(
            `UPDATE beneficiaries SET deleted_at = now() WHERE id = $1 AND user_id = $2`,
            [id, userId],
          );
        }

        return {
          status: 204,
          body: null,
          resourceType: 'beneficiary',
          resourceId: id,
        };
      },
    );

    if (result.replayed) reply.header('Idempotency-Replay', 'true');
    return reply.code(result.status).send(result.body);
  });
}
