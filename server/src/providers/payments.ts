import { z } from 'zod';

/**
 * Payment provider boundary.
 *
 * CrossPay owns the trade, collection instructions, payout orchestration,
 * idempotency and ledger. The provider only performs the local collection,
 * payout, refund or bank transfer and reports its own status. A provider
 * rejection is not retried blindly; a transport/5xx failure is.
 */

export const collectionSchema = z.object({
  checkoutRequestId: z.string().min(1),
  transactionRef: z.string().min(1),
  provider: z.string().min(1),
  phoneNumber: z.string().min(1),
  amountMinor: z.number().int().positive(),
  currency: z.string().length(3),
  feeMinor: z.number().int().nonnegative().default(0),
  status: z.string().min(1),
  resultCode: z.number().int().nullable().optional(),
  resultDesc: z.string().nullable().optional(),
  mpesaReceiptNumber: z.string().nullable().optional(),
  walletBacked: z.boolean().optional(),
});

export const payoutSchema = z.object({
  payoutId: z.string().min(1),
  transactionRef: z.string().min(1),
  provider: z.string().min(1),
  phoneNumber: z.string().min(1),
  amountMinor: z.number().int().positive(),
  currency: z.string().length(3),
  feeMinor: z.number().int().nonnegative().default(0),
  status: z.string().min(1),
  resultCode: z.number().int().nullable().optional(),
  resultDesc: z.string().nullable().optional(),
  mpesaReceiptNumber: z.string().nullable().optional(),
  walletBacked: z.boolean().optional(),
});

export const refundSchema = z.object({
  refundId: z.string().min(1),
  requestId: z.string().min(1),
  amountMinor: z.number().int().positive(),
  currency: z.string().length(3),
  status: z.string().min(1),
  feeRefundMinor: z.number().int().nonnegative().optional(),
  journalTransactionId: z.string().nullable().optional(),
});

export const bankAccountSchema = z.object({
  accountRef: z.string().min(1),
  name: z.string().min(1),
  currency: z.string().length(3),
  type: z.string().min(1),
  ownerType: z.string().min(1).optional(),
  purpose: z.string().min(1).optional(),
  status: z.string().min(1),
  institutionId: z.string().min(1).optional(),
  balanceMinor: z.number().int().optional(),
});

export const bankTransferSchema = z.object({
  transactionRef: z.string().min(1),
  state: z.string().min(1),
  amountMinor: z.number().int().positive(),
  currency: z.string().length(3),
  fromAccount: z.string().min(1),
  toAccount: z.string().min(1),
});

export type PaymentCollection = z.infer<typeof collectionSchema>;
export type PaymentPayout = z.infer<typeof payoutSchema>;
export type PaymentRefund = z.infer<typeof refundSchema>;
export type PaymentBankAccount = z.infer<typeof bankAccountSchema>;
export type PaymentBankTransfer = z.infer<typeof bankTransferSchema>;

export interface CollectionInput {
  phoneNumber: string;
  amountMinor: number;
  currency: string;
  provider?: string;
  institutionId?: string;
  transactionRef: string;
  callbackUrl?: string;
}

export interface PayoutInput {
  phoneNumber: string;
  amountMinor: number;
  currency: string;
  provider?: string;
  institutionId?: string;
  transactionRef: string;
  callbackUrl?: string;
}

export interface RefundInput {
  requestId: string;
  amountMinor: number;
  reason?: string;
}

export interface TransferInput {
  transactionRef: string;
  fromAccount: string;
  toAccount: string;
  amountMinor: number;
  note?: string;
}

export interface PaymentProvider {
  readonly name: string;
  createCollection(input: CollectionInput): Promise<PaymentCollection>;
  getCollection(checkoutRequestId: string): Promise<PaymentCollection | null>;
  createPayout(input: PayoutInput): Promise<PaymentPayout>;
  getPayout(payoutId: string): Promise<PaymentPayout | null>;
  refund(input: RefundInput): Promise<PaymentRefund>;
  getBankAccount(accountRef: string): Promise<PaymentBankAccount | null>;
  transfer(input: TransferInput): Promise<PaymentBankTransfer>;
}

export class PaymentUnavailableError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'PaymentUnavailableError';
  }
}

export class PaymentRejectedError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'PaymentRejectedError';
  }
}

export class DisabledPaymentProvider implements PaymentProvider {
  readonly name = 'disabled';

