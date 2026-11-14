import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { after, before, describe, it } from 'node:test';
import type { TestDatabase } from './helpers/test-database.js';
import { createUser, startTestDatabase } from './helpers/test-database.js';
import { canonicalJson, CryptoBox, CryptoError, hashRequest } from '../src/crypto.js';
import { withTransaction } from '../src/db/pool.js';
import { createOtpChallenge, verifyOtpChallenge } from '../src/auth/otp.js';
import {
  issueRefreshToken,
  RefreshTokenExpiredError,
  RefreshTokenInvalidError,
  rotateRefreshToken,
} from '../src/auth/refresh-tokens.js';

let db: TestDatabase;

before(async () => {
  db = await startTestDatabase();
}, { timeout: 180_000 });

after(async () => {
  await db.close();
});

describe('application encryption', () => {
  it('round-trips restricted values and rejects tampering', () => {
    const crypto = new CryptoBox(randomBytes(32));
    const plaintext = 'ID-1990-0012-8912 / Amina Hassan';
    const ciphertext = crypto.encrypt(plaintext);

    assert.equal(crypto.decrypt(ciphertext), plaintext);
    assert.equal(ciphertext.includes(Buffer.from(plaintext)), false);

    const tampered = Buffer.from(ciphertext);
    tampered[tampered.length - 1] = (tampered[tampered.length - 1] ?? 0) ^ 0xff;
    assert.throws(() => crypto.decrypt(tampered), CryptoError);

    const other = new CryptoBox(randomBytes(32));
    assert.throws(() => other.decrypt(ciphertext), CryptoError);
  });

  it('hashes deterministically and compares without timing leaks', () => {
    const crypto = new CryptoBox(randomBytes(32));
    const one = crypto.hashSensitive('+255755000111');
    const two = crypto.hashSensitive('+255755000111');
    assert.equal(one, two);
    assert.match(one, /^[a-f0-9]{64}$/);
    assert.notEqual(one, crypto.hashSensitive('+255755000112'));
    assert.equal(crypto.matchesHash('+255755000111', one), true);
    assert.equal(crypto.matchesHash('+255755000112', one), false);
  });

  it('produces a stable request hash regardless of key order', () => {
    const a = { quoteId: 'q1', recipient: { name: 'Amina', railId: 'mpesa-ke' } };
    const b = { recipient: { railId: 'mpesa-ke', name: 'Amina' }, quoteId: 'q1' };
    assert.equal(canonicalJson(a), canonicalJson(b));
    assert.equal(hashRequest(a), hashRequest(b));
    assert.notEqual(hashRequest(a), hashRequest({ quoteId: 'q2' }));
  });
});

