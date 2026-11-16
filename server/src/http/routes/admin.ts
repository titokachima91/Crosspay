import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import { requireAdmin } from '../admin-auth.js';
import { conflict, notFound, unprocessable } from '../errors.js';
import { parseBody } from '../validation.js';
import { withTransaction } from '../../db/pool.js';
import { postJournal } from '../../ledger.js';
import { ledgerAccountId } from '../../trades.js';
import { mapMatch, tryMatchTrade, disburseMatch, type MatchRow } from '../../matching.js';

const currency = z
  .string()
  .trim()
  .length(3)
  .transform((value) => value.toUpperCase());

const corridorParams = z.object({
  send: currency,
  receive: currency,
});
const idParams = z.object({ id: z.string().uuid() });

const corridorPatchSchema = z.object({
  enabled: z.boolean().optional(),
  exposureCapMinor: z.number().int().positive().nullable().optional(),
  estimatedSettleSeconds: z.number().int().positive().nullable().optional(),
  matchDeadlineSeconds: z.number().int().min(30).max(86_400).optional(),
  spreadBps: z.number().int().min(0).max(10_000).optional(),
  minAmountMinor: z.number().int().nonnegative().nullable().optional(),
  maxAmountMinor: z.number().int().positive().nullable().optional(),
});

const providerSchema = z.object({
  name: z.string().trim().min(1).max(120),
});

const providerPatchSchema = z.object({
  status: z.enum(['active', 'suspended']),
});

const orderSchema = z.object({
  providerId: z.string().uuid(),
  provideCurrency: currency,
  receiveCurrency: currency,
  capacityMinor: z.number().int().positive(),
  minAmountMinor: z.number().int().nonnegative().optional(),
  maxAmountMinor: z.number().int().positive(),
  rate: z.number().positive().max(1_000_000_000),
  expiresAt: z.string().datetime(),
  prefundReference: z.string().trim().min(1).max(200),
});

const orderPatchSchema = z.object({
  status: z.enum(['cancelled']),
});

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

function admin(request: FastifyRequest, ctx: AppContext): void {
  requireAdmin(request, ctx);
}

async function audit(
  request: FastifyRequest,
  ctx: AppContext,
  input: {
    action: string;
    resourceType: string;
    resourceId?: string | null;
    reason?: string | null;
    before?: unknown;
    after?: unknown;
  },
): Promise<void> {
  await ctx.pool.query(
    `INSERT INTO admin_audit_log
       (actor_label, action, resource_type, resource_id, reason, before, after, ip)
     VALUES ('env-admin', $1, $2, $3, $4, $5::jsonb, $6::jsonb, $7)`,
    [
      input.action,
      input.resourceType,
      input.resourceId ?? null,
      input.reason ?? null,
      input.before === undefined ? null : JSON.stringify(input.before),
      input.after === undefined ? null : JSON.stringify(input.after),
      request.ip ?? null,
    ],
  );
}

