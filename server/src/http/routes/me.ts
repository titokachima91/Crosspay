import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import { withTransaction } from '../../db/pool.js';
import { requireUserId } from '../auth.js';
import { conflict, unauthorized, unprocessable } from '../errors.js';
import { parseBody } from '../validation.js';
import { resolveLimitCurrency } from '../../services/users.js';

const kycSchema = z
  .object({
    accountType: z.enum(['personal', 'business']),
    legalName: z.string().trim().min(1).max(200),
    hubId: z.string().trim().min(1).max(64).optional(),
    idNumber: z.string().trim().min(4).max(64),
  })
  .superRefine((value, ctx) => {
    if (value.accountType === 'business' && !value.hubId) {
      ctx.addIssue({
        code: 'custom',
        path: ['hubId'],
        message: 'A business account needs a trading hub',
      });
    }
    if (value.accountType === 'personal' && value.hubId) {
      ctx.addIssue({
        code: 'custom',
        path: ['hubId'],
        message: 'A personal account cannot have a trading hub',
      });
    }
  });

interface ProfileRow {
  id: string;
  phone: string;
  display_name: string | null;
  account_type: 'personal' | 'business';
  hub_id: string | null;
  kyc_status: 'not_started' | 'pending' | 'verified' | 'rejected';
  tier_code: string;
  limit_currency_code: string | null;
}

export function registerMeRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get('/me', async (request) => {
    const userId = requireUserId(request);

    const result = await ctx.pool.query<ProfileRow>(
      `SELECT id, phone, display_name, account_type, hub_id, kyc_status,
              tier_code, limit_currency_code
       FROM users
       WHERE id = $1 AND deleted_at IS NULL`,
      [userId],
    );
    const user = result.rows[0];
    if (!user) throw unauthorized('USER_NOT_FOUND', 'The signed-in account no longer exists');

    if (
      user.kyc_status === 'not_started' ||
      user.display_name === null ||
      user.limit_currency_code === null
    ) {
      throw conflict('PROFILE_INCOMPLETE', 'Complete the KYC step before loading the profile');
    }

    const limit = await ctx.pool.query(
      `SELECT daily_limit_minor
       FROM tier_limits
       WHERE tier_code = $1 AND currency_code = $2`,
      [user.tier_code, user.limit_currency_code],
    );
    const dailyLimitMinor = BigInt(String(limit.rows[0]?.['daily_limit_minor'] ?? '0'));

    const used = await ctx.pool.query(
      `SELECT COALESCE(sum(send_amount_minor), 0)::bigint AS used
       FROM trades
       WHERE user_id = $1
         AND status NOT IN ('cancelled', 'expired', 'failed')
         AND created_at >= (date_trunc('day', now() AT TIME ZONE $2) AT TIME ZONE $2)`,
      [userId, ctx.limitTimezone],
    );
    const dailyUsedMinor = BigInt(String(used.rows[0]?.['used'] ?? '0'));

    return {
      id: user.id,
      phone: user.phone,
      accountType: user.account_type,
      displayName: user.display_name,
      ...(user.hub_id === null ? {} : { hubId: user.hub_id }),
      kycStatus: user.kyc_status,
      tier: user.tier_code,
      limit: {
        currency: user.limit_currency_code,
        dailyLimitMinor: Number(dailyLimitMinor),
        dailyUsedMinor: Number(dailyUsedMinor),
      },
    };
  });

  app.put('/me/kyc', async (request) => {
    const userId = requireUserId(request);
    const body = parseBody(kycSchema, request.body);

    return withTransaction(ctx.pool, async (client) => {
      const selected = await client.query<ProfileRow>(
        `SELECT id, phone, display_name, account_type, hub_id, kyc_status,
                tier_code, limit_currency_code
         FROM users
         WHERE id = $1 AND deleted_at IS NULL
         FOR UPDATE`,
        [userId],
      );
      const user = selected.rows[0];
      if (!user) throw unauthorized('USER_NOT_FOUND', 'The signed-in account no longer exists');

      const existing = await client.query(
        `SELECT status
         FROM kyc_verifications
         WHERE user_id = $1 AND status IN ('pending', 'verified')
         ORDER BY submitted_at DESC
         LIMIT 1`,
        [userId],
      );
      const existingStatus = existing.rows[0]?.['status'];
      if (existingStatus === 'verified') {
        throw conflict('KYC_ALREADY_VERIFIED', 'This account is already verified');
      }
      if (existingStatus === 'pending') {
        throw conflict('KYC_ALREADY_SUBMITTED', 'A verification is already in review');
      }

      const hubId = body.accountType === 'business' ? (body.hubId ?? null) : null;
      if (body.accountType === 'business' && hubId) {
        const hub = await client.query(
          `SELECT id FROM hubs WHERE id = $1 AND active`,
          [hubId],
        );
        if (hub.rowCount !== 1) {
          throw unprocessable('INVALID_HUB', 'The trading hub is not available');
        }
      }

      const limitCurrency = await resolveLimitCurrency(client, user.phone, hubId);
      const idType = body.accountType === 'business' ? 'business_tin' : 'national_id';
      const idHash = ctx.crypto.hashSensitive(body.idNumber);
      const encrypted = ctx.crypto.encrypt(body.idNumber);
      const last4 = body.idNumber.replace(/[^A-Za-z0-9]/g, '').slice(-4);
      if (last4.length === 0) {
        throw unprocessable('ID_NUMBER_INVALID', 'The identity number is not valid');
      }

      const duplicate = await client.query(
        `SELECT user_id
         FROM kyc_verifications
         WHERE id_type = $1
           AND id_number_hash = $2
           AND status IN ('pending', 'verified')
           AND user_id <> $3
         LIMIT 1`,
        [idType, idHash, userId],
      );
      if (duplicate.rowCount) {
        throw conflict(
          'ID_NUMBER_ALREADY_USED',
          'This identity document is already linked to another account',
        );
      }

      await client.query(
        `INSERT INTO kyc_verifications
           (user_id, account_type, legal_name, hub_id, id_type,
            id_number_encrypted, id_number_hash, id_last4, status)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'pending')`,
        [
          userId,
          body.accountType,
          body.legalName,
          hubId,
          idType,
          encrypted,
          idHash,
          last4,
        ],
      ).catch((error: { code?: string; constraint?: string }) => {
        if (error.code === '23505' && error.constraint === 'kyc_submitted_identity_uidx') {
          throw conflict(
            'ID_NUMBER_ALREADY_USED',
            'This identity document is already linked to another account',
          );
        }
        if (error.code === '23505' && error.constraint === 'kyc_one_pending_per_user_uidx') {
          throw conflict('KYC_ALREADY_SUBMITTED', 'A verification is already in review');
        }
        throw error;
      });

      await client.query(
        `UPDATE users
         SET display_name = $2,
             account_type = $3,
             hub_id = $4,
             kyc_status = 'pending',
             limit_currency_code = $5
         WHERE id = $1`,
        [userId, body.legalName, body.accountType, hubId, limitCurrency],
      );

      return { kycStatus: 'pending' as const };
    });
  });
}
