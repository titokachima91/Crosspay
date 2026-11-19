-- 0019_trade_invoices.sql
-- Shareable invoice links for a trade. The server issues the token, expiry and
-- the two public URLs; the app never builds or extends an invoice link.
--
-- One invoice exists per trade. The token is encrypted at rest so the owner can
-- fetch the same link again, and hashed for public lookup so a token cannot be
-- recovered from a database index alone.

CREATE TABLE trade_invoices (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trade_id            uuid NOT NULL UNIQUE REFERENCES trades (id) ON DELETE RESTRICT,
  token_hash          text NOT NULL UNIQUE CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  token_encrypted     bytea NOT NULL CHECK (octet_length(token_encrypted) > 0),
  amount_minor        bigint NOT NULL CHECK (amount_minor > 0),
  currency_code       char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  created_by_user_id  uuid NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  valid_until         timestamptz NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT invoice_expiry_after_created CHECK (valid_until > created_at)
);

CREATE INDEX trade_invoices_expiry_idx ON trade_invoices (valid_until);

COMMENT ON TABLE trade_invoices IS
  'One share link per trade. Evidence only: an invoice never moves money or changes trade status.';
COMMENT ON COLUMN trade_invoices.token_hash IS
  'SHA-256 of the random share token, used for public lookup.';
COMMENT ON COLUMN trade_invoices.token_encrypted IS
  'AES-256-GCM ciphertext, so the owner can fetch the same link again.';