function corridorView(row: CorridorRow) {
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

async function loadCorridors(ctx: AppContext): Promise<CorridorRow[]> {
  const result = await ctx.pool.query<CorridorRow>(
    `SELECT send_currency, receive_currency, enabled, exposure_cap_minor,
            min_amount_minor, max_amount_minor, estimated_settle_seconds,
            match_deadline_seconds, spread_bps, open_send_minor, open_trades,
            available_send_minor
     FROM p2p_corridor_exposure
     ORDER BY send_currency, receive_currency`,
  );
  return result.rows;
}

export function adminDashboardHtml(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CrossPay Ops</title>
<style>
  :root { color-scheme: dark; --bg:#0f1216; --card:#171c23; --line:#2a3240; --text:#e8edf5; --muted:#8b98aa; --accent:#4fd1a5; --warn:#f2b84b; --bad:#f16b6b; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
  header { display:flex; gap:16px; align-items:center; padding:16px 24px; border-bottom:1px solid var(--line); background:#11161c; position:sticky; top:0; z-index:2; }
  h1 { margin:0; font-size:17px; letter-spacing:.2px; }
  h2 { margin:0 0 10px; font-size:14px; color:var(--muted); text-transform:uppercase; letter-spacing:.08em; }
  main { padding:20px 24px 60px; display:grid; gap:18px; grid-template-columns:repeat(auto-fit,minmax(360px,1fr)); }
  section { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:14px 16px; overflow:auto; }
  table { width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }
  th,td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); white-space:nowrap; }
  th { color:var(--muted); font-weight:500; font-size:12px; }
  td.num { text-align:right; }
  .pill { display:inline-block; padding:1px 8px; border-radius:999px; font-size:11px; border:1px solid var(--line); }
  .ok { color:var(--accent); border-color:color-mix(in srgb,var(--accent) 40%,transparent); }
  .warn { color:var(--warn); border-color:color-mix(in srgb,var(--warn) 40%,transparent); }
  .bad { color:var(--bad); border-color:color-mix(in srgb,var(--bad) 40%,transparent); }
  button { background:#202833; color:var(--text); border:1px solid var(--line); padding:6px 10px; border-radius:8px; cursor:pointer; }
  button:hover { border-color:var(--accent); }
  input { background:#0c1015; color:var(--text); border:1px solid var(--line); border-radius:8px; padding:8px 10px; min-width:240px; }
  .row { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
  .muted { color:var(--muted); }
  .error { color:var(--bad); }
  .empty { color:var(--muted); padding:8px 0; }
</style>
</head>
<body>
<header>
  <h1>CrossPay Ops</h1>
  <div class="row" style="flex:1">
    <input id="key" type="password" placeholder="Admin key" autocomplete="off">
    <button id="load">Load</button>
    <button id="refresh">Refresh</button>
    <span id="status" class="muted"></span>
  </div>
</header>
<main>
  <section><h2>Corridors</h2><div id="corridors"></div></section>
  <section><h2>Funded queue</h2><div id="queue"></div></section>
  <section><h2>Open matches</h2><div id="matches"></div></section>
  <section><h2>Pending payouts</h2><div id="payouts"></div></section>
  <section><h2>Pending refunds</h2><div id="refunds"></div></section>
  <section><h2>Liquidity orders</h2><div id="orders"></div></section>
  <section><h2>Alerts</h2><div id="alerts"></div></section>
</main>
<script>
const $ = (id) => document.getElementById(id);
const keyInput = $('key');
keyInput.value = sessionStorage.getItem('crosspay_admin_key') || '';
const fmt = (n) => n == null ? '—' : Number(n).toLocaleString();
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function table(rows, cols) {
  if (!rows || rows.length === 0) return '<div class="empty">Nothing here.</div>';
  return '<table><thead><tr>' + cols.map(c => '<th>' + esc(c.label) + '</th>').join('') +
    '</tr></thead><tbody>' + rows.map(r => '<tr>' + cols.map(c => {
      const value = c.render ? c.render(r) : esc(r[c.key]);
      return '<td' + (c.num ? ' class="num"' : '') + '>' + value + '</td>';
    }).join('') + '</tr>').join('') + '</tbody></table>';
}
async function api(path, options = {}) {
  const key = keyInput.value.trim();
  if (!key) throw new Error('Enter the admin key.');
  sessionStorage.setItem('crosspay_admin_key', key);
  const response = await fetch(path, {
    ...options,
    headers: { 'x-admin-key': key, 'content-type': 'application/json', ...(options.headers || {}) }
  });
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;
  if (!response.ok) throw new Error((body && body.error && body.error.message) || ('HTTP ' + response.status));
  return body;
}
async function load() {
  $('status').textContent = 'Loading…';
  $('status').className = 'muted';
  try {
    const data = await api('/api/v1/admin/overview');
    $('status').textContent = 'Updated ' + new Date().toLocaleTimeString();
    $('corridors').innerHTML = table(data.corridors, [
      { label:'Corridor', render:r => esc(r.from + ' → ' + r.to) },
      { label:'Enabled', render:r => '<span class="pill ' + (r.enabled ? 'ok' : 'bad') + '">' + (r.enabled ? 'on' : 'off') + '</span>' },
      { label:'Open', key:'openTrades', num:true },
      { label:'Exposure', render:r => fmt(r.openSendMinor) + ' / ' + fmt(r.exposureCapMinor), num:true },
      { label:'Use', render:r => r.utilizationPercent == null ? '—' : r.utilizationPercent + '%', num:true },
      { label:'', render:r => '<button data-toggle="' + esc(r.from + '/' + r.to) + '">' + (r.enabled ? 'Disable' : 'Enable') + '</button>' }
    ]);
    $('queue').innerHTML = table(data.queue, [
      { label:'Reference', key:'reference' }, { label:'Status', key:'status' },
      { label:'Send', render:r => esc(r.sendCurrency + ' ' + fmt(r.sendAmountMinor)), num:true },
      { label:'Receive', render:r => esc(r.receiveCurrency + ' ' + fmt(r.receiveAmountMinor)), num:true },
      { label:'Age', key:'ageSeconds', num:true },
      { label:'', render:r => '<button data-match="' + esc(r.id) + '">Match</button>' }
    ]);
    $('matches').innerHTML = table(data.matches, [
      { label:'Match', render:r => esc(String(r.id).slice(0, 8)) },
      { label:'Status', key:'status' },
      { label:'Counterparty', render:r => esc(r.liquidity ? 'LP' : 'user') },
      { label:'Buy', render:r => esc(r.buyCurrency + ' ' + fmt(r.buyAmountMinor)), num:true },
      { label:'Sell', render:r => esc(r.sellCurrency + ' ' + fmt(r.sellAmountMinor)), num:true },
      { label:'', render:r => r.status === 'locked' ? '<button data-disburse="' + esc(r.id) + '">Disburse</button>' : '' }
    ]);
    $('payouts').innerHTML = table(data.payouts, [
      { label:'Trade', key:'reference' }, { label:'Status', key:'status' },
      { label:'Amount', render:r => esc(r.currency + ' ' + fmt(r.amountMinor)), num:true },
      { label:'Provider ref', key:'providerReference' }
    ]);
    $('refunds').innerHTML = table(data.refunds, [
      { label:'Trade', key:'reference' }, { label:'Status', key:'status' },
      { label:'Amount', render:r => esc(r.currency + ' ' + fmt(r.amountMinor)), num:true }
    ]);
    $('orders').innerHTML = table(data.liquidityOrders, [
      { label:'Provider', key:'providerName' },
      { label:'Provide', render:r => esc(r.provideCurrency + ' ' + fmt(r.remainingMinor) + ' / ' + fmt(r.capacityMinor)), num:true },
      { label:'Receive', key:'receiveCurrency' },
      { label:'Rate', key:'rate', num:true },
      { label:'Status', key:'status' }
    ]);
    $('alerts').innerHTML = data.alerts.length === 0
      ? '<div class="empty">No alerts.</div>'
      : '<ul>' + data.alerts.map(a => '<li><span class="pill ' + (a.level === 'critical' ? 'bad' : 'warn') + '">' + esc(a.level) + '</span> ' + esc(a.message) + '</li>').join('') + '</ul>';
    for (const button of document.querySelectorAll('[data-toggle]')) {
      button.addEventListener('click', async () => {
        const [from, to] = button.dataset.toggle.split('/');
        const corridor = data.corridors.find(c => c.from === from && c.to === to);
        try {
          await api('/api/v1/admin/corridors/' + from + '/' + to, {
            method: 'PATCH',
            body: JSON.stringify({ enabled: !corridor.enabled })
          });
          await load();
        } catch (error) { $('status').textContent = error.message; $('status').className = 'error'; }
      });
    }
    for (const button of document.querySelectorAll('[data-match]')) {
      button.addEventListener('click', async () => {
        try {
          await api('/api/v1/admin/trades/' + encodeURIComponent(button.dataset.match) + '/match', { method: 'POST' });
          await load();
        } catch (error) { $('status').textContent = error.message; $('status').className = 'error'; }
      });
    }
    for (const button of document.querySelectorAll('[data-disburse]')) {
      button.addEventListener('click', async () => {
        try {
          await api('/api/v1/admin/matches/' + encodeURIComponent(button.dataset.disburse) + '/disburse', { method: 'POST' });
          await load();
        } catch (error) { $('status').textContent = error.message; $('status').className = 'error'; }
      });
    }
  } catch (error) {
    $('status').textContent = error.message;
    $('status').className = 'error';
  }
}
$('load').addEventListener('click', load);
$('refresh').addEventListener('click', load);
keyInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') load(); });
if (keyInput.value) load();
</script>
</body>
</html>`;
}

export function registerAdminRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.get('/admin/overview', async (request) => {
    admin(request, ctx);
    const [corridors, queue, matches, payouts, refunds, orders] = await Promise.all([
      loadCorridors(ctx),
      ctx.pool.query(
        `SELECT t.id, t.reference, t.route, t.status, t.send_currency,
                t.receive_currency, t.send_amount_minor, t.receive_amount_minor,
                EXTRACT(EPOCH FROM (now() - t.created_at))::int AS age_seconds
         FROM trades t
         WHERE t.status IN ('escrowed', 'matching')
         ORDER BY t.created_at
         LIMIT 50`,
      ),
      ctx.pool.query<MatchRow>(
        `SELECT id, buy_trade_id, sell_trade_id, liquidity_order_id,
                buy_amount_minor, sell_amount_minor, buy_currency, sell_currency,
                status, match_rate, matched_at, released_at
         FROM p2p_matches
         WHERE status = 'locked'
         ORDER BY matched_at
         LIMIT 50`,
      ),
      ctx.pool.query(
        `SELECT p.id, p.trade_id, t.reference, p.provider, p.provider_reference,
                p.amount_minor, p.currency_code, p.status, p.requested_at
         FROM payouts p JOIN trades t ON t.id = p.trade_id
         WHERE p.status IN ('pending', 'submitted')
         ORDER BY p.requested_at
         LIMIT 50`,
      ),
      ctx.pool.query(
        `SELECT r.id, r.trade_id, t.reference, r.amount_minor, r.currency_code,
                r.reason_code, r.status, r.requested_at
         FROM refunds r JOIN trades t ON t.id = r.trade_id
         WHERE r.status IN ('pending', 'submitted')
         ORDER BY r.requested_at
         LIMIT 50`,
      ),
      ctx.pool.query(
        `SELECT o.id, o.provider_id, p.name AS provider_name, o.provide_currency,
                o.receive_currency, o.capacity_minor, o.remaining_minor,
                o.min_amount_minor, o.max_amount_minor, o.rate, o.status, o.expires_at
         FROM liquidity_orders o JOIN liquidity_providers p ON p.id = o.provider_id
         ORDER BY o.created_at DESC
         LIMIT 100`,
      ),
    ]);

    const alerts: Array<{ level: 'warning' | 'critical'; message: string }> = [];
    const corridorViews = corridors.map(corridorView);
    for (const corridor of corridorViews) {
      if (corridor.enabled && corridor.utilizationPercent !== null && corridor.utilizationPercent >= 80) {
        alerts.push({
          level: corridor.utilizationPercent >= 100 ? 'critical' : 'warning',
          message: `${corridor.from}→${corridor.to} exposure is ${corridor.utilizationPercent}% of cap`,
        });
      }
    }
    if (matches.rowCount && matches.rows.some((m) => m.matched_at && Date.now() - new Date(m.matched_at).getTime() > 5 * 60_000)) {
      alerts.push({ level: 'warning', message: 'A locked match is older than five minutes' });
    }
    if (payouts.rowCount && payouts.rowCount > 0) {
      alerts.push({ level: 'warning', message: `${payouts.rowCount} payout(s) pending` });
    }
    if (refunds.rowCount && refunds.rowCount > 0) {
      alerts.push({ level: 'warning', message: `${refunds.rowCount} refund(s) pending` });
    }

    return {
      generatedAt: new Date().toISOString(),
      corridors: corridorViews,
      queue: queue.rows.map((row) => ({
        id: row['id'],
        reference: row['reference'],
        route: row['route'],
        status: row['status'],
        sendCurrency: row['send_currency'],
        receiveCurrency: row['receive_currency'],
        sendAmountMinor: Number(row['send_amount_minor']),
        receiveAmountMinor: Number(row['receive_amount_minor']),
        ageSeconds: Number(row['age_seconds']),
      })),
      matches: matches.rows.map((row) => ({
        ...mapMatch(row),
        buyTradeId: row.buy_trade_id,
        sellTradeId: row.sell_trade_id,
        liquidityOrderId: row.liquidity_order_id,
      })),
      payouts: payouts.rows.map((row) => ({
        id: row['id'],
        tradeId: row['trade_id'],
        reference: row['reference'],
        provider: row['provider'],
        providerReference: row['provider_reference'],
        amountMinor: Number(row['amount_minor']),
        currency: row['currency_code'],
        status: row['status'],
      })),
      refunds: refunds.rows.map((row) => ({
        id: row['id'],
        tradeId: row['trade_id'],
        reference: row['reference'],
        amountMinor: Number(row['amount_minor']),
        currency: row['currency_code'],
        reasonCode: row['reason_code'],
        status: row['status'],
      })),
      liquidityOrders: orders.rows.map((row) => ({
        id: row['id'],
        providerId: row['provider_id'],
        providerName: row['provider_name'],
        provideCurrency: row['provide_currency'],
        receiveCurrency: row['receive_currency'],
        capacityMinor: Number(row['capacity_minor']),
        remainingMinor: Number(row['remaining_minor']),
        minAmountMinor: Number(row['min_amount_minor']),
        maxAmountMinor: Number(row['max_amount_minor']),
        rate: Number(row['rate']),
        status: row['status'],
        expiresAt: row['expires_at'],
      })),
      alerts,
    };
  });

  app.patch('/admin/corridors/:send/:receive', async (request) => {
    admin(request, ctx);
    const params = parseBody(corridorParams, request.params);
    if (params.send === params.receive) {
      throw unprocessable('CORRIDOR_INVALID', 'A corridor needs two different currencies');
    }
    const body = parseBody(corridorPatchSchema, request.body ?? {});
    const current = await ctx.pool.query<CorridorRow>(
      `SELECT send_currency, receive_currency, enabled, exposure_cap_minor,
              min_amount_minor, max_amount_minor, estimated_settle_seconds,
              match_deadline_seconds, spread_bps, open_send_minor, open_trades,
              available_send_minor
       FROM p2p_corridor_exposure WHERE send_currency = $1 AND receive_currency = $2`,
      [params.send, params.receive],
    );
    const row = current.rows[0];
    if (!row) throw notFound('CORRIDOR_NOT_FOUND', 'Corridor not found');

    const enabled = body.enabled ?? row.enabled;
    const cap =
      body.exposureCapMinor === undefined
        ? row.exposure_cap_minor
        : body.exposureCapMinor === null
          ? null
          : String(body.exposureCapMinor);
    if (enabled && cap === null) {
      throw unprocessable('CORRIDOR_CAP_REQUIRED', 'An enabled corridor needs an exposure cap');
    }
    const minAmount =
      body.minAmountMinor === undefined
        ? row.min_amount_minor
        : body.minAmountMinor === null
          ? null
          : String(body.minAmountMinor);
    const maxAmount =
      body.maxAmountMinor === undefined
        ? row.max_amount_minor
        : body.maxAmountMinor === null
          ? null
          : String(body.maxAmountMinor);
    if (minAmount !== null && maxAmount !== null && BigInt(minAmount) >= BigInt(maxAmount)) {
      throw unprocessable('CORRIDOR_AMOUNT_INVALID', 'The corridor minimum must be below its maximum');
    }

    await ctx.pool.query(
      `UPDATE p2p_corridors
       SET enabled = $3,
           exposure_cap_minor = $4,
           estimated_settle_seconds = $5,
           match_deadline_seconds = $6,
           spread_bps = $7,
           min_amount_minor = $8,
           max_amount_minor = $9
       WHERE send_currency = $1 AND receive_currency = $2`,
      [
        params.send,
        params.receive,
        enabled,
        cap,
        body.estimatedSettleSeconds === undefined
          ? row.estimated_settle_seconds
          : body.estimatedSettleSeconds,
        body.matchDeadlineSeconds ?? row.match_deadline_seconds,
        body.spreadBps ?? row.spread_bps,
        minAmount,
        maxAmount,
      ],
    );
    const updated = corridorView(
      (await loadCorridors(ctx)).find(
        (c) => c.send_currency === params.send && c.receive_currency === params.receive,
      ) as CorridorRow,
    );
    await audit(request, ctx, {
      action: 'corridor.update',
      resourceType: 'p2p_corridor',
      resourceId: `${params.send}-${params.receive}`,
      before: corridorView(row),
      after: updated,
    });
    return { corridor: updated };
  });

  app.post('/admin/trades/:id/match', async (request) => {
    admin(request, ctx);
    const { id } = parseBody(idParams, request.params);
    const attempt = await tryMatchTrade(ctx, { tradeId: id });
    await audit(request, ctx, {
      action: 'trade.match',
      resourceType: 'trade',
      resourceId: id,
      after: attempt,
    });
    return attempt;
  });

  app.post('/admin/matches/:id/disburse', async (request) => {
    admin(request, ctx);
    const { id } = parseBody(idParams, request.params);
    const result = await disburseMatch(ctx, { matchId: id });
    await audit(request, ctx, {
      action: 'match.disburse',
      resourceType: 'p2p_match',
      resourceId: id,
      after: result,
    });
    return result;
  });

  app.get('/admin/liquidity/providers', async (request) => {
    admin(request, ctx);
    const result = await ctx.pool.query(
      `SELECT id, name, status, created_at FROM liquidity_providers ORDER BY created_at`,
    );
    return {
      providers: result.rows.map((row) => ({
        id: row['id'],
        name: row['name'],
        status: row['status'],
        createdAt: row['created_at'],
      })),
    };
  });

  app.post('/admin/liquidity/providers', async (request, reply) => {
    admin(request, ctx);
    const body = parseBody(providerSchema, request.body);
    try {
      const result = await ctx.pool.query(
        `INSERT INTO liquidity_providers (name) VALUES ($1)
         RETURNING id, name, status, created_at`,
        [body.name],
      );
      const created = {
        id: result.rows[0]?.['id'],
        name: result.rows[0]?.['name'],
        status: result.rows[0]?.['status'],
        createdAt: result.rows[0]?.['created_at'],
      };
      await audit(request, ctx, {
        action: 'liquidity_provider.create',
        resourceType: 'liquidity_provider',
        resourceId: String(created.id),
        after: created,
      });
      return reply.code(201).send({ provider: created });
    } catch (error) {
      if ((error as { code?: string }).code === '23505') {
        throw conflict('LIQUIDITY_PROVIDER_EXISTS', 'A liquidity provider with that name exists');
      }
      throw error;
    }
  });

  app.patch('/admin/liquidity/providers/:id', async (request) => {
    admin(request, ctx);
    const { id } = parseBody(idParams, request.params);
    const body = parseBody(providerPatchSchema, request.body);
    const before = await ctx.pool.query<{ status: string; name: string }>(
      `SELECT status, name FROM liquidity_providers WHERE id = $1`,
      [id],
    );
    if (!before.rows[0]) {
      throw notFound('LIQUIDITY_PROVIDER_NOT_FOUND', 'Liquidity provider not found');
    }
    const result = await ctx.pool.query(
      `UPDATE liquidity_providers SET status = $2 WHERE id = $1
       RETURNING id, name, status, created_at`,
      [id, body.status],
    );
    const row = result.rows[0];
    if (!row) throw notFound('LIQUIDITY_PROVIDER_NOT_FOUND', 'Liquidity provider not found');
    await audit(request, ctx, {
      action: 'liquidity_provider.update',
      resourceType: 'liquidity_provider',
      resourceId: id,
      before: before.rows[0],
      after: { status: row['status'] },
    });
    return { provider: { id: row['id'], name: row['name'], status: row['status'] } };
  });

  app.get('/admin/liquidity/orders', async (request) => {
    admin(request, ctx);
    const result = await ctx.pool.query(
      `SELECT o.id, o.provider_id, p.name AS provider_name, o.provide_currency,
              o.receive_currency, o.capacity_minor, o.remaining_minor,
              o.min_amount_minor, o.max_amount_minor, o.rate, o.status, o.expires_at
       FROM liquidity_orders o JOIN liquidity_providers p ON p.id = o.provider_id
       ORDER BY o.created_at DESC`,
    );
    return {
      orders: result.rows.map((row) => ({
        id: row['id'],
        providerId: row['provider_id'],
        providerName: row['provider_name'],
        provideCurrency: row['provide_currency'],
        receiveCurrency: row['receive_currency'],
        capacityMinor: Number(row['capacity_minor']),
        remainingMinor: Number(row['remaining_minor']),
        minAmountMinor: Number(row['min_amount_minor']),
        maxAmountMinor: Number(row['max_amount_minor']),
        rate: Number(row['rate']),
        status: row['status'],
        expiresAt: row['expires_at'],
      })),
    };
  });

  app.post('/admin/liquidity/orders', async (request, reply) => {
    admin(request, ctx);
    const body = parseBody(orderSchema, request.body);
    if (body.provideCurrency === body.receiveCurrency) {
      throw unprocessable('LIQUIDITY_ORDER_INVALID', 'The two currencies must differ');
    }
    const minAmount = body.minAmountMinor ?? 0;
    if (minAmount >= body.maxAmountMinor || body.maxAmountMinor > body.capacityMinor) {
      throw unprocessable('LIQUIDITY_ORDER_INVALID', 'The order amount bounds are invalid');
    }
    const expiresAt = new Date(body.expiresAt);
    if (expiresAt.getTime() <= Date.now()) {
      throw unprocessable('LIQUIDITY_ORDER_INVALID', 'The order expiry must be in the future');
    }

    const created = await withTransaction(ctx.pool, async (client) => {
      const provider = await client.query(
        `SELECT id FROM liquidity_providers WHERE id = $1 AND status = 'active'`,
        [body.providerId],
      );
      if (!provider.rowCount) {
        throw notFound('LIQUIDITY_PROVIDER_NOT_FOUND', 'An active liquidity provider was not found');
      }
      const result = await client.query(
        `INSERT INTO liquidity_orders
           (provider_id, provide_currency, receive_currency, capacity_minor,
            remaining_minor, min_amount_minor, max_amount_minor, rate,
            prefund_reference, prefunded_at, expires_at)
         VALUES ($1, $2, $3, $4, $4, $5, $6, $7::numeric, $8, now(), $9)
         RETURNING id, provider_id, provide_currency, receive_currency,
                   capacity_minor, remaining_minor, min_amount_minor,
                   max_amount_minor, rate, status, expires_at`,
        [
          body.providerId,
          body.provideCurrency,
          body.receiveCurrency,
          body.capacityMinor,
          minAmount,
          body.maxAmountMinor,
          body.rate,
          body.prefundReference,
          expiresAt,
        ],
      );
      const row = result.rows[0];
      const cash = await ledgerAccountId(client, {
        code: '1000',
        currency: body.provideCurrency,
      });
      const lpPayable = await ledgerAccountId(client, {
        code: '2050',
        currency: body.provideCurrency,
      });
      await postJournal(client, {
        postingKey: `lp:${row?.['id']}:prefund`,
        kind: 'opening_balance',
        currencyCode: body.provideCurrency,
        liquidityProviderId: body.providerId,
        lines: [
          { accountId: cash, amountMinor: BigInt(body.capacityMinor) },
          { accountId: lpPayable, amountMinor: -BigInt(body.capacityMinor) },
        ],
      });
      return row;
    });

    const order = {
      id: created?.['id'],
      providerId: created?.['provider_id'],
      provideCurrency: created?.['provide_currency'],
      receiveCurrency: created?.['receive_currency'],
      capacityMinor: Number(created?.['capacity_minor']),
      remainingMinor: Number(created?.['remaining_minor']),
      minAmountMinor: Number(created?.['min_amount_minor']),
      maxAmountMinor: Number(created?.['max_amount_minor']),
      rate: Number(created?.['rate']),
      status: created?.['status'],
      expiresAt: created?.['expires_at'],
    };
    await audit(request, ctx, {
      action: 'liquidity_order.create',
      resourceType: 'liquidity_order',
      resourceId: String(order.id),
      reason: body.prefundReference,
      after: order,
    });
    return reply.code(201).send({ order });
  });

  app.patch('/admin/liquidity/orders/:id', async (request) => {
    admin(request, ctx);
    const { id } = parseBody(idParams, request.params);
    parseBody(orderPatchSchema, request.body);
    const cancelled = await withTransaction(ctx.pool, async (client) => {
      const existing = await client.query<{
        id: string;
        provider_id: string;
        provide_currency: string;
        remaining_minor: string;
        status: string;
      }>(
        `SELECT id, provider_id, provide_currency, remaining_minor, status
         FROM liquidity_orders WHERE id = $1 FOR UPDATE`,
        [id],
      );
      const order = existing.rows[0];
      if (!order || !['active', 'depleted', 'expired'].includes(order.status)) {
        throw notFound('LIQUIDITY_ORDER_NOT_FOUND', 'An active liquidity order was not found');
      }
      const inUse = await client.query(
        `SELECT 1 FROM p2p_matches
         WHERE liquidity_order_id = $1 AND status = 'locked'
         LIMIT 1`,
        [id],
      );
      if (inUse.rowCount) {
        throw conflict('LIQUIDITY_ORDER_IN_USE', 'A locked match still uses this order');
      }
      const remaining = BigInt(order.remaining_minor);
      if (remaining > 0n) {
        const cash = await ledgerAccountId(client, {
          code: '1000',
          currency: order.provide_currency,
        });
        const lpPayable = await ledgerAccountId(client, {
          code: '2050',
          currency: order.provide_currency,
        });
        await postJournal(client, {
          postingKey: `lp:${id}:return`,
          kind: 'adjustment',
          currencyCode: order.provide_currency,
          liquidityProviderId: order.provider_id,
          lines: [
            { accountId: lpPayable, amountMinor: remaining },
            { accountId: cash, amountMinor: -remaining },
          ],
        });
      }
      await client.query(`UPDATE liquidity_orders SET status = 'cancelled' WHERE id = $1`, [id]);
      return order;
    });
    await audit(request, ctx, {
      action: 'liquidity_order.cancel',
      resourceType: 'liquidity_order',
      resourceId: id,
      before: cancelled,
      after: { status: 'cancelled' },
    });
    return { order: { id, status: 'cancelled', providerId: cancelled.provider_id } };
  });
}
