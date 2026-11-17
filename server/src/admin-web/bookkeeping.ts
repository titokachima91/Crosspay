import type { Pool } from 'pg';

export interface TrialBalanceRow {
  currency: string;
  code: string;
  name: string;
  type: string;
  normalSide: 'debit' | 'credit';
  debitMinor: number;
  creditMinor: number;
  balanceMinor: number;
  side: 'Dr' | 'Cr';
  lineCount: number;
}

export interface TrialBalanceCurrency {
  currency: string;
  accounts: TrialBalanceRow[];
  totalDebitMinor: number;
  totalCreditMinor: number;
  balanced: boolean;
}

export interface JournalListRow {
  id: string;
  postingKey: string;
  kind: string;
  currency: string;
  occurredAt: string;
  createdAt: string;
  reference: string | null;
  tradeId: string | null;
  fxGroupId: string | null;
  reversesTransactionId: string | null;
  lineCount: number;
  debitMinor: number;
}

export interface JournalLineView {
  code: string;
  name: string;
  type: string;
  side: 'Dr' | 'Cr';
  amountMinor: number;
}

export interface JournalDetail {
  id: string;
  postingKey: string;
  kind: string;
  currency: string;
  occurredAt: string;
  createdAt: string;
  reference: string | null;
  tradeId: string | null;
  tradeStatus: string | null;
  payoutId: string | null;
  refundId: string | null;
  fxGroupId: string | null;
  fxPartners: Array<{ id: string; currency: string; postingKey: string; kind: string }>;
  reversesTransactionId: string | null;
  reversalIds: string[];
  lines: JournalLineView[];
  debitMinor: number;
  creditMinor: number;
  balanced: boolean;
}

interface TrialRow {
  currency_code: string;
  code: string;
  name: string;
  type: string;
  normal_side: 'debit' | 'credit';
  debit_minor: string;
  credit_minor: string;
  net_minor: string;
  line_count: number;
}

function toTrialRow(row: TrialRow): TrialBalanceRow {
  const net = Number(row.net_minor);
  return {
    currency: row.currency_code,
    code: row.code,
    name: row.name,
    type: row.type,
    normalSide: row.normal_side,
    debitMinor: Number(row.debit_minor),
    creditMinor: Number(row.credit_minor),
    balanceMinor: Math.abs(net),
    side: net >= 0 ? 'Dr' : 'Cr',
    lineCount: row.line_count,
  };
}

/**
 * Debit-positive trial balance per currency. Accounts with no journal lines are
 * omitted; every active account is seeded and will appear once it is used.
 */
export async function loadTrialBalance(pool: Pool): Promise<TrialBalanceCurrency[]> {
  const result = await pool.query<TrialRow>(
    `SELECT a.currency_code, a.code, a.name, a.type, a.normal_side,
            COALESCE(sum(l.amount_minor) FILTER (WHERE l.amount_minor > 0), 0)::text AS debit_minor,
            COALESCE(-sum(l.amount_minor) FILTER (WHERE l.amount_minor < 0), 0)::text AS credit_minor,
            COALESCE(sum(l.amount_minor), 0)::text AS net_minor,
            count(l.id)::int AS line_count
     FROM ledger_accounts a
     JOIN journal_lines l ON l.account_id = a.id
     WHERE a.active
     GROUP BY a.id
     ORDER BY a.currency_code, a.code`,
  );

  const byCurrency = new Map<string, TrialBalanceRow[]>();
  for (const row of result.rows) {
    const view = toTrialRow(row);
    const list = byCurrency.get(view.currency) ?? [];
    list.push(view);
    byCurrency.set(view.currency, list);
  }

  return [...byCurrency.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([currency, accounts]) => {
      const totalDebitMinor = accounts.reduce((sum, account) => sum + account.debitMinor, 0);
      const totalCreditMinor = accounts.reduce((sum, account) => sum + account.creditMinor, 0);
      return {
        currency,
        accounts,
        totalDebitMinor,
        totalCreditMinor,
        balanced: totalDebitMinor === totalCreditMinor,
      };
    });
}

interface JournalRow {
  id: string;
  posting_key: string;
  kind: string;
  currency_code: string;
  occurred_at: Date;
  created_at: Date;
  reference: string | null;
  fx_group_id: string | null;
  reverses_transaction_id: string | null;
  trade_id: string | null;
  line_count: number;
  debit_minor: string;
}

