import type { Pool } from 'pg';
import { mapMatch, type MatchRow } from '../matching.js';
import type { MatchView } from '../matching.js';

export interface CorridorView {
  from: string;
  to: string;
  enabled: boolean;
  exposureCapMinor: number | null;
  minAmountMinor: number | null;
  maxAmountMinor: number | null;
  estimatedSettleSeconds: number | null;
  matchDeadlineSeconds: number;
  spreadBps: number;
  openSendMinor: number;
  openTrades: number;
  availableSendMinor: number | null;
  utilizationPercent: number | null;
}

interface CorridorRow {
  send_currency: string;
  receive_currency: string;
  enabled: boolean;
  exposure_cap_minor: string | null;
  min_amount_minor: string | null;
  max_amount_minor: string | null;
  estimated_settle_seconds: number | null;
  match_deadline_seconds: number;
  spread_bps: number;
  open_send_minor: string;
  open_trades: number;
  available_send_minor: string | null;
}

function corridorView(row: CorridorRow): CorridorView {
  return {
    from: row.send_currency,
    to: row.receive_currency,
    enabled: row.enabled,
    exposureCapMinor: row.exposure_cap_minor === null ? null : Number(row.exposure_cap_minor),
    minAmountMinor: row.min_amount_minor === null ? null : Number(row.min_amount_minor),
    maxAmountMinor: row.max_amount_minor === null ? null : Number(row.max_amount_minor),
    estimatedSettleSeconds: row.estimated_settle_seconds,
    matchDeadlineSeconds: row.match_deadline_seconds,
    spreadBps: row.spread_bps,
    openSendMinor: Number(row.open_send_minor),
    openTrades: row.open_trades,
    availableSendMinor:
      row.available_send_minor === null ? null : Number(row.available_send_minor),
    utilizationPercent:
      row.exposure_cap_minor === null || Number(row.exposure_cap_minor) === 0
        ? null
        : Math.round((Number(row.open_send_minor) / Number(row.exposure_cap_minor)) * 100),
  };
}

export async function loadCorridors(pool: Pool): Promise<CorridorView[]> {
  const result = await pool.query<CorridorRow>(
    `SELECT send_currency, receive_currency, enabled, exposure_cap_minor,
            min_amount_minor, max_amount_minor, estimated_settle_seconds,
            match_deadline_seconds, spread_bps, open_send_minor, open_trades,
            available_send_minor
     FROM p2p_corridor_exposure
     ORDER BY send_currency, receive_currency`,
  );
  return result.rows.map(corridorView);
}

export interface OverviewData {
  generatedAt: string;
  corridors: CorridorView[];
  counts: {
    queue: number;
    matches: number;
    payouts: number;
    refunds: number;
    liquidityOrders: number;
  };
  queue: Array<{
    id: string;
    reference: string;
    status: string;
    sendCurrency: string;
    receiveCurrency: string;
    sendAmountMinor: number;
    receiveAmountMinor: number;
    ageSeconds: number;
    phoneLast4: string;
  }>;
  matches: Array<
    MatchView & {
      buyTradeId: string;
      sellTradeId: string | null;
      liquidityOrderId: string | null;
    }
  >;
  payouts: Array<{
    id: string;
    tradeId: string;
    reference: string;
    provider: string;
    providerReference: string | null;
    amountMinor: number;
    currency: string;
    status: string;
    requestedAt: Date;
  }>;
  refunds: Array<{
    id: string;
    tradeId: string;
    reference: string;
    amountMinor: number;
    currency: string;
    reasonCode: string;
    status: string;
    requestedAt: Date;
  }>;
  liquidityOrders: Array<{
    id: string;
    providerId: string;
    providerName: string;
    provideCurrency: string;
    receiveCurrency: string;
    capacityMinor: number;
    remainingMinor: number;
    minAmountMinor: number;
    maxAmountMinor: number;
    rate: number;
    status: string;
    expiresAt: Date;
  }>;
  alerts: Array<{ level: 'warning' | 'critical'; message: string }>;
}

