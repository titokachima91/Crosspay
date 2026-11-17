import { positiveInt } from '../runtime.js';

export interface AdminWebConfig {
  port: number;
  host: string;
  baseUrl: string;
  cookieSecure: boolean;
  sessionTtlSeconds: number;
  totpIssuer: string;
}

export function loadAdminWebConfig(): AdminWebConfig {
  const baseUrl = (process.env['ADMIN_BASE_URL'] ?? 'http://127.0.0.1:3001').replace(/\/+$/, '');
  const secureDefault = baseUrl.startsWith('https://');
  const cookieSecureRaw = (process.env['ADMIN_COOKIE_SECURE'] ?? '').trim().toLowerCase();
  return {
    port: positiveInt('ADMIN_WEB_PORT', 3001),
    host: process.env['ADMIN_WEB_HOST'] ?? '127.0.0.1',
    baseUrl,
    cookieSecure:
      cookieSecureRaw === ''
        ? secureDefault || process.env['NODE_ENV'] === 'production'
        : cookieSecureRaw === 'true',
    sessionTtlSeconds: positiveInt('ADMIN_SESSION_TTL_SECONDS', 8 * 60 * 60),
    totpIssuer: process.env['ADMIN_TOTP_ISSUER'] ?? 'CrossPay Admin',
  };
}
