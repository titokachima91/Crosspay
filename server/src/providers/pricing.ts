import { z } from 'zod';

/**
 * Pricing is a provider concern, not a route concern. The API supports two
 * implementations:
 *
 * - DisabledPricingProvider: honest 503 until a real pricing source is
 *   approved. This is the default.
 * - SandboxPricingProvider: the reference provider exposed by
 *   kachi-fintech-sandbox at /api/v1/sandbox/pricing/*. It returns the
 *   sandbox's current rate, fee and route availability, never a real quote
 *   contract.
 *
 * The provider never persists a quote and never applies a user's limits; the
 * API owns those, so a provider outage cannot consume a quote or a limit.
 */

export const pricingLevelSchema = z.enum(['healthy', 'limited', 'down']);

export const pricingStatusSchema = z.object({
  code: z.string().min(1),
  level: pricingLevelSchema,
});

export const pricingRouteSchema = z.object({
  route: z.enum(['p2p', 'bank']),
  feeBps: z.number().int().min(0).max(10_000),
  feeMinor: z.number().int().nonnegative(),
  payoutMinor: z.number().int().positive(),
  totalDebitMinor: z.number().int().positive(),
  estimatedMinSeconds: z.number().int().positive(),
  estimatedMaxSeconds: z.number().int().positive(),
  isRecommended: z.boolean(),
  isAvailable: z.boolean(),
  matchingDensityPercent: z.number().int().min(0).max(100).optional(),
  status: pricingStatusSchema.optional(),
  safeguardCode: z.string().min(1).max(64).optional(),
  breakdown: z
    .array(
      z.object({
        code: z.string().min(1),
        amountMinor: z.number().int(),
      }),
    )
    .default([]),
});

export const pricingQuoteSchema = z.object({
  rate: z.number().positive(),
  quotedAt: z.string().min(1),
  expiresAt: z.string().min(1),
  routes: z.array(pricingRouteSchema).min(1),
});

export const pricingEstimateSchema = z.object({
  rate: z.number().positive(),
  receiveAmountMinor: z.number().int().positive(),
  estimatedMinSeconds: z.number().int().positive(),
  estimatedMaxSeconds: z.number().int().positive(),
  route: z.enum(['p2p', 'bank']),
});

export const ratesPayloadSchema = z.object({
  rates: z.array(
    z.object({
      from: z.string().length(3),
      to: z.string().length(3),
      rate: z.number().positive(),
      change24hPercent: z.number().optional(),
      status: pricingStatusSchema.optional(),
    }),
  ),
  queueHealth: z
    .object({
      p2pDensityPercent: z.number().min(0).max(100),
      bankSweepPercent: z.number().min(0).max(100),
    })
    .optional(),
});

export type PricingStatus = z.infer<typeof pricingStatusSchema>;
export type PricingRoute = z.infer<typeof pricingRouteSchema>;
export type PricingQuote = z.infer<typeof pricingQuoteSchema>;
export type PricingEstimate = z.infer<typeof pricingEstimateSchema>;
export type RatesPayload = z.infer<typeof ratesPayloadSchema>;

export interface PricingRequest {
  sendCurrency: string;
  receiveCurrency: string;
  sendAmountMinor: number;
}

export interface PricingProvider {
  readonly name: string;
  rates(): Promise<RatesPayload>;
  estimate(input: PricingRequest): Promise<PricingEstimate>;
  quote(input: PricingRequest & { phone?: string }): Promise<PricingQuote>;
}

/** The provider is intentionally not connected. Map this to 503. */
export class PricingUnavailableError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'PricingUnavailableError';
  }
}

/** The provider evaluated the request and rejected it (bad corridor, etc.). */
export class PricingRejectedError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'PricingRejectedError';
  }
}

export class DisabledPricingProvider implements PricingProvider {
  readonly name = 'disabled';

  rates(): Promise<RatesPayload> {
    return Promise.reject(
      new PricingUnavailableError('PRICING_NOT_CONFIGURED', 'Live rates are not connected yet'),
    );
  }

