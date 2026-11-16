import type { Pool } from 'pg';
import type { CryptoBox } from '../crypto.js';
import type { SmsSender } from '../providers/sms.js';
import type { PricingProvider } from '../providers/pricing.js';
import type { PaymentProvider } from '../providers/payments.js';

export interface AppContext {
  pool: Pool;
  crypto: CryptoBox;
  smsSender: SmsSender;
  pricingProvider: PricingProvider;
  paymentProvider: PaymentProvider;
  jwtSecret: Uint8Array;
  accessTokenTtlSeconds: number;
  refreshTokenTtlSeconds: number;
  idempotencyTtlSeconds: number;
  limitTimezone: string;
  collectionPushTimeoutSeconds: number;
  collectionPollIntervalSeconds: number;
  /** Public URL the provider calls back; omitted when callbacks are not set up. */
  paymentCallbackUrl?: string;
  /** HMAC secret for provider callbacks; null keeps the endpoint honest. */
  paymentWebhookSecret?: Uint8Array | null;
  paymentWebhookMaxSkewSeconds: number;
  /** Matching is opt-in; the default false keeps every corridor disabled. */
  p2pEnabled: boolean;
  /** Absolute public API URL used for export/invoice links. */
  publicApiUrl?: string;
  /** Ops dashboard key; absent keeps admin endpoints at an honest 503. */
  adminApiKey?: string | null;
}
