import type { Pool, PoolClient } from 'pg';

type Queryable = Pool | PoolClient;

export interface ConfigCurrency {
  code: string;
  name: string;
  countryCode: string;
  decimals: number;
}

export interface ConfigHub {
  id: string;
  name: string;
  countryCode: string;
}

export interface ConfigPayoutRail {
  id: string;
  name: string;
  countryCode: string;
  kind: 'mobile_money' | 'bank';
}

export interface ConfigCountry {
  code: string;
  name: string;
  dialCode: string;
  nationalNumberLength: number;
}

export interface ConfigCarrier {
  id: string;
  name: string;
  countryCode: string;
  prefixPattern: string;
}

export interface ConfigSupport {
  email?: string;
  phone?: string;
  whatsapp?: string;
  hours?: string;
}

export interface AppConfigPayload {
  currencies: ConfigCurrency[];
  hubs: ConfigHub[];
  payoutRails: ConfigPayoutRail[];
  countries: ConfigCountry[];
  carriers: ConfigCarrier[];
  support?: ConfigSupport;
}

async function rows(db: Queryable, text: string): Promise<Record<string, unknown>[]> {
  const result = await db.query(text);
  return result.rows as Record<string, unknown>[];
}

/**
 * Builds the exact GET /config shape the Flutter AppConfig parser requires:
 * all five lists are always present and ordered, and every payout rail has a
 * kind. The optional support block is omitted when no real support desk is
 * configured.
 */
export async function loadAppConfig(db: Queryable): Promise<AppConfigPayload> {
  const [currencies, hubs, payoutRails, countries, carriers, support] = await Promise.all([
    rows(
      db,
      `SELECT code, name, country_code, decimals
       FROM currencies
       WHERE active
       ORDER BY sort_order, code`,
    ),
    rows(
      db,
      `SELECT id, name, country_code
       FROM hubs
       WHERE active
       ORDER BY sort_order, id`,
    ),
    rows(
      db,
      `SELECT id, name, country_code, kind
       FROM payout_rails
       WHERE active
       ORDER BY sort_order, id`,
    ),
    rows(
      db,
      `SELECT code, name, dial_code, national_number_length
       FROM countries
       WHERE active
       ORDER BY sort_order, code`,
    ),
    rows(
      db,
      `SELECT id, name, country_code, prefix_pattern
       FROM carriers
       WHERE active
       ORDER BY country_code, sort_order, id`,
    ),
    rows(
      db,
      `SELECT email, phone, whatsapp, hours
       FROM support_settings
       WHERE id = 1`,
    ),
  ]);

  const payload: AppConfigPayload = {
    currencies: currencies.map((row) => ({
      code: String(row['code']),
      name: String(row['name']),
      countryCode: String(row['country_code']),
      decimals: Number(row['decimals']),
    })),
    hubs: hubs.map((row) => ({
      id: String(row['id']),
      name: String(row['name']),
      countryCode: String(row['country_code']),
    })),
    payoutRails: payoutRails.map((row) => ({
      id: String(row['id']),
      name: String(row['name']),
      countryCode: String(row['country_code']),
      kind: row['kind'] as 'mobile_money' | 'bank',
    })),
    countries: countries.map((row) => ({
      code: String(row['code']),
      name: String(row['name']),
      dialCode: String(row['dial_code']),
      nationalNumberLength: Number(row['national_number_length']),
    })),
    carriers: carriers.map((row) => ({
      id: String(row['id']),
      name: String(row['name']),
      countryCode: String(row['country_code']),
      prefixPattern: String(row['prefix_pattern']),
    })),
  };

  const supportRow = support[0];
  if (supportRow) {
    const supportPayload: ConfigSupport = {};
    for (const key of ['email', 'phone', 'whatsapp', 'hours'] as const) {
      const value = supportRow[key];
      if (value !== null && value !== undefined) supportPayload[key] = String(value);
    }
    if (Object.keys(supportPayload).length > 0) payload.support = supportPayload;
  }

  return payload;
}
