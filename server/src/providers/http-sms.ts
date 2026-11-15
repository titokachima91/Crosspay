import type { SmsSender } from './sms.js';

export interface HttpSmsOptions {
  url: string;
  apiKey?: string;
  senderId?: string;
  timeoutMs?: number;
}

export class SmsDeliveryError extends Error {
  readonly code = 'SMS_DELIVERY_FAILED';
  constructor(message = 'The SMS gateway did not accept the message') {
    super(message);
    this.name = 'SmsDeliveryError';
  }
}

/**
 * Reference HTTP SMS adapter.
 *
 * It posts `{ recipient, message }` to the configured gateway, with an
 * optional `x-api-key` and `senderId`. The sandbox `/v1/send-sms` route is a
 * compatible gateway. A real partner with a different shape should get its own
 * adapter rather than bending this one.
 */
export class HttpSmsSender implements SmsSender {
  private readonly url: string;
  private readonly apiKey?: string;
  private readonly senderId?: string;
  private readonly timeoutMs: number;

  constructor(options: HttpSmsOptions) {
    this.url = options.url;
    this.apiKey = options.apiKey;
    this.senderId = options.senderId;
    this.timeoutMs = options.timeoutMs ?? 5_000;
  }

  async sendOtp(phone: string, code: string): Promise<void> {
    const message = `Your CrossPay verification code is ${code}. It expires in 5 minutes. Never share it.`;
    const headers: Record<string, string> = {
      'content-type': 'application/json',
    };
    if (this.apiKey) headers['x-api-key'] = this.apiKey;

    let response: Response;
    try {
      response = await fetch(this.url, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          recipient: phone,
          message,
          ...(this.senderId ? { senderId: this.senderId } : {}),
        }),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch {
      throw new SmsDeliveryError('The SMS gateway could not be reached');
    }

    if (!response.ok) {
      throw new SmsDeliveryError(`The SMS gateway returned HTTP ${response.status}`);
    }

    // Some gateways return HTTP 200 with { success: false }. Treat that as a
    // delivery failure; never include the code or the response body in logs.
    const text = await response.text();
    if (text.length > 0) {
      try {
        const body = JSON.parse(text) as { success?: unknown };
        if (body && body.success === false) {
          throw new SmsDeliveryError('The SMS gateway rejected the message');
        }
      } catch (error) {
        if (error instanceof SmsDeliveryError) throw error;
        // A non-JSON 2xx response is accepted; some gateways return plain text.
      }
    }
  }
}
