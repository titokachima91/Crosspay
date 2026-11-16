import type { FastifyInstance } from 'fastify';
import type { PoolClient } from 'pg';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import type { UserRow } from '../../services/users.js';
import { requireUserId } from '../auth.js';
import {
  AppError,
  conflict,
  forbidden,
  notFound,
  serviceUnavailable,
  unauthorized,
} from '../errors.js';
import { parseBody, requireIdempotencyKey } from '../validation.js';
import { runIdempotent } from '../idempotent-route.js';
import {
  QuoteExpiredError,
  QuoteNotActiveError,
  QuoteNotFoundError,
  consumeQuote,
} from '../../quotes.js';
import { assertWithinDailyLimit } from '../../services/limits.js';
import {
  PaymentRejectedError,
  PaymentUnavailableError,
} from '../../providers/payments.js';
import {
  applyCollectionResult,
  attachPaymentAttempt,
  findTradeForUser,
  insertPaymentAttempt,
  insertTrade,
  listTradeEvents,
  listTradesForUser,
  loadPaymentAttempt,
  loadQuoteRoute,
  mapTrade,
  resolveRecipientRail,
  setTradeStatus,
  tradeReferenceFor,
  type TradeView,
} from '../../trades.js';
import { refundTrade } from '../../payments.js';
import { tryMatchTrade } from '../../matching.js';

const accountSchema = z
  .string()
  .trim()
  .min(4)
  .max(64)
  .regex(/^[A-Za-z0-9+][A-Za-z0-9+ -]*$/, 'Unsupported account characters');

const initiateSchema = z.object({
  quoteId: z.string().uuid(),
  route: z.enum(['p2p', 'bank']),
  recipient: z.object({
    railId: z.string().trim().min(1).max(64),
    account: accountSchema,
    name: z.string().trim().min(1).max(200),
    reference: z.string().trim().min(1).max(120).optional(),
  }),
});

const idSchema = z.object({ id: z.string().uuid() });
const listSchema = z.object({
  limit: z.coerce.number().int().min(1).max(200).optional(),
});

interface TradeUserRow extends UserRow {
  limit_currency_code: string | null;
}

interface CollectionInstructions {
  pushSent: boolean;
  networkName?: string;
  amountMinor: number;
  pushTimeoutSeconds: number;
  pollIntervalSeconds: number;
  manual?: { methodCode: string; number: string; reference: string };
}

interface InitiateResponse {
  trade: TradeView;
  collection: CollectionInstructions;
}

interface ClaimResponse {
  trade: TradeView;
  paymentStatus: string;
  /** Internal retry marker; stripped before the response leaves the server. */
  needsRefund?: boolean;
  refundStatus?: string;
}

function normalizeAccount(account: string): string {
  return account.replace(/[\s-]/g, '');
}

function last4(account: string): string {
  const value = account.replace(/[^A-Za-z0-9]/g, '').slice(-4);
  return value.length > 0 ? value : '0000';
}

async function loadTradeUser(client: PoolClient, userId: string): Promise<TradeUserRow> {
  const result = await client.query<TradeUserRow>(
    `SELECT id, phone, display_name, account_type, hub_id, kyc_status,
            tier_code, limit_currency_code
     FROM users
     WHERE id = $1 AND deleted_at IS NULL`,
    [userId],
  );
  const user = result.rows[0];
  if (!user) throw unauthorized('USER_NOT_FOUND', 'The signed-in account no longer exists');
  if (user.kyc_status !== 'verified') {
    throw forbidden('VERIFICATION_REQUIRED', 'Verify your identity before sending money');
  }
  if (user.limit_currency_code === null) {
    throw conflict('PROFILE_INCOMPLETE', 'Finish the KYC step before sending money');
  }
  return user;
}

/** Maps quote lifecycle errors to the app-facing codes and 4xx statuses. */
function quoteFailure(error: unknown): never {
  if (error instanceof QuoteNotFoundError) {
    throw notFound('QUOTE_NOT_FOUND', 'The rate lock does not exist');
  }
  if (error instanceof QuoteExpiredError) {
    throw conflict('QUOTE_EXPIRED', 'The rate lock has expired; request a new quote');
  }
  if (error instanceof QuoteNotActiveError) {
    throw conflict('QUOTE_NOT_ACTIVE', 'The rate lock was already used');
  }
  throw error;
}

