-- 0002_identity_access.sql
-- Identity, KYC, one-time codes, refresh-token families and throttling.
-- PINs and biometric templates never enter this database.

CREATE TABLE users (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone               text NOT NULL UNIQUE
                        CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
  phone_verified_at   timestamptz,
  display_name        text CHECK (display_name IS NULL
                                  OR length(btrim(display_name)) BETWEEN 1 AND 200),
  account_type        text NOT NULL DEFAULT 'personal'
                        CHECK (account_type IN ('personal', 'business')),
  hub_id              text REFERENCES hubs (id) ON DELETE RESTRICT,
  kyc_status          text NOT NULL DEFAULT 'not_started'
                        CHECK (kyc_status IN ('not_started', 'pending', 'verified', 'rejected')),
  tier_code           text NOT NULL DEFAULT 'starter'
                        REFERENCES tiers (code) ON DELETE RESTRICT,
  limit_currency_code char(3) REFERENCES currencies (code) ON DELETE RESTRICT,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,
  CONSTRAINT users_business_hub CHECK (
    (account_type = 'business' AND hub_id IS NOT NULL)
    OR (account_type = 'personal' AND hub_id IS NULL)
  ),
  CONSTRAINT users_verified_complete CHECK (
    kyc_status <> 'verified'
    OR (display_name IS NOT NULL
        AND limit_currency_code IS NOT NULL
        AND phone_verified_at IS NOT NULL)
  ),
  CONSTRAINT users_deleted_after_created CHECK (deleted_at IS NULL OR deleted_at >= created_at)
);

