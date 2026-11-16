import type { Pool, PoolClient } from 'pg';
import { unprocessable } from '../http/errors.js';

export interface LimitSubject {
  id: string;
  tier_code: string;
  limit_currency_code: string | null;
}

/**
 * Enforces the approved daily limit only when the send currency is the one the
 * limit is denominated in. A cross-currency limit needs an FX conversion and
 * belongs to the trade flow; inventing one here would be worse than deferring
 * the check.
 *
 * The check counts every trade that is still capable of moving money. It runs
 * inside the caller's transaction at initiation so a quote cannot be spent
 * after the remaining limit has shrunk.
 */
export async function assertWithinDailyLimit(
  db: Pool | PoolClient,
  user: LimitSubject,
  input: { sendCurrency: string; sendAmountMinor: bigint },
  limitTimezone: string,
): Promise<void> {
  if (user.limit_currency_code !== input.sendCurrency) return;

  const limit = await db.query(
    `SELECT daily_limit_minor
     FROM tier_limits
     WHERE tier_code = $1 AND currency_code = $2`,
    [user.tier_code, user.limit_currency_code],
  );
  const dailyLimit = BigInt(String(limit.rows[0]?.['daily_limit_minor'] ?? '0'));
  if (dailyLimit === 0n) {
    throw unprocessable(
      'LIMIT_EXCEEDED',
      'No approved daily limit exists for this account yet',
    );
  }

  const used = await db.query(
    `SELECT COALESCE(sum(send_amount_minor), 0)::bigint AS used
     FROM trades
     WHERE user_id = $1
       AND send_currency = $3
       AND status NOT IN ('cancelled', 'expired', 'failed')
       AND created_at >= (date_trunc('day', now() AT TIME ZONE $2) AT TIME ZONE $2)`,
    [user.id, limitTimezone, input.sendCurrency],
  );
  const dailyUsed = BigInt(String(used.rows[0]?.['used'] ?? '0'));
  if (dailyUsed + input.sendAmountMinor > dailyLimit) {
    throw unprocessable('LIMIT_EXCEEDED', 'That amount is above the remaining daily limit');
  }
}
