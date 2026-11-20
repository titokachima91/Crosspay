import type { PoolClient } from 'pg';
import { AppError, unprocessable } from '../http/errors.js';

export interface UserRow {
  id: string;
  phone: string;
  display_name: string | null;
  account_type: 'personal' | 'business';
  hub_id: string | null;
  kyc_status: 'not_started' | 'pending' | 'verified' | 'rejected';
  tier_code: string;
  limit_currency_code: string | null;
}

export async function findOrCreateUserByPhone(
  client: PoolClient,
  phone: string,
): Promise<{ user: UserRow; created: boolean }> {
  const result = await client.query(
    `INSERT INTO users (phone, phone_verified_at)
     VALUES ($1, now())
     ON CONFLICT (phone) DO UPDATE
       SET phone_verified_at = COALESCE(users.phone_verified_at, now())
       WHERE users.deleted_at IS NULL
     RETURNING id, phone, display_name, account_type, hub_id, kyc_status,
               tier_code, limit_currency_code, (xmax = 0) AS created`,
    [phone],
  );

  const row = result.rows[0];
  if (!row) throw new AppError(403, 'ACCOUNT_DISABLED', 'This account is not available');
  return {
    user: {
      id: String(row['id']),
      phone: String(row['phone']),
      display_name: row['display_name'] === null ? null : String(row['display_name']),
      account_type: row['account_type'] as UserRow['account_type'],
      hub_id: row['hub_id'] === null ? null : String(row['hub_id']),
      kyc_status: row['kyc_status'] as UserRow['kyc_status'],
      tier_code: String(row['tier_code']),
      limit_currency_code:
        row['limit_currency_code'] === null ? null : String(row['limit_currency_code']),
    },
    created: Boolean(row['created']),
  };
}

/**
 * Resolves the currency of the daily limit. A business account uses its hub's
 * country; a personal account uses the longest matching dial code. The server
 * never silently picks a currency that does not belong to the account.
 */
export async function resolveLimitCurrency(
  client: PoolClient,
  phone: string,
  hubId: string | null,
): Promise<string> {
  if (hubId) {
    const hub = await client.query(
      `SELECT h.country_code, c.code
       FROM hubs h
       JOIN currencies c ON c.country_code = h.country_code AND c.active
       WHERE h.id = $1 AND h.active
       ORDER BY c.sort_order, c.code
       LIMIT 1`,
      [hubId],
    );
    const row = hub.rows[0];
    if (!row) throw unprocessable('INVALID_HUB', 'The trading hub is not available');
    return String(row['code']);
  }

  const currency = await client.query(
    `SELECT c.code
     FROM countries co
     JOIN currencies c ON c.country_code = co.code AND c.active
     WHERE co.active AND $1 LIKE ('+' || co.dial_code || '%')
     ORDER BY length(co.dial_code) DESC, c.sort_order, c.code
     LIMIT 1`,
    [phone],
  );
  const row = currency.rows[0];
  if (!row) {
    throw unprocessable('UNSUPPORTED_COUNTRY', 'No supported currency matches this phone number');
  }
  return String(row['code']);
}

export function isProfileComplete(user: UserRow): boolean {
  return user.display_name !== null && user.kyc_status !== 'not_started';
}