  private fail(): Promise<never> {
    return Promise.reject(
      new PaymentUnavailableError(
        'PAYMENT_PROVIDER_NOT_CONFIGURED',
        'The payment provider is not connected yet',
      ),
    );
  }

  createCollection(): Promise<PaymentCollection> { return this.fail(); }
  getCollection(): Promise<PaymentCollection | null> { return this.fail(); }
  createPayout(): Promise<PaymentPayout> { return this.fail(); }
  getPayout(): Promise<PaymentPayout | null> { return this.fail(); }
  refund(): Promise<PaymentRefund> { return this.fail(); }
  getBankAccount(): Promise<PaymentBankAccount | null> { return this.fail(); }
  transfer(): Promise<PaymentBankTransfer> { return this.fail(); }
}

interface SandboxOptions {
  baseUrl: string;
  apiKey: string;
  timeoutMs?: number;
}

interface SandboxPspProvider {
  id: string;
  currency: string;
  kind: string;
  phonePrefixes: string[];
}

function providerError(status: number, body: unknown): PaymentRejectedError {
  const candidate = body as
    | { error?: { code?: unknown; message?: unknown } | string; message?: unknown }
    | null;
  const nested = candidate && typeof candidate.error === 'object' ? candidate.error : null;
  const code = typeof nested?.code === 'string' ? nested.code : 'PAYMENT_REJECTED';
  const message =
    typeof nested?.message === 'string'
      ? nested.message
      : typeof candidate?.message === 'string'
        ? candidate.message
        : 'The payment provider rejected the request';
  return new PaymentRejectedError(status, code, message);
}

function parseProvider<T>(schema: z.ZodType<T>, body: unknown): T {
  const result = schema.safeParse(body);
  if (!result.success) {
    throw new PaymentUnavailableError(
      'PAYMENT_PROVIDER_INVALID_RESPONSE',
      'The payment provider returned an invalid response',
    );
  }
  return result.data;
}

async function readJson(response: Response): Promise<unknown> {
  const text = await response.text();
  if (text.length === 0) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new PaymentUnavailableError(
      'PAYMENT_PROVIDER_INVALID_RESPONSE',
      'The payment provider returned an unreadable response',
    );
  }
}

/**
 * Reference adapter for the sandbox provider primitives. The sandbox is not a
 * second CrossPay API; it only exposes collections, payouts, refunds, bank
 * accounts and transfers.
 */
export class SandboxPaymentProvider implements PaymentProvider {
  readonly name = 'sandbox';
  private readonly baseUrl: string;
  private readonly apiKey: string;
  private readonly timeoutMs: number;
  private providersCache: SandboxPspProvider[] | null = null;

