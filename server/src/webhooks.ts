import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import type { PoolClient } from 'pg';
import { z } from 'zod';
import type { AppContext } from './http/context.js';
import { withTransaction } from './db/pool.js';
import { AppError, unprocessable } from './http/errors.js';
import { refundTrade, paymentFailure } from './payments.js';
import { tryMatchTrade } from './matching.js';
import {
  applyCollectionResult,
  findPaymentAttemptByReference,
  findTradeByAttemptReference,
} from './trades.js';
import { applyPayoutSnapshot, findPayoutByProviderReference } from './payments.js';

export const callbackPayloadSchema = z
  .object({
    checkoutRequestId: z.string().min(1).max(200).optional(),
    payoutId: z.string().min(1).max(200).optional(),
    transactionRef: z.string().min(1).max(200).optional(),
    amountMinor: z.number().int().positive().optional(),
    currency: z.string().length(3).optional(),
    status: z.string().min(1).max(64),
    timestamp: z.string().optional(),
  })
  .passthrough();

export type CallbackPayload = z.infer<typeof callbackPayloadSchema>;

/**
 * The sandbox signs `${timestamp}.${raw body}`. Comparing the hex bytes in
 * constant time keeps a forged callback from becoming a paid trade.
 */
export function verifyCallbackSignature(input: {
  rawBody: string;
  timestamp: string;
  signature: string;
  secret: Uint8Array;
}): boolean {
  const expected = createHmac('sha256', input.secret)
    .update(`${input.timestamp}.${input.rawBody}`)
    .digest();
  const provided = Buffer.from(input.signature, 'hex');
  if (provided.length !== expected.length) return false;
  return timingSafeEqual(provided, expected);
}

export function callbackEventType(kind: 'collection' | 'payout', status: string): string {
  const value = status.trim().toUpperCase();
  const outcome = ['SUCCESS', 'SUCCEEDED', 'COMPLETED', 'PAID', 'CONFIRMED', 'REFUNDED'].includes(
    value,
  )
    ? 'success'
    : ['FAILED', 'FAILURE', 'CANCELLED', 'CANCELED', 'EXPIRED', 'REJECTED', 'REVERSED'].includes(
          value,
        )
      ? 'failed'
      : 'pending';
  return `psp.${kind}.${outcome}`;
}

async function claimEvent(
  ctx: AppContext,
  input: {
    provider: string;
    eventId: string;
    eventType: string;
    rawBody: string;
  },
): Promise<{ id: string; replay: boolean }> {
  return withTransaction(ctx.pool, async (client) => {
    const payloadHash = createHash('sha256').update(input.rawBody, 'utf8').digest('hex');
    const inserted = await client.query<{ id: string }>(
      `INSERT INTO payment_events
         (provider, provider_event_id, event_type, signature_verified, payload_hash, payload)
       VALUES ($1, $2, $3, true, $4, $5::jsonb)
       ON CONFLICT (provider, provider_event_id) DO NOTHING
       RETURNING id`,
      [
        input.provider,
        input.eventId,
        input.eventType,
        payloadHash,
        JSON.stringify({ received: true }),
      ],
    );
    const row = inserted.rows[0];
    if (row) return { id: row.id, replay: false };

    const existing = await client.query<{ id: string; status: string }>(
      `SELECT id, status FROM payment_events
       WHERE provider = $1 AND provider_event_id = $2`,
      [input.provider, input.eventId],
    );
    const found = existing.rows[0];
    if (!found) throw new AppError(500, 'PAYMENT_EVENT_NOT_FOUND', 'Payment event disappeared');
    // A previous attempt failed mid-flight. Resuming is safe: every money
    // operation below is idempotent by posting key or provider reference.
    return { id: found.id, replay: found.status !== 'received' };
  });
}

async function markEvent(
  client: PoolClient,
  input: {
    eventId: string;
    status: 'processed' | 'ignored' | 'failed';
    tradeId?: string | null;
    paymentAttemptId?: string | null;
    payload?: unknown;
  },
): Promise<void> {
  await client.query(
    `UPDATE payment_events
     SET status = $2,
         trade_id = COALESCE($3, trade_id),
         payment_attempt_id = COALESCE($4, payment_attempt_id),
         payload = COALESCE($5::jsonb, payload),
         processed_at = CASE WHEN $2 = 'processed' THEN now() ELSE NULL END
     WHERE id = $1`,
    [
      input.eventId,
      input.status,
      input.tradeId ?? null,
      input.paymentAttemptId ?? null,
      input.payload === undefined ? null : JSON.stringify(input.payload),
    ],
  );
}

export interface WebhookResult {
  received: true;
  replay?: true;
  ignored?: true;
  paymentStatus?: string;
  tradeStatus?: string;
}

