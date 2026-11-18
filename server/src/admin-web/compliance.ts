import type { Pool } from 'pg';
import { withTransaction } from '../db/pool.js';
import type { AppContext } from '../http/context.js';

export const KYC_REJECTION_CODES = [
  'ID_UNREADABLE',
  'NAME_MISMATCH',
  'DOCUMENT_EXPIRED',
  'DUPLICATE_IDENTITY',
  'SANCTIONS_MATCH',
  'OTHER',
] as const;
export type KycRejectionCode = (typeof KYC_REJECTION_CODES)[number];

export const KYC_STATUSES = ['pending', 'verified', 'rejected'] as const;
export type KycStatus = (typeof KYC_STATUSES)[number];

export class ComplianceError extends Error {
  readonly statusCode: number;
  readonly code: string;

  constructor(statusCode: number, code: string, message: string) {
    super(message);
    this.name = 'ComplianceError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

function fail(statusCode: number, code: string, message: string): ComplianceError {
  return new ComplianceError(statusCode, code, message);
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

export interface KycQueueItem {
  id: string;
  userId: string;
  customerName: string | null;
  phoneLast4: string;
  accountType: string;
  legalName: string;
  hubId: string | null;
  idType: string;
  idLast4: string;
  status: KycStatus;
  submittedAt: string;
  reviewedAt: string | null;
  reviewedBy: string | null;
  rejectionCode: string | null;
}

export async function loadKycQueue(
  pool: Pool,
  statusFilter = 'pending',
): Promise<{
  items: KycQueueItem[];
  counts: { pending: number; verified: number; rejected: number };
}> {
  const status = KYC_STATUSES.includes(statusFilter as KycStatus)
    ? statusFilter
    : 'pending';
  const [items, counts] = await Promise.all([
    pool.query<{
      id: string;
      user_id: string;
      display_name: string | null;
      phone_last4: string;
      account_type: string;
      legal_name: string;
      hub_id: string | null;
      id_type: string;
      id_last4: string;
      status: KycStatus;
      submitted_at: Date;
      reviewed_at: Date | null;
      reviewed_by: string | null;
      rejection_code: string | null;
    }>(
      `SELECT k.id, k.user_id, u.display_name, right(u.phone, 4) AS phone_last4,
              k.account_type, k.legal_name, k.hub_id, k.id_type, k.id_last4,
              k.status, k.submitted_at, k.reviewed_at,
              reviewer.name AS reviewed_by, k.rejection_code
       FROM kyc_verifications k
       JOIN users u ON u.id = k.user_id
       LEFT JOIN admin_users reviewer ON reviewer.id = k.reviewed_by_admin_id
       WHERE k.status = $1
       ORDER BY k.submitted_at ASC, k.id ASC
       LIMIT 100`,
      [status],
    ),
    pool.query<{ pending: number; verified: number; rejected: number }>(
      `SELECT count(*) FILTER (WHERE status = 'pending')::int AS pending,
              count(*) FILTER (WHERE status = 'verified')::int AS verified,
              count(*) FILTER (WHERE status = 'rejected')::int AS rejected
       FROM kyc_verifications`,
    ),
  ]);

  return {
    items: items.rows.map((row) => ({
      id: row.id,
      userId: row.user_id,
      customerName: row.display_name,
      phoneLast4: row.phone_last4,
      accountType: row.account_type,
      legalName: row.legal_name,
      hubId: row.hub_id,
      idType: row.id_type,
      idLast4: row.id_last4,
      status: row.status,
      submittedAt: new Date(row.submitted_at).toISOString(),
      reviewedAt: row.reviewed_at ? new Date(row.reviewed_at).toISOString() : null,
      reviewedBy: row.reviewed_by,
      rejectionCode: row.rejection_code,
    })),
    counts: {
      pending: Number(counts.rows[0]?.pending ?? 0),
      verified: Number(counts.rows[0]?.verified ?? 0),
      rejected: Number(counts.rows[0]?.rejected ?? 0),
    },
  };
}

export async function loadKycVerification(pool: Pool, id: string) {
  const result = await pool.query<{
    id: string;
    user_id: string;
    display_name: string | null;
    phone_last4: string;
    account_type: string;
    legal_name: string;
    hub_id: string | null;
    hub_name: string | null;
    id_type: string;
    id_last4: string;
    status: KycStatus;
    rejection_code: string | null;
    submitted_at: Date;
    verified_at: Date | null;
    reviewed_at: Date | null;
    reviewed_by: string | null;
    review_note: string | null;
  }>(
    `SELECT k.id, k.user_id, u.display_name, right(u.phone, 4) AS phone_last4,
            k.account_type, k.legal_name, k.hub_id, h.name AS hub_name,
            k.id_type, k.id_last4, k.status, k.rejection_code,
            k.submitted_at, k.verified_at, k.reviewed_at,
            reviewer.name AS reviewed_by, k.review_note
     FROM kyc_verifications k
     JOIN users u ON u.id = k.user_id
     LEFT JOIN hubs h ON h.id = k.hub_id
     LEFT JOIN admin_users reviewer ON reviewer.id = k.reviewed_by_admin_id
     WHERE k.id = $1`,
    [id],
  );
  const row = result.rows[0];
  if (!row) return null;

  const history = await pool.query<{
    id: string;
    status: KycStatus;
    id_type: string;
    id_last4: string;
    submitted_at: Date;
    reviewed_at: Date | null;
    reviewed_by: string | null;
    rejection_code: string | null;
  }>(
    `SELECT k.id, k.status, k.id_type, k.id_last4, k.submitted_at,
            k.reviewed_at, reviewer.name AS reviewed_by, k.rejection_code
     FROM kyc_verifications k
     LEFT JOIN admin_users reviewer ON reviewer.id = k.reviewed_by_admin_id
     WHERE k.user_id = $1
     ORDER BY k.submitted_at DESC, k.id DESC
     LIMIT 20`,
    [row.user_id],
  );

  return {
    verification: {
      id: row.id,
      userId: row.user_id,
      customerName: row.display_name,
      phoneLast4: row.phone_last4,
      accountType: row.account_type,
      legalName: row.legal_name,
      hubId: row.hub_id,
      hubName: row.hub_name,
      idType: row.id_type,
      idLast4: row.id_last4,
      status: row.status,
      rejectionCode: row.rejection_code,
      submittedAt: new Date(row.submitted_at).toISOString(),
      verifiedAt: row.verified_at ? new Date(row.verified_at).toISOString() : null,
      reviewedAt: row.reviewed_at ? new Date(row.reviewed_at).toISOString() : null,
      reviewedBy: row.reviewed_by,
      reviewNote: row.review_note,
    },
    history: history.rows.map((item) => ({
      id: item.id,
      status: item.status,
      idType: item.id_type,
      idLast4: item.id_last4,
      submittedAt: new Date(item.submitted_at).toISOString(),
      reviewedAt: item.reviewed_at ? new Date(item.reviewed_at).toISOString() : null,
      reviewedBy: item.reviewed_by,
      rejectionCode: item.rejection_code,
    })),
  };
}

export async function reviewKyc(
  ctx: AppContext,
  input: {
    id: string;
    adminId: string;
    decision: 'approve' | 'reject';
    rejectionCode?: string;
    note?: string;
  },
): Promise<{
  before: { status: KycStatus; rejectionCode: string | null };
  after: { status: KycStatus; rejectionCode: string | null };
  userId: string;
}> {
  const note = text(input.note);
  if (note.length > 300) {
    throw fail(422, 'KYC_NOTE_INVALID', 'The review note is too long');
  }
  if (input.decision === 'reject') {
    if (note.length < 5) {
      throw fail(422, 'KYC_NOTE_REQUIRED', 'A rejection note of 5-300 characters is required');
    }
    if (!KYC_REJECTION_CODES.includes(input.rejectionCode as KycRejectionCode)) {
      throw fail(422, 'KYC_REJECTION_CODE_INVALID', 'Choose a rejection code');
    }
  }

  return withTransaction(ctx.pool, async (client) => {
    const current = await client.query<{
      id: string;
      user_id: string;
      status: KycStatus;
      rejection_code: string | null;
    }>(
      `SELECT id, user_id, status, rejection_code
       FROM kyc_verifications WHERE id = $1 FOR UPDATE`,
      [input.id],
    );
    const verification = current.rows[0];
    if (!verification) throw fail(404, 'KYC_NOT_FOUND', 'KYC verification not found');
    if (verification.status !== 'pending') {
      throw fail(409, 'KYC_ALREADY_DECIDED', 'This KYC verification is already decided');
    }

    const user = await client.query<{ kyc_status: string }>(
      `SELECT kyc_status FROM users WHERE id = $1 FOR UPDATE`,
      [verification.user_id],
    );
    if (!user.rows[0]) throw fail(404, 'KYC_USER_NOT_FOUND', 'Customer not found');
    if (user.rows[0].kyc_status !== 'pending') {
      throw fail(
        409,
        'KYC_USER_STATE_MISMATCH',
        'The customer account is not in a pending KYC state',
      );
    }

    const approved = input.decision === 'approve';
    const rejectionCode = approved ? null : input.rejectionCode!.toUpperCase();
    const status: KycStatus = approved ? 'verified' : 'rejected';

    await client.query(
      `UPDATE kyc_verifications
       SET status = $2,
           verified_at = CASE WHEN $2 = 'verified' THEN now() ELSE NULL END,
           rejection_code = $3,
           reviewed_by_admin_id = $4,
           reviewed_at = now(),
           review_note = $5
       WHERE id = $1`,
      [input.id, status, rejectionCode, input.adminId, note || null],
    );
    await client.query(
      `UPDATE users SET kyc_status = $2 WHERE id = $1`,
      [verification.user_id, status],
    );

    return {
      before: {
        status: verification.status,
        rejectionCode: verification.rejection_code,
      },
      after: { status, rejectionCode },
      userId: verification.user_id,
    };
  });
}