describe('restricted database fields', () => {
  it('stores KYC identifiers encrypted and finds duplicates by hash', async () => {
    const crypto = new CryptoBox(randomBytes(32));
    const user = await createUser(db.pool);
    const idNumber = '19900101-12345-8912';
    const encrypted = crypto.encrypt(idNumber);
    const hashed = crypto.hashSensitive(idNumber);

    await db.pool.query(
      `INSERT INTO kyc_verifications
         (user_id, account_type, legal_name, id_type, id_number_encrypted,
          id_number_hash, id_last4, status)
       VALUES ($1, 'personal', 'Amina Hassan', 'national_id', $2, $3, '8912', 'pending')`,
      [user, encrypted, hashed],
    );

    const stored = await db.pool.query(
      `SELECT id_number_encrypted, id_number_hash, id_last4
       FROM kyc_verifications WHERE user_id = $1`,
      [user],
    );
    const row = stored.rows[0];
    assert.ok(row);
    const storedBytes = Buffer.from(row['id_number_encrypted'] as Buffer);
    assert.equal(storedBytes.includes(Buffer.from(idNumber)), false);
    assert.equal(crypto.decrypt(storedBytes), idNumber);
    assert.equal(row['id_number_hash'], hashed);
    assert.equal(row['id_last4'], '8912');

    const other = await createUser(db.pool);
    await assert.rejects(
      db.pool.query(
        `INSERT INTO kyc_verifications
           (user_id, account_type, legal_name, id_type, id_number_encrypted,
            id_number_hash, id_last4, status)
         VALUES ($1, 'personal', 'Other Person', 'national_id', $2, $3, '8912', 'pending')`,
        [other, crypto.encrypt(idNumber), hashed],
      ),
      /kyc_submitted_identity_uidx/,
    );
  });

  it('rejects an empty encrypted identifier and a second pending KYC', async () => {
    const crypto = new CryptoBox(randomBytes(32));
    const user = await createUser(db.pool);
    const first = crypto.hashSensitive('ID-ONE-1234');
    await db.pool.query(
      `INSERT INTO kyc_verifications
         (user_id, account_type, legal_name, id_type, id_number_encrypted,
          id_number_hash, id_last4, status)
       VALUES ($1, 'personal', 'Amina Hassan', 'national_id', $2, $3, '1234', 'pending')`,
      [user, crypto.encrypt('ID-ONE-1234'), first],
    );

    await assert.rejects(
      db.pool.query(
        `INSERT INTO kyc_verifications
           (user_id, account_type, legal_name, id_type, id_number_encrypted,
            id_number_hash, id_last4, status)
         VALUES ($1, 'personal', 'Amina Hassan', 'national_id', $2, $3, '5678', 'pending')`,
        [user, crypto.encrypt('ID-TWO-5678'), crypto.hashSensitive('ID-TWO-5678')],
      ),
      /kyc_one_pending_per_user_uidx/,
    );

    await assert.rejects(
      db.pool.query(
        `INSERT INTO kyc_verifications
           (user_id, account_type, legal_name, id_type, id_number_encrypted,
            id_number_hash, id_last4, status)
         VALUES ($1, 'personal', 'Empty', 'passport', ''::bytea, $2, '0000', 'pending')`,
        [user, crypto.hashSensitive('EMPTY')],
      ),
      /id_number_encrypted/,
    );
  });

  it('stores only hashes of OTP codes and refresh tokens', async () => {
    const crypto = new CryptoBox(randomBytes(32));
    const user = await createUser(db.pool);
    const code = '483920';
    const codeHash = crypto.hashSensitive(code);
    const tokenHash = crypto.hashToken('refresh-token-value');

    await db.pool.query(
      `INSERT INTO otp_challenges (phone, code_hash, expires_at)
       VALUES ('+255755999888', $1, now() + interval '5 minutes')`,
      [codeHash],
    );
    await db.pool.query(
      `INSERT INTO refresh_tokens (user_id, token_hash, family_id, expires_at)
       VALUES ($1, $2, gen_random_uuid(), now() + interval '30 days')`,
      [user, tokenHash],
    );

    const otp = await db.pool.query(
      `SELECT code_hash FROM otp_challenges WHERE phone = '+255755999888'`,
    );
    assert.equal(otp.rows[0]?.['code_hash'], codeHash);
    assert.notEqual(otp.rows[0]?.['code_hash'], code);
    assert.equal(crypto.matchesHash(code, codeHash), true);

    const token = await db.pool.query(
      `SELECT token_hash FROM refresh_tokens WHERE user_id = $1`,
      [user],
    );
    assert.equal(token.rows[0]?.['token_hash'], tokenHash);
    assert.match(tokenHash, /^[a-f0-9]{64}$/);
  });

  it('encrypts saved recipient destinations', async () => {
    const crypto = new CryptoBox(randomBytes(32));
    const user = await createUser(db.pool);
    const account = '+254712345678';

    await db.pool.query(
      `INSERT INTO beneficiaries
         (user_id, rail_id, name, account_or_phone_encrypted, account_last4, account_hash)
       VALUES ($1, 'mpesa-ke', 'Amina Hassan', $2, '5678', $3)`,
      [user, crypto.encrypt(account), crypto.hashSensitive(account)],
    );

    const stored = await db.pool.query(
      `SELECT account_or_phone_encrypted, account_last4
       FROM beneficiaries WHERE user_id = $1`,
      [user],
    );
    const bytes = Buffer.from(stored.rows[0]?.['account_or_phone_encrypted'] as Buffer);
    assert.equal(bytes.includes(Buffer.from(account)), false);
    assert.equal(crypto.decrypt(bytes), account);
    assert.equal(stored.rows[0]?.['account_last4'], '5678');
  });
});

