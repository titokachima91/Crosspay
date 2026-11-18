import type { Pool, PoolClient } from 'pg';
import { withTransaction } from '../db/pool.js';
import type { AppContext } from '../http/context.js';
import { loadServiceControls, type ServiceControls } from '../services/service-controls.js';

export const DECLARED_FEE_BPS: Record<'p2p' | 'bank', number> = {
  p2p: 150,
  bank: 250,
};

export interface SupportContacts {
  email: string | null;
  phone: string | null;
  whatsapp: string | null;
  hours: string | null;
}

export type ConfigChangeStatus = 'pending' | 'approved' | 'rejected' | 'cancelled';

export interface ConfigChangeSummary {
  id: string;
  configKey: string;
  status: ConfigChangeStatus;
  reason: string;
  proposedById: string;
  proposedByName: string | null;
  proposedByEmail: string | null;
  decisionNote: string | null;
  decidedById: string | null;
  decidedByName: string | null;
  decidedByEmail: string | null;
  configVersion: number | null;
  createdAt: string;
  decidedAt: string | null;
  appliedAt: string | null;
}

export interface ConfigChangeDetail extends ConfigChangeSummary {
  before: unknown;
  after: unknown;
}

export interface ConfigCenterData {
  controls: ServiceControls;
  support: SupportContacts;
  tiers: Array<{ code: string; name: string }>;
  currencies: Array<{ code: string; name: string }>;
  limits: Array<{
    tierCode: string;
    tierName: string;
    currency: string;
    dailyLimitMinor: string;
  }>;
  pending: ConfigChangeSummary[];
  recent: ConfigChangeSummary[];
  versions: Array<{ version: number; notes: string | null; publishedAt: string }>;
  observedFees: Array<{
    route: string;
    sendCurrency: string;
    receiveCurrency: string;
    minBps: number;
    maxBps: number;
    quotes: number;
    lastSeen: string;
  }>;
}

export class ConfigCenterError extends Error {
  readonly statusCode: number;
  readonly code: string;