  estimate(): Promise<PricingEstimate> {
    return Promise.reject(
      new PricingUnavailableError('PRICING_NOT_CONFIGURED', 'Live pricing is not connected yet'),
    );
  }

  quote(): Promise<PricingQuote> {
    return Promise.reject(
      new PricingUnavailableError('PRICING_NOT_CONFIGURED', 'Live pricing is not connected yet'),
    );
  }
}

interface SandboxOptions {
  baseUrl: string;
  apiKey: string;
  timeoutMs?: number;
}

function parseProvider<T>(schema: z.ZodType<T>, body: unknown): T {
  const result = schema.safeParse(body);
  if (!result.success) {
    throw new PricingUnavailableError(
      'PRICING_UNAVAILABLE',
      'The pricing provider returned an invalid response',
    );
  }
  return result.data;
}

function providerError(status: number, body: unknown): PricingRejectedError {
  const candidate = body as
    | { error?: { code?: unknown; message?: unknown } | string; message?: unknown }
    | null;
  const nested = candidate && typeof candidate.error === 'object' ? candidate.error : null;
  const code = typeof nested?.code === 'string' ? nested.code : 'PRICING_REJECTED';
  const message =
    typeof nested?.message === 'string'
      ? nested.message
      : typeof candidate?.message === 'string'
        ? candidate.message
        : 'The pricing provider rejected the request';
  return new PricingRejectedError(status, code, message);
}

async function readJson(response: Response): Promise<unknown> {
  const text = await response.text();
  if (text.length === 0) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new PricingUnavailableError(
      'PRICING_UNAVAILABLE',
      'The pricing provider returned an unreadable response',
    );
  }
}

/**
 * Speaks the sandbox provider contract. Every failure is translated into a
 * pricing error so callers cannot accidentally treat a network failure as a
 * zero rate.
 */
export class SandboxPricingProvider implements PricingProvider {
  readonly name = 'sandbox';
  private readonly baseUrl: string;
  private readonly apiKey: string;
  private readonly timeoutMs: number;

  constructor(options: SandboxOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, '');
    this.apiKey = options.apiKey;
    this.timeoutMs = options.timeoutMs ?? 5_000;
  }

  private async get(path: string, query: Record<string, string | number | undefined>, authenticated: boolean): Promise<unknown> {
    const url = new URL(`${this.baseUrl}${path}`);
    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined) url.searchParams.set(key, String(value));
    }

    let response: Response;
    try {
      response = await fetch(url, {
        headers: authenticated ? { 'x-api-key': this.apiKey } : {},
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch {
      throw new PricingUnavailableError(
        'PRICING_UNAVAILABLE',
        'The pricing provider is unavailable',
      );
    }

    const body = await readJson(response);
    if (!response.ok) {
      if (response.status >= 400 && response.status < 500) {
        throw providerError(response.status, body);
      }
      throw new PricingUnavailableError(
        'PRICING_UNAVAILABLE',
        'The pricing provider is unavailable',
      );
    }
    return body;
  }

  async rates(): Promise<RatesPayload> {
    const body = await this.get('/api/v1/rates', {}, false);
    return parseProvider(ratesPayloadSchema, body);
  }

  async estimate(input: PricingRequest): Promise<PricingEstimate> {
    const body = await this.get(
      '/api/v1/sandbox/pricing/estimate',
      {
        sendCurrency: input.sendCurrency,
        receiveCurrency: input.receiveCurrency,
        sendAmountMinor: input.sendAmountMinor,
      },
      true,
    );
    return parseProvider(pricingEstimateSchema, body);
  }

  async quote(input: PricingRequest & { phone?: string }): Promise<PricingQuote> {
    const body = await this.get(
      '/api/v1/sandbox/pricing/quote',
      {
        sendCurrency: input.sendCurrency,
        receiveCurrency: input.receiveCurrency,
        sendAmountMinor: input.sendAmountMinor,
        phone: input.phone,
      },
      true,
    );
    return parseProvider(pricingQuoteSchema, body);
  }
}
