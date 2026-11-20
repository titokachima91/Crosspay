import { randomInt } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import { withTransaction } from '../../db/pool.js';
import { createOtpChallenge, verifyOtpChallenge } from '../../auth/otp.js';
import {
  issueRefreshToken,
  RefreshTokenExpiredError,
  RefreshTokenInvalidError,
  revokeOtherRefreshFamilies,
  revokeRefreshFamily,
  rotateRefreshToken,
} from '../../auth/refresh-tokens.js';
import { signAccessToken } from '../auth.js';
import { parseBody } from '../validation.js';
import {
  serviceUnavailable,
  tooManyRequests,
  unauthorized,
  unprocessable,
} from '../errors.js';
import { SmsNotConfiguredError } from '../../providers/sms.js';
import { consumeRateLimit } from '../../services/rate-limit.js';
import { findOrCreateUserByPhone, isProfileComplete } from '../../services/users.js';

const phoneSchema = z.string().regex(/^\+[1-9][0-9]{7,14}$/);

const otpRequestSchema = z.object({ phone: phoneSchema });
const otpVerifySchema = z.object({
  phone: phoneSchema,
  code: z.string().regex(/^[0-9]{4,10}$/),
});
const refreshSchema = z.object({ refreshToken: z.string().min(1).max(512) });
const logoutSchema = z.object({ refreshToken: z.string().min(1).max(512) });

