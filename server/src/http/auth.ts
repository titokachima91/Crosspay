import { jwtVerify, SignJWT } from 'jose';
import type { FastifyRequest } from 'fastify';
import { unauthorized } from './errors.js';

export const JWT_ISSUER = 'crosspay-api';
export const JWT_AUDIENCE = 'crosspay-app';
export const EXPORT_AUDIENCE = 'crosspay-export';

export interface AccessTokenInput {
  userId: string;
  secret: Uint8Array;
  ttlSeconds?: number;
  now?: Date;
}

export async function signAccessToken(input: AccessTokenInput): Promise<string> {
  const nowSeconds = Math.floor((input.now ?? new Date()).getTime() / 1000);
  const ttlSeconds = input.ttlSeconds ?? 900;
  return new SignJWT({})
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setSubject(input.userId)
    .setIssuer(JWT_ISSUER)
    .setAudience(JWT_AUDIENCE)
    .setIssuedAt(nowSeconds)
    .setExpirationTime(nowSeconds + ttlSeconds)
    .sign(input.secret);
}

export async function verifyAccessToken(
  token: string,
  secret: Uint8Array,
): Promise<{ userId: string }> {
  try {
    const result = await jwtVerify(token, secret, {
      issuer: JWT_ISSUER,
      audience: JWT_AUDIENCE,
      algorithms: ['HS256'],
    });
    const userId = result.payload.sub;
    if (!userId) throw unauthorized();
    return { userId };
  } catch (error) {
    if (error instanceof Error && error.name === 'AppError') throw error;
    throw unauthorized();
  }
}

/** Short-lived, single-purpose token for a server-built CSV download link. */
export async function signExportToken(input: {
  userId: string;
  secret: Uint8Array;
  ttlSeconds?: number;
  now?: Date;
}): Promise<string> {
  const nowSeconds = Math.floor((input.now ?? new Date()).getTime() / 1000);
  return new SignJWT({ scope: 'trades_export' })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setSubject(input.userId)
    .setIssuer(JWT_ISSUER)
    .setAudience(EXPORT_AUDIENCE)
    .setIssuedAt(nowSeconds)
    .setExpirationTime(nowSeconds + (input.ttlSeconds ?? 300))
    .sign(input.secret);
}

export async function verifyExportToken(
  token: string,
  secret: Uint8Array,
): Promise<{ userId: string }> {
  try {
    const result = await jwtVerify(token, secret, {
      issuer: JWT_ISSUER,
      audience: EXPORT_AUDIENCE,
      algorithms: ['HS256'],
    });
    const userId = result.payload.sub;
    if (!userId || result.payload['scope'] !== 'trades_export') throw unauthorized();
    return { userId };
  } catch {
    throw unauthorized('EXPORT_LINK_INVALID', 'The export link is invalid or has expired');
  }
}

export function bearerToken(request: FastifyRequest): string {
  const header = request.headers.authorization;
  if (!header || Array.isArray(header)) throw unauthorized();
  const [scheme, token] = header.split(' ');
  if (scheme?.toLowerCase() !== 'bearer' || !token) throw unauthorized();
  return token;
}

export function requireUserId(request: FastifyRequest): string {
  if (!request.userId) throw unauthorized();
  return request.userId;
}

declare module 'fastify' {
  interface FastifyRequest {
    userId?: string;
  }
}
