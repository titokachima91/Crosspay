import { createHash } from 'node:crypto';
import type { Pool, PoolClient } from 'pg';
import { withTransaction } from '../db/pool.js';
import type { AppContext } from '../http/context.js';

export const STATEMENT_SOURCE_KINDS = ['provider', 'bank'] as const;
export type StatementSourceKind = (typeof STATEMENT_SOURCE_KINDS)[number];

export const STATEMENT_LINE_KINDS = [
  'collection',
  'payout',
  'refund',
  'fee',
  'transfer',
  'adjustment',
] as const;
export type StatementLineKind = (typeof STATEMENT_LINE_KINDS)[number];

export const EXCEPTION_KINDS = [
  'unmatched_reference',
  'amount_mismatch',
  'currency_mismatch',
  'status_mismatch',
  'missing_journal',
  'duplicate_reference',
  'unmatched_journal',
  'unsupported_line',
  'missing_in_statement',
] as const;
export type ExceptionKind = (typeof EXCEPTION_KINDS)[number];

export class ReconciliationError extends Error {
  readonly statusCode: number;
  readonly code: string;

  constructor(statusCode: number, code: string, message: string) {
    super(message);
    this.name = 'ReconciliationError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

function fail(statusCode: number, code: string, message: string): ReconciliationError {
  return new ReconciliationError(statusCode, code, message);
}

interface ParsedLine {
  lineNo: number;
  occurredAt: Date;
  reference: string | null;
  kind: StatementLineKind;
  amountMinor: string;
  currency: string;
  postingKey: string | null;
  description: string | null;
}

interface ParsedStatement {
  lines: ParsedLine[];
  periodStart: Date;
  periodEnd: Date;
}

/** Minimal RFC-4180-style parser: commas, quotes, escaped quotes and newlines. */
function parseRows(input: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;

  for (let index = 0; index < input.length; index += 1) {
    const character = input[index]!;
    if (quoted) {
      if (character === '"') {
        if (input[index + 1] === '"') {
          field += '"';
          index += 1;
        } else {
          quoted = false;
        }
      } else {
        field += character;
      }
      continue;
    }
    if (character === '"') {
      quoted = true;
    } else if (character === ',') {
      row.push(field);
      field = '';
    } else if (character === '\n') {
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else if (character !== '\r') {
      field += character;
    }
  }
  if (quoted) throw fail(422, 'STATEMENT_CSV_INVALID', 'The CSV has an unterminated quote');
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows.filter((values) => values.some((value) => value.trim().length > 0));
}

export function parseStatementCsv(csv: string, currency: string): ParsedStatement {
  if (!csv.trim()) {
    throw fail(422, 'STATEMENT_CSV_INVALID', 'Paste the statement CSV first');
  }
  const rows = parseRows(csv.replace(/^\uFEFF/, ''));
  if (rows.length < 2) {
    throw fail(422, 'STATEMENT_CSV_INVALID', 'The CSV needs a header and at least one line');
  }
  if (rows.length > 5_001) {
    throw fail(422, 'STATEMENT_CSV_TOO_LARGE', 'The CSV has more than 5,000 statement lines');
  }

  const header = rows[0]!.map((value) => value.trim().toLowerCase());
  const required = ['occurred_at', 'reference', 'kind', 'amount_minor', 'currency'];
  const missing = required.filter((name) => !header.includes(name));
  if (missing.length > 0) {
    throw fail(
      422,
      'STATEMENT_CSV_INVALID',
      `The CSV header is missing: ${missing.join(', ')}`,
    );
  }
  const column = (name: string): number => header.indexOf(name);
  const value = (row: string[], name: string): string => {
    const index = column(name);
    return index >= 0 ? (row[index] ?? '').trim() : '';
  };

  const lines: ParsedLine[] = [];
  let periodStart: Date | null = null;
  let periodEnd: Date | null = null;

  for (let index = 1; index < rows.length; index += 1) {
    const row = rows[index]!;
    const rowNo = index + 1;
    const occurredRaw = value(row, 'occurred_at');
    const occurredAt = new Date(occurredRaw);
    if (!occurredRaw || Number.isNaN(occurredAt.getTime())) {
      throw fail(422, 'STATEMENT_CSV_INVALID', `Row ${rowNo}: occurred_at is not a timestamp`);
    }

    const kind = value(row, 'kind') as StatementLineKind;
    if (!STATEMENT_LINE_KINDS.includes(kind)) {
      throw fail(422, 'STATEMENT_CSV_INVALID', `Row ${rowNo}: unknown kind "${kind}"`);
    }

    const amountRaw = value(row, 'amount_minor');
    if (!/^\d+$/.test(amountRaw) || BigInt(amountRaw) <= 0n) {
      throw fail(422, 'STATEMENT_CSV_INVALID', `Row ${rowNo}: amount_minor must be positive whole units`);
    }
    if (BigInt(amountRaw) > 9_223_372_036_854_775_807n) {
      throw fail(422, 'STATEMENT_CSV_INVALID', `Row ${rowNo}: amount_minor is too large`);
    }

    const lineCurrency = value(row, 'currency').toUpperCase();
    if (!/^[A-Z]{3}$/.test(lineCurrency)) {
      throw fail(422, 'STATEMENT_CSV_INVALID', `Row ${rowNo}: currency must be a 3-letter code`);
    }
    if (lineCurrency !== currency.toUpperCase()) {
      throw fail(
        422,
        'STATEMENT_CSV_INVALID',
        `Row ${rowNo}: currency ${lineCurrency} does not match statement currency ${currency}`,
      );
    }

    const reference = value(row, 'reference') || null;
    if (reference && reference.length > 120) {
      throw fail(422, 'STATEMENT_CSV_INVALID', `Row ${rowNo}: reference is too long`);
    }
    if (!reference && ['collection', 'payout', 'refund'].includes(kind)) {
      throw fail(
        422,
        'STATEMENT_CSV_INVALID',
        `Row ${rowNo}: ${kind} lines need a provider reference`,
      );
    }

    const postingKey = value(row, 'posting_key') || null;
    if (postingKey && postingKey.length > 200) {
      throw fail(422, 'STATEMENT_CSV_INVALID', `Row ${rowNo}: posting_key is too long`);
    }
    const description = value(row, 'description') || null;
    if (description && description.length > 300) {
      throw fail(422, 'STATEMENT_CSV_INVALID', `Row ${rowNo}: description is too long`);
    }

    lines.push({
      lineNo: rowNo,
      occurredAt,
      reference,
      kind,
      amountMinor: BigInt(amountRaw).toString(),
      currency: lineCurrency,
      postingKey,
      description,
    });
    if (!periodStart || occurredAt < periodStart) periodStart = occurredAt;
    if (!periodEnd || occurredAt > periodEnd) periodEnd = occurredAt;
  }

  if (lines.length === 0 || !periodStart || !periodEnd) {
    throw fail(422, 'STATEMENT_CSV_INVALID', 'The CSV has no statement lines');
  }
  return { lines, periodStart, periodEnd };
}

interface MatchResult {
  status: 'matched' | 'exception';
  matchedTable: 'payment_attempt' | 'payout' | 'refund' | 'journal' | null;
  matchedId: string | null;
  matchedJournalId: string | null;
  exceptionKind: ExceptionKind | null;
}

function exception(
  kind: ExceptionKind,
  matchedTable: MatchResult['matchedTable'] = null,
  matchedId: string | null = null,
  matchedJournalId: string | null = null,
): MatchResult {
  return {
    status: 'exception',
    matchedTable,
    matchedId,
    matchedJournalId,
    exceptionKind: kind,
  };
}

function matched(
  matchedTable: MatchResult['matchedTable'],
  matchedId: string,
  matchedJournalId: string,
): MatchResult {
  return {
    status: 'matched',
    matchedTable,
    matchedId,
    matchedJournalId,
    exceptionKind: null,
  };
}

async function journalForReference(
  client: PoolClient,
  query: string,
  values: unknown[],
): Promise<string | null> {
  const result = await client.query<{ id: string }>(query, values);
  return result.rows[0]?.id ?? null;
}

async function matchLine(
  client: PoolClient,
  input: {
    line: ParsedLine;
    sourceKind: StatementSourceKind;
    provider: string | null;
    duplicate: boolean;
  },
): Promise<MatchResult> {
  const { line, sourceKind, provider } = input;
  if (input.duplicate) return exception('duplicate_reference');

  if (line.postingKey) {
    const result = await client.query<{
      id: string;
      currency_code: string;
      debit_total: string;
    }>(
      `SELECT tx.id, tx.currency_code,
              COALESCE(sum(l.amount_minor) FILTER (WHERE l.amount_minor > 0), 0)::text
                AS debit_total
       FROM journal_transactions tx
       JOIN journal_lines l ON l.transaction_id = tx.id
       WHERE tx.posting_key = $1
       GROUP BY tx.id, tx.currency_code`,
      [line.postingKey],
    );
    const journal = result.rows[0];
    if (!journal) return exception('unmatched_journal');
    if (journal.currency_code !== line.currency) return exception('currency_mismatch', 'journal', journal.id, journal.id);
    if (journal.debit_total !== line.amountMinor) return exception('amount_mismatch', 'journal', journal.id, journal.id);
    return matched('journal', journal.id, journal.id);
  }

  if (sourceKind === 'bank') {
    return exception('unsupported_line');
  }
  if (!provider) return exception('unsupported_line');
  if (line.kind === 'fee' || line.kind === 'transfer' || line.kind === 'adjustment') {
    return exception('unsupported_line');
  }

  if (line.kind === 'collection') {
    const result = await client.query<{
      id: string;
      trade_id: string;
      amount_minor: string;
      currency_code: string;
      status: string;
    }>(
      `SELECT id, trade_id, amount_minor::text, currency_code, status
       FROM payment_attempts
       WHERE provider = $1 AND external_reference = $2`,
      [provider, line.reference],
    );
    const attempt = result.rows[0];
    if (!attempt) return exception('unmatched_reference');
    if (attempt.currency_code !== line.currency) {
      return exception('currency_mismatch', 'payment_attempt', attempt.id);
    }
    if (attempt.amount_minor !== line.amountMinor) {
      return exception('amount_mismatch', 'payment_attempt', attempt.id);
    }
    if (attempt.status !== 'confirmed') {
      return exception('status_mismatch', 'payment_attempt', attempt.id);
    }
    const journalId = await journalForReference(
      client,
      `SELECT id FROM journal_transactions
       WHERE trade_id = $1 AND currency_code = $2 AND kind = 'deposit_received'
       ORDER BY created_at LIMIT 1`,
      [attempt.trade_id, line.currency],
    );
    if (!journalId) return exception('missing_journal', 'payment_attempt', attempt.id);
    return matched('payment_attempt', attempt.id, journalId);
  }

  if (line.kind === 'payout') {
    const result = await client.query<{
      id: string;
      amount_minor: string;
      currency_code: string;
      status: string;
    }>(
      `SELECT id, amount_minor::text, currency_code, status
       FROM payouts WHERE provider = $1 AND provider_reference = $2`,
      [provider, line.reference],
    );
    const payout = result.rows[0];
    if (!payout) return exception('unmatched_reference');
    if (payout.currency_code !== line.currency) {
      return exception('currency_mismatch', 'payout', payout.id);
    }
    if (payout.amount_minor !== line.amountMinor) {
      return exception('amount_mismatch', 'payout', payout.id);
    }
    if (payout.status !== 'paid') {
      return exception('status_mismatch', 'payout', payout.id);
    }
    const journalId = await journalForReference(
      client,
      `SELECT id FROM journal_transactions
       WHERE payout_id = $1 AND currency_code = $2 AND kind = 'payout_sent'
       ORDER BY created_at LIMIT 1`,
      [payout.id, line.currency],
    );
    if (!journalId) return exception('missing_journal', 'payout', payout.id);
    return matched('payout', payout.id, journalId);
  }

  const result = await client.query<{
    id: string;
    amount_minor: string;
    currency_code: string;
    status: string;
  }>(
    `SELECT id, amount_minor::text, currency_code, status
     FROM refunds WHERE provider = $1 AND provider_reference = $2`,
    [provider, line.reference],
  );
  const refund = result.rows[0];
  if (!refund) return exception('unmatched_reference');
  if (refund.currency_code !== line.currency) {
    return exception('currency_mismatch', 'refund', refund.id);
  }
  if (refund.amount_minor !== line.amountMinor) {
    return exception('amount_mismatch', 'refund', refund.id);
  }
  if (refund.status !== 'paid') {
    return exception('status_mismatch', 'refund', refund.id);
  }
  const journalId = await journalForReference(
    client,
    `SELECT id FROM journal_transactions
     WHERE refund_id = $1 AND currency_code = $2 AND kind = 'refund_paid'
     ORDER BY created_at LIMIT 1`,
    [refund.id, line.currency],
  );
  if (!journalId) return exception('missing_journal', 'refund', refund.id);
  return matched('refund', refund.id, journalId);
}

export interface ImportStatementInput {
  csv: string;
  fileName: string;
  sourceKind: string;
  sourceLabel: string;
  currency: string;
  adminId: string;
}

export interface ImportedStatement {
  id: string;
  lineCount: number;
  matchedCount: number;
  exceptionCount: number;
  missingCount: number;
}

interface MissingInternalRow {
  table: 'payment_attempt' | 'payout' | 'refund';
  id: string;
  reference: string;
  amountMinor: string;
  currency: string;
}

async function findMissingInternalRows(
  client: PoolClient,
  input: {
    provider: string | null;
    currency: string;
    periodStart: Date;
    periodEnd: Date;
    lines: ParsedLine[];
  },
): Promise<MissingInternalRow[]> {
  if (!input.provider) return [];
  const references = {
    collection: new Set<string>(),
    payout: new Set<string>(),
    refund: new Set<string>(),
  };
  for (const line of input.lines) {
    if (!line.reference) continue;
    if (line.kind === 'collection') references.collection.add(line.reference);
    if (line.kind === 'payout') references.payout.add(line.reference);
    if (line.kind === 'refund') references.refund.add(line.reference);
  }

  const missing: MissingInternalRow[] = [];
  const attempts = await client.query<{
    id: string;
    reference: string;
    amount_minor: string;
  }>(
    `SELECT id, external_reference AS reference, amount_minor::text
     FROM payment_attempts
     WHERE provider = $1 AND currency_code = $2 AND status = 'confirmed'
       AND external_reference IS NOT NULL
       AND created_at >= $3 AND created_at <= $4`,
    [input.provider, input.currency, input.periodStart, input.periodEnd],
  );
  for (const row of attempts.rows) {
    if (references.collection.has(row.reference)) continue;
    missing.push({
      table: 'payment_attempt',
      id: row.id,
      reference: row.reference,
      amountMinor: row.amount_minor,
      currency: input.currency,
    });
  }

  const payouts = await client.query<{
    id: string;
    reference: string;
    amount_minor: string;
  }>(
    `SELECT id, provider_reference AS reference, amount_minor::text
     FROM payouts
     WHERE provider = $1 AND currency_code = $2 AND status = 'paid'
       AND provider_reference IS NOT NULL
       AND completed_at >= $3 AND completed_at <= $4`,
    [input.provider, input.currency, input.periodStart, input.periodEnd],
  );
  for (const row of payouts.rows) {
    if (references.payout.has(row.reference)) continue;
    missing.push({
      table: 'payout',
      id: row.id,
      reference: row.reference,
      amountMinor: row.amount_minor,
      currency: input.currency,
    });
  }

  const refunds = await client.query<{
    id: string;
    reference: string;
    amount_minor: string;
  }>(
    `SELECT id, provider_reference AS reference, amount_minor::text
     FROM refunds
     WHERE provider = $1 AND currency_code = $2 AND status = 'paid'
       AND provider_reference IS NOT NULL
       AND completed_at >= $3 AND completed_at <= $4`,
    [input.provider, input.currency, input.periodStart, input.periodEnd],
  );
  for (const row of refunds.rows) {
    if (references.refund.has(row.reference)) continue;
    missing.push({
      table: 'refund',
      id: row.id,
      reference: row.reference,
      amountMinor: row.amount_minor,
      currency: input.currency,
    });
  }

  return missing;
}

export async function importStatement(
  ctx: AppContext,
  input: ImportStatementInput,
): Promise<ImportedStatement> {
  const sourceKind = input.sourceKind as StatementSourceKind;
  if (!STATEMENT_SOURCE_KINDS.includes(sourceKind)) {
    throw fail(422, 'STATEMENT_SOURCE_INVALID', 'Choose provider or bank');
  }
  const sourceLabel = input.sourceLabel.trim();
  if (sourceLabel.length < 1 || sourceLabel.length > 80) {
    throw fail(422, 'STATEMENT_SOURCE_INVALID', 'Source label must be 1-80 characters');
  }
  const currency = input.currency.trim().toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) {
    throw fail(422, 'STATEMENT_CURRENCY_INVALID', 'Choose a statement currency');
  }
  const fileName = (input.fileName.trim() || 'manual-import.csv').slice(0, 200);
  const provider = sourceKind === 'provider' ? sourceLabel.toLowerCase() : null;
  if (provider && !/^[a-z][a-z0-9_]{1,63}$/.test(provider)) {
    throw fail(
      422,
      'STATEMENT_SOURCE_INVALID',
      'Provider source must be the lowercase provider id, for example mpesa_tz',
    );
  }

  const currencyRow = await ctx.pool.query(
    `SELECT 1 FROM currencies WHERE code = $1 AND active`,
    [currency],
  );
  if (!currencyRow.rowCount) {
    throw fail(422, 'STATEMENT_CURRENCY_INVALID', 'That currency is not active');
  }

  const parsed = parseStatementCsv(input.csv, currency);
  const fileSha256 = createHash('sha256')
    .update(`${sourceKind}\n${sourceLabel}\n${currency}\n${input.csv}`, 'utf8')
    .digest('hex');

  try {
    return await withTransaction(ctx.pool, async (client) => {
      const seen = new Set<string>();
      const matches: MatchResult[] = [];
      for (const line of parsed.lines) {
        const key = line.reference ? `${line.kind}:${line.reference}` : '';
        const duplicate = key.length > 0 && seen.has(key);
        if (key) seen.add(key);
        matches.push(
          await matchLine(client, { line, sourceKind, provider, duplicate }),
        );
      }

      const matchedCount = matches.filter((match) => match.status === 'matched').length;
      const exceptionCount = matches.length - matchedCount;
      const missing = await findMissingInternalRows(client, {
        provider,
        currency,
        periodStart: parsed.periodStart,
        periodEnd: parsed.periodEnd,
        lines: parsed.lines,
      });
      const statement = await client.query<{ id: string }>(
        `INSERT INTO settlement_statements
           (source_kind, source_label, provider, currency_code, period_start, period_end,
            file_name, file_sha256, line_count, matched_count, exception_count,
            missing_count, imported_by_admin_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
         RETURNING id`,
        [
          sourceKind,
          sourceLabel,
          provider,
          currency,
          parsed.periodStart,
          parsed.periodEnd,
          fileName,
          fileSha256,
          parsed.lines.length,
          matchedCount,
          exceptionCount,
          missing.length,
          input.adminId,
        ],
      );
      const statementId = statement.rows[0]!.id;

      for (let index = 0; index < parsed.lines.length; index += 1) {
        const line = parsed.lines[index]!;
        const match = matches[index]!;
        const inserted = await client.query<{ id: string }>(
          `INSERT INTO settlement_lines
             (statement_id, line_no, occurred_at, reference, kind, amount_minor,
              currency_code, posting_key, description, status, matched_table,
              matched_id, matched_journal_id)
           VALUES ($1, $2, $3, $4, $5, $6::bigint, $7, $8, $9, $10, $11, $12, $13)
           RETURNING id`,
          [
            statementId,
            line.lineNo,
            line.occurredAt,
            line.reference,
            line.kind,
            line.amountMinor,
            line.currency,
            line.postingKey,
            line.description,
            match.status,
            match.matchedTable,
            match.matchedId,
            match.matchedJournalId,
          ],
        );
        if (match.exceptionKind) {
          await client.query(
            `INSERT INTO reconciliation_exceptions
               (statement_id, line_id, kind, reference, amount_minor, currency_code)
             VALUES ($1, $2, $3, $4, $5::bigint, $6)`,
            [
              statementId,
              inserted.rows[0]!.id,
              match.exceptionKind,
              line.reference,
              line.amountMinor,
              line.currency,
            ],
          );
        }
      }

      for (const row of missing) {
        await client.query(
          `INSERT INTO reconciliation_exceptions
             (statement_id, line_id, internal_table, internal_id, kind, reference,
              amount_minor, currency_code)
           VALUES ($1, NULL, $2, $3, 'missing_in_statement', $4, $5::bigint, $6)`,
          [
            statementId,
            row.table,
            row.id,
            row.reference,
            row.amountMinor,
            row.currency,
          ],
        );
      }

      return {
        id: statementId,
        lineCount: parsed.lines.length,
        matchedCount,
        exceptionCount,
        missingCount: missing.length,
      };
    });
  } catch (error) {
    if ((error as { code?: string }).code === '23505') {
      throw fail(
        409,
        'STATEMENT_DUPLICATE',
        'That statement file was already imported for this source and currency',
      );
    }
    throw error;
  }
}

export interface StatementListItem {
  id: string;
  sourceKind: StatementSourceKind;
  sourceLabel: string;
  provider: string | null;
  currency: string;
  periodStart: string;
  periodEnd: string;
  fileName: string;
  lineCount: number;
  matchedCount: number;
  exceptionCount: number;
  missingCount: number;
  openExceptions: number;
  status: 'imported' | 'closed';
  importedBy: string | null;
  createdAt: string;
  closedAt: string | null;
}

export async function loadReconciliationCenter(pool: Pool) {
  const [statements, summary] = await Promise.all([
    pool.query<{
      id: string;
      source_kind: StatementSourceKind;
      source_label: string;
      provider: string | null;
      currency_code: string;
      period_start: Date;
      period_end: Date;
      file_name: string;
      line_count: number;
      matched_count: number;
      exception_count: number;
      missing_count: number;
      open_exceptions: number;
      status: 'imported' | 'closed';
      imported_by: string | null;
      created_at: Date;
      closed_at: Date | null;
    }>(
      `SELECT s.id, s.source_kind, s.source_label, s.provider, s.currency_code,
              s.period_start, s.period_end, s.file_name, s.line_count,
              s.matched_count, s.exception_count,
              s.missing_count,
              (SELECT count(*)::int FROM reconciliation_exceptions e
               WHERE e.statement_id = s.id AND e.status = 'open') AS open_exceptions,
              s.status, importer.name AS imported_by, s.created_at, s.closed_at
       FROM settlement_statements s
       LEFT JOIN admin_users importer ON importer.id = s.imported_by_admin_id
       ORDER BY s.created_at DESC, s.id DESC
       LIMIT 50`,
    ),
    pool.query<{
      open_statements: number;
      closed_statements: number;
      open_exceptions: number;
      total_exceptions: number;
      missing_total: number;
    }>(
      `SELECT
         (SELECT count(*)::int FROM settlement_statements WHERE status = 'imported') AS open_statements,
         (SELECT count(*)::int FROM settlement_statements WHERE status = 'closed') AS closed_statements,
         (SELECT count(*)::int FROM reconciliation_exceptions WHERE status = 'open') AS open_exceptions,
         (SELECT count(*)::int FROM reconciliation_exceptions) AS total_exceptions,
         (SELECT count(*)::int FROM reconciliation_exceptions
          WHERE kind = 'missing_in_statement') AS missing_total`,
    ),
  ]);

  return {
    statements: statements.rows.map((row) => ({
      id: row.id,
      sourceKind: row.source_kind,
      sourceLabel: row.source_label,
      provider: row.provider,
      currency: row.currency_code,
      periodStart: new Date(row.period_start).toISOString(),
      periodEnd: new Date(row.period_end).toISOString(),
      fileName: row.file_name,
      lineCount: row.line_count,
      matchedCount: row.matched_count,
      exceptionCount: row.exception_count,
      missingCount: row.missing_count,
      openExceptions: row.open_exceptions,
      status: row.status,
      importedBy: row.imported_by,
      createdAt: new Date(row.created_at).toISOString(),
      closedAt: row.closed_at ? new Date(row.closed_at).toISOString() : null,
    })) satisfies StatementListItem[],
    summary: {
      openStatements: Number(summary.rows[0]?.open_statements ?? 0),
      closedStatements: Number(summary.rows[0]?.closed_statements ?? 0),
      openExceptions: Number(summary.rows[0]?.open_exceptions ?? 0),
      totalExceptions: Number(summary.rows[0]?.total_exceptions ?? 0),
      missingTotal: Number(summary.rows[0]?.missing_total ?? 0),
    },
    currencies: (
      await pool.query<{ code: string; name: string }>(
        `SELECT code, name FROM currencies WHERE active ORDER BY sort_order, code`,
      )
    ).rows,
  };
}

export interface StatementLineView {
  id: string;
  lineNo: number;
  occurredAt: string;
  reference: string | null;
  kind: string;
  amountMinor: string;
  currency: string;
  postingKey: string | null;
  description: string | null;
  status: 'matched' | 'exception';
  matchedTable: string | null;
  matchedId: string | null;
  matchedJournalId: string | null;
  matchedJournalPostingKey: string | null;
  exception: {
    id: string;
    kind: ExceptionKind;
    status: 'open' | 'resolved';
    note: string | null;
    resolvedAt: string | null;
    resolvedBy: string | null;
  } | null;
}

export async function loadStatement(pool: Pool, id: string) {
  const statement = await pool.query<{
    id: string;
    source_kind: StatementSourceKind;
    source_label: string;
    provider: string | null;
    currency_code: string;
    period_start: Date;
    period_end: Date;
    file_name: string;
    line_count: number;
    matched_count: number;
    exception_count: number;
    missing_count: number;
    open_exceptions: number;
    status: 'imported' | 'closed';
    imported_by: string | null;
    closed_by: string | null;
    created_at: Date;
    closed_at: Date | null;
  }>(
    `SELECT s.id, s.source_kind, s.source_label, s.provider, s.currency_code,
            s.period_start, s.period_end, s.file_name, s.line_count,
            s.matched_count, s.exception_count,
            s.missing_count,
            (SELECT count(*)::int FROM reconciliation_exceptions e
             WHERE e.statement_id = s.id AND e.status = 'open') AS open_exceptions,
            s.status, importer.name AS imported_by, closer.name AS closed_by,
            s.created_at, s.closed_at
     FROM settlement_statements s
     LEFT JOIN admin_users importer ON importer.id = s.imported_by_admin_id
     LEFT JOIN admin_users closer ON closer.id = s.closed_by_admin_id
     WHERE s.id = $1`,
    [id],
  );
  const header = statement.rows[0];
  if (!header) return null;

  const lines = await pool.query<{
    id: string;
    line_no: number;
    occurred_at: Date;
    reference: string | null;
    kind: string;
    amount_minor: string;
    currency_code: string;
    posting_key: string | null;
    description: string | null;
    status: 'matched' | 'exception';
    matched_table: string | null;
    matched_id: string | null;
    matched_journal_id: string | null;
    journal_posting_key: string | null;
    exception_id: string | null;
    exception_kind: ExceptionKind | null;
    exception_status: 'open' | 'resolved' | null;
    exception_note: string | null;
    exception_resolved_at: Date | null;
    exception_resolved_by: string | null;
  }>(
    `SELECT l.id, l.line_no, l.occurred_at, l.reference, l.kind,
            l.amount_minor::text, l.currency_code, l.posting_key, l.description,
            l.status, l.matched_table, l.matched_id, l.matched_journal_id,
            j.posting_key AS journal_posting_key,
            e.id AS exception_id, e.kind AS exception_kind,
            e.status AS exception_status, e.note AS exception_note,
            e.resolved_at AS exception_resolved_at, resolver.name AS exception_resolved_by
     FROM settlement_lines l
     LEFT JOIN journal_transactions j ON j.id = l.matched_journal_id
     LEFT JOIN reconciliation_exceptions e ON e.line_id = l.id
     LEFT JOIN admin_users resolver ON resolver.id = e.resolved_by_admin_id
     WHERE l.statement_id = $1
     ORDER BY l.line_no`,
    [id],
  );

  const missing = await pool.query<{
    id: string;
    kind: ExceptionKind;
    internal_table: string;
    internal_id: string;
    reference: string;
    amount_minor: string;
    currency_code: string;
    status: 'open' | 'resolved';
    note: string | null;
    resolved_at: Date | null;
    resolved_by: string | null;
    created_at: Date;
  }>(
    `SELECT e.id, e.kind, e.internal_table, e.internal_id, e.reference,
            e.amount_minor::text, e.currency_code, e.status, e.note,
            e.resolved_at, resolver.name AS resolved_by, e.created_at
     FROM reconciliation_exceptions e
     LEFT JOIN admin_users resolver ON resolver.id = e.resolved_by_admin_id
     WHERE e.statement_id = $1 AND e.kind = 'missing_in_statement'
     ORDER BY e.created_at, e.id`,
    [id],
  );

  return {
    statement: {
      id: header.id,
      sourceKind: header.source_kind,
      sourceLabel: header.source_label,
      provider: header.provider,
      currency: header.currency_code,
      periodStart: new Date(header.period_start).toISOString(),
      periodEnd: new Date(header.period_end).toISOString(),
      fileName: header.file_name,
      lineCount: header.line_count,
      matchedCount: header.matched_count,
      exceptionCount: header.exception_count,
      missingCount: header.missing_count,
      openExceptions: header.open_exceptions,
      status: header.status,
      importedBy: header.imported_by,
      closedBy: header.closed_by,
      createdAt: new Date(header.created_at).toISOString(),
      closedAt: header.closed_at ? new Date(header.closed_at).toISOString() : null,
    },
    lines: lines.rows.map((row) => ({
      id: row.id,
      lineNo: row.line_no,
      occurredAt: new Date(row.occurred_at).toISOString(),
      reference: row.reference,
      kind: row.kind,
      amountMinor: row.amount_minor,
      currency: row.currency_code,
      postingKey: row.posting_key,
      description: row.description,
      status: row.status,
      matchedTable: row.matched_table,
      matchedId: row.matched_id,
      matchedJournalId: row.matched_journal_id,
      matchedJournalPostingKey: row.journal_posting_key,
      exception: row.exception_id
        ? {
            id: row.exception_id,
            kind: row.exception_kind!,
            status: row.exception_status!,
            note: row.exception_note,
            resolvedAt: row.exception_resolved_at
              ? new Date(row.exception_resolved_at).toISOString()
              : null,
            resolvedBy: row.exception_resolved_by,
          }
        : null,
    })) satisfies StatementLineView[],
    missing: missing.rows.map((row) => ({
      id: row.id,
      kind: row.kind,
      internalTable: row.internal_table,
      internalId: row.internal_id,
      reference: row.reference,
      amountMinor: row.amount_minor,
      currency: row.currency_code,
      status: row.status,
      note: row.note,
      resolvedAt: row.resolved_at ? new Date(row.resolved_at).toISOString() : null,
      resolvedBy: row.resolved_by,
      createdAt: new Date(row.created_at).toISOString(),
    })),
  };
}

export async function resolveException(
  ctx: AppContext,
  input: { id: string; note: string; adminId: string },
): Promise<{ statementId: string; note: string }> {
  const note = input.note.trim();
  if (note.length < 5 || note.length > 300) {
    throw fail(422, 'EXCEPTION_NOTE_INVALID', 'A resolution note of 5-300 characters is required');
  }

  return withTransaction(ctx.pool, async (client) => {
    const current = await client.query<{
      id: string;
      statement_id: string;
      status: 'open' | 'resolved';
    }>(
      `SELECT id, statement_id, status FROM reconciliation_exceptions
       WHERE id = $1 FOR UPDATE`,
      [input.id],
    );
    const row = current.rows[0];
    if (!row) throw fail(404, 'EXCEPTION_NOT_FOUND', 'Reconciliation exception not found');
    if (row.status !== 'open') {
      throw fail(409, 'EXCEPTION_ALREADY_RESOLVED', 'This exception is already resolved');
    }
    await client.query(
      `UPDATE reconciliation_exceptions
       SET status = 'resolved', note = $2, resolved_by_admin_id = $3, resolved_at = now()
       WHERE id = $1`,
      [input.id, note, input.adminId],
    );
    return { statementId: row.statement_id, note };
  });
}

export async function closeStatement(
  ctx: AppContext,
  input: { id: string; adminId: string },
): Promise<{ lineCount: number; exceptionCount: number }> {
  return withTransaction(ctx.pool, async (client) => {
    const current = await client.query<{
      id: string;
      status: 'imported' | 'closed';
      line_count: number;
      exception_count: number;
    }>(
      `SELECT id, status, line_count, exception_count
       FROM settlement_statements WHERE id = $1 FOR UPDATE`,
      [input.id],
    );
    const row = current.rows[0];
    if (!row) throw fail(404, 'STATEMENT_NOT_FOUND', 'Statement not found');
    if (row.status === 'closed') {
      throw fail(409, 'STATEMENT_ALREADY_CLOSED', 'This statement is already closed');
    }
    const open = await client.query<{ count: number }>(
      `SELECT count(*)::int AS count FROM reconciliation_exceptions
       WHERE statement_id = $1 AND status = 'open'`,
      [input.id],
    );
    if (Number(open.rows[0]?.count ?? 0) > 0) {
      throw fail(
        409,
        'RECONCILIATION_OPEN_EXCEPTIONS',
        'Resolve every open exception before closing the statement',
      );
    }
    if (row.line_count === 0) {
      throw fail(422, 'STATEMENT_EMPTY', 'An empty statement cannot be closed');
    }
    await client.query(
      `UPDATE settlement_statements
       SET status = 'closed', closed_by_admin_id = $2, closed_at = now()
       WHERE id = $1`,
      [input.id, input.adminId],
    );
    return { lineCount: row.line_count, exceptionCount: row.exception_count };
  });
}
