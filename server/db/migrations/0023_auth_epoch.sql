-- 0023_auth_epoch.sql
-- One active session per account. A successful OTP verification increments the
-- user's epoch; access tokens carry the epoch they were issued under, and the
-- auth hook rejects a token whose epoch is stale. Refresh families are revoked
-- in the same transaction, so the old device cannot obtain a new access token.

ALTER TABLE users
  ADD COLUMN auth_epoch integer NOT NULL DEFAULT 0 CHECK (auth_epoch >= 0);

COMMENT ON COLUMN users.auth_epoch IS
  'Incremented on every new sign-in. Access tokens with an older epoch are rejected.';
