import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppContext } from '../context.js';
import { AppError, notFound, serviceUnavailable, unauthorized } from '../errors.js';
import { parseBody } from '../validation.js';
import {
  callbackPayloadSchema,
  handleCollectionCallback,
  handlePayoutCallback,
  verifyCallbackSignature,
} from '../../webhooks.js';

const providerParamsSchema = z.object({
  provider: z.string().regex(/^[a-z][a-z0-9_]{1,63}$/),
});

function header(value: string | string[] | undefined): string | null {
  if (typeof value === 'string' && value.length > 0) return value;
  return null;
}

/**
 * Public provider callback surface. Authentication is the HMAC, not a JWT:
 * every event is verified against the raw body, a bounded timestamp and a
 * per-provider secret before it can move money.
 */
export function registerWebhookRoutes(app: FastifyInstance, ctx: AppContext): void {
  app.post('/webhooks/payments/:provider', async (request) => {
    const params = parseBody(providerParamsSchema, request.params);

    if (!ctx.paymentWebhookSecret) {
      throw serviceUnavailable('WEBHOOKS_NOT_CONFIGURED', 'Provider callbacks are not connected yet');
    }
    if (params.provider !== ctx.paymentProvider.name) {
      throw notFound('WEBHOOK_PROVIDER_UNKNOWN', 'Unknown payment provider');
    }

    const timestamp = header(request.headers['x-kachi-timestamp']);
    const signature = header(request.headers['x-kachi-signature']);
    if (!timestamp || !signature) {
      throw unauthorized('WEBHOOK_SIGNATURE_REQUIRED', 'The callback signature is missing');
    }
    const sentAt = Number(timestamp);
    if (!Number.isFinite(sentAt)) {
      throw unauthorized('WEBHOOK_TIMESTAMP_INVALID', 'The callback timestamp is invalid');
    }
    const skewMs = Math.abs(Date.now() - sentAt);
    if (skewMs > ctx.paymentWebhookMaxSkewSeconds * 1_000) {
      throw unauthorized('WEBHOOK_TIMESTAMP_INVALID', 'The callback timestamp is too old');
    }

    const rawBody = request.rawBody;
    if (rawBody === undefined) {
      throw new AppError(400, 'WEBHOOK_BODY_MISSING', 'The raw callback body is missing');
    }
    if (
      !verifyCallbackSignature({
        rawBody,
        timestamp,
        signature,
        secret: ctx.paymentWebhookSecret,
      })
    ) {
      throw unauthorized('WEBHOOK_SIGNATURE_INVALID', 'The callback signature is invalid');
    }

    const payload = parseBody(callbackPayloadSchema, request.body);
    if (payload.checkoutRequestId) {
      return handleCollectionCallback(ctx, {
        provider: params.provider,
        rawBody,
        payload,
      });
    }
    if (payload.payoutId) {
      return handlePayoutCallback(ctx, {
        provider: params.provider,
        rawBody,
        payload,
      });
    }
    throw new AppError(400, 'WEBHOOK_INVALID', 'The callback is neither a collection nor a payout');
  });
}
