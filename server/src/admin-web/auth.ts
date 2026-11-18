import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import type { Pool } from 'pg';
import argon2 from 'argon2';
import { TOTP, Secret } from 'otpauth';
import type { CryptoBox } from '../crypto.js';

export const ADMIN_SESSION_COOKIE = 'cp_admin_session';
export const ADMIN_CHALLENGE_COOKIE = 'cp_admin_challenge';

export type AdminRole = 'viewer' | 'ops' | 'finance' | 'compliance' | 'superadmin';

export type AdminPermission =
  | 'view'
  | 'ops:match'
  | 'corridor:write'
  | 'liquidity:write'
  | 'refund:write'
  | 'admin:users'
  | 'audit:read'
  | 'ledger:read'
  | 'support:read'
  | 'support:write'
  | 'pii:reveal'
  | 'config:read'
  | 'config:propose'
  | 'config:approve'
  | 'config:control'
  | 'reconciliation:read'
  | 'reconciliation:import'
  | 'reconciliation:resolve'
  | 'reconciliation:close'
  | 'kyc:read'
  | 'kyc:review';

const PERMISSIONS: Record<AdminPermission, AdminRole[]> = {
  view: ['viewer', 'ops', 'finance', 'compliance', 'superadmin'],
  'ops:match': ['ops', 'superadmin'],
  'corridor:write': ['ops', 'superadmin'],
  'liquidity:write': ['finance', 'superadmin'],
  'refund:write': ['ops', 'finance', 'superadmin'],
  'admin:users': ['superadmin'],
  'audit:read': ['compliance', 'superadmin'],
  'ledger:read': ['finance', 'compliance', 'superadmin'],
  'support:read': ['ops', 'compliance', 'superadmin'],
  'support:write': ['ops', 'compliance', 'superadmin'],
  'pii:reveal': ['compliance', 'superadmin'],
  'config:read': ['ops', 'finance', 'superadmin'],
  'config:propose': ['ops', 'finance', 'superadmin'],
  'config:approve': ['finance', 'superadmin'],
  'config:control': ['superadmin'],
  'reconciliation:read': ['finance', 'compliance', 'superadmin'],
  'reconciliation:import': ['finance', 'superadmin'],
  'reconciliation:resolve': ['finance', 'superadmin'],
  'reconciliation:close': ['finance', 'superadmin'],
  'kyc:read': ['compliance', 'superadmin'],
  'kyc:review': ['compliance', 'superadmin'],
};

export interface AdminSession {
  sessionId: string;
  csrfToken: string;
  user: {
    id: string;
    email: string;
    name: string;
    status: 'active' | 'suspended';
    roles: AdminRole[];
  };
  expiresAt: Date;
}

export function hasPermission(roles: AdminRole[], permission: AdminPermission): boolean {
  return roles.some((role) => PERMISSIONS[permission].includes(role));
}

export function requirePermission(roles: AdminRole[], permission: AdminPermission): void {
  if (!hasPermission(roles, permission)) {
    const error = new Error('This account does not have permission for that action') as Error & {
      statusCode: number;
      code: string;
    };
    error.statusCode = 403;
    error.code = 'ADMIN_FORBIDDEN';
    throw error;
  }
}

export function hashToken(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

export function randomToken(bytes = 32): string {
  return randomBytes(bytes).toString('base64url');
}

export function safeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left, 'utf8');
  const b = Buffer.from(right, 'utf8');
  return a.length === b.length && timingSafeEqual(a, b);
}

export async function hashPassword(password: string): Promise<string> {
  return argon2.hash(password, { type: argon2.argon2id, memoryCost: 19_456, timeCost: 2, parallelism: 1 });
}

export async function verifyPassword(hash: string, password: string): Promise<boolean> {
  try {
    return await argon2.verify(hash, password);
  } catch {
    return false;
  }
}

export function generateTotpSecret(): string {
  return new Secret({ size: 20 }).base32;
}

export function totpFor(email: string, issuer: string, secret: string): TOTP {
  return new TOTP({
    issuer,
    label: email,
    algorithm: 'SHA1',
    digits: 6,
    period: 30,
    secret: Secret.fromBase32(secret),
  });
}

export function verifyTotp(email: string, issuer: string, secret: string, token: string): boolean {
  return verifyTotpStep(email, issuer, secret, token) !== null;
}

export function verifyTotpStep(
  email: string,
  issuer: string,
  secret: string,
  token: string,
): number | null {
  try {
    const delta = totpFor(email, issuer, secret).validate({
      token: token.replace(/\s/g, ''),
      window: 1,
    });
    if (delta === null) return null;
    return Math.floor(Date.now() / 30_000) + delta;
  } catch {
    return null;
  }
}