  constructor(statusCode: number, code: string, message: string) {
    super(message);
    this.name = 'ConfigCenterError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

function fail(statusCode: number, code: string, message: string): ConfigCenterError {
  return new ConfigCenterError(statusCode, code, message);
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function nullable(value: unknown): string | null {
  const result = text(value);
  return result.length > 0 ? result : null;
}

function reason(value: unknown): string {
  const result = text(value);
  if (result.length < 10 || result.length > 300) {
    throw fail(422, 'CONFIG_REASON_INVALID', 'A reason of 10-300 characters is required');
  }
  return result;
}

function sameValue(left: unknown, right: unknown): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

function supportContacts(row: {
  email: string | null;
  phone: string | null;
  whatsapp: string | null;
  hours: string | null;
} | undefined): SupportContacts {
  return {
    email: row?.email ?? null,
    phone: row?.phone ?? null,
    whatsapp: row?.whatsapp ?? null,
    hours: row?.hours ?? null,
  };
}

export function normalizeSupportContacts(input: {
  email: unknown;
  phone: unknown;
  whatsapp: unknown;
  hours: unknown;
}): SupportContacts {
  const email = nullable(input.email);
  const phone = nullable(input.phone);
  const whatsapp = nullable(input.whatsapp);
  const hours = nullable(input.hours);
  if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    throw fail(422, 'SUPPORT_EMAIL_INVALID', 'Support email is not valid');
  }
  if (email && email.length > 200) {
    throw fail(422, 'SUPPORT_EMAIL_INVALID', 'Support email is too long');
  }
  for (const [label, value] of [
    ['Support phone', phone],
    ['Support WhatsApp', whatsapp],
  ] as const) {
    if (value && (value.length < 4 || value.length > 32)) {
      throw fail(422, 'SUPPORT_CONTACT_INVALID', `${label} must be 4-32 characters`);
    }
  }
  if (hours && hours.length > 200) {
    throw fail(422, 'SUPPORT_CONTACT_INVALID', 'Support hours are too long');
  }
  return { email, phone, whatsapp, hours };
}

export function normalizeDailyLimit(value: unknown): string | null {
  const raw = text(value);
  if (!raw) return null;
  if (!/^\d+$/.test(raw)) {
    throw fail(422, 'TIER_LIMIT_INVALID', 'The daily limit must be whole minor units');
  }
  const amount = BigInt(raw);
  if (amount > 9_223_372_036_854_775_807n) {
    throw fail(422, 'TIER_LIMIT_INVALID', 'The daily limit is too large');
  }
  return amount.toString();
}

function tierLimitKey(tierCode: string, currency: string): string {
  return `tier_limit:${tierCode}:${currency}`;
}

function parseTierLimitKey(key: string): { tierCode: string; currency: string } {
  const match = /^tier_limit:([a-z][a-z0-9_]{1,31}):([A-Z]{3})$/.exec(key);
  if (!match) throw fail(500, 'CONFIG_KEY_INVALID', 'Stored config key is invalid');
  return { tierCode: match[1]!, currency: match[2]! };
}

export async function loadConfigCenter(pool: Pool): Promise<ConfigCenterData> {
  const [controls, support, tiers, currencies, limits, pending, recent, versions, observed] =
    await Promise.all([
      loadServiceControls(pool),
      pool.query<{
        email: string | null;
        phone: string | null;
        whatsapp: string | null;
        hours: string | null;
      }>(`SELECT email, phone, whatsapp, hours FROM support_settings WHERE id = 1`),
      pool.query<{ code: string; name: string }>(
        `SELECT code, name FROM tiers WHERE active ORDER BY sort_order, code`,
      ),
      pool.query<{ code: string; name: string }>(
        `SELECT code, name FROM currencies WHERE active ORDER BY sort_order, code`,
      ),
      pool.query<{
        tier_code: string;
        tier_name: string;
        currency_code: string;
        daily_limit_minor: string;
      }>(
        `SELECT tl.tier_code, t.name AS tier_name, tl.currency_code,
                tl.daily_limit_minor::text
         FROM tier_limits tl
         JOIN tiers t ON t.code = tl.tier_code
         ORDER BY t.sort_order, tl.currency_code`,
      ),
      loadChanges(pool, `c.status = 'pending'`, 'c.created_at DESC'),
      loadChanges(pool, `c.status <> 'pending'`, 'c.decided_at DESC'),
      pool.query<{ version: number; notes: string | null; published_at: Date }>(
        `SELECT version, notes, published_at FROM config_versions
         ORDER BY version DESC LIMIT 10`,
      ),
      pool.query<{
        route: string;
        send_currency: string;
        receive_currency: string;
        min_bps: number;
        max_bps: number;
        quotes: number;
        last_seen: Date;
      }>(
        `SELECT qr.route, q.send_currency, q.receive_currency,
                min(qr.fee_bps)::int AS min_bps, max(qr.fee_bps)::int AS max_bps,
                count(*)::int AS quotes, max(q.created_at) AS last_seen
         FROM quote_routes qr
         JOIN quotes q ON q.id = qr.quote_id
         WHERE q.created_at > now() - interval '7 days'
         GROUP BY qr.route, q.send_currency, q.receive_currency
         ORDER BY q.send_currency, q.receive_currency, qr.route`,
      ),
    ]);

  return {
    controls,
    support: supportContacts(support.rows[0]),
    tiers: tiers.rows,
    currencies: currencies.rows,
    limits: limits.rows.map((row) => ({
      tierCode: row.tier_code,
      tierName: row.tier_name,
      currency: row.currency_code,
      dailyLimitMinor: row.daily_limit_minor,
    })),
    pending: pending,
    recent: recent.slice(0, 20),
    versions: versions.rows.map((row) => ({
      version: row.version,
      notes: row.notes,
      publishedAt: new Date(row.published_at).toISOString(),
    })),
    observedFees: observed.rows.map((row) => ({
      route: row.route,
      sendCurrency: row.send_currency,
      receiveCurrency: row.receive_currency,
      minBps: row.min_bps,
      maxBps: row.max_bps,
      quotes: row.quotes,
      lastSeen: new Date(row.last_seen).toISOString(),
    })),
  };
}

interface ChangeRow {
  id: string;
  config_key: string;
  status: ConfigChangeStatus;
  reason: string;
  proposed_by_admin_id: string;
  proposed_by_name: string | null;
  proposed_by_email: string | null;
  decision_note: string | null;
  decided_by_admin_id: string | null;
  decided_by_name: string | null;
  decided_by_email: string | null;
  config_version: number | null;
  created_at: Date;
  decided_at: Date | null;
  applied_at: Date | null;
}

async function loadChanges(
  pool: Pool,
  condition: string,
  order: string,
): Promise<ConfigChangeSummary[]> {
  const result = await pool.query<ChangeRow>(
    `SELECT c.id, c.config_key, c.status, c.reason,
            c.proposed_by_admin_id, proposer.name AS proposed_by_name,
            proposer.email AS proposed_by_email,
            c.decision_note, c.decided_by_admin_id,
            decider.name AS decided_by_name, decider.email AS decided_by_email,
            c.config_version, c.created_at, c.decided_at, c.applied_at
     FROM admin_config_changes c
     LEFT JOIN admin_users proposer ON proposer.id = c.proposed_by_admin_id
     LEFT JOIN admin_users decider ON decider.id = c.decided_by_admin_id
     WHERE ${condition}
     ORDER BY ${order}
     LIMIT 50`,
  );
  return result.rows.map(mapChange);
}

function mapChange(row: ChangeRow): ConfigChangeSummary {
  return {
    id: row.id,
    configKey: row.config_key,
    status: row.status,
    reason: row.reason,
    proposedById: row.proposed_by_admin_id,
    proposedByName: row.proposed_by_name,
    proposedByEmail: row.proposed_by_email,
    decisionNote: row.decision_note,
    decidedById: row.decided_by_admin_id,
    decidedByName: row.decided_by_name,
    decidedByEmail: row.decided_by_email,
    configVersion: row.config_version,
    createdAt: new Date(row.created_at).toISOString(),
    decidedAt: row.decided_at ? new Date(row.decided_at).toISOString() : null,
    appliedAt: row.applied_at ? new Date(row.applied_at).toISOString() : null,
  };
}

export async function loadConfigChange(
  pool: Pool,
  id: string,
): Promise<ConfigChangeDetail | null> {
  const result = await pool.query<ChangeRow & { before: unknown; after: unknown }>(
    `SELECT c.id, c.config_key, c.status, c.reason, c.before, c.after,
            c.proposed_by_admin_id, proposer.name AS proposed_by_name,
            proposer.email AS proposed_by_email,
            c.decision_note, c.decided_by_admin_id,
            decider.name AS decided_by_name, decider.email AS decided_by_email,
            c.config_version, c.created_at, c.decided_at, c.applied_at
     FROM admin_config_changes c
     LEFT JOIN admin_users proposer ON proposer.id = c.proposed_by_admin_id
     LEFT JOIN admin_users decider ON decider.id = c.decided_by_admin_id
     WHERE c.id = $1`,
    [id],
  );
  const row = result.rows[0];
  if (!row) return null;
  return { ...mapChange(row), before: row.before, after: row.after };
}

async function insertChange(
  client: PoolClient,
  input: {
    configKey: string;
    before: unknown;
    after: unknown;
    reason: string;
    adminId: string;
  },
): Promise<{ id: string }> {
  try {
    const result = await client.query<{ id: string }>(
      `INSERT INTO admin_config_changes
         (config_key, before, after, reason, proposed_by_admin_id)
       VALUES ($1, $2::jsonb, $3::jsonb, $4, $5)
       RETURNING id`,
      [
        input.configKey,
        JSON.stringify(input.before),
        JSON.stringify(input.after),
        input.reason,
        input.adminId,
      ],
    );
    return result.rows[0]!;
  } catch (error) {
    if ((error as { code?: string }).code === '23505') {
      throw fail(
        409,
        'CONFIG_CHANGE_CONFLICT',
        'Another change for this setting is already waiting for approval',
      );
    }
    throw error;
  }
}

export async function proposeSupportContacts(
  ctx: AppContext,
  input: {
    contacts: SupportContacts;
    reason: string;
    adminId: string;
  },
): Promise<{ id: string }> {
  const proposed = input.contacts;
  const why = reason(input.reason);
  return withTransaction(ctx.pool, async (client) => {
    await client.query(`LOCK TABLE support_settings IN SHARE ROW EXCLUSIVE MODE`);
    const current = await client.query<{
      email: string | null;
      phone: string | null;
      whatsapp: string | null;
      hours: string | null;
    }>(`SELECT email, phone, whatsapp, hours FROM support_settings WHERE id = 1`);
    const before = supportContacts(current.rows[0]);
    if (sameValue(before, proposed)) {
      throw fail(422, 'CONFIG_NO_CHANGE', 'The proposed support contacts are already current');
    }
    return insertChange(client, {
      configKey: 'support_contacts',
      before,
      after: proposed,
      reason: why,
      adminId: input.adminId,
    });
  });
}

export async function proposeTierLimit(
  ctx: AppContext,
  input: {
    tierCode: string;
    currency: string;
    dailyLimitMinor: string | null;
    reason: string;
    adminId: string;
  },
): Promise<{ id: string }> {
  const tierCode = text(input.tierCode);
  const currency = text(input.currency).toUpperCase();
  if (!/^[a-z][a-z0-9_]{1,31}$/.test(tierCode) || !/^[A-Z]{3}$/.test(currency)) {
    throw fail(422, 'TIER_LIMIT_INVALID', 'Choose a tier and currency');
  }
  const limit = input.dailyLimitMinor;
  if (limit !== null && !/^\d+$/.test(limit)) {
    throw fail(422, 'TIER_LIMIT_INVALID', 'The daily limit must be whole minor units');
  }
  const why = reason(input.reason);

  return withTransaction(ctx.pool, async (client) => {
    const tier = await client.query(
      `SELECT 1 FROM tiers WHERE code = $1 AND active`,
      [tierCode],
    );
    if (!tier.rowCount) throw fail(422, 'TIER_LIMIT_INVALID', 'Tier is not active');
    const currencyRow = await client.query(
      `SELECT 1 FROM currencies WHERE code = $1 AND active`,
      [currency],
    );
    if (!currencyRow.rowCount) {
      throw fail(422, 'TIER_LIMIT_INVALID', 'Currency is not active');
    }

    await client.query(`LOCK TABLE tier_limits IN SHARE ROW EXCLUSIVE MODE`);
    const current = await client.query<{ daily_limit_minor: string }>(
      `SELECT daily_limit_minor::text FROM tier_limits
       WHERE tier_code = $1 AND currency_code = $2`,
      [tierCode, currency],
    );
    const before = { tierCode, currency, dailyLimitMinor: current.rows[0]?.daily_limit_minor ?? null };
    const after = { tierCode, currency, dailyLimitMinor: limit };
    if (sameValue(before, after)) {
      throw fail(422, 'CONFIG_NO_CHANGE', 'The proposed daily limit is already current');
    }
    return insertChange(client, {
      configKey: tierLimitKey(tierCode, currency),
      before,
      after,
      reason: why,
      adminId: input.adminId,
    });
  });
}

async function applySupportContacts(
  client: PoolClient,
  after: SupportContacts,
): Promise<void> {
  await client.query(`LOCK TABLE support_settings IN SHARE ROW EXCLUSIVE MODE`);
  const empty =
    !after.email && !after.phone && !after.whatsapp && !after.hours;
  if (empty) {
    await client.query(`DELETE FROM support_settings WHERE id = 1`);
    return;
  }
  await client.query(
    `INSERT INTO support_settings (id, email, phone, whatsapp, hours)
     VALUES (1, $1, $2, $3, $4)
     ON CONFLICT (id) DO UPDATE
       SET email = EXCLUDED.email, phone = EXCLUDED.phone,
           whatsapp = EXCLUDED.whatsapp, hours = EXCLUDED.hours`,
    [after.email, after.phone, after.whatsapp, after.hours],
  );
}

async function applyTierLimit(
  client: PoolClient,
  configKey: string,
  after: { tierCode?: string; currency?: string; dailyLimitMinor?: string | null },
): Promise<void> {
  await client.query(`LOCK TABLE tier_limits IN SHARE ROW EXCLUSIVE MODE`);
  const parsed = parseTierLimitKey(configKey);
  const tierCode = text(after.tierCode) || parsed.tierCode;
  const currency = text(after.currency).toUpperCase() || parsed.currency;
  const limit = after.dailyLimitMinor ?? null;
  if (limit === null) {
    await client.query(
      `DELETE FROM tier_limits WHERE tier_code = $1 AND currency_code = $2`,
      [tierCode, currency],
    );
    return;
  }
  if (!/^\d+$/.test(limit)) {
    throw fail(500, 'CONFIG_VALUE_INVALID', 'Stored tier limit is invalid');
  }
  await client.query(
    `INSERT INTO tier_limits (tier_code, currency_code, daily_limit_minor)
     VALUES ($1, $2, $3::bigint)
     ON CONFLICT (tier_code, currency_code)
     DO UPDATE SET daily_limit_minor = EXCLUDED.daily_limit_minor`,
    [tierCode, currency, limit],
  );
}

export interface ConfigDecisionResult {
  before: unknown;
  after: unknown;
  status: ConfigChangeStatus;
  configVersion: number | null;
}

export async function decideConfigChange(
  ctx: AppContext,
  input: {
    changeId: string;
    adminId: string;
    decision: 'approved' | 'rejected' | 'cancelled';
    note?: string;
    allowCancelAny?: boolean;
  },
): Promise<ConfigDecisionResult> {
  const note = nullable(input.note);
  if (note && note.length > 300) {
    throw fail(422, 'CONFIG_DECISION_INVALID', 'The decision note is too long');
  }

  return withTransaction(ctx.pool, async (client) => {
    const result = await client.query<{
      id: string;
      config_key: string;
      before: unknown;
      after: unknown;
      status: ConfigChangeStatus;
      proposed_by_admin_id: string;
    }>(
      `SELECT id, config_key, before, after, status, proposed_by_admin_id
       FROM admin_config_changes WHERE id = $1 FOR UPDATE`,
      [input.changeId],
    );
    const change = result.rows[0];
    if (!change) throw fail(404, 'CONFIG_CHANGE_NOT_FOUND', 'Config change not found');
    if (change.status !== 'pending') {
      throw fail(409, 'CONFIG_CHANGE_DECIDED', 'This change has already been decided');
    }

    if (input.decision === 'cancelled') {
      if (change.proposed_by_admin_id !== input.adminId && !input.allowCancelAny) {
        throw fail(403, 'CONFIG_CANCEL_FORBIDDEN', 'Only the proposer can cancel this change');
      }
      await client.query(
        `UPDATE admin_config_changes
         SET status = 'cancelled', decided_by_admin_id = $2,
             decision_note = $3, decided_at = now()
         WHERE id = $1`,
        [input.changeId, input.adminId, note],
      );
      return { before: change.before, after: change.after, status: 'cancelled', configVersion: null };
    }

    if (input.decision === 'approved' && change.proposed_by_admin_id === input.adminId) {
      throw fail(
        403,
        'CONFIG_SELF_APPROVAL',
        'A proposer cannot approve their own configuration change',
      );
    }

    if (input.decision === 'rejected') {
      await client.query(
        `UPDATE admin_config_changes
         SET status = 'rejected', decided_by_admin_id = $2,
             decision_note = $3, decided_at = now()
         WHERE id = $1`,
        [input.changeId, input.adminId, note],
      );
      return { before: change.before, after: change.after, status: 'rejected', configVersion: null };
    }

    if (change.config_key === 'support_contacts') {
      await applySupportContacts(client, change.after as SupportContacts);
    } else if (change.config_key.startsWith('tier_limit:')) {
      await applyTierLimit(
        client,
        change.config_key,
        change.after as { tierCode?: string; currency?: string; dailyLimitMinor?: string | null },
      );
    } else {
      throw fail(500, 'CONFIG_KEY_INVALID', 'Stored config key is invalid');
    }

    await client.query(`LOCK TABLE config_versions IN SHARE ROW EXCLUSIVE MODE`);
    const next = await client.query<{ version: number }>(
      `SELECT COALESCE(max(version), 0) + 1 AS version FROM config_versions`,
    );
    const version = Number(next.rows[0]?.version);
    await client.query(
      `INSERT INTO config_versions (version, notes)
       VALUES ($1, $2)`,
      [version, `Admin config change ${change.id}: ${change.config_key}`],
    );
    await client.query(
      `UPDATE admin_config_changes
       SET status = 'approved', decided_by_admin_id = $2,
           decision_note = $3, decided_at = now(), applied_at = now(),
           config_version = $4
       WHERE id = $1`,
      [input.changeId, input.adminId, note, version],
    );

    return {
      before: change.before,
      after: change.after,
      status: 'approved',
      configVersion: version,
    };
  });
}

export async function proposeRollback(
  ctx: AppContext,
  input: { changeId: string; reason: string; adminId: string },
): Promise<{ id: string }> {
  const source = await loadConfigChange(ctx.pool, input.changeId);
  if (!source) throw fail(404, 'CONFIG_CHANGE_NOT_FOUND', 'Config change not found');
  if (source.status !== 'approved' || source.configVersion === null) {
    throw fail(422, 'CONFIG_ROLLBACK_INVALID', 'Only an approved change can be rolled back');
  }
  const why = reason(input.reason);

  if (source.configKey === 'support_contacts') {
    const target = source.before as SupportContacts;
    return withTransaction(ctx.pool, async (client) => {
      await client.query(`LOCK TABLE support_settings IN SHARE ROW EXCLUSIVE MODE`);
      const current = await client.query<{
        email: string | null;
        phone: string | null;
        whatsapp: string | null;
        hours: string | null;
      }>(`SELECT email, phone, whatsapp, hours FROM support_settings WHERE id = 1`);
      const before = supportContacts(current.rows[0]);
      const after = supportContacts({
        email: target.email,
        phone: target.phone,
        whatsapp: target.whatsapp,
        hours: target.hours,
      });
      if (sameValue(before, after)) {
        throw fail(422, 'CONFIG_NO_CHANGE', 'The previous support contacts are already current');
      }
      return insertChange(client, {
        configKey: 'support_contacts',
        before,
        after,
        reason: why,
        adminId: input.adminId,
      });
    });
  }

  if (source.configKey.startsWith('tier_limit:')) {
    const parsed = parseTierLimitKey(source.configKey);
    const target = source.before as { dailyLimitMinor: string | null };
    return withTransaction(ctx.pool, async (client) => {
      await client.query(`LOCK TABLE tier_limits IN SHARE ROW EXCLUSIVE MODE`);
      const current = await client.query<{ daily_limit_minor: string }>(
        `SELECT daily_limit_minor::text FROM tier_limits
         WHERE tier_code = $1 AND currency_code = $2`,
        [parsed.tierCode, parsed.currency],
      );
      const before = {
        tierCode: parsed.tierCode,
        currency: parsed.currency,
        dailyLimitMinor: current.rows[0]?.daily_limit_minor ?? null,
      };
      const after = {
        tierCode: parsed.tierCode,
        currency: parsed.currency,
        dailyLimitMinor: target.dailyLimitMinor,
      };
      if (sameValue(before, after)) {
        throw fail(422, 'CONFIG_NO_CHANGE', 'The previous daily limit is already current');
      }
      return insertChange(client, {
        configKey: source.configKey,
        before,
        after,
        reason: why,
        adminId: input.adminId,
      });
    });
  }

  throw fail(422, 'CONFIG_ROLLBACK_INVALID', 'This setting cannot be rolled back');
}

export async function updateServiceControls(
  ctx: AppContext,
  input: {
    quotesPaused: boolean;
    tradesPaused: boolean;
    message: string;
    adminId: string;
  },
): Promise<{ before: ServiceControls; after: ServiceControls }> {
  const message = nullable(input.message);
  if (message && message.length > 300) {
    throw fail(422, 'SERVICE_MESSAGE_INVALID', 'The maintenance message is too long');
  }

  return withTransaction(ctx.pool, async (client) => {
    const current = await client.query<{
      quotes_paused: boolean;
      trades_paused: boolean;
      message: string | null;
      updated_at: Date;
    }>(
      `SELECT quotes_paused, trades_paused, message, updated_at
       FROM service_controls WHERE id = 1 FOR UPDATE`,
    );
    const before: ServiceControls = current.rows[0]
      ? {
          quotesPaused: current.rows[0].quotes_paused,
          tradesPaused: current.rows[0].trades_paused,
          message: current.rows[0].message,
          updatedAt: new Date(current.rows[0].updated_at).toISOString(),
        }
      : { quotesPaused: false, tradesPaused: false, message: null, updatedAt: null };

    const updated = await client.query<{
      quotes_paused: boolean;
      trades_paused: boolean;
      message: string | null;
      updated_at: Date;
    }>(
      `INSERT INTO service_controls
         (id, quotes_paused, trades_paused, message, updated_by_admin_id)
       VALUES (1, $1, $2, $3, $4)
       ON CONFLICT (id) DO UPDATE
         SET quotes_paused = EXCLUDED.quotes_paused,
             trades_paused = EXCLUDED.trades_paused,
             message = EXCLUDED.message,
             updated_by_admin_id = EXCLUDED.updated_by_admin_id
       RETURNING quotes_paused, trades_paused, message, updated_at`,
      [input.quotesPaused, input.tradesPaused, message, input.adminId],
    );
    const row = updated.rows[0]!;
    return {
      before,
      after: {
        quotesPaused: row.quotes_paused,
        tradesPaused: row.trades_paused,
        message: row.message,
        updatedAt: new Date(row.updated_at).toISOString(),
      },
    };
  });
}
