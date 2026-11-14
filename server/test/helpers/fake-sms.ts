import type { SmsSender } from '../../src/providers/sms.js';

export interface CapturedSms {
  phone: string;
  code: string;
}

/** Test-only transport. Production uses a real partner or stays disabled. */
export class CapturingSmsSender implements SmsSender {
  readonly messages: CapturedSms[] = [];

  async sendOtp(phone: string, code: string): Promise<void> {
    this.messages.push({ phone, code });
  }

  lastCode(phone: string): string | undefined {
    for (let index = this.messages.length - 1; index >= 0; index -= 1) {
      const message = this.messages[index];
      if (message?.phone === phone) return message.code;
    }
    return undefined;
  }
}