/** Applies one signed collection callback. */
export async function handleCollectionCallback(
  ctx: AppContext,
  input: { provider: string; rawBody: string; payload: CallbackPayload },
): Promise<WebhookResult> {
  const reference = input.payload.checkoutRequestId;
  if (!reference) {
    throw unprocessable('WEBHOOK_INVALID', 'The collection callback has no checkoutRequestId');
  }

  const collection = await ctx.paymentProvider.getCollection(reference).catch(paymentFailure);
  if (!collection) {
    throw new AppError(
      502,
      'PAYMENT_NOT_FOUND',
      'The payment provider has no record of this collection',
    );
  }
  if (
    input.payload.amountMinor !== undefined &&
    input.payload.amountMinor !== collection.amountMinor
  ) {
    throw unprocessable('WEBHOOK_AMOUNT_MISMATCH', 'The callback amount does not match the provider');
  }
  if (input.payload.currency !== undefined && input.payload.currency !== collection.currency) {
    throw unprocessable(
      'WEBHOOK_CURRENCY_MISMATCH',
      'The callback currency does not match the provider',
    );
  }

  const eventType = callbackEventType('collection', collection.status);
  const claim = await claimEvent(ctx, {
    provider: input.provider,
    eventId: `collection:${reference}:${collection.status.toUpperCase()}`,
    eventType,
    rawBody: input.rawBody,
  });
  if (claim.replay) return { received: true, replay: true };

  const applied = await withTransaction(ctx.pool, async (client) => {
    const trade = await findTradeByAttemptReference(client, {
      provider: input.provider,
      externalReference: reference,
      forUpdate: true,
    });
    if (!trade) {
      await markEvent(client, { eventId: claim.id, status: 'ignored' });
      return { outcome: 'ignored' as const, tradeId: null as string | null };
    }
    const attempt = await findPaymentAttemptByReference(client, {
      provider: input.provider,
      externalReference: reference,
      forUpdate: true,
    });
    if (!attempt) {
      await markEvent(client, {
        eventId: claim.id,
        status: 'ignored',
        tradeId: trade.id,
      });
      return { outcome: 'ignored' as const, tradeId: trade.id };
    }
    const result = await applyCollectionResult(client, { trade, attempt, collection });
    await markEvent(client, {
      eventId: claim.id,
      status: 'processed',
      tradeId: trade.id,
      paymentAttemptId: attempt.id,
      payload: {
        checkoutRequestId: reference,
        status: collection.status,
        amountMinor: collection.amountMinor,
        currency: collection.currency,
      },
    });
    return { outcome: result.outcome, tradeId: trade.id };
  });

  if (applied.outcome === 'late_paid' && applied.tradeId) {
    try {
      const refund = await refundTrade(ctx, {
        tradeId: applied.tradeId,
        reasonCode: 'late_collection',
        allowClosed: true,
      });
      return {
        received: true,
        paymentStatus: collection.status,
        tradeStatus: refund.trade.status,
      };
    } catch (error) {
      // The collection is already booked. Reopen the event so the provider's
      // retry can finish the refund instead of leaving the money parked.
      await withTransaction(ctx.pool, async (client) => {
        await client.query(
          `UPDATE payment_events SET status = 'received', processed_at = NULL WHERE id = $1`,
          [claim.id],
        );
      });
      throw error;
    }
  }

  if (applied.outcome === 'escrowed' && applied.tradeId && ctx.p2pEnabled) {
    await tryMatchTrade(ctx, { tradeId: applied.tradeId }).catch(() => undefined);
  }

  return {
    received: true,
    ...(applied.outcome === 'ignored' ? { ignored: true as const } : {}),
    paymentStatus: collection.status,
  };
}

/** Applies one signed payout callback. */
export async function handlePayoutCallback(
  ctx: AppContext,
  input: { provider: string; rawBody: string; payload: CallbackPayload },
): Promise<WebhookResult> {
  const providerReference = input.payload.payoutId;
  if (!providerReference) {
    throw unprocessable('WEBHOOK_INVALID', 'The payout callback has no payoutId');
  }

  const payout = await ctx.paymentProvider.getPayout(providerReference).catch(paymentFailure);
  if (!payout) {
    throw new AppError(502, 'PAYOUT_NOT_FOUND', 'The payment provider has no record of this payout');
  }

  const eventType = callbackEventType('payout', payout.status);
  const claim = await claimEvent(ctx, {
    provider: input.provider,
    eventId: `payout:${providerReference}:${payout.status.toUpperCase()}`,
    eventType,
    rawBody: input.rawBody,
  });
  if (claim.replay) return { received: true, replay: true };

  const known = await withTransaction(ctx.pool, async (client) => {
    const row = await findPayoutByProviderReference(client, {
      provider: input.provider,
      providerReference,
    });
    if (!row) {
      await markEvent(client, { eventId: claim.id, status: 'ignored' });
      return null;
    }
    return row;
  });
  if (!known) return { received: true, ignored: true };

  const result = await applyPayoutSnapshot(ctx, { payoutId: known.id, snapshot: payout });
  await withTransaction(ctx.pool, async (client) => {
    await markEvent(client, {
      eventId: claim.id,
      status: 'processed',
      tradeId: known.trade_id,
      payload: {
        payoutId: providerReference,
        status: payout.status,
        amountMinor: payout.amountMinor,
        currency: payout.currency,
      },
    });
  });
  return { received: true, paymentStatus: payout.status, tradeStatus: result.trade.status };
}