export async function loadJournals(
  pool: Pool,
  input: { currency?: string; kind?: string; reference?: string } = {},
): Promise<JournalListRow[]> {
  const currency = (input.currency ?? '').trim().toUpperCase();
  const kind = (input.kind ?? '').trim();
  const reference = (input.reference ?? '').trim();
  const result = await pool.query<JournalRow>(
    `SELECT tx.id, tx.posting_key, tx.kind, tx.currency_code,
            tx.occurred_at, tx.created_at, t.reference, tx.trade_id,
            tx.fx_group_id, tx.reverses_transaction_id,
            count(l.id)::int AS line_count,
            COALESCE(sum(l.amount_minor) FILTER (WHERE l.amount_minor > 0), 0)::text AS debit_minor
     FROM journal_transactions tx
     LEFT JOIN trades t ON t.id = tx.trade_id
     JOIN journal_lines l ON l.transaction_id = tx.id
     WHERE ($1::text = '' OR tx.currency_code = $1)
       AND ($2::text = '' OR tx.kind = $2)
       AND ($3::text = '' OR t.reference ILIKE '%' || $3 || '%')
     GROUP BY tx.id, t.reference
     ORDER BY tx.created_at DESC, tx.id DESC
     LIMIT 100`,
    [currency, kind, reference],
  );
  return result.rows.map((row) => ({
    id: row.id,
    postingKey: row.posting_key,
    kind: row.kind,
    currency: row.currency_code,
    occurredAt: new Date(row.occurred_at).toISOString(),
    createdAt: new Date(row.created_at).toISOString(),
    reference: row.reference,
    tradeId: row.trade_id,
    fxGroupId: row.fx_group_id,
    reversesTransactionId: row.reverses_transaction_id,
    lineCount: row.line_count,
    debitMinor: Number(row.debit_minor),
  }));
}

export async function loadJournal(pool: Pool, id: string): Promise<JournalDetail | null> {
  const header = await pool.query<{
    id: string;
    posting_key: string;
    kind: string;
    currency_code: string;
    occurred_at: Date;
    created_at: Date;
    reference: string | null;
    trade_id: string | null;
    trade_status: string | null;
    payout_id: string | null;
    refund_id: string | null;
    fx_group_id: string | null;
    reverses_transaction_id: string | null;
  }>(
    `SELECT tx.id, tx.posting_key, tx.kind, tx.currency_code,
            tx.occurred_at, tx.created_at, t.reference, tx.trade_id,
            t.status AS trade_status, tx.payout_id, tx.refund_id,
            tx.fx_group_id, tx.reverses_transaction_id
     FROM journal_transactions tx
     LEFT JOIN trades t ON t.id = tx.trade_id
     WHERE tx.id = $1`,
    [id],
  );
  const row = header.rows[0];
  if (!row) return null;

  const [lines, reversalIds, fxPartners] = await Promise.all([
    pool.query<{
      code: string;
      name: string;
      type: string;
      normal_side: 'debit' | 'credit';
      amount_minor: string;
    }>(
      `SELECT a.code, a.name, a.type, a.normal_side, l.amount_minor
       FROM journal_lines l
       JOIN ledger_accounts a ON a.id = l.account_id
       WHERE l.transaction_id = $1
       ORDER BY a.code`,
      [id],
    ),
    pool.query<{ id: string }>(
      `SELECT id FROM journal_transactions WHERE reverses_transaction_id = $1 ORDER BY created_at`,
      [id],
    ),
    row.fx_group_id
      ? pool.query<{ id: string; currency_code: string; posting_key: string; kind: string }>(
          `SELECT id, currency_code, posting_key, kind
           FROM journal_transactions
           WHERE fx_group_id = $1 AND id <> $2
           ORDER BY currency_code`,
          [row.fx_group_id, id],
        )
      : Promise.resolve({
          rows: [] as Array<{ id: string; currency_code: string; posting_key: string; kind: string }>,
        }),
  ]);

  const linesView: JournalLineView[] = lines.rows.map((line) => {
    const amount = BigInt(line.amount_minor);
    return {
      code: line.code,
      name: line.name,
      type: line.type,
      side: amount >= 0n ? 'Dr' : 'Cr',
      amountMinor: Number(amount < 0n ? -amount : amount),
    };
  });
  const debitMinor = linesView
    .filter((line) => line.side === 'Dr')
    .reduce((sum, line) => sum + line.amountMinor, 0);
  const creditMinor = linesView
    .filter((line) => line.side === 'Cr')
    .reduce((sum, line) => sum + line.amountMinor, 0);

  return {
    id: row.id,
    postingKey: row.posting_key,
    kind: row.kind,
    currency: row.currency_code,
    occurredAt: new Date(row.occurred_at).toISOString(),
    createdAt: new Date(row.created_at).toISOString(),
    reference: row.reference,
    tradeId: row.trade_id,
    tradeStatus: row.trade_status,
    payoutId: row.payout_id,
    refundId: row.refund_id,
    fxGroupId: row.fx_group_id,
    fxPartners: fxPartners.rows.map((partner) => ({
      id: partner.id,
      currency: partner.currency_code,
      postingKey: partner.posting_key,
      kind: partner.kind,
    })),
    reversesTransactionId: row.reverses_transaction_id,
    reversalIds: reversalIds.rows.map((record) => record.id),
    lines: linesView,
    debitMinor,
    creditMinor,
    balanced: debitMinor === creditMinor,
  };
}

export const JOURNAL_KINDS = [
  'deposit_received',
  'fee_earned',
  'payout_sent',
  'refund_paid',
  'fx_conversion',
  'p2p_settlement',
  'p2p_compensation',
  'adjustment',
  'opening_balance',
] as const;
