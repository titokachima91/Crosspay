-- 0012_admin_identity.sql
-- Named admin users, TOTP, server-side sessions, challenges and recovery codes.
-- Replaces the shared ADMIN_API_KEY as the primary admin identity.

CREATE TABLE admin_users (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email                  text NOT NULL CHECK (email = lower(email) AND position('@' IN email) > 1),
  name                   text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  password_hash          text NOT NULL,
  totp_secret_encrypted  bytea,
  totp_enrolled_at       timestamptz,
  totp_last_step         bigint NOT NULL DEFAULT 0,
  status                 text NOT NULL DEFAULT 'active'
                           CHECK (status IN ('active', 'suspended')),
  last_login_at          timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX admin_users_email_uidx ON admin_users (email);

CREATE TABLE admin_user_roles (
  admin_user_id uuid NOT NULL REFERENCES admin_users (id) ON DELETE CASCADE,
  role          text NOT NULL
                  CHECK (role IN ('viewer', 'ops', 'finance', 'compliance', 'superadmin')),
  granted_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (admin_user_id, role)
);

CREATE TABLE admin_sessions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id  uuid NOT NULL REFERENCES admin_users (id) ON DELETE CASCADE,
  token_hash     text NOT NULL UNIQUE CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  csrf_token     text NOT NULL CHECK (length(csrf_token) BETWEEN 20 AND 200),
  ip             text,
  user_agent     text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at   timestamptz NOT NULL DEFAULT now(),
  expires_at     timestamptz NOT NULL,
  revoked_at     timestamptz,
  CONSTRAINT admin_session_expiry_after_creation CHECK (expires_at > created_at)
);

CREATE INDEX admin_sessions_user_idx ON admin_sessions (admin_user_id, created_at DESC);
CREATE INDEX admin_sessions_active_idx ON admin_sessions (expires_at)
  WHERE revoked_at IS NULL;

CREATE TABLE admin_login_challenges (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id uuid NOT NULL REFERENCES admin_users (id) ON DELETE CASCADE,
  token_hash    text NOT NULL UNIQUE CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  purpose       text NOT NULL CHECK (purpose IN ('login', 'totp_setup')),
  secret_encrypted bytea,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  consumed_at   timestamptz,
  CONSTRAINT admin_challenge_expiry_after_creation CHECK (expires_at > created_at)
);

CREATE INDEX admin_challenges_user_idx ON admin_login_challenges (admin_user_id, created_at DESC);

CREATE TABLE admin_recovery_codes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id uuid NOT NULL REFERENCES admin_users (id) ON DELETE CASCADE,
  code_hash     text NOT NULL UNIQUE CHECK (code_hash ~ '^[a-f0-9]{64}$'),
  created_at    timestamptz NOT NULL DEFAULT now(),
  used_at       timestamptz
);

CREATE INDEX admin_recovery_codes_user_idx ON admin_recovery_codes (admin_user_id)
  WHERE used_at IS NULL;

CREATE TABLE admin_login_attempts (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email      text,
  ip         text,
  succeeded  boolean NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX admin_login_attempts_email_idx
  ON admin_login_attempts (email, created_at DESC)
  WHERE succeeded = false;
CREATE INDEX admin_login_attempts_ip_idx
  ON admin_login_attempts (ip, created_at DESC)
  WHERE succeeded = false;

ALTER TABLE admin_audit_log
  ADD COLUMN admin_user_id uuid REFERENCES admin_users (id) ON DELETE SET NULL;
CREATE INDEX admin_audit_user_idx ON admin_audit_log (admin_user_id, created_at DESC)
  WHERE admin_user_id IS NOT NULL;

CREATE TRIGGER admin_users_set_updated_at
  BEFORE UPDATE ON admin_users FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE admin_users IS
  'Named admin identities. TOTP secrets are encrypted with the application crypto box.';
COMMENT ON TABLE admin_sessions IS
  'Server-side admin sessions. Only the token hash is stored; cookies are HttpOnly.';
COMMENT ON TABLE admin_login_challenges IS
  'Short-lived password-to-TOTP and TOTP-enrollment challenges.';
COMMENT ON COLUMN admin_audit_log.admin_user_id IS
  'Named admin actor. actor_label remains for Phase A/break-glass actions.';