export async function claimTotpStep(
  pool: Pool,
  adminUserId: string,
  step: number,
): Promise<boolean> {
  const result = await pool.query(
    `UPDATE admin_users
     SET totp_last_step = $2
     WHERE id = $1 AND totp_last_step < $2
     RETURNING id`,
    [adminUserId, step],
  );
  return result.rowCount === 1;
}

export async function setTotpSecret(
  pool: Pool,
  adminUserId: string,
  encryptedSecret: Buffer,
): Promise<void> {
  await pool.query(
    `UPDATE admin_users
     SET totp_secret_encrypted = $2, totp_enrolled_at = now(), totp_last_step = 0
     WHERE id = $1`,
    [adminUserId, encryptedSecret],
  );
}

export async function recordLoginAttempt(
  pool: Pool,
  input: { email: string | null; ip: string | null; succeeded: boolean },
): Promise<void> {
  await pool.query(
    `INSERT INTO admin_login_attempts (email, ip, succeeded) VALUES ($1, $2, $3)`,
    [input.email, input.ip, input.succeeded],
  );
}

export async function tooManyLoginFailures(
  pool: Pool,
  input: { email: string; ip: string | null },
): Promise<boolean> {
  const result = await pool.query<{ count: string }>(
    `SELECT count(*)::text AS count
     FROM admin_login_attempts
     WHERE succeeded = false
       AND created_at > now() - interval '15 minutes'
       AND (email = $1 OR ($2::text IS NOT NULL AND ip = $2))`,
    [input.email, input.ip],
  );
  return Number(result.rows[0]?.count ?? '0') >= 10;
}

export async function findAdminByEmail(
  pool: Pool,
  email: string,
): Promise<{
  id: string;
  email: string;
  name: string;
  password_hash: string;
  totp_secret_encrypted: Buffer | null;
  totp_enrolled_at: Date | null;
  status: 'active' | 'suspended';
} | null> {
  const result = await pool.query<{
    id: string;
    email: string;
    name: string;
    password_hash: string;
    totp_secret_encrypted: Buffer | null;
    totp_enrolled_at: Date | null;
    status: 'active' | 'suspended';
  }>(
    `SELECT id, email, name, password_hash, totp_secret_encrypted, totp_enrolled_at, status
     FROM admin_users WHERE email = $1`,
    [email.trim().toLowerCase()],
  );
  return result.rows[0] ?? null;
}

export async function rolesFor(pool: Pool, adminUserId: string): Promise<AdminRole[]> {
  const result = await pool.query<{ role: AdminRole }>(
    `SELECT role FROM admin_user_roles WHERE admin_user_id = $1 ORDER BY role`,
    [adminUserId],
  );
  return result.rows.map((row) => row.role);
}

export async function createAdminUser(
  pool: Pool,
  input: { email: string; name: string; password: string; roles: AdminRole[]; totpSecret?: string; crypto: CryptoBox },
): Promise<string> {
  const passwordHash = await hashPassword(input.password);
  const result = await pool.query<{ id: string }>(
    `INSERT INTO admin_users (email, name, password_hash, totp_secret_encrypted, totp_enrolled_at)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING id`,
    [
      input.email.trim().toLowerCase(),
      input.name.trim(),
      passwordHash,
      input.totpSecret ? input.crypto.encrypt(input.totpSecret) : null,
      input.totpSecret ? new Date() : null,
    ],
  );
  const id = String(result.rows[0]?.id);
  for (const role of input.roles) {
    await pool.query(
      `INSERT INTO admin_user_roles (admin_user_id, role) VALUES ($1, $2)`,
      [id, role],
    );
  }
  return id;
}