export async function loadOverview(pool: Pool): Promise<OverviewData> {
  const [corridors, queue, matches, payouts, refunds, orders, counts] = await Promise.all([
    loadCorridors(pool),
    pool.query(
      `SELECT t.id, t.reference, t.status, t.send_currency, t.receive_currency,
              t.send_amount_minor, t.receive_amount_minor,
              EXTRACT(EPOCH FROM (now() - t.created_at))::int AS age_seconds,
              right(u.phone, 4) AS phone_last4
       FROM trades t JOIN users u ON u.id = t.user_id
       WHERE t.status IN ('escrowed', 'matching')
       ORDER BY t.created_at
       LIMIT 25`,
    ),
    pool.query<MatchRow>(
      `SELECT id, buy_trade_id, sell_trade_id, liquidity_order_id,
              buy_amount_minor, sell_amount_minor, buy_currency, sell_currency,
              status, match_rate, matched_at, released_at
       FROM p2p_matches
       WHERE status = 'locked'
       ORDER BY matched_at
       LIMIT 25`,
    ),
    pool.query(
      `SELECT p.id, p.trade_id, t.reference, p.provider, p.provider_reference,
              p.amount_minor, p.currency_code, p.status, p.requested_at
       FROM payouts p JOIN trades t ON t.id = p.trade_id
       WHERE p.status IN ('pending', 'submitted')
       ORDER BY p.requested_at
       LIMIT 25`,
    ),
    pool.query(
      `SELECT r.id, r.trade_id, t.reference, r.amount_minor, r.currency_code,
              r.reason_code, r.status, r.requested_at
       FROM refunds r JOIN trades t ON t.id = r.trade_id
       WHERE r.status IN ('pending', 'submitted')
       ORDER BY r.requested_at
       LIMIT 25`,
    ),
    pool.query(
      `SELECT o.id, o.provider_id, p.name AS provider_name, o.provide_currency,
              o.receive_currency, o.capacity_minor, o.remaining_minor,
              o.min_amount_minor, o.max_amount_minor, o.rate, o.status, o.expires_at
       FROM liquidity_orders o JOIN liquidity_providers p ON p.id = o.provider_id
       ORDER BY o.created_at DESC LIMIT 50`,
    ),
    pool.query<{
      queue: string;
      matches: string;
      payouts: string;
      refunds: string;
      liquidity_orders: string;
    }>(
      `SELECT
         (SELECT count(*) FROM trades WHERE status IN ('escrowed', 'matching'))::text AS queue,
         (SELECT count(*) FROM p2p_matches WHERE status = 'locked')::text AS matches,
         (SELECT count(*) FROM payouts WHERE status IN ('pending', 'submitted'))::text AS payouts,
         (SELECT count(*) FROM refunds WHERE status IN ('pending', 'submitted'))::text AS refunds,
         (SELECT count(*) FROM liquidity_orders WHERE status = 'active')::text AS liquidity_orders`,
    ),
  ]);

  const alerts: Array<{ level: 'warning' | 'critical'; message: string }> = [];
  for (const corridor of corridors) {
    if (corridor.enabled && corridor.utilizationPercent !== null && corridor.utilizationPercent >= 80) {
      alerts.push({
        level: corridor.utilizationPercent >= 100 ? 'critical' : 'warning',
        message: `${corridor.from}→${corridor.to} exposure is ${corridor.utilizationPercent}% of cap`,
      });
    }
  }
  if (matches.rows.some((m) => m.matched_at && Date.now() - new Date(m.matched_at).getTime() > 5 * 60_000)) {
    alerts.push({ level: 'warning', message: 'A locked match is older than five minutes' });
  }
  if (Number(counts.rows[0]?.payouts ?? '0') > 0) {
    alerts.push({ level: 'warning', message: `${counts.rows[0]?.payouts} payout(s) pending` });
  }
  if (Number(counts.rows[0]?.refunds ?? '0') > 0) {
    alerts.push({ level: 'warning', message: `${counts.rows[0]?.refunds} refund(s) pending` });
  }

  return {
    generatedAt: new Date().toISOString(),
    corridors,
    counts: {
      queue: Number(counts.rows[0]?.queue ?? '0'),
      matches: Number(counts.rows[0]?.matches ?? '0'),
      payouts: Number(counts.rows[0]?.payouts ?? '0'),
      refunds: Number(counts.rows[0]?.refunds ?? '0'),
      liquidityOrders: Number(counts.rows[0]?.liquidity_orders ?? '0'),
    },
    queue: queue.rows.map((row) => ({
      id: String(row['id']),
      reference: String(row['reference']),
      status: String(row['status']),
      sendCurrency: String(row['send_currency']),
      receiveCurrency: String(row['receive_currency']),
      sendAmountMinor: Number(row['send_amount_minor']),
      receiveAmountMinor: Number(row['receive_amount_minor']),
      ageSeconds: Number(row['age_seconds']),
      phoneLast4: String(row['phone_last4'] ?? ''),
    })),
    matches: matches.rows.map((row) => ({
      ...mapMatch(row),
      buyTradeId: row.buy_trade_id,
      sellTradeId: row.sell_trade_id,
      liquidityOrderId: row.liquidity_order_id,
    })),
    payouts: payouts.rows.map((row) => ({
      id: String(row['id']),
      tradeId: String(row['trade_id']),
      reference: String(row['reference']),
      provider: String(row['provider']),
      providerReference: row['provider_reference'] === null ? null : String(row['provider_reference']),
      amountMinor: Number(row['amount_minor']),
      currency: String(row['currency_code']),
      status: String(row['status']),
      requestedAt: row['requested_at'] as Date,
    })),
    refunds: refunds.rows.map((row) => ({
      id: String(row['id']),
      tradeId: String(row['trade_id']),
      reference: String(row['reference']),
      amountMinor: Number(row['amount_minor']),
      currency: String(row['currency_code']),
      reasonCode: String(row['reason_code']),
      status: String(row['status']),
      requestedAt: row['requested_at'] as Date,
    })),
    liquidityOrders: orders.rows.map((row) => ({
      id: String(row['id']),
      providerId: String(row['provider_id']),
      providerName: String(row['provider_name']),
      provideCurrency: String(row['provide_currency']),
      receiveCurrency: String(row['receive_currency']),
      capacityMinor: Number(row['capacity_minor']),
      remainingMinor: Number(row['remaining_minor']),
      minAmountMinor: Number(row['min_amount_minor']),
      maxAmountMinor: Number(row['max_amount_minor']),
      rate: Number(row['rate']),
      status: String(row['status']),
      expiresAt: row['expires_at'] as Date,
    })),
    alerts,
  };
}

