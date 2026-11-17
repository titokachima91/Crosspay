import 'dotenv/config';
import { stdin, stdout } from 'node:process';
import { createPoolFromEnv } from '../src/db/pool.js';
import { CryptoBox } from '../src/crypto.js';
import {
  createAdminUser,
  generateRecoveryCodes,
  generateTotpSecret,
  hashRecoveryCode,
  totpFor,
  type AdminRole,
} from '../src/admin-web/auth.js';

/**
 * Creates the first named admin. The password and TOTP secret are printed to
 * the terminal only; nothing is stored in source or environment.
 *
 *   npm run admin:create -- --email admin@example.com --name "Ada" --role superadmin
 */

function arg(name: string, fallback = ''): string {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) return fallback;
  return process.argv[index + 1] ?? fallback;
}

async function readHidden(prompt: string): Promise<string> {
  if (!stdin.isTTY) {
    const value = process.env['ADMIN_PASSWORD'];
    if (!value) throw new Error('ADMIN_PASSWORD is required when stdin is not a TTY');
    return value;
  }
  stdout.write(prompt);
  return new Promise((resolve, reject) => {
    let value = '';
    const wasRaw = stdin.isRaw;
    stdin.setRawMode(true);
    stdin.resume();
    const onData = (buffer: Buffer) => {
      for (const byte of buffer) {
        if (byte === 13 || byte === 10) {
          stdin.setRawMode(Boolean(wasRaw));
          stdin.pause();
          stdin.off('data', onData);
          stdout.write('\n');
          resolve(value);
          return;
        }
        if (byte === 3) {
          stdin.setRawMode(Boolean(wasRaw));
          stdin.pause();
          stdin.off('data', onData);
          stdout.write('\n');
          reject(new Error('cancelled'));
          return;
        }
        if (byte === 127 || byte === 8) {
          if (value.length > 0) {
            value = value.slice(0, -1);
            stdout.write('\b \b');
          }
          continue;
        }
        const char = String.fromCharCode(byte);
        if (char >= ' ') {
          value += char;
          stdout.write('*');
        }
      }
    };
    stdin.on('data', onData);
  });
}

async function main(): Promise<void> {
  const email = arg('email').trim().toLowerCase();
  const name = arg('name').trim();
  const role = (arg('role', 'superadmin').trim() as AdminRole);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Error('--email must be a valid email');
  if (name.length === 0) throw new Error('--name is required');
  if (!['viewer', 'ops', 'finance', 'compliance', 'superadmin'].includes(role)) {
    throw new Error('--role must be viewer, ops, finance, compliance or superadmin');
  }

  const password = await readHidden('Password (12+ characters): ');
  const confirm = await readHidden('Confirm password: ');
  if (password.length < 12) throw new Error('password must be at least 12 characters');
  if (password !== confirm) throw new Error('passwords do not match');

  const pool = createPoolFromEnv();
  try {
    const crypto = CryptoBox.fromBase64(process.env['DATA_ENCRYPTION_KEY'] ?? '');
    const secret = generateTotpSecret();
    const id = await createAdminUser(pool, {
      email,
      name,
      password,
      roles: [role],
      totpSecret: secret,
      crypto,
    });
    const codes = generateRecoveryCodes(10);
    for (const code of codes) {
      await pool.query(
        `INSERT INTO admin_recovery_codes (admin_user_id, code_hash) VALUES ($1, $2)`,
        [id, hashRecoveryCode(code)],
      );
    }
    const uri = totpFor(email, process.env['ADMIN_TOTP_ISSUER'] ?? 'CrossPay Admin', secret).toString();
    const { default: QRCode } = await import('qrcode');
    console.log(`\nAdmin created: ${email} (${role})\n`);
    console.log('Scan this TOTP URI with an authenticator app:\n');
    console.log(await QRCode.toString(uri, { type: 'terminal', small: true }));
    console.log(`\nTOTP secret: ${secret}\n`);
    console.log('Recovery codes (store offline, shown once):\n');
    for (const code of codes) console.log(`  ${code}`);
    console.log('\nSign in at /login. The first password change is recommended.\n');
  } finally {
    await pool.end();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