export async function createSession(
  pool: Pool,
  input: {
    adminUserId: string;
    ip: string | null;
    userAgent: string | null;
    ttlSeconds: number;
  },
): Promise<{ token: string; csrfToken: string; expiresAt: Date }> {
  const token = randomToken(32);
  const csrfToken = randomToken(24);
  const expiresAt = new Date(Date.now() + input.ttlSeconds * 1_000);
  await pool.query(
    `INSERT INTO admin_sessions
       (admin_user_id, token_hash, csrf_token, ip, user_agent, expires_at)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [input.adminUserId, hashToken(token), csrfToken, input.ip, input.userAgent, expiresAt],
  );
  await pool.query(`UPDATE admin_users SET last_login_at = now() WHERE id = $1`, [input.adminUserId]);
  return { token, csrfToken, expiresAt };
}

export async function loadSession(pool: Pool, token: string): Promise<AdminSession | null> {
  if (!token) return null;
  const result = await pool.query<{
    session_id: string;
    csrf_token: string;
    expires_at: Date;
    user_id: string;
    email: string;
    name: string;
    status: 'active' | 'suspended';
    roles: AdminRole[];
  }>(
    `SELECT s.id AS session_id, s.csrf_token, s.expires_at,
            u.id AS user_id, u.email, u.name, u.status,
            COALESCE(array_agg(r.role) FILTER (WHERE r.role IS NOT NULL), '{}') AS roles
     FROM admin_sessions s
     JOIN admin_users u ON u.id = s.admin_user_id
     LEFT JOIN admin_user_roles r ON r.admin_user_id = u.id
     WHERE s.token_hash = $1
       AND s.revoked_at IS NULL
       AND s.expires_at > now()
       AND u.status = 'active'
     GROUP BY s.id, s.csrf_token, s.expires_at, u.id, u.email, u.name, u.status`,
    [hashToken(token)],
  );
  const row = result.rows[0];
  if (!row) return null;
  await pool.query(`UPDATE admin_sessions SET last_seen_at = now() WHERE id = $1`, [row.session_id]);
  return {
    sessionId: row.session_id,
    csrfToken: row.csrf_token,
    user: {
      id: row.user_id,
      email: row.email,
      name: row.name,
      status: row.status,
      roles: row.roles,
    },
    expiresAt: row.expires_at,
  };
}

export async function revokeSession(pool: Pool, sessionId: string): Promise<void> {
  await pool.query(
    `UPDATE admin_sessions SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL`,
    [sessionId],
  );
}

export async function createChallenge(
  pool: Pool,
  input: {
    adminUserId: string;
    purpose: 'login' | 'totp_setup';
    ttlSeconds?: number;
    secretEncrypted?: Buffer;
  },
): Promise<string> {
  const token = randomToken(32);
  await pool.query(
    `INSERT INTO admin_login_challenges
       (admin_user_id, token_hash, purpose, secret_encrypted, expires_at)
     VALUES ($1, $2, $3, $4, $5)`,
    [
      input.adminUserId,
      hashToken(token),
      input.purpose,
      input.secretEncrypted ?? null,
      new Date(Date.now() + (input.ttlSeconds ?? 600) * 1_000),
    ],
  );
  return token;
}

export async function loadChallenge(
  pool: Pool,
  input: { token: string; purpose: 'login' | 'totp_setup' },
): Promise<{ adminUserId: string; secretEncrypted: Buffer | null } | null> {
  if (!input.token) return null;
  const result = await pool.query<{ admin_user_id: string; secret_encrypted: Buffer | null }>(
    `SELECT admin_user_id, secret_encrypted
     FROM admin_login_challenges
     WHERE token_hash = $1
       AND purpose = $2
       AND consumed_at IS NULL
       AND expires_at > now()`,
    [hashToken(input.token), input.purpose],
  );
  const row = result.rows[0];
  if (!row) return null;
  return { adminUserId: row.admin_user_id, secretEncrypted: row.secret_encrypted };
}

export async function consumeChallenge(
  pool: Pool,
  input: { token: string; purpose: 'login' | 'totp_setup' },
): Promise<string | null> {
  if (!input.token) return null;
  const result = await pool.query<{ admin_user_id: string }>(
    `UPDATE admin_login_challenges
     SET consumed_at = now()
     WHERE token_hash = $1
       AND purpose = $2
       AND consumed_at IS NULL
       AND expires_at > now()
     RETURNING admin_user_id`,
    [hashToken(input.token), input.purpose],
  );
  return result.rows[0]?.admin_user_id ?? null;
}

export function hashRecoveryCode(code: string): string {
  return createHash('sha256').update(code.replace(/[\s-]/g, '').toUpperCase(), 'utf8').digest('hex');
}

export function generateRecoveryCodes(count = 10): string[] {
  const codes: string[] = [];
  for (let index = 0; index < count; index += 1) {
    const raw = randomBytes(9).toString('base64url').replace(/[-_]/g, '').toUpperCase();
    codes.push(`${raw.slice(0, 4)}-${raw.slice(4, 8)}-${raw.slice(8, 12)}`);
  }
  return codes;
}

/** Atomically consumes one unused recovery code. */
export async function consumeRecoveryCode(
  pool: Pool,
  adminUserId: string,
  code: string,
): Promise<boolean> {
  const result = await pool.query(
    `UPDATE admin_recovery_codes
     SET used_at = now()
     WHERE admin_user_id = $1 AND code_hash = $2 AND used_at IS NULL
     RETURNING id`,
    [adminUserId, hashRecoveryCode(code)],
  );
  return (result.rowCount ?? 0) === 1;
}