export interface TradeListItem {
  id: string;
  reference: string;
  status: string;
  route: string;
  sendCurrency: string;
  receiveCurrency: string;
  sendAmountMinor: number;
  receiveAmountMinor: number;
  beneficiaryName: string;
  beneficiaryLast4: string;
  phoneLast4: string;
  createdAt: Date;
}

export async function searchTrades(pool: Pool, query: string): Promise<TradeListItem[]> {
  const term = query.trim();
  const like = `%${term}%`;
  const result = await pool.query(
    `SELECT t.id, t.reference, t.status, t.route, t.send_currency,
            t.receive_currency, t.send_amount_minor, t.receive_amount_minor,
            t.beneficiary_name, t.beneficiary_account_last4,
            right(u.phone, 4) AS phone_last4, t.created_at
     FROM trades t JOIN users u ON u.id = t.user_id
     WHERE $1 = ''
        OR t.reference ILIKE $2
        OR u.phone LIKE $2
        OR t.beneficiary_account_last4 = $1
     ORDER BY t.created_at DESC, t.id DESC
     LIMIT 50`,
    [term, like],
  );
  return result.rows.map((row) => ({
    id: String(row['id']),
    reference: String(row['reference']),
    status: String(row['status']),
    route: String(row['route']),
    sendCurrency: String(row['send_currency']),
    receiveCurrency: String(row['receive_currency']),
    sendAmountMinor: Number(row['send_amount_minor']),
    receiveAmountMinor: Number(row['receive_amount_minor']),
    beneficiaryName: String(row['beneficiary_name']),
    beneficiaryLast4: String(row['beneficiary_account_last4']),
    phoneLast4: String(row['phone_last4'] ?? ''),
    createdAt: row['created_at'] as Date,
  }));
}

