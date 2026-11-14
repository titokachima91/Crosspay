import type { z } from 'zod';
import { badRequest } from './errors.js';

export function parseBody<T>(schema: z.ZodType<T>, body: unknown): T {
  const result = schema.safeParse(body);
  if (!result.success) {
    throw badRequest('VALIDATION_FAILED', 'The request body is invalid');
  }
  return result.data;
}