export function registerAuthRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.post('/auth/otp/request', async (request, reply) => {
    const { phone } = parseBody(otpRequestSchema, request.body);

    const limit = await consumeRateLimit(ctx.pool, {
      scope: 'otp.request',
      key: phone,
      limit: 5,
      windowSeconds: 900,
      crypto: ctx.crypto,
    });
    if (!limit.allowed) {
      throw tooManyRequests(
        'RATE_LIMITED',
        'Too many verification code requests; try again later',
        limit.retryAfterSeconds,
      );
    }

    const ipLimit = await consumeRateLimit(ctx.pool, {
      scope: 'otp.request.ip',
      key: request.ip,
      limit: 30,
      windowSeconds: 900,
      crypto: ctx.crypto,
    });
    if (!ipLimit.allowed) {
      throw tooManyRequests(
        'RATE_LIMITED',
        'Too many verification code requests; try again later',
        ipLimit.retryAfterSeconds,
      );
    }

    const code = randomInt(0, 1_000_000).toString().padStart(6, '0');
    const challenge = await withTransaction(ctx.pool, (client) =>
      createOtpChallenge(client, { phone, code }, ctx.crypto),
    );

    try {
      await ctx.smsSender.sendOtp(phone, code);
    } catch (error) {
      await ctx.pool
        .query(`UPDATE otp_challenges SET superseded_at = now() WHERE id = $1`, [
          challenge.id,
        ])
        .catch(() => undefined);
      if (error instanceof SmsNotConfiguredError) {
        throw serviceUnavailable(
          'SMS_NOT_CONFIGURED',
          'Verification messages are not connected yet',
        );
      }
      throw serviceUnavailable('SMS_DELIVERY_FAILED', 'Could not send the verification code');
    }

    return reply.code(200).send({
      codeLength: challenge.codeLength,
      resendAfterSeconds: challenge.resendAfterSeconds,
      expiresInSeconds: challenge.expiresInSeconds,
    });
  });

  app.post('/auth/otp/verify', async (request, reply) => {
    const { phone, code } = parseBody(otpVerifySchema, request.body);

    const limit = await consumeRateLimit(ctx.pool, {
      scope: 'otp.verify',
      key: phone,
      limit: 10,
      windowSeconds: 900,
      crypto: ctx.crypto,
    });
    if (!limit.allowed) {
      throw tooManyRequests(
        'RATE_LIMITED',
        'Too many verification attempts; try again later',
        limit.retryAfterSeconds,
      );
    }

    const ipLimit = await consumeRateLimit(ctx.pool, {
      scope: 'otp.verify.ip',
      key: request.ip,
      limit: 50,
      windowSeconds: 900,
      crypto: ctx.crypto,
    });
    if (!ipLimit.allowed) {
      throw tooManyRequests(
        'RATE_LIMITED',
        'Too many verification attempts; try again later',
        ipLimit.retryAfterSeconds,
      );
    }

    const result = await withTransaction(ctx.pool, async (client) => {
      const verification = await verifyOtpChallenge(client, { phone, code }, ctx.crypto);
      if (verification.state !== 'verified') {
        return { kind: 'failed' as const, verification };
      }

      const account = await findOrCreateUserByPhone(client, phone);
      const user = account.user;
      const refresh = await issueRefreshToken(client, {
        userId: user.id,
        crypto: ctx.crypto,
        ttlSeconds: ctx.refreshTokenTtlSeconds,
      });
      // One active session per account: a new sign-in signs out every other
      // device by revoking its refresh family.
      await revokeOtherRefreshFamilies(client, {
        userId: user.id,
        keepFamilyId: refresh.familyId,
      });
      const epoch = await client.query<{ auth_epoch: number }>(
        `UPDATE users SET auth_epoch = auth_epoch + 1
         WHERE id = $1
         RETURNING auth_epoch`,
        [user.id],
      );
      return {
        kind: 'ok' as const,
        user,
        refresh,
        isNewUser: account.created,
        sessionEpoch: Number(epoch.rows[0]?.auth_epoch ?? 0),
      };
    });

    if (result.kind === 'failed') {
      switch (result.verification.state) {
        case 'expired':
          throw unprocessable('OTP_EXPIRED', 'The verification code has expired');
        case 'too_many_attempts':
          throw tooManyRequests(
            'OTP_TOO_MANY_ATTEMPTS',
            'Too many incorrect attempts for this code',
            900,
          );
        default:
          throw unprocessable('OTP_INVALID', 'The verification code is invalid');
      }
    }

    const accessToken = await signAccessToken({
      userId: result.user.id,
      sessionEpoch: result.sessionEpoch,
      secret: ctx.jwtSecret,
      ttlSeconds: ctx.accessTokenTtlSeconds,
    });

    return reply.code(200).send({
      accessToken,
      refreshToken: result.refresh.token,
      expiresInSeconds: ctx.accessTokenTtlSeconds,
      profileComplete: isProfileComplete(result.user),
      isNewUser: result.isNewUser,
    });
  });

  app.post('/auth/refresh', async (request, reply) => {
    const { refreshToken } = parseBody(refreshSchema, request.body);

    const ipLimit = await consumeRateLimit(ctx.pool, {
      scope: 'auth.refresh.ip',
      key: request.ip,
      limit: 60,
      windowSeconds: 900,
      crypto: ctx.crypto,
    });
    if (!ipLimit.allowed) {
      throw tooManyRequests(
        'RATE_LIMITED',
        'Too many refresh attempts; try again later',
        ipLimit.retryAfterSeconds,
      );
    }

    let result;
    try {
      result = await withTransaction(ctx.pool, (client) =>
        rotateRefreshToken(client, {
          token: refreshToken,
          crypto: ctx.crypto,
          ttlSeconds: ctx.refreshTokenTtlSeconds,
        }),
      );
    } catch (error) {
      if (error instanceof RefreshTokenInvalidError) {
        throw unauthorized('REFRESH_TOKEN_INVALID', 'The refresh token is invalid');
      }
      if (error instanceof RefreshTokenExpiredError) {
        throw unauthorized('REFRESH_TOKEN_EXPIRED', 'The refresh token has expired');
      }
      throw error;
    }

    if (result.state === 'reused') {
      throw unauthorized(
        'REFRESH_TOKEN_REUSED',
        'This refresh token was already used; sign in again',
      );
    }

    const epoch = await ctx.pool.query<{ auth_epoch: number }>(
      `SELECT auth_epoch FROM users WHERE id = $1 AND deleted_at IS NULL`,
      [result.userId],
    );
    const authEpoch = epoch.rows[0]?.auth_epoch;
    if (authEpoch === undefined) {
      throw unauthorized('USER_NOT_FOUND', 'The signed-in account no longer exists');
    }

    const accessToken = await signAccessToken({
      userId: result.userId,
      sessionEpoch: Number(authEpoch),
      secret: ctx.jwtSecret,
      ttlSeconds: ctx.accessTokenTtlSeconds,
    });

    return reply.code(200).send({
      accessToken,
      refreshToken: result.token,
      expiresInSeconds: ctx.accessTokenTtlSeconds,
    });
  });

  app.post('/auth/logout', async (request, reply) => {
    const { refreshToken } = parseBody(logoutSchema, request.body);

    const ipLimit = await consumeRateLimit(ctx.pool, {
      scope: 'auth.logout.ip',
      key: request.ip,
      limit: 120,
      windowSeconds: 900,
      crypto: ctx.crypto,
    });
    if (!ipLimit.allowed) {
      throw tooManyRequests(
        'RATE_LIMITED',
        'Too many sign-out attempts; try again later',
        ipLimit.retryAfterSeconds,
      );
    }

    // The refresh token is the credential. Revoke its family and answer 204
    // even when it is unknown or already revoked: sign-out is idempotent and
    // must not reveal whether a token exists.
    await withTransaction(ctx.pool, async (client) => {
      const row = await client.query<{ family_id: string }>(
        `SELECT family_id FROM refresh_tokens WHERE token_hash = $1`,
        [ctx.crypto.hashToken(refreshToken)],
      );
      const familyId = row.rows[0]?.family_id;
      if (familyId) await revokeRefreshFamily(client, familyId);
    });

    return reply.code(204).send();
  });
}
