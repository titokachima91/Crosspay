import type { SmsSender } from '../../src/providers/sms.js';

export interface CapturedSms {
  phone: string;
  code: string;
}

export interface CapturedText {
  phone: string;
  message: string;
}

/** Test-only transport. Production uses a real partner or stays disabled. */
export class CapturingSmsSender implements SmsSender {
  readonly available = true;
  readonly messages: CapturedSms[] = [];
  readonly texts: CapturedText[] = [];

  async sendOtp(phone: string, code: string): Promise<void> {
    this.messages.push({ phone, code });
  }

  async sendMessage(phone: string, message: string): Promise<void> {
    this.texts.push({ phone, message });
  }

  lastCode(phone: string): string | undefined {
    for (let index = this.messages.length - 1; index >= 0; index -= 1) {
      const message = this.messages[index];
      if (message?.phone === phone) return message.code;
    }
    return undefined;
  }
}
