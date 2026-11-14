import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  hkdfSync,
  randomBytes,
  timingSafeEqual,
} from 'node:crypto';

const VERSION = 1;
const IV_BYTES = 12;
const TAG_BYTES = 16;
const KEY_BYTES = 32;

export class CryptoError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CryptoError';
  }
}

function deriveKey(masterKey: Buffer, label: string): Buffer {
  const derived = hkdfSync(
    'sha256',
    masterKey,
    Buffer.alloc(0),
    Buffer.from(`crosspay:${label}`, 'utf8'),
    KEY_BYTES,
  );
  return Buffer.from(derived);
}

/**
 * Application-level encryption for restricted fields. The master key never
 * enters the database; it is supplied by the hosting secret manager.
 */
export class CryptoBox {
  private readonly encryptionKey: Buffer;
  private readonly hashingKey: Buffer;

  constructor(masterKey: Buffer) {
    if (masterKey.length !== KEY_BYTES) {
      throw new CryptoError(`master key must be ${KEY_BYTES} bytes`);
    }
    this.encryptionKey = deriveKey(masterKey, 'encryption');
    this.hashingKey = deriveKey(masterKey, 'hashing');
  }

  static fromBase64(value: string): CryptoBox {
    const key = Buffer.from(value, 'base64');
    if (key.length !== KEY_BYTES) {
      throw new CryptoError('DATA_ENCRYPTION_KEY must be 32 bytes, base64 encoded');
    }
    return new CryptoBox(key);
  }

  encrypt(plaintext: string): Buffer {
    const iv = randomBytes(IV_BYTES);
    const cipher = createCipheriv('aes-256-gcm', this.encryptionKey, iv);
    const ciphertext = Buffer.concat([
      cipher.update(Buffer.from(plaintext, 'utf8')),
      cipher.final(),
    ]);
    const tag = cipher.getAuthTag();
    return Buffer.concat([Buffer.from([VERSION]), iv, tag, ciphertext]);
  }

  decrypt(payload: Buffer): string {
    if (payload.length <= 1 + IV_BYTES + TAG_BYTES) {
      throw new CryptoError('encrypted payload is too short');
    }
    if (payload[0] !== VERSION) {
      throw new CryptoError(`unsupported ciphertext version ${payload[0]}`);
    }
    const iv = payload.subarray(1, 1 + IV_BYTES);
    const tag = payload.subarray(1 + IV_BYTES, 1 + IV_BYTES + TAG_BYTES);
    const ciphertext = payload.subarray(1 + IV_BYTES + TAG_BYTES);
    const decipher = createDecipheriv('aes-256-gcm', this.encryptionKey, iv);
    decipher.setAuthTag(tag);
    try {
      return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
    } catch {
      throw new CryptoError('encrypted payload failed authentication');
    }
  }

  /** HMAC-SHA-256 for lookups and duplicate detection without decryption. */
  hashSensitive(value: string): string {
    return createHmac('sha256', this.hashingKey).update(value, 'utf8').digest('hex');
  }

  /** A SHA-256 fingerprint for a token that does not need a secret pepper. */
  hashToken(value: string): string {
    return createHash('sha256').update(value, 'utf8').digest('hex');
  }

  matchesHash(value: string, expectedHex: string): boolean {
    const actual = Buffer.from(this.hashSensitive(value), 'hex');
    const expected = Buffer.from(expectedHex, 'hex');
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  }
}

/** Deterministic JSON so a retried request is recognized as the same body. */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') {
    return JSON.stringify(value);
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new CryptoError('request body contains a non-finite number');
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(',')}]`;
  }
  if (typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record).sort();
    return `{${keys
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`)
      .join(',')}}`;
  }
  throw new CryptoError(`request body contains unsupported type ${typeof value}`);
}

export function hashRequest(body: unknown): string {
  return createHash('sha256').update(canonicalJson(body), 'utf8').digest('hex');
}

export function isHex64(value: string): boolean {
  return /^[a-f0-9]{64}$/.test(value);
}