  constructor(options: SandboxOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, '');
    this.apiKey = options.apiKey;
    this.timeoutMs = options.timeoutMs ?? 5_000;
  }

  /**
   * The sandbox is authoritative for which PSP serves a currency and phone
   * prefix. Asking it keeps provider codes out of CrossPay and means a new
   * sandbox provider needs no CrossPay release.
   */
  private async resolveProvider(currency: string, phoneNumber: string): Promise<string> {
    if (this.providersCache === null) {
      const { body } = await this.request('GET', '/api/sandbox/psp/providers');
      const parsed = parseProvider(
        z.object({
          providers: z.array(
            z.object({
              id: z.string().min(1),
              currency: z.string().length(3),
              kind: z.string().min(1),
              phonePrefixes: z.array(z.string()).default([]),
            }),
          ),
        }),
        body,
      );
      this.providersCache = parsed.providers;
    }

    const candidates = this.providersCache.filter(
      (provider) => provider.kind === 'mobile_money' && provider.currency === currency,
    );
    const chosen =
      candidates.find((provider) =>
        provider.phonePrefixes.some((pattern) => {
          try {
            return new RegExp(pattern).test(phoneNumber);
          } catch {
            return false;
          }
        }),
      ) ?? candidates[0];
    if (!chosen) {
      throw new PaymentUnavailableError(
        'PAYMENT_PROVIDER_NOT_CONFIGURED',
        `No sandbox payment provider serves ${currency}`,
      );
    }
    return chosen.id;
  }

  private async request(
    method: 'GET' | 'POST',
    path: string,
    { body, idempotencyKey }: { body?: unknown; idempotencyKey?: string } = {},
  ): Promise<{ status: number; body: unknown }> {
    const headers: Record<string, string> = { 'x-api-key': this.apiKey };
    if (body !== undefined) headers['content-type'] = 'application/json';
    if (idempotencyKey) headers['idempotency-key'] = idempotencyKey;

    let response: Response;
    try {
      response = await fetch(`${this.baseUrl}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch {
      throw new PaymentUnavailableError(
        'PAYMENT_PROVIDER_UNAVAILABLE',
        'The payment provider is unavailable',
      );
    }

    const payload = await readJson(response);
    if (!response.ok) {
      if (response.status >= 400 && response.status < 500) {
        throw providerError(response.status, payload);
      }
      throw new PaymentUnavailableError(
        'PAYMENT_PROVIDER_UNAVAILABLE',
        'The payment provider is unavailable',
      );
    }
    return { status: response.status, body: payload };
  }

  async createCollection(input: CollectionInput): Promise<PaymentCollection> {
    // An explicit provider or institution wins. Otherwise ask the sandbox
    // which PSP serves this currency and phone prefix, so provider routing is
    // provider data, not a CrossPay constant.
    const provider =
      input.provider ??
      input.institutionId ??
      (await this.resolveProvider(input.currency, input.phoneNumber));
    const { body } = await this.request('POST', '/api/sandbox/psp/stk-push', {
      idempotencyKey: input.transactionRef,
      body: {
        phoneNumber: input.phoneNumber,
        amountMinor: input.amountMinor,
        currency: input.currency,
        provider,
        institutionId: input.institutionId,
        transactionRef: input.transactionRef,
        callbackUrl: input.callbackUrl,
      },
    });
    const response = body as { checkoutRequestId?: unknown; request?: unknown } | null;
    const request = response?.request ?? response;
    return parseProvider(collectionSchema, request);
  }

  async getCollection(checkoutRequestId: string): Promise<PaymentCollection | null> {
    try {
      const { body } = await this.request(
        'GET',
        `/api/sandbox/psp/requests/${encodeURIComponent(checkoutRequestId)}`,
      );
      return parseProvider(collectionSchema, (body as { request?: unknown } | null)?.request);
    } catch (error) {
      if (error instanceof PaymentRejectedError && error.statusCode === 404) return null;
      throw error;
    }
  }

  async createPayout(input: PayoutInput): Promise<PaymentPayout> {
    const { body } = await this.request('POST', '/api/sandbox/psp/payouts', {
      idempotencyKey: input.transactionRef,
      body: {
        phoneNumber: input.phoneNumber,
        amountMinor: input.amountMinor,
        currency: input.currency,
        provider: input.provider,
        institutionId: input.institutionId,
        transactionRef: input.transactionRef,
        callbackUrl: input.callbackUrl,
      },
    });
    return parseProvider(
      payoutSchema,
      (body as { payout?: unknown } | null)?.payout ?? body,
    );
  }

  async getPayout(payoutId: string): Promise<PaymentPayout | null> {
    try {
      const { body } = await this.request(
        'GET',
        `/api/sandbox/psp/payouts/${encodeURIComponent(payoutId)}`,
      );
      return parseProvider(payoutSchema, (body as { payout?: unknown } | null)?.payout);
    } catch (error) {
      if (error instanceof PaymentRejectedError && error.statusCode === 404) return null;
      throw error;
    }
  }

  async refund(input: RefundInput): Promise<PaymentRefund> {
    const { body } = await this.request('POST', '/api/sandbox/psp/refunds', {
      idempotencyKey: `refund:${input.requestId}:${input.amountMinor}`,
      body: {
        requestId: input.requestId,
        amountMinor: input.amountMinor,
        reason: input.reason,
      },
    });
    return parseProvider(refundSchema, body);
  }

  async getBankAccount(accountRef: string): Promise<PaymentBankAccount | null> {
    try {
      const { body } = await this.request(
        'GET',
        `/api/sandbox/bank/accounts/${encodeURIComponent(accountRef)}`,
      );
      return parseProvider(bankAccountSchema, (body as { account?: unknown } | null)?.account);
    } catch (error) {
      if (error instanceof PaymentRejectedError && error.statusCode === 404) return null;
      throw error;
    }
  }

  async transfer(input: TransferInput): Promise<PaymentBankTransfer> {
    const { body } = await this.request('POST', '/api/sandbox/bank/transfer', {
      idempotencyKey: input.transactionRef,
      body: {
        transactionRef: input.transactionRef,
        fromAccount: input.fromAccount,
        toAccount: input.toAccount,
        amountMinor: input.amountMinor,
        note: input.note,
      },
    });
    return parseProvider(
      bankTransferSchema,
      (body as { transfer?: unknown } | null)?.transfer ?? body,
    );
  }
}
