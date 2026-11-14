export class AppError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
    readonly headers?: Record<string, string>,
  ) {
    super(message);
    this.name = 'AppError';
  }
}

export function badRequest(code: string, message: string): AppError {
  return new AppError(400, code, message);
}

export function unauthorized(code = 'UNAUTHORIZED', message = 'Authentication is required'): AppError {
  return new AppError(401, code, message);
}

export function forbidden(code: string, message: string): AppError {
  return new AppError(403, code, message);
}

export function notFound(code: string, message: string): AppError {
  return new AppError(404, code, message);
}

export function conflict(code: string, message: string): AppError {
  return new AppError(409, code, message);
}

export function unprocessable(code: string, message: string): AppError {
  return new AppError(422, code, message);
}

export function tooManyRequests(
  code: string,
  message: string,
  retryAfterSeconds: number,
): AppError {
  return new AppError(429, code, message, {
    'Retry-After': String(Math.max(1, Math.ceil(retryAfterSeconds))),
  });
}

export function serviceUnavailable(code: string, message: string): AppError {
  return new AppError(503, code, message);
}