CREATE INDEX users_tier_idx ON users (tier_code);
CREATE INDEX users_active_created_idx ON users (created_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE kyc_verifications (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  account_type         text NOT NULL CHECK (account_type IN ('personal', 'business')),
  legal_name           text NOT NULL CHECK (length(btrim(legal_name)) BETWEEN 1 AND 200),
  hub_id               text REFERENCES hubs (id) ON DELETE RESTRICT,
  id_type              text NOT NULL
                         CHECK (id_type IN ('national_id', 'passport', 'business_tin')),
  id_number_encrypted  bytea NOT NULL CHECK (octet_length(id_number_encrypted) > 0),
  id_number_hash       text NOT NULL CHECK (id_number_hash ~ '^[a-f0-9]{64}$'),
  id_last4             text NOT NULL CHECK (id_last4 ~ '^[A-Za-z0-9]{1,4}$'),
  status               text NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending', 'verified', 'rejected')),
  provider             text CHECK (provider IS NULL
                                  OR provider ~ '^[a-z][a-z0-9_]{1,63}$'),
  provider_reference   text,
  rejection_code       text CHECK (rejection_code IS NULL
                                  OR rejection_code ~ '^[A-Z][A-Z0-9_]{1,63}$'),
  submitted_at         timestamptz NOT NULL DEFAULT now(),
  verified_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kyc_business_hub CHECK (
    (account_type = 'business' AND hub_id IS NOT NULL)
    OR (account_type = 'personal' AND hub_id IS NULL)
  ),
  CONSTRAINT kyc_id_type_matches_account CHECK (
    (account_type = 'personal' AND id_type IN ('national_id', 'passport'))
    OR (account_type = 'business' AND id_type = 'business_tin')
  ),
  CONSTRAINT kyc_verified_at_consistent CHECK (
    (status = 'verified' AND verified_at IS NOT NULL)
    OR (status <> 'verified' AND verified_at IS NULL)
  ),
  CONSTRAINT kyc_rejection_consistent CHECK (
    (status = 'rejected' AND rejection_code IS NOT NULL)
    OR (status <> 'rejected' AND rejection_code IS NULL)
  ),
  CONSTRAINT kyc_times_ordered CHECK (verified_at IS NULL OR verified_at >= submitted_at)
);

CREATE UNIQUE INDEX kyc_submitted_identity_uidx
  ON kyc_verifications (id_type, id_number_hash)
  WHERE status IN ('pending', 'verified');
CREATE UNIQUE INDEX kyc_one_pending_per_user_uidx
  ON kyc_verifications (user_id)
  WHERE status = 'pending';
CREATE INDEX kyc_user_history_idx
  ON kyc_verifications (user_id, submitted_at DESC);

CREATE TABLE otp_challenges (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_seq          bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  phone                text NOT NULL CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
  code_hash            text NOT NULL CHECK (code_hash ~ '^[a-f0-9]{64}$'),
  attempts             smallint NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts         smallint NOT NULL DEFAULT 5 CHECK (max_attempts BETWEEN 1 AND 10),
  expires_at           timestamptz NOT NULL,
  resend_after_seconds integer NOT NULL DEFAULT 60
                         CHECK (resend_after_seconds BETWEEN 0 AND 3600),
  consumed_at          timestamptz,
  superseded_at        timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT otp_attempts_within_max CHECK (attempts <= max_attempts),
  CONSTRAINT otp_expiry_after_created CHECK (expires_at > created_at),
  CONSTRAINT otp_consumed_after_created CHECK (consumed_at IS NULL OR consumed_at >= created_at),
  CONSTRAINT otp_superseded_after_created CHECK (superseded_at IS NULL OR superseded_at >= created_at)
);

CREATE INDEX otp_phone_created_idx ON otp_challenges (phone, created_at DESC);
CREATE INDEX otp_expiry_idx ON otp_challenges (expires_at);

CREATE TABLE refresh_tokens (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  token_hash       text NOT NULL UNIQUE CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  family_id        uuid NOT NULL,
  expires_at       timestamptz NOT NULL,
  revoked_at       timestamptz,
  replaced_by_id   uuid REFERENCES refresh_tokens (id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  last_used_at     timestamptz,
  CONSTRAINT refresh_expiry_after_created CHECK (expires_at > created_at),
  CONSTRAINT refresh_revoked_after_created CHECK (revoked_at IS NULL OR revoked_at >= created_at),
  CONSTRAINT refresh_last_used_after_created CHECK (last_used_at IS NULL OR last_used_at >= created_at),
  CONSTRAINT refresh_not_self_replaced CHECK (replaced_by_id IS NULL OR replaced_by_id <> id)
);

CREATE INDEX refresh_family_idx ON refresh_tokens (family_id);
CREATE INDEX refresh_user_idx ON refresh_tokens (user_id, created_at DESC);
CREATE INDEX refresh_expiry_idx ON refresh_tokens (expires_at) WHERE revoked_at IS NULL;

-- Database-backed throttling for deployments without Redis. The key is a
-- hash, never the phone number or account number itself.
CREATE TABLE rate_limit_buckets (
  scope        text NOT NULL CHECK (scope ~ '^[a-z][a-z0-9_.]{1,63}$'),
  key_hash     text NOT NULL CHECK (key_hash ~ '^[a-f0-9]{64}$'),
  window_start timestamptz NOT NULL,
  count        integer NOT NULL DEFAULT 0 CHECK (count >= 0),
  expires_at   timestamptz NOT NULL,
  PRIMARY KEY (scope, key_hash, window_start),
  CONSTRAINT rate_limit_window_ordered CHECK (expires_at > window_start)
);

CREATE INDEX rate_limit_expiry_idx ON rate_limit_buckets (expires_at);

CREATE TRIGGER users_set_updated_at
  BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER kyc_verifications_set_updated_at
  BEFORE UPDATE ON kyc_verifications FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON COLUMN users.kyc_status IS
  'Internal values include not_started. The API only returns pending, verified or rejected; profileComplete gates the pre-KYC state.';
COMMENT ON COLUMN users.limit_currency_code IS
  'Currency of the daily limit shown on Home. Required before a user can be verified.';
COMMENT ON COLUMN kyc_verifications.id_number_encrypted IS
  'Application-level AES-256-GCM ciphertext. The plaintext identifier is never returned or logged.';
COMMENT ON COLUMN kyc_verifications.id_number_hash IS
  'HMAC-SHA-256 used for duplicate detection and lookups without decryption.';
COMMENT ON COLUMN otp_challenges.code_hash IS
  'HMAC-SHA-256 of the one-time code. The plaintext code is never stored.';
COMMENT ON COLUMN refresh_tokens.token_hash IS
  'SHA-256/HMAC hash of the refresh token. Rotation revokes the whole family on reuse.';
