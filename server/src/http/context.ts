import type { Pool } from 'pg';
import type { CryptoBox } from '../crypto.js';
import type { SmsSender } from '../providers/sms.js';

export interface AppContext {
  pool: Pool;
  crypto: CryptoBox;
  smsSender: SmsSender;
  jwtSecret: Uint8Array;
  accessTokenTtlSeconds: number;
  refreshTokenTtlSeconds: number;
  idempotencyTtlSeconds: number;
  limitTimezone: string;
}