/**
 * A rejected payment is not retried blindly. An unavailable provider is a 503,
 * and the disabled default keeps the contract's honest PAYOUT_NOT_CONFIGURED.
 */
function paymentFailure(error: unknown): never {
  if (error instanceof PaymentRejectedError) {
    throw new AppError(error.statusCode, error.code, error.message);
  }
  if (error instanceof PaymentUnavailableError) {
    if (error.code === 'PAYMENT_PROVIDER_NOT_CONFIGURED') {
      throw serviceUnavailable('PAYOUT_NOT_CONFIGURED', 'Payments are not connected yet');
    }
    throw serviceUnavailable(error.code, error.message);
  }
  throw error;
}

function pushSentFor(status: string): boolean {
  return !['FAILED', 'FAILURE', 'CANCELLED', 'CANCELED', 'EXPIRED', 'REJECTED'].includes(
    status.trim().toUpperCase(),
  );
}

function tradeError(
  code: string,
  message: string,
  trade: TradeView,
): { trade: TradeView; error: { code: string; message: string } } {
  return { trade, error: { code, message } };
}

export function registerTradeRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.post('/trade/initiate', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const body = parseBody(initiateSchema, request.body);
    const normalizedAccount = normalizeAccount(body.recipient.account);
    const accountHash = ctx.crypto.hashSensitive(normalizedAccount);

    const result = await runIdempotent<InitiateResponse>(
      ctx,
      { userId, scope: 'trade.initiate', key, requestBody: request.body },
      async (client) => {
        const user = await loadTradeUser(client, userId);

        let quote;
        try {
          quote = await consumeQuote(client, { quoteId: body.quoteId, userId });
        } catch (error) {
          quoteFailure(error);
        }

        await assertWithinDailyLimit(
          client,
          user,
          {
            sendCurrency: quote.send_currency,
            sendAmountMinor: BigInt(quote.send_amount_minor),
          },
          ctx.limitTimezone,
        );

        const route = await loadQuoteRoute(client, {
          quoteId: quote.id,
          route: body.route,
        });
        await resolveRecipientRail(client, {
          railId: body.recipient.railId,
          receiveCurrency: quote.receive_currency,
          route: body.route,
        });

        const reference = tradeReferenceFor({
          userId,
          quoteId: quote.id,
          route: body.route,
          railId: body.recipient.railId,
          accountHash,
        });

        const trade = await insertTrade(client, {
          reference,
          userId,
          quoteId: quote.id,
          quoteRouteId: route.id,
          route: body.route,
          sendCurrency: quote.send_currency,
          receiveCurrency: quote.receive_currency,
          sendAmountMinor: BigInt(quote.send_amount_minor),
          feeMinor: BigInt(route.fee_minor),
          feeBps: route.fee_bps,
          receiveAmountMinor: BigInt(route.payout_minor),
          rate: quote.rate,
          beneficiaryName: body.recipient.name,
          beneficiaryRailId: body.recipient.railId,
          beneficiaryAccountEncrypted: ctx.crypto.encrypt(normalizedAccount),
          beneficiaryAccountLast4: last4(normalizedAccount),
          beneficiaryReference: body.recipient.reference ?? null,
        });

        const totalDebit = BigInt(route.total_debit_minor);
        let collection;
        try {
          collection = await ctx.paymentProvider.createCollection({
            phoneNumber: user.phone,
            amountMinor: Number(totalDebit),
            currency: trade.send_currency,
            transactionRef: reference,
            callbackUrl: ctx.paymentCallbackUrl,
          });
        } catch (error) {
          paymentFailure(error);
        }

        const attempt = await insertPaymentAttempt(client, {
          tradeId: trade.id,
          provider: ctx.paymentProvider.name,
          externalReference: collection.checkoutRequestId,
          amountMinor: totalDebit,
          currencyCode: trade.send_currency,
          networkName: collection.provider,
          pushSent: pushSentFor(collection.status),
          pushTimeoutSeconds: ctx.collectionPushTimeoutSeconds,
          pollIntervalSeconds: ctx.collectionPollIntervalSeconds,
          status: pushSentFor(collection.status) ? 'sent' : 'pending',
        });
        await attachPaymentAttempt(client, { tradeId: trade.id, attemptId: attempt.id });

        const applied = await applyCollectionResult(client, { trade, attempt, collection });
        const instructions: CollectionInstructions = {
          pushSent: pushSentFor(collection.status),
          amountMinor: Number(totalDebit),
          pushTimeoutSeconds: ctx.collectionPushTimeoutSeconds,
          pollIntervalSeconds: ctx.collectionPollIntervalSeconds,
        };
        if (collection.provider) instructions.networkName = collection.provider;

        if (applied.outcome === 'failed') {
          const failedView = mapTrade(applied.trade);
          return {
            status: 200,
            body: { trade: failedView, collection: instructions },
            resourceType: 'trade',
            resourceId: trade.id,
          };
        }

        return {
          status: 201,
          body: { trade: mapTrade(applied.trade), collection: instructions },
          resourceType: 'trade',
          resourceId: trade.id,
        };
      },
    );

    if (result.replayed) reply.header('Idempotency-Replay', 'true');
    if (ctx.p2pEnabled) {
      const body = result.body as InitiateResponse;
      if (body.trade.status === 'escrowed') {
        await tryMatchTrade(ctx, { tradeId: body.trade.id, userId }).catch(() => undefined);
      }
    }
    return reply.code(result.status).send(result.body);
  });

  app.get('/trades', async (request) => {
    const userId = requireUserId(request);
    const query = parseBody(listSchema, request.query);
    const trades = await listTradesForUser(ctx.pool, {
      userId,
      limit: query.limit ?? 100,
    });
    return { trades };
  });

  app.get('/trades/:id', async (request) => {
    const userId = requireUserId(request);
    const { id } = parseBody(idSchema, request.params);
    const trade = await findTradeForUser(ctx.pool, { userId, tradeId: id });
    return mapTrade(trade);
  });

  app.get('/trades/:id/history', async (request) => {
    const userId = requireUserId(request);
    const { id } = parseBody(idSchema, request.params);
    await findTradeForUser(ctx.pool, { userId, tradeId: id });
    return { events: await listTradeEvents(ctx.pool, id) };
  });

  /**
   * The payer says they paid manually. This only re-checks the provider now; it
   * never marks a trade paid without the provider confirming. A confirmed
   * collection posts the deposit and moves the trade to escrowed.
   */
  app.post('/trades/:id/payment-claim', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const { id } = parseBody(idSchema, request.params);

    const result = await runIdempotent<ClaimResponse>(
      ctx,
      { userId, scope: 'trade.payment_claim', key, requestBody: { id } },
      async (client) => {
        const trade = await findTradeForUser(client, {
          userId,
          tradeId: id,
          forUpdate: true,
        });
        const attempt = await loadPaymentAttempt(client, {
          tradeId: trade.id,
          attemptId: trade.current_payment_attempt_id,
        });
        if (!attempt || attempt.external_reference === null) {
          throw notFound('PAYMENT_NOT_FOUND', 'This trade has no payment attempt to check');
        }
        if (!['pending_deposit', 'cancelled', 'expired', 'failed'].includes(trade.status)) {
          return {
            status: 200,
            body: { trade: mapTrade(trade), paymentStatus: attempt.status.toUpperCase() },
            resourceType: 'trade',
            resourceId: trade.id,
          };
        }

        const collection = await ctx.paymentProvider
          .getCollection(attempt.external_reference)
          .catch(paymentFailure);
        if (!collection) {
          throw new AppError(
            502,
            'PAYMENT_NOT_FOUND',
            'The payment provider has no record of this collection',
          );
        }

        const applied = await applyCollectionResult(client, { trade, attempt, collection });
        if (applied.outcome === 'late_paid') {
          return {
            status: 200,
            body: {
              trade: mapTrade(applied.trade),
              paymentStatus: collection.status,
              needsRefund: true,
            },
            resourceType: 'trade',
            resourceId: trade.id,
          };
        }
        return {
          status: 200,
          body: {
            trade: mapTrade(applied.trade),
            paymentStatus: collection.status,
          },
          resourceType: 'trade',
          resourceId: trade.id,
        };
      },
    );

    if (result.replayed) reply.header('Idempotency-Replay', 'true');
    const body = result.body as ClaimResponse;
    if (body.needsRefund) {
      const refunded = await refundTrade(ctx, {
        userId,
        tradeId: id,
        reasonCode: 'late_collection',
        allowClosed: true,
      });
      body.trade = refunded.trade;
      body.refundStatus = refunded.refund.status;
      delete body.needsRefund;
    }
    if (ctx.p2pEnabled && body.trade.status === 'escrowed') {
      await tryMatchTrade(ctx, { tradeId: id, userId }).catch(() => undefined);
    }
    return reply.code(result.status).send(body);
  });

  app.post('/trades/:id/cancel', async (request, reply) => {
    const userId = requireUserId(request);
    const key = requireIdempotencyKey(request);
    const { id } = parseBody(idSchema, request.params);

    const result = await runIdempotent<{ trade?: TradeView; error?: { code: string; message: string } }>(
      ctx,
      { userId, scope: 'trade.cancel', key, requestBody: { id } },
      async (client) => {
        const trade = await findTradeForUser(client, {
          userId,
          tradeId: id,
          forUpdate: true,
        });

        if (trade.status !== 'pending_deposit') {
          if (
            ['escrowed', 'matching', 'matched', 'disbursing', 'completed'].includes(trade.status)
          ) {
            return {
              status: 409,
              body: tradeError(
                'ALREADY_PAID',
                'The payment already arrived; keep watching the trade',
                mapTrade(trade),
              ),
              resourceType: 'trade',
              resourceId: trade.id,
            };
          }
          return {
            status: 409,
            body: tradeError(
              'CANNOT_CANCEL',
              'This trade can no longer be cancelled',
              mapTrade(trade),
            ),
            resourceType: 'trade',
            resourceId: trade.id,
          };
        }

        const attempt = await loadPaymentAttempt(client, {
          tradeId: trade.id,
          attemptId: trade.current_payment_attempt_id,
        });

        // Never cancel a trade whose push the provider has already confirmed.
        if (attempt?.external_reference) {
          const collection = await ctx.paymentProvider
            .getCollection(attempt.external_reference)
            .catch(paymentFailure);
          if (collection) {
            const applied = await applyCollectionResult(client, { trade, attempt, collection });
            if (applied.outcome === 'escrowed') {
              return {
                status: 409,
                body: tradeError(
                  'ALREADY_PAID',
                  'The payment already arrived; keep watching the trade',
                  mapTrade(applied.trade),
                ),
                resourceType: 'trade',
                resourceId: trade.id,
              };
            }
            if (applied.outcome === 'failed') {
              return {
                status: 200,
                body: { trade: mapTrade(applied.trade) },
                resourceType: 'trade',
                resourceId: trade.id,
              };
            }
          }
        }

        if (attempt) {
          await client.query(
            `UPDATE payment_attempts
             SET status = 'expired'
             WHERE id = $1 AND status IN ('pending', 'sent')`,
            [attempt.id],
          );
        }

        const cancelled = await setTradeStatus(client, {
          tradeId: trade.id,
          from: ['pending_deposit'],
          to: 'cancelled',
          actor: 'user',
          failureCode: 'CANCELLED_BY_USER',
        });

        return {
          status: 200,
          body: { trade: mapTrade(cancelled) },
          resourceType: 'trade',
          resourceId: trade.id,
        };
      },
    );

    if (result.replayed) reply.header('Idempotency-Replay', 'true');
    return reply.code(result.status).send(result.body);
  });
}
