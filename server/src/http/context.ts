import type { Pool } from 'pg';
import type { CryptoBox } from '../crypto.js';
import type { SmsSender } from '../providers/sms.js';
import type { PricingProvider } from '../providers/pricing.js';

export interface AppContext {
  pool: Pool;
  crypto: CryptoBox;
  smsSender: SmsSender;
  pricingProvider: PricingProvider;
  jwtSecret: Uint8Array;
  accessTokenTtlSeconds: number;
  refreshTokenTtlSeconds: number;
  idempotencyTtlSeconds: number;
  limitTimezone: string;
}
