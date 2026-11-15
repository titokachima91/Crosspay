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
}
