import { randomBytes } from 'node:crypto';
import type { Pool } from 'pg';
import { withTransaction } from '../db/pool.js';
import type { AppContext } from '../http/context.js';

export const SUPPORT_STATUSES = [
  'open',
  'pending_customer',
  'pending_internal',
  'resolved',
  'closed',
] as const;
export type SupportStatus = (typeof SUPPORT_STATUSES)[number];

export const SUPPORT_PRIORITIES = ['low', 'normal', 'high', 'urgent'] as const;
export type SupportPriority = (typeof SUPPORT_PRIORITIES)[number];

export const SUPPORT_CATEGORIES = [
  'payment_not_received',
  'payout_delay',
  'refund',
  'account_access',
  'kyc',
  'beneficiary',
  'other',
] as const;
export type SupportCategory = (typeof SUPPORT_CATEGORIES)[number];

export const SUPPORT_OPENED_VIA = [
  'admin',
  'phone',
  'email',
  'whatsapp',
  'app',
  'other',
] as const;
export type SupportOpenedVia = (typeof SUPPORT_OPENED_VIA)[number];

export class SupportError extends Error {
  readonly statusCode: number;
  readonly code: string;

  constructor(statusCode: number, code: string, message: string) {
    super(message);
    this.name = 'SupportError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

export class SupportSmsUnavailableError extends SupportError {
  constructor() {
    super(
      503,
      'SMS_NOT_CONFIGURED',
      'No SMS provider is configured, so the reply was not sent. Copy the text and use a connected channel.',
    );
    this.name = 'SupportSmsUnavailableError';
  }
}

function failure(statusCode: number, code: string, message: string): SupportError {
  return new SupportError(statusCode, code, message);
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function bounded(value: unknown, label: string, min: number, max: number): string {
  const result = text(value);
  if (result.length < min || result.length > max) {
    throw failure(422, 'SUPPORT_INPUT_INVALID', `${label} must be ${min}-${max} characters`);
  }
  return result;
}

function oneOf<T extends string>(value: unknown, allowed: readonly T[], label: string): T {
  const result = text(value) as T;
  if (!allowed.includes(result)) {
    throw failure(422, 'SUPPORT_INPUT_INVALID', `${label} is not a valid value`);
  }
  return result;
}

const REFERENCE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/** `CS-YYMMDD-XXXXXX`, matching the database check constraint. */
export function newSupportCaseReference(now = new Date()): string {
  const date = [
    String(now.getUTCFullYear()).slice(-2),
    String(now.getUTCMonth() + 1).padStart(2, '0'),
    String(now.getUTCDate()).padStart(2, '0'),
  ].join('');
  const bytes = randomBytes(6);
  let token = '';
  for (const byte of bytes) token += REFERENCE_ALPHABET[byte % REFERENCE_ALPHABET.length];
  return `CS-${date}-${token}`;
}

export interface SupportCaseListItem {
  id: string;
  reference: string;
  subject: string;
  category: SupportCategory;
  status: SupportStatus;
  priority: SupportPriority;
  customerName: string | null;
  phoneLast4: string;
  assigneeName: string | null;
  tradeReference: string | null;
  lastActivityAt: string;
  createdAt: string;
}

export interface SupportFilters {
  query?: string;
  status?: string;
  priority?: string;
  assignee?: string;
  adminId: string;
}

interface SupportCaseRow {
  id: string;
  reference: string;
  subject: string;
  category: SupportCategory;
  status: SupportStatus;
  priority: SupportPriority;
  customer_name: string | null;
  phone_last4: string;
  assignee_name: string | null;
  trade_reference: string | null;
  last_activity_at: Date;
  created_at: Date;
}

function toCaseListItem(row: SupportCaseRow): SupportCaseListItem {
  return {
    id: row.id,
    reference: row.reference,
    subject: row.subject,
    category: row.category,
    status: row.status,
    priority: row.priority,
    customerName: row.customer_name,
    phoneLast4: row.phone_last4,
    assigneeName: row.assignee_name,
    tradeReference: row.trade_reference,
    lastActivityAt: new Date(row.last_activity_at).toISOString(),
    createdAt: new Date(row.created_at).toISOString(),
  };
}

export async function loadSupportCases(
  pool: Pool,
  filters: SupportFilters,
): Promise<SupportCaseListItem[]> {
  const query = text(filters.query).slice(0, 80);
  const like = `%${query}%`;
  const status = SUPPORT_STATUSES.includes(filters.status as SupportStatus)
    ? String(filters.status)
    : '';
  const priority = SUPPORT_PRIORITIES.includes(filters.priority as SupportPriority)
    ? String(filters.priority)
    : '';
  const assignee = text(filters.assignee);

  const result = await pool.query<SupportCaseRow>(
    `SELECT c.id, c.reference, c.subject, c.category, c.status, c.priority,
            u.display_name AS customer_name, right(u.phone, 4) AS phone_last4,
            a.name AS assignee_name, t.reference AS trade_reference,
            c.last_activity_at, c.created_at
     FROM support_cases c
     JOIN users u ON u.id = c.user_id
     LEFT JOIN admin_users a ON a.id = c.assignee_admin_id
     LEFT JOIN trades t ON t.id = c.trade_id
     WHERE ($1::text = ''
            OR c.reference ILIKE $2
            OR u.phone LIKE $2
            OR t.reference ILIKE $2)
       AND ($3::text = '' OR c.status = $3)
       AND ($4::text = '' OR c.priority = $4)
       AND ($5::text = 'all'
            OR ($5::text = 'me' AND c.assignee_admin_id = $6)
            OR ($5::text = 'unassigned' AND c.assignee_admin_id IS NULL)
            OR ($5::text NOT IN ('all', 'me', 'unassigned')
                AND c.assignee_admin_id::text = $5))
     ORDER BY CASE c.priority
                WHEN 'urgent' THEN 0 WHEN 'high' THEN 1
                WHEN 'normal' THEN 2 ELSE 3 END,
              c.last_activity_at DESC, c.id DESC
     LIMIT 100`,
    [query, like, status, priority, assignee, filters.adminId],
  );
  return result.rows.map(toCaseListItem);
}

export async function loadSupportSummary(pool: Pool, adminId: string) {
  const result = await pool.query<{
    open: number;
    pending_customer: number;
    unassigned: number;
    urgent: number;
    mine: number;
  }>(
    `SELECT count(*) FILTER (WHERE status IN ('open', 'pending_internal'))::int AS open,
            count(*) FILTER (WHERE status = 'pending_customer')::int AS pending_customer,
            count(*) FILTER (WHERE assignee_admin_id IS NULL
                               AND status NOT IN ('resolved', 'closed'))::int AS unassigned,
            count(*) FILTER (WHERE priority IN ('high', 'urgent')
                               AND status NOT IN ('resolved', 'closed'))::int AS urgent,
            count(*) FILTER (WHERE assignee_admin_id = $1
                               AND status NOT IN ('resolved', 'closed'))::int AS mine
     FROM support_cases`,
    [adminId],
  );
  const row = result.rows[0];
  return {
    open: Number(row?.open ?? 0),
    pendingCustomer: Number(row?.pending_customer ?? 0),
    unassigned: Number(row?.unassigned ?? 0),
    urgent: Number(row?.urgent ?? 0),
    mine: Number(row?.mine ?? 0),
  };
}

export interface SupportMessageView {
  id: string;
  channel: string;
  visibility: 'internal' | 'customer';
  body: string;
  deliveryStatus: string;
  errorCode: string | null;
  deliveredAt: string | null;
  createdAt: string;
  authorName: string | null;
  authorEmail: string | null;
}

export interface SupportCaseDetail {
  id: string;
  reference: string;
  subject: string;
  category: SupportCategory;
  status: SupportStatus;
  priority: SupportPriority;
  openedVia: string;
  assigneeAdminId: string | null;
  assigneeName: string | null;
  creatorName: string | null;
  creatorEmail: string | null;
  firstResponseAt: string | null;
  resolvedAt: string | null;
  closedAt: string | null;
  lastActivityAt: string;
  createdAt: string;
  customer: {
    id: string;
    displayName: string | null;
    phoneLast4: string;
    accountType: string;
    kycStatus: string;
    tierCode: string;
    limitCurrencyCode: string | null;
    phoneVerified: boolean;
    createdAt: string;
  };
  trade: {
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
    createdAt: string;
  } | null;
  messages: SupportMessageView[];
}

export async function loadSupportCase(
  pool: Pool,
  caseId: string,
): Promise<SupportCaseDetail | null> {
  const result = await pool.query<{
    id: string;
    reference: string;
    subject: string;
    category: SupportCategory;
    status: SupportStatus;
    priority: SupportPriority;
    opened_via: string;
    assignee_admin_id: string | null;
    assignee_name: string | null;
    creator_name: string | null;
    creator_email: string | null;
    first_response_at: Date | null;
    resolved_at: Date | null;
    closed_at: Date | null;
    last_activity_at: Date;
    created_at: Date;
    user_id: string;
    display_name: string | null;
    phone_last4: string;
    account_type: string;
    kyc_status: string;
    tier_code: string;
    limit_currency_code: string | null;
    phone_verified_at: Date | null;
    user_created_at: Date;
    trade_id: string | null;
    trade_reference: string | null;
    trade_status: string | null;
    trade_route: string | null;
    send_currency: string | null;
    receive_currency: string | null;
    send_amount_minor: string | null;
    receive_amount_minor: string | null;
    beneficiary_name: string | null;
    beneficiary_last4: string | null;
    trade_created_at: Date | null;
  }>(
    `SELECT c.id, c.reference, c.subject, c.category, c.status, c.priority,
            c.opened_via, c.assignee_admin_id,
            a.name AS assignee_name,
            creator.name AS creator_name, creator.email AS creator_email,
            c.first_response_at, c.resolved_at, c.closed_at,
            c.last_activity_at, c.created_at,
            u.id AS user_id, u.display_name, right(u.phone, 4) AS phone_last4,
            u.account_type, u.kyc_status, u.tier_code, u.limit_currency_code,
            u.phone_verified_at, u.created_at AS user_created_at,
            t.id AS trade_id, t.reference AS trade_reference, t.status AS trade_status,
            t.route AS trade_route, t.send_currency, t.receive_currency,
            t.send_amount_minor, t.receive_amount_minor,
            t.beneficiary_name, t.beneficiary_account_last4 AS beneficiary_last4,
            t.created_at AS trade_created_at
     FROM support_cases c
     JOIN users u ON u.id = c.user_id
     LEFT JOIN admin_users a ON a.id = c.assignee_admin_id
     LEFT JOIN admin_users creator ON creator.id = c.created_by_admin_id
     LEFT JOIN trades t ON t.id = c.trade_id
     WHERE c.id = $1`,
    [caseId],
  );
  const row = result.rows[0];
  if (!row) return null;

  const messages = await pool.query<{
    id: string;
    channel: string;
    visibility: 'internal' | 'customer';
    body: string;
    delivery_status: string;
    error_code: string | null;
    delivered_at: Date | null;
    created_at: Date;
    author_name: string | null;
    author_email: string | null;
  }>(
    `SELECT m.id, m.channel, m.visibility, m.body, m.delivery_status,
            m.error_code, m.delivered_at, m.created_at,
            a.name AS author_name, a.email AS author_email
     FROM support_case_messages m
     LEFT JOIN admin_users a ON a.id = m.author_admin_id
     WHERE m.case_id = $1
     ORDER BY m.created_at, m.id`,
    [caseId],
  );

  return {
    id: row.id,
    reference: row.reference,
    subject: row.subject,
    category: row.category,
    status: row.status,
    priority: row.priority,
    openedVia: row.opened_via,
    assigneeAdminId: row.assignee_admin_id,
    assigneeName: row.assignee_name,
    creatorName: row.creator_name,
    creatorEmail: row.creator_email,
    firstResponseAt: row.first_response_at ? new Date(row.first_response_at).toISOString() : null,
    resolvedAt: row.resolved_at ? new Date(row.resolved_at).toISOString() : null,
    closedAt: row.closed_at ? new Date(row.closed_at).toISOString() : null,
    lastActivityAt: new Date(row.last_activity_at).toISOString(),
    createdAt: new Date(row.created_at).toISOString(),
    customer: {
      id: row.user_id,
      displayName: row.display_name,
      phoneLast4: row.phone_last4,
      accountType: row.account_type,
      kycStatus: row.kyc_status,
      tierCode: row.tier_code,
      limitCurrencyCode: row.limit_currency_code,
      phoneVerified: row.phone_verified_at !== null,
      createdAt: new Date(row.user_created_at).toISOString(),
    },
    trade:
      row.trade_id && row.trade_reference
        ? {
            id: row.trade_id,
            reference: row.trade_reference,
            status: row.trade_status ?? '',
            route: row.trade_route ?? '',
            sendCurrency: row.send_currency ?? '',
            receiveCurrency: row.receive_currency ?? '',
            sendAmountMinor: Number(row.send_amount_minor ?? 0),
            receiveAmountMinor: Number(row.receive_amount_minor ?? 0),
            beneficiaryName: row.beneficiary_name ?? '',
            beneficiaryLast4: row.beneficiary_last4 ?? '',
            createdAt: row.trade_created_at
              ? new Date(row.trade_created_at).toISOString()
              : '',
          }
        : null,
    messages: messages.rows.map((message) => ({
      id: message.id,
      channel: message.channel,
      visibility: message.visibility,
      body: message.body,
      deliveryStatus: message.delivery_status,
      errorCode: message.error_code,
      deliveredAt: message.delivered_at
        ? new Date(message.delivered_at).toISOString()
        : null,
      createdAt: new Date(message.created_at).toISOString(),
      authorName: message.author_name,
      authorEmail: message.author_email,
    })),
  };
}

export async function loadCustomer360(pool: Pool, userId: string) {
  const user = await pool.query<{
    id: string;
    display_name: string | null;
    phone_last4: string;
    account_type: string;
    kyc_status: string;
    tier_code: string;
    limit_currency_code: string | null;
    phone_verified_at: Date | null;
    created_at: Date;
  }>(
    `SELECT id, display_name, right(phone, 4) AS phone_last4,
            account_type, kyc_status, tier_code, limit_currency_code,
            phone_verified_at, created_at
     FROM users WHERE id = $1 AND deleted_at IS NULL`,
    [userId],
  );
  const row = user.rows[0];
  if (!row) return null;

  const [trades, cases, counts] = await Promise.all([
    pool.query<{
      id: string;
      reference: string;
      status: string;
      route: string;
      send_currency: string;
      receive_currency: string;
      send_amount_minor: string;
      receive_amount_minor: string;
      created_at: Date;
    }>(
      `SELECT id, reference, status, route, send_currency, receive_currency,
              send_amount_minor, receive_amount_minor, created_at
       FROM trades WHERE user_id = $1
       ORDER BY created_at DESC, id DESC LIMIT 20`,
      [userId],
    ),
    pool.query<{
      id: string;
      reference: string;
      subject: string;
      status: SupportStatus;
      priority: SupportPriority;
      last_activity_at: Date;
      assignee_name: string | null;
    }>(
      `SELECT c.id, c.reference, c.subject, c.status, c.priority,
              c.last_activity_at, a.name AS assignee_name
       FROM support_cases c
       LEFT JOIN admin_users a ON a.id = c.assignee_admin_id
       WHERE c.user_id = $1
       ORDER BY c.last_activity_at DESC, c.id DESC LIMIT 20`,
      [userId],
    ),
    pool.query<{ total: number; open: number }>(
      `SELECT count(*)::int AS total,
              count(*) FILTER (WHERE status NOT IN ('resolved', 'closed'))::int AS open
       FROM support_cases WHERE user_id = $1`,
      [userId],
    ),
  ]);

  return {
    customer: {
      id: row.id,
      displayName: row.display_name,
      phoneLast4: row.phone_last4,
      accountType: row.account_type,
      kycStatus: row.kyc_status,
      tierCode: row.tier_code,
      limitCurrencyCode: row.limit_currency_code,
      phoneVerified: row.phone_verified_at !== null,
      createdAt: new Date(row.created_at).toISOString(),
    },
    caseCount: Number(counts.rows[0]?.total ?? 0),
    openCaseCount: Number(counts.rows[0]?.open ?? 0),
    trades: trades.rows.map((trade) => ({
      id: trade.id,
      reference: trade.reference,
      status: trade.status,
      route: trade.route,
      sendCurrency: trade.send_currency,
      receiveCurrency: trade.receive_currency,
      sendAmountMinor: Number(trade.send_amount_minor),
      receiveAmountMinor: Number(trade.receive_amount_minor),
      createdAt: new Date(trade.created_at).toISOString(),
    })),
    cases: cases.rows.map((supportCase) => ({
      id: supportCase.id,
      reference: supportCase.reference,
      subject: supportCase.subject,
      status: supportCase.status,
      priority: supportCase.priority,
      assigneeName: supportCase.assignee_name,
      lastActivityAt: new Date(supportCase.last_activity_at).toISOString(),
    })),
  };
}

export async function loadSupportAgents(pool: Pool) {
  const result = await pool.query<{
    id: string;
    name: string;
    email: string;
    roles: string[];
  }>(
    `SELECT u.id, u.name, u.email,
            array_agg(r.role ORDER BY r.role) AS roles
     FROM admin_users u
     JOIN admin_user_roles r ON r.admin_user_id = u.id
     WHERE u.status = 'active'
       AND EXISTS (
         SELECT 1 FROM admin_user_roles support_role
         WHERE support_role.admin_user_id = u.id
           AND support_role.role IN ('ops', 'compliance', 'superadmin')
       )
     GROUP BY u.id, u.name, u.email
     ORDER BY u.name, u.email`,
  );
  return result.rows;
}

export interface CannedReply {
  id: string;
  title: string;
  body: string;
  category: string | null;
  active: boolean;
}

export async function loadCannedReplies(pool: Pool, activeOnly = true): Promise<CannedReply[]> {
  const result = await pool.query<{
    id: string;
    title: string;
    body: string;
    category: string | null;
    active: boolean;
  }>(
    `SELECT id, title, body, category, active
     FROM support_canned_replies
     WHERE ($1::boolean = false OR active)
     ORDER BY active DESC, title`,
    [activeOnly],
  );
  return result.rows;
}

export interface CreateSupportCaseInput {
  userId?: string;
  phone?: string;
  tradeReference?: string;
  subject: string;
  category: string;
  priority: string;
  openedVia: string;
  note?: string;
  adminId: string;
}

export interface CreatedSupportCase {
  id: string;
  reference: string;
  userId: string;
  tradeId: string | null;
  customerName: string | null;
  phoneLast4: string;
}

export async function createSupportCase(
  ctx: AppContext,
  input: CreateSupportCaseInput,
): Promise<CreatedSupportCase> {
  const subject = bounded(input.subject, 'Subject', 3, 200);
  const category = oneOf(input.category, SUPPORT_CATEGORIES, 'Category');
  const priority = oneOf(input.priority, SUPPORT_PRIORITIES, 'Priority');
  const openedVia = oneOf(input.openedVia, SUPPORT_OPENED_VIA, 'Opened via');
  const note = text(input.note);
  if (note.length > 4000) {
    throw failure(422, 'SUPPORT_INPUT_INVALID', 'The opening note must be 4000 characters or fewer');
  }
  const phone = text(input.phone);
  const userId = text(input.userId);
  if (!userId && !/^\+[1-9][0-9]{7,14}$/.test(phone)) {
    throw failure(
      422,
      'SUPPORT_CUSTOMER_INVALID',
      'Enter a customer phone in international format, for example +2557…',
    );
  }

  return withTransaction(ctx.pool, async (client) => {
    const user = userId
      ? await client.query<{ id: string; display_name: string | null; phone: string }>(
          `SELECT id, display_name, phone FROM users
           WHERE id = $1 AND deleted_at IS NULL`,
          [userId],
        )
      : await client.query<{ id: string; display_name: string | null; phone: string }>(
          `SELECT id, display_name, phone FROM users
           WHERE phone = $1 AND deleted_at IS NULL`,
          [phone],
        );
    const customer = user.rows[0];
    if (!customer) {
      throw failure(404, 'SUPPORT_CUSTOMER_NOT_FOUND', 'No customer account matches that phone');
    }

    let tradeId: string | null = null;
    const tradeReference = text(input.tradeReference).toUpperCase();
    if (tradeReference) {
      const trade = await client.query<{ id: string; user_id: string }>(
        `SELECT id, user_id FROM trades WHERE reference = $1`,
        [tradeReference],
      );
      const tradeRow = trade.rows[0];
      if (!tradeRow) {
        throw failure(404, 'SUPPORT_TRADE_NOT_FOUND', 'No trade matches that reference');
      }
      if (tradeRow.user_id !== customer.id) {
        throw failure(422, 'SUPPORT_TRADE_MISMATCH', 'That trade belongs to another customer');
      }
      tradeId = tradeRow.id;
    }

    let inserted:
      | { id: string; reference: string }
      | undefined;
    for (let attempt = 0; attempt < 4 && !inserted; attempt += 1) {
      const reference = newSupportCaseReference();
      await client.query('SAVEPOINT support_case_reference');
      try {
        const result = await client.query<{ id: string; reference: string }>(
          `INSERT INTO support_cases
             (reference, user_id, trade_id, subject, category, status, priority,
              created_by_admin_id, opened_via)
           VALUES ($1, $2, $3, $4, $5, 'open', $6, $7, $8)
           RETURNING id, reference`,
          [reference, customer.id, tradeId, subject, category, priority, input.adminId, openedVia],
        );
        await client.query('RELEASE SAVEPOINT support_case_reference');
        inserted = result.rows[0];
      } catch (error) {
        await client.query('ROLLBACK TO SAVEPOINT support_case_reference');
        if ((error as { code?: string }).code === '23505') continue;
        throw error;
      }
    }
    if (!inserted) {
      throw failure(503, 'SUPPORT_CASE_REFERENCE_FAILED', 'Could not allocate a case reference');
    }

    if (note.length > 0) {
      await client.query(
        `INSERT INTO support_case_messages
           (case_id, channel, visibility, author_admin_id, body)
         VALUES ($1, 'note', 'internal', $2, $3)`,
        [inserted.id, input.adminId, note],
      );
    }

    return {
      id: inserted.id,
      reference: inserted.reference,
      userId: customer.id,
      tradeId,
      customerName: customer.display_name,
      phoneLast4: customer.phone.slice(-4),
    };
  });
}

export async function appendSupportNote(
  ctx: AppContext,
  input: { caseId: string; adminId: string; body: string },
): Promise<string> {
  const body = bounded(input.body, 'Note', 1, 4000);
  const result = await ctx.pool.query<{ id: string }>(
    `INSERT INTO support_case_messages
       (case_id, channel, visibility, author_admin_id, body)
     VALUES ($1, 'note', 'internal', $2, $3)
     RETURNING id`,
    [input.caseId, input.adminId, body],
  );
  return result.rows[0]!.id;
}

export interface SendSupportSmsResult {
  status: 'sent' | 'failed';
  messageId: string;
  errorCode: string | null;
}

/**
 * Records the outbound SMS before calling the gateway so a crash cannot lose
 * the fact that a reply was attempted. The gateway never receives an internal
 * note. Delivery state is the only mutable field on the message row.
 */
export async function sendSupportSms(
  ctx: AppContext,
  input: { caseId: string; adminId: string; body: string },
): Promise<SendSupportSmsResult> {
  if (!ctx.smsSender.available) throw new SupportSmsUnavailableError();
  const body = bounded(input.body, 'Message', 1, 480);
  const customer = await ctx.pool.query<{ phone: string }>(
    `SELECT u.phone
     FROM support_cases c JOIN users u ON u.id = c.user_id
     WHERE c.id = $1`,
    [input.caseId],
  );
  const phone = customer.rows[0]?.phone;
  if (!phone) throw failure(404, 'SUPPORT_CASE_NOT_FOUND', 'Support case not found');

  const inserted = await ctx.pool.query<{ id: string }>(
    `INSERT INTO support_case_messages
       (case_id, channel, visibility, author_admin_id, body, delivery_status)
     VALUES ($1, 'sms', 'customer', $2, $3, 'pending')
     RETURNING id`,
    [input.caseId, input.adminId, body],
  );
  const messageId = inserted.rows[0]!.id;

  try {
    await ctx.smsSender.sendMessage(phone, body);
  } catch {
    const errorCode = 'SMS_DELIVERY_FAILED';
    await ctx.pool.query(
      `UPDATE support_case_messages
       SET delivery_status = 'failed', error_code = $2
       WHERE id = $1 AND delivery_status = 'pending'`,
      [messageId, errorCode],
    );
    return { status: 'failed', messageId, errorCode };
  }

  await withTransaction(ctx.pool, async (client) => {
    await client.query(
      `UPDATE support_case_messages
       SET delivery_status = 'sent', delivered_at = now()
       WHERE id = $1 AND delivery_status = 'pending'`,
      [messageId],
    );
    await client.query(
      `UPDATE support_cases
       SET status = CASE WHEN status = 'open' THEN 'pending_customer' ELSE status END,
           first_response_at = COALESCE(first_response_at, now())
       WHERE id = $1`,
      [input.caseId],
    );
  });
  return { status: 'sent', messageId, errorCode: null };
}

export interface UpdateSupportCaseInput {
  caseId: string;
  status: string;
  priority: string;
  assigneeAdminId: string | null;
}

export async function updateSupportCase(
  ctx: AppContext,
  input: UpdateSupportCaseInput,
): Promise<{ before: Record<string, unknown>; after: Record<string, unknown> }> {
  const status = oneOf(input.status, SUPPORT_STATUSES, 'Status');
  const priority = oneOf(input.priority, SUPPORT_PRIORITIES, 'Priority');
  const assignee = text(input.assigneeAdminId) || null;

  return withTransaction(ctx.pool, async (client) => {
    const current = await client.query<{
      id: string;
      status: SupportStatus;
      priority: SupportPriority;
      assignee_admin_id: string | null;
    }>(
      `SELECT id, status, priority, assignee_admin_id
       FROM support_cases WHERE id = $1 FOR UPDATE`,
      [input.caseId],
    );
    const before = current.rows[0];
    if (!before) throw failure(404, 'SUPPORT_CASE_NOT_FOUND', 'Support case not found');

    if (assignee) {
      const agent = await client.query(
        `SELECT 1 FROM admin_users WHERE id = $1 AND status = 'active'`,
        [assignee],
      );
      if (!agent.rowCount) {
        throw failure(422, 'SUPPORT_ASSIGNEE_INVALID', 'Choose an active admin account');
      }
    }

    const updated = await client.query<{
      status: SupportStatus;
      priority: SupportPriority;
      assignee_admin_id: string | null;
    }>(
      `UPDATE support_cases
       SET status = $2,
           priority = $3,
           assignee_admin_id = $4,
           last_activity_at = now(),
           resolved_at = CASE
             WHEN $2 IN ('resolved', 'closed') THEN COALESCE(resolved_at, now())
             ELSE NULL END,
           closed_at = CASE
             WHEN $2 = 'closed' THEN COALESCE(closed_at, now())
             ELSE NULL END
       WHERE id = $1
       RETURNING status, priority, assignee_admin_id`,
      [input.caseId, status, priority, assignee],
    );

    return {
      before: {
        status: before.status,
        priority: before.priority,
        assigneeAdminId: before.assignee_admin_id,
      },
      after: {
        status: updated.rows[0]?.status,
        priority: updated.rows[0]?.priority,
        assigneeAdminId: updated.rows[0]?.assignee_admin_id,
      },
    };
  });
}

export async function loadSupportCasePii(ctx: AppContext, caseId: string) {
  const result = await ctx.pool.query<{
    phone: string;
    beneficiary_name: string | null;
    beneficiary_account_encrypted: Buffer | null;
  }>(
    `SELECT u.phone, t.beneficiary_name, t.beneficiary_account_encrypted
     FROM support_cases c
     JOIN users u ON u.id = c.user_id
     LEFT JOIN trades t ON t.id = c.trade_id
     WHERE c.id = $1`,
    [caseId],
  );
  const row = result.rows[0];
  if (!row) return null;
  return {
    phone: row.phone,
    beneficiaryName: row.beneficiary_name,
    beneficiaryAccount: row.beneficiary_account_encrypted
      ? ctx.crypto.decrypt(row.beneficiary_account_encrypted)
      : null,
  };
}

export async function recordPiiReveal(
  ctx: AppContext,
  input: {
    caseId: string;
    adminId: string;
    reason: string;
    fields: string[];
  },
): Promise<void> {
  const reason = bounded(input.reason, 'Reason', 5, 300);
  await ctx.pool.query(
    `INSERT INTO support_pii_reveals (case_id, admin_user_id, reason, fields)
     VALUES ($1, $2, $3, $4)`,
    [input.caseId, input.adminId, reason, input.fields],
  );
}

export async function createCannedReply(
  ctx: AppContext,
  input: { title: string; body: string; category: string; adminId: string },
): Promise<string> {
  const title = bounded(input.title, 'Title', 3, 120);
  const body = bounded(input.body, 'Body', 3, 2000);
  const category = text(input.category);
  if (category && !SUPPORT_CATEGORIES.includes(category as SupportCategory)) {
    throw failure(422, 'SUPPORT_INPUT_INVALID', 'Category is not a valid value');
  }
  const result = await ctx.pool.query<{ id: string }>(
    `INSERT INTO support_canned_replies
       (title, body, category, created_by_admin_id)
     VALUES ($1, $2, $3, $4)
     RETURNING id`,
    [title, body, category || null, input.adminId],
  ).catch((error: { code?: string }) => {
    if (error.code === '23505') {
      throw failure(422, 'CANNED_REPLY_DUPLICATE', 'A canned reply with that title already exists');
    }
    throw error;
  });
  return result.rows[0]!.id;
}

export async function toggleCannedReply(
  ctx: AppContext,
  id: string,
): Promise<{ before: boolean; after: boolean }> {
  const result = await ctx.pool.query<{ active: boolean }>(
    `UPDATE support_canned_replies
     SET active = NOT active
     WHERE id = $1
     RETURNING active`,
    [id],
  );
  const row = result.rows[0];
  if (!row) throw failure(404, 'CANNED_REPLY_NOT_FOUND', 'Canned reply not found');
  return { before: !row.active, after: row.active };
}
