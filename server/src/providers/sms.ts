export interface SmsSender {
  /** False keeps the support UI honest instead of queuing a message nowhere. */
  readonly available: boolean;
  sendOtp(phone: string, code: string): Promise<void>;
  sendMessage(phone: string, message: string): Promise<void>;
}

export class SmsNotConfiguredError extends Error {
  readonly code = 'SMS_NOT_CONFIGURED';
  constructor() {
    super('No SMS provider is configured');
    this.name = 'SmsNotConfiguredError';
  }
}

/**
 * Production default until a real SMS partner is connected. It never pretends
 * to deliver a code. The OTP request endpoint returns 503 SMS_NOT_CONFIGURED.
 */
export class DisabledSmsSender implements SmsSender {
  readonly available = false;

  async sendOtp(): Promise<void> {
    throw new SmsNotConfiguredError();
  }

  async sendMessage(): Promise<void> {
    throw new SmsNotConfiguredError();
  }
}
