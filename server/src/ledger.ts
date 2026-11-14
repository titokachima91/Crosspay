import type { PoolClient } from 'pg';

export type JournalKind =
  | 'deposit_received'
  | 'fee_earned'
  | 'payout_sent'
  | 'refund_paid'
  | 'fx_conversion'
  | 'adjustment'
  | 'opening_balance';

export interface JournalLineInput {
  accountId: string;
  /** Positive = debit, negative = credit. */
  amountMinor: bigint;
}

export interface PostJournalInput {
  postingKey: string;
  kind: JournalKind;
  currencyCode: string;
  lines: JournalLineInput[];
  tradeId?: string;
  paymentEventId?: string;
  payoutId?: string;
  refundId?: string;
  fxGroupId?: string;
  reversesTransactionId?: string;
  occurredAt?: Date;
}

export class JournalValidationError extends Error {
  readonly code = 'JOURNAL_VALIDATION_FAILED';
  constructor(message: string) {
    super(message);
    this.name = 'JournalValidationError';
  }
}

export function sumMinorUnits(lines: ReadonlyArray<JournalLineInput>): bigint {
  return lines.reduce((total, line) => total + line.amountMinor, 0n);
}

/**
 * Posts one balanced, single-currency journal transaction. The caller must run
 * this inside the same database transaction as the business event. The
 * database re-checks balance and currency at commit.
 */
export async function postJournal(
  client: PoolClient,
  input: PostJournalInput,
): Promise<{ transactionId: string }> {
  if (input.lines.length < 2) {
    throw new JournalValidationError('a journal transaction needs at least two lines');
  }
  if (input.lines.some((line) => line.amountMinor === 0n)) {
    throw new JournalValidationError('journal lines cannot be zero');
  }
  if (sumMinorUnits(input.lines) !== 0n) {
    throw new JournalValidationError('journal lines must sum to zero');
  }

  const transaction = await client.query(
    `INSERT INTO journal_transactions
       (posting_key, kind, trade_id, payment_event_id, payout_id, refund_id,
        currency_code, fx_group_id, reverses_transaction_id, occurred_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, COALESCE($10, now()))
     RETURNING id`,
    [
      input.postingKey,
      input.kind,
      input.tradeId ?? null,
      input.paymentEventId ?? null,
      input.payoutId ?? null,
      input.refundId ?? null,
      input.currencyCode,
      input.fxGroupId ?? null,
      input.reversesTransactionId ?? null,
      input.occurredAt ?? null,
    ],
  );

  const transactionId = String(transaction.rows[0]?.['id']);
  for (const line of input.lines) {
    await client.query(
      `INSERT INTO journal_lines (transaction_id, account_id, amount_minor)
       VALUES ($1, $2, $3)`,
      [transactionId, line.accountId, line.amountMinor.toString()],
    );
  }

  return { transactionId };
}

/** Fetches the lines needed to build a reversing entry. */
export async function getJournalLines(
  client: PoolClient,
  transactionId: string,
): Promise<Array<{ accountId: string; amountMinor: bigint }>> {
  const result = await client.query(
    `SELECT account_id, amount_minor
     FROM journal_lines
     WHERE transaction_id = $1
     ORDER BY id`,
    [transactionId],
  );
  return result.rows.map((row) => ({
    accountId: String(row['account_id']),
    amountMinor: BigInt(String(row['amount_minor'])),
  }));
}

/** Posts the exact opposite of an existing transaction under a new posting key. */
export async function reverseJournal(
  client: PoolClient,
  input: {
    originalTransactionId: string;
    postingKey: string;
    occurredAt?: Date;
  },
): Promise<{ transactionId: string }> {
  const original = await client.query(
    `SELECT id, kind, trade_id, payment_event_id, payout_id, refund_id, currency_code
     FROM journal_transactions
     WHERE id = $1`,
    [input.originalTransactionId],
  );
  const row = original.rows[0];
  if (!row) throw new JournalValidationError('original journal transaction not found');

  const lines = await getJournalLines(client, input.originalTransactionId);
  if (lines.length < 2) throw new JournalValidationError('original transaction has no lines');

  return postJournal(client, {
    postingKey: input.postingKey,
    kind: 'adjustment',
    currencyCode: String(row['currency_code']),
    tradeId: row['trade_id'] === null ? undefined : String(row['trade_id']),
    paymentEventId:
      row['payment_event_id'] === null ? undefined : String(row['payment_event_id']),
    payoutId: row['payout_id'] === null ? undefined : String(row['payout_id']),
    refundId: row['refund_id'] === null ? undefined : String(row['refund_id']),
    reversesTransactionId: input.originalTransactionId,
    occurredAt: input.occurredAt,
    lines: lines.map((line) => ({
      accountId: line.accountId,
      amountMinor: -line.amountMinor,
    })),
  });
}
