import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import { requireUserId } from '../auth.js';
import {
  AppError,
  badRequest,
  conflict,
  forbidden,
  serviceUnavailable,
  unauthorized,
  unprocessable,
} from '../errors.js';
import {
  PricingRejectedError,
  PricingUnavailableError,
} from '../../providers/pricing.js';
import { createQuote, QuotePricingInvalidError } from '../../quotes.js';
import { assertQuotesOpen } from '../../services/service-controls.js';
import { assertWithinDailyLimit } from '../../services/limits.js';

const currency = z
  .string()
  .trim()
  .length(3)
  .transform((value) => value.toUpperCase());

const corridorSchema = z
  .object({
    sendCurrency: currency,
    receiveCurrency: currency,
    sendAmountMinor: z.coerce.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  })
  .superRefine((value, ctx) => {
    if (value.sendCurrency === value.receiveCurrency) {
      ctx.addIssue({
        code: 'custom',
        path: ['receiveCurrency'],
        message: 'The send and receive currencies must differ',
      });
    }
  });

type CorridorInput = z.infer<typeof corridorSchema>;

interface PricingUser {
  id: string;
  phone: string;
  kyc_status: 'not_started' | 'pending' | 'verified' | 'rejected';
  tier_code: string;
  limit_currency_code: string | null;
}

function parseQuery(input: unknown): CorridorInput {
  const result = corridorSchema.safeParse(input);
  if (!result.success) {
    throw badRequest('VALIDATION_FAILED', 'The corridor parameters are invalid');
  }
  return result.data;
}

function pricingFailure(error: unknown): never {
  if (error instanceof PricingRejectedError) {
    throw new AppError(error.statusCode, error.code, error.message);
  }
  if (error instanceof PricingUnavailableError) {
    throw serviceUnavailable(error.code, error.message);
  }
  if (error instanceof QuotePricingInvalidError) {
    throw serviceUnavailable(
      'PRICING_UNAVAILABLE',
      'The pricing provider returned an invalid quote',
    );
  }
  throw error;
}

async function loadUser(ctx: AppContext, userId: string): Promise<PricingUser> {
  const result = await ctx.pool.query<PricingUser>(
    `SELECT id, phone, kyc_status, tier_code, limit_currency_code
     FROM users
     WHERE id = $1 AND deleted_at IS NULL`,
    [userId],
  );
  const user = result.rows[0];
  if (!user) throw unauthorized('USER_NOT_FOUND', 'The signed-in account no longer exists');
  return user;
}

async function assertSupportedCurrencies(
  ctx: AppContext,
  input: CorridorInput,
): Promise<void> {
  const result = await ctx.pool.query(
    `SELECT code FROM currencies WHERE code = $1 OR code = $2`,
    [input.sendCurrency, input.receiveCurrency],
  );
  if (result.rowCount !== 2) {
    throw unprocessable('VALIDATION_FAILED', 'The currency is not supported');
  }
}

/**
 * The daily limit is re-checked at initiation too. This endpoint checks early
 * so a user learns about the limit before a provider quote is requested.
 */
async function assertCorrectLimit(
  ctx: AppContext,
  user: PricingUser,
  input: CorridorInput,
): Promise<void> {
  await assertWithinDailyLimit(
    ctx.pool,
    user,
    { sendCurrency: input.sendCurrency, sendAmountMinor: BigInt(input.sendAmountMinor) },
    ctx.limitTimezone,
  );
}

export function registerPricingRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get('/rates', async () => {
    return ctx.pricingProvider.rates().catch(pricingFailure);
  });

  app.get('/trade/estimate', async (request) => {
    const userId = requireUserId(request);
    await loadUser(ctx, userId);
    const input = parseQuery(request.query);
    await assertSupportedCurrencies(ctx, input);

    return ctx.pricingProvider.estimate(input).catch(pricingFailure);
  });

  app.post('/trade/quote', async (request) => {
    const userId = requireUserId(request);
    await assertQuotesOpen(ctx.pool);
    const input = parseQuery(request.body);
    const user = await loadUser(ctx, userId);

    if (user.kyc_status !== 'verified') {
      throw forbidden('VERIFICATION_REQUIRED', 'Verify your identity before requesting a quote');
    }
    if (user.limit_currency_code === null) {
      throw conflict('PROFILE_INCOMPLETE', 'Finish the KYC step before requesting a quote');
    }

    await assertSupportedCurrencies(ctx, input);
    await assertCorrectLimit(ctx, user, input);

    const priced = await ctx.pricingProvider
      .quote({ ...input, phone: user.phone })
      .catch(pricingFailure);

    const quotedAt = new Date(priced.quotedAt);
    const expiresAt = new Date(priced.expiresAt);
    if (
      Number.isNaN(quotedAt.getTime()) ||
      Number.isNaN(expiresAt.getTime()) ||
      expiresAt.getTime() <= Date.now()
    ) {
      throw serviceUnavailable('PRICING_UNAVAILABLE', 'The pricing provider returned an expired quote');
    }

    return createQuote(ctx.pool, {
      userId,
      sendCurrency: input.sendCurrency,
      receiveCurrency: input.receiveCurrency,
      sendAmountMinor: BigInt(input.sendAmountMinor),
      rate: priced.rate,
      quotedAt,
      expiresAt,
      routes: priced.routes,
    }).catch(pricingFailure);
  });
}