describe('one-time codes and refresh-token rotation', () => {
  it('counts wrong codes, locks after the limit and consumes a correct code once', async () => {
    const crypto = new CryptoBox(randomBytes(32));
    const phone = '+255755777666';
    await withTransaction(db.pool, (client) =>
      createOtpChallenge(client, { phone, code: '483920' }, crypto),
    );

    const firstTry = await withTransaction(db.pool, (client) =>
      verifyOtpChallenge(client, { phone, code: '000000' }, crypto),
    );
    assert.deepEqual(firstTry, { state: 'invalid', attemptsRemaining: 4 });

    for (let attempt = 0; attempt < 4; attempt += 1) {
      await withTransaction(db.pool, (client) =>
        verifyOtpChallenge(client, { phone, code: '000000' }, crypto),
      );
    }
    const locked = await withTransaction(db.pool, (client) =>
      verifyOtpChallenge(client, { phone, code: '000000' }, crypto),
    );
    assert.deepEqual(locked, { state: 'too_many_attempts' });

    const correctAfterLock = await withTransaction(db.pool, (client) =>
      verifyOtpChallenge(client, { phone, code: '483920' }, crypto),
    );
    assert.deepEqual(correctAfterLock, { state: 'too_many_attempts' });

    await withTransaction(db.pool, (client) =>
      createOtpChallenge(client, { phone, code: '112233' }, crypto),
    );
    const verified = await withTransaction(db.pool, (client) =>
      verifyOtpChallenge(client, { phone, code: '112233' }, crypto),
    );
    assert.equal(verified.state, 'verified');

    const replay = await withTransaction(db.pool, (client) =>
      verifyOtpChallenge(client, { phone, code: '112233' }, crypto),
    );
    assert.deepEqual(replay, { state: 'invalid', attemptsRemaining: 0 });
  });

  it('reports an expired code without consuming it', async () => {
    const crypto = new CryptoBox(randomBytes(32));
    const phone = '+255755777555';
    const now = new Date();
    await withTransaction(db.pool, (client) =>
      createOtpChallenge(client, { phone, code: '998877', ttlSeconds: 1, now }, crypto),
    );

    const expired = await withTransaction(db.pool, (client) =>
      verifyOtpChallenge(
        client,
        { phone, code: '998877', now: new Date(now.getTime() + 5_000) },
        crypto,
      ),
    );
    assert.deepEqual(expired, { state: 'expired' });
  });

  it('rotates refresh tokens and revokes the family when a rotated token is reused', async () => {
    const crypto = new CryptoBox(randomBytes(32));
    const user = await createUser(db.pool);

    const first = await withTransaction(db.pool, (client) =>
      issueRefreshToken(client, { userId: user, crypto }),
    );
    const rotated = await withTransaction(db.pool, (client) =>
      rotateRefreshToken(client, { token: first.token, crypto }),
    );
    assert.equal(rotated.state, 'rotated');
    if (rotated.state !== 'rotated') throw new Error('unreachable');
    assert.notEqual(rotated.token, first.token);
    assert.equal(rotated.familyId, first.familyId);

    const reuse = await withTransaction(db.pool, (client) =>
      rotateRefreshToken(client, { token: first.token, crypto }),
    );
    assert.equal(reuse.state, 'reused');

    const afterFamilyRevocation = await withTransaction(db.pool, (client) =>
      rotateRefreshToken(client, { token: rotated.token, crypto }),
    );
    assert.equal(afterFamilyRevocation.state, 'reused');

    const family = await db.pool.query(
      `SELECT count(*)::int AS total,
              count(*) FILTER (WHERE revoked_at IS NOT NULL)::int AS revoked
       FROM refresh_tokens WHERE family_id = $1`,
      [first.familyId],
    );
    assert.equal(Number(family.rows[0]?.['total']), 2);
    assert.equal(Number(family.rows[0]?.['revoked']), 2);
  });

  it('rejects unknown and expired refresh tokens', async () => {
    const crypto = new CryptoBox(randomBytes(32));
    const user = await createUser(db.pool);

    await assert.rejects(
      withTransaction(db.pool, (client) =>
        rotateRefreshToken(client, { token: 'not-a-real-token', crypto }),
      ),
      RefreshTokenInvalidError,
    );

    const now = new Date(Date.now() - 10_000);
    const expired = await withTransaction(db.pool, (client) =>
      issueRefreshToken(client, { userId: user, crypto, ttlSeconds: 1, now }),
    );
    await assert.rejects(
      withTransaction(db.pool, (client) =>
        rotateRefreshToken(client, { token: expired.token, crypto }),
      ),
      RefreshTokenExpiredError,
    );
  });
});
