export interface SmsSender {
  sendOtp(phone: string, code: string): Promise<void>;
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
  async sendOtp(): Promise<void> {
    throw new SmsNotConfiguredError();
  }
}
