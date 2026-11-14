-- 0003_recipients_trading.sql
-- Saved recipients, quotes, quote route snapshots, trades and their immutable
-- timeline. Financial amounts are always integer minor units.

CREATE TABLE beneficiaries (
  id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                    uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  rail_id                    text NOT NULL REFERENCES payout_rails (id) ON DELETE RESTRICT,
  name                       text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  account_or_phone_encrypted bytea NOT NULL CHECK (octet_length(account_or_phone_encrypted) > 0),
  account_last4              text NOT NULL CHECK (account_last4 ~ '^[A-Za-z0-9]{1,4}$'),
  account_hash               text NOT NULL CHECK (account_hash ~ '^[a-f0-9]{64}$'),
  name_verified              boolean NOT NULL DEFAULT false,
  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now(),
  deleted_at                 timestamptz,
  CONSTRAINT beneficiary_deleted_after_created CHECK (
    deleted_at IS NULL OR deleted_at >= created_at
  )
);

CREATE UNIQUE INDEX beneficiaries_active_destination_uidx
  ON beneficiaries (user_id, rail_id, account_hash)
  WHERE deleted_at IS NULL;
CREATE INDEX beneficiaries_user_active_idx
  ON beneficiaries (user_id, created_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE quotes (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  send_currency      char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  receive_currency   char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  send_amount_minor  bigint NOT NULL CHECK (send_amount_minor > 0),
  rate               numeric(20, 10) NOT NULL CHECK (rate > 0),
  quoted_at          timestamptz NOT NULL DEFAULT now(),
  expires_at         timestamptz NOT NULL,
  status             text NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active', 'consumed', 'expired', 'cancelled')),
  consumed_at        timestamptz,
  cancelled_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT quote_distinct_currencies CHECK (send_currency <> receive_currency),
  CONSTRAINT quote_expiry_after_quoted CHECK (expires_at > quoted_at),
  CONSTRAINT quote_consumed_consistent CHECK (
    (status = 'consumed' AND consumed_at IS NOT NULL)
    OR (status <> 'consumed' AND consumed_at IS NULL)
  ),
  CONSTRAINT quote_cancelled_consistent CHECK (
    (status = 'cancelled' AND cancelled_at IS NOT NULL)
    OR (status <> 'cancelled' AND cancelled_at IS NULL)
  ),
  CONSTRAINT quote_consumed_after_quoted CHECK (consumed_at IS NULL OR consumed_at >= quoted_at)
);

CREATE INDEX quotes_user_expiry_idx ON quotes (user_id, expires_at DESC);
CREATE INDEX quotes_expiry_worker_idx ON quotes (expires_at) WHERE status = 'active';

CREATE TABLE quote_routes (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_id                 uuid NOT NULL REFERENCES quotes (id) ON DELETE CASCADE,
  route                    text NOT NULL CHECK (route IN ('p2p', 'bank')),
  fee_bps                  integer NOT NULL CHECK (fee_bps BETWEEN 0 AND 10000),
  fee_minor                bigint NOT NULL CHECK (fee_minor >= 0),
  payout_minor             bigint NOT NULL CHECK (payout_minor > 0),
  total_debit_minor        bigint NOT NULL CHECK (total_debit_minor > 0),
  estimated_min_seconds    integer NOT NULL CHECK (estimated_min_seconds > 0),
  estimated_max_seconds    integer NOT NULL CHECK (estimated_max_seconds > 0),
  is_recommended           boolean NOT NULL DEFAULT false,
  is_available             boolean NOT NULL DEFAULT true,
  matching_density_percent smallint CHECK (matching_density_percent BETWEEN 0 AND 100),
  status_code              text CHECK (status_code IS NULL
                                       OR status_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  status_level             text CHECK (status_level IS NULL
                                       OR status_level IN ('healthy', 'limited', 'down')),
  safeguard_code           text CHECK (safeguard_code IS NULL
                                       OR safeguard_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  fee_breakdown            jsonb NOT NULL DEFAULT '[]'::jsonb
                             CHECK (jsonb_typeof(fee_breakdown) = 'array'),
  created_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT quote_route_unique UNIQUE (quote_id, route),
  CONSTRAINT quote_route_estimate_ordered CHECK (estimated_max_seconds >= estimated_min_seconds),
  CONSTRAINT quote_route_total_covers_fee CHECK (total_debit_minor >= fee_minor),
  CONSTRAINT quote_route_unavailable_has_no_recommendation CHECK (
    is_available OR NOT is_recommended
  )
);

CREATE UNIQUE INDEX quote_routes_one_recommended_idx
  ON quote_routes (quote_id) WHERE is_recommended;
CREATE UNIQUE INDEX quote_routes_id_quote_uidx ON quote_routes (id, quote_id);

CREATE TABLE trades (
  id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reference                     text NOT NULL UNIQUE
                                  CHECK (reference ~ '^[A-Z0-9][A-Z0-9-]{5,31}$'),
  user_id                       uuid NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  quote_id                      uuid NOT NULL UNIQUE REFERENCES quotes (id) ON DELETE RESTRICT,
  quote_route_id                uuid NOT NULL REFERENCES quote_routes (id) ON DELETE RESTRICT,
  route                         text NOT NULL CHECK (route IN ('p2p', 'bank')),
  status                        text NOT NULL
                                  CHECK (status IN ('pending_deposit', 'escrowed', 'matching',
                                                    'matched', 'disbursing', 'completed',
                                                    'expired', 'refunded', 'failed', 'cancelled')),
  send_currency                 char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  receive_currency              char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  send_amount_minor             bigint NOT NULL CHECK (send_amount_minor > 0),
  fee_minor                     bigint NOT NULL CHECK (fee_minor >= 0),
  fee_bps                       integer NOT NULL CHECK (fee_bps BETWEEN 0 AND 10000),
  receive_amount_minor          bigint NOT NULL CHECK (receive_amount_minor > 0),
  rate                          numeric(20, 10) NOT NULL CHECK (rate > 0),
  beneficiary_name              text NOT NULL CHECK (length(btrim(beneficiary_name)) BETWEEN 1 AND 200),
  beneficiary_rail_id           text NOT NULL REFERENCES payout_rails (id) ON DELETE RESTRICT,
  beneficiary_account_encrypted bytea NOT NULL CHECK (octet_length(beneficiary_account_encrypted) > 0),
  beneficiary_account_last4     text NOT NULL CHECK (beneficiary_account_last4 ~ '^[A-Za-z0-9]{1,4}$'),
  beneficiary_reference         text CHECK (beneficiary_reference IS NULL
                                            OR length(btrim(beneficiary_reference)) BETWEEN 1 AND 120),
  verification_hash             text CHECK (verification_hash IS NULL
                                            OR verification_hash ~ '^[a-f0-9]{64}$'),
  current_payment_attempt_id    uuid,
  failure_code                  text CHECK (failure_code IS NULL
                                            OR failure_code ~ '^[A-Z][A-Z0-9_]{1,63}$'),
  created_at                    timestamptz NOT NULL DEFAULT now(),
  updated_at                    timestamptz NOT NULL DEFAULT now(),
  completed_at                  timestamptz,
  cancelled_at                  timestamptz,
  CONSTRAINT trade_distinct_currencies CHECK (send_currency <> receive_currency),
  CONSTRAINT trade_completed_after_created CHECK (completed_at IS NULL OR completed_at >= created_at),
  CONSTRAINT trade_cancelled_after_created CHECK (cancelled_at IS NULL OR cancelled_at >= created_at),
  CONSTRAINT trade_route_belongs_to_quote FOREIGN KEY (quote_route_id, quote_id)
    REFERENCES quote_routes (id, quote_id) ON DELETE RESTRICT
);

CREATE INDEX trades_user_created_idx ON trades (user_id, created_at DESC);
CREATE INDEX trades_status_created_idx ON trades (status, created_at DESC);
CREATE INDEX trades_current_attempt_idx ON trades (current_payment_attempt_id)
  WHERE current_payment_attempt_id IS NOT NULL;

CREATE TABLE trade_events (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  trade_id   uuid NOT NULL REFERENCES trades (id) ON DELETE RESTRICT,
  status     text NOT NULL
               CHECK (status IN ('pending_deposit', 'escrowed', 'matching', 'matched',
                                 'disbursing', 'completed', 'expired', 'refunded',
                                 'failed', 'cancelled')),
  at         timestamptz NOT NULL DEFAULT now(),
  note_code  text CHECK (note_code IS NULL OR note_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  actor      text NOT NULL DEFAULT 'system'
               CHECK (actor IN ('server', 'provider', 'user', 'system')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX trade_events_timeline_idx ON trade_events (trade_id, at, id);

CREATE TABLE payment_attempts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trade_id              uuid NOT NULL REFERENCES trades (id) ON DELETE RESTRICT,
  provider              text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_]{1,63}$'),
  external_reference    text,
  method                text NOT NULL CHECK (method IN ('push', 'manual')),
  amount_minor          bigint NOT NULL CHECK (amount_minor > 0),
  currency_code         char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  push_sent             boolean NOT NULL DEFAULT false,
  network_name          text,
  push_timeout_seconds  integer CHECK (push_timeout_seconds IS NULL OR push_timeout_seconds > 0),
  poll_interval_seconds integer CHECK (poll_interval_seconds IS NULL OR poll_interval_seconds > 0),
  manual_method_code    text CHECK (manual_method_code IS NULL
                                    OR manual_method_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  manual_number         text,
  manual_reference      text,
  status                text NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'sent', 'confirmed', 'failed', 'expired')),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payment_attempt_manual_fields CHECK (
    method <> 'manual' OR manual_method_code IS NOT NULL
  )
);

CREATE UNIQUE INDEX payment_attempts_provider_reference_uidx
  ON payment_attempts (provider, external_reference)
  WHERE external_reference IS NOT NULL;
CREATE INDEX payment_attempts_trade_idx ON payment_attempts (trade_id, created_at DESC);

ALTER TABLE trades
  ADD CONSTRAINT trades_current_payment_attempt_fk
  FOREIGN KEY (current_payment_attempt_id) REFERENCES payment_attempts (id)
  ON DELETE SET NULL
  DEFERRABLE INITIALLY DEFERRED;

CREATE TRIGGER trades_set_updated_at
  BEFORE UPDATE ON trades FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER payment_attempts_set_updated_at
  BEFORE UPDATE ON payment_attempts FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER beneficiaries_set_updated_at
  BEFORE UPDATE ON beneficiaries FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- The timeline is written by the database, not by a caller who might forget.
-- A transaction may set crosspay.actor to server/provider/user; otherwise the
-- event is recorded as system.
CREATE FUNCTION record_trade_status_event()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor_value text;
BEGIN
  actor_value := COALESCE(NULLIF(current_setting('crosspay.actor', true), ''), 'system');

  IF TG_OP = 'INSERT' THEN
    INSERT INTO trade_events (trade_id, status, at, actor)
    VALUES (NEW.id, NEW.status, NEW.created_at, actor_value);
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO trade_events (trade_id, status, at, actor)
    VALUES (NEW.id, NEW.status, now(), actor_value);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trades_record_status_event
  AFTER INSERT OR UPDATE OF status ON trades
  FOR EACH ROW EXECUTE FUNCTION record_trade_status_event();

COMMENT ON TABLE beneficiaries IS
  'Saved recipients. account_or_phone is encrypted; only the owner may read it.';
COMMENT ON COLUMN beneficiaries.name_verified IS
  'Destination name check result, mapped to kycVerified in the API. It is not full KYC of the recipient.';
COMMENT ON TABLE quotes IS
  'Server-issued rate locks. A quote is user-bound, expires on the server clock and is consumed once.';
COMMENT ON TABLE quote_routes IS
  'Immutable route snapshots returned by /trade/quote.';
COMMENT ON TABLE trades IS
  'Current trade state plus an immutable price and recipient snapshot. Money display never re-reads the quote.';
COMMENT ON TABLE trade_events IS
  'Append-only timeline written by the trades trigger. Never rewritten.';
COMMENT ON COLUMN trades.beneficiary_account_encrypted IS
  'Encrypted destination snapshot. A later recipient edit cannot change this trade.';
COMMENT ON COLUMN trades.beneficiary_reference IS
  'Optional payer reference, encrypted at rest when it contains personal data.';