export async function loadTradeDetail(pool: Pool, tradeId: string) {
  const trade = await pool.query(
    `SELECT t.id, t.reference, t.status, t.route, t.send_currency, t.receive_currency,
            t.send_amount_minor, t.fee_minor, t.receive_amount_minor, t.rate,
            t.beneficiary_name, t.beneficiary_last4,
            t.failure_code, t.created_at, t.updated_at, t.completed_at,
            right(u.phone, 4) AS phone_last4
     FROM (
       SELECT *, beneficiary_account_last4 AS beneficiary_last4
       FROM trades
     ) t
     JOIN users u ON u.id = t.user_id
     WHERE t.id = $1`,
    [tradeId],
  );
  if (!trade.rows[0]) return null;
  const [events, attempts, payouts, refunds, journals, match] = await Promise.all([
    pool.query(
      `SELECT status, at, note_code, actor FROM trade_events
       WHERE trade_id = $1 ORDER BY at, id`,
      [tradeId],
    ),
    pool.query(
      `SELECT id, provider, external_reference, method, amount_minor, currency_code,
              status, network_name, created_at
       FROM payment_attempts WHERE trade_id = $1 ORDER BY created_at DESC`,
      [tradeId],
    ),
    pool.query(
      `SELECT id, provider, provider_reference, amount_minor, currency_code,
              status, attempt_count, last_error_code, requested_at, completed_at
       FROM payouts WHERE trade_id = $1 ORDER BY created_at DESC`,
      [tradeId],
    ),
    pool.query(
      `SELECT id, amount_minor, currency_code, reason_code, provider,
              provider_reference, status, requested_at, completed_at
       FROM refunds WHERE trade_id = $1 ORDER BY created_at DESC`,
      [tradeId],
    ),
    pool.query(
      `SELECT tx.kind, tx.currency_code, tx.created_at, tx.posting_key,
              a.code, a.name, l.amount_minor
       FROM journal_transactions tx
       JOIN journal_lines l ON l.transaction_id = tx.id
       JOIN ledger_accounts a ON a.id = l.account_id
       WHERE tx.trade_id = $1
       ORDER BY tx.created_at, l.id`,
      [tradeId],
    ),
    pool.query<MatchRow>(
      `SELECT id, buy_trade_id, sell_trade_id, liquidity_order_id,
              buy_amount_minor, sell_amount_minor, buy_currency, sell_currency,
              status, match_rate, matched_at, released_at
       FROM p2p_matches
       WHERE buy_trade_id = $1 OR sell_trade_id = $1
       ORDER BY created_at DESC LIMIT 1`,
      [tradeId],
    ),
  ]);
  return {
    trade: trade.rows[0],
    events: events.rows,
    attempts: attempts.rows,
    payouts: payouts.rows,
    refunds: refunds.rows,
    journals: journals.rows,
    match: match.rows[0] ? mapMatch(match.rows[0]) : null,
  };
}

export async function loadAnalytics(pool: Pool) {
  const [byStatus, byCorridor, payouts, refunds, liquidity] = await Promise.all([
    pool.query(
      `SELECT send_currency, status, count(*)::int AS trades,
              COALESCE(sum(send_amount_minor), 0)::text AS send_minor
       FROM trades GROUP BY send_currency, status
       ORDER BY send_currency, status`,
    ),
    pool.query(
      `SELECT send_currency, receive_currency, count(*)::int AS trades,
              COALESCE(sum(send_amount_minor), 0)::text AS send_minor,
              COALESCE(sum(receive_amount_minor), 0)::text AS receive_minor
       FROM trades WHERE status = 'completed'
       GROUP BY send_currency, receive_currency
       ORDER BY send_currency, receive_currency`,
    ),
    pool.query(
      `SELECT currency_code, status, count(*)::int AS count,
              COALESCE(sum(amount_minor), 0)::text AS amount_minor
       FROM payouts GROUP BY currency_code, status
       ORDER BY currency_code, status`,
    ),
    pool.query(
      `SELECT currency_code, status, count(*)::int AS count,
              COALESCE(sum(amount_minor), 0)::text AS amount_minor
       FROM refunds GROUP BY currency_code, status
       ORDER BY currency_code, status`,
    ),
    pool.query(
      `SELECT provide_currency, status, count(*)::int AS count,
              COALESCE(sum(remaining_minor), 0)::text AS remaining_minor
       FROM liquidity_orders GROUP BY provide_currency, status
       ORDER BY provide_currency, status`,
    ),
  ]);
  return {
    byStatus: byStatus.rows,
    byCorridor: byCorridor.rows,
    payouts: payouts.rows,
    refunds: refunds.rows,
    liquidity: liquidity.rows,
  };
}

export async function loadAudit(pool: Pool) {
  const result = await pool.query(
    `SELECT a.id, a.actor_label, a.action, a.resource_type, a.resource_id,
            a.reason, a.created_at, u.email AS admin_email
     FROM admin_audit_log a
     LEFT JOIN admin_users u ON u.id = a.admin_user_id
     ORDER BY a.created_at DESC
     LIMIT 100`,
  );
  return result.rows;
}

export async function loadAdminUsers(pool: Pool) {
  const result = await pool.query(
    `SELECT u.id, u.email, u.name, u.status, u.totp_enrolled_at,
            u.last_login_at, u.created_at,
            COALESCE(array_agg(r.role) FILTER (WHERE r.role IS NOT NULL), '{}') AS roles
     FROM admin_users u
     LEFT JOIN admin_user_roles r ON r.admin_user_id = u.id
     GROUP BY u.id
     ORDER BY u.created_at`,
  );
  return result.rows.map((row) => ({
    id: String(row['id']),
    email: String(row['email']),
    name: String(row['name']),
    status: String(row['status']),
    totpEnrolledAt: row['totp_enrolled_at'],
    lastLoginAt: row['last_login_at'],
    createdAt: row['created_at'],
    roles: row['roles'] as string[],
  }));
}
