-- 0005_financial_operations.sql
-- Provider callbacks and operational payment records. These tables are created
-- in B1 because the ledger references them; their behaviour belongs to B2/B3.

CREATE TABLE payment_events (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider            text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_]{1,63}$'),
  provider_event_id   text NOT NULL CHECK (length(btrim(provider_event_id)) BETWEEN 1 AND 200),
  event_type          text NOT NULL CHECK (event_type ~ '^[a-z][a-z0-9_.]{1,63}$'),
  trade_id            uuid REFERENCES trades (id) ON DELETE RESTRICT,
  payment_attempt_id  uuid REFERENCES payment_attempts (id) ON DELETE RESTRICT,
  signature_verified  boolean NOT NULL DEFAULT false,
  payload_hash        text NOT NULL CHECK (payload_hash ~ '^[a-f0-9]{64}$'),
  payload             jsonb NOT NULL DEFAULT '{}'::jsonb
                        CHECK (jsonb_typeof(payload) = 'object'),
  status              text NOT NULL DEFAULT 'received'
                        CHECK (status IN ('received', 'processed', 'ignored', 'failed')),
  received_at         timestamptz NOT NULL DEFAULT now(),
  processed_at        timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payment_event_processed_consistent CHECK (
    (status = 'processed' AND processed_at IS NOT NULL)
    OR (status <> 'processed' AND processed_at IS NULL)
  ),
  CONSTRAINT payment_event_unique_provider_id UNIQUE (provider, provider_event_id),
  CONSTRAINT payment_event_processed_after_received CHECK (
    processed_at IS NULL OR processed_at >= received_at
  )
);

CREATE INDEX payment_events_trade_idx ON payment_events (trade_id, received_at DESC);
CREATE INDEX payment_events_status_idx ON payment_events (status, received_at);

CREATE TABLE payouts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trade_id          uuid NOT NULL REFERENCES trades (id) ON DELETE RESTRICT,
  provider          text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_]{1,63}$'),
  provider_reference text,
  amount_minor      bigint NOT NULL CHECK (amount_minor > 0),
  currency_code     char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  status            text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'submitted', 'paid', 'failed', 'cancelled')),
  attempt_count     integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_error_code   text CHECK (last_error_code IS NULL
                                OR last_error_code ~ '^[A-Z][A-Z0-9_]{1,63}$'),
  requested_at      timestamptz NOT NULL DEFAULT now(),
  completed_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payout_completed_consistent CHECK (
    (status IN ('paid', 'failed', 'cancelled') AND completed_at IS NOT NULL)
    OR (status IN ('pending', 'submitted') AND completed_at IS NULL)
  ),
  CONSTRAINT payout_completed_after_requested CHECK (
    completed_at IS NULL OR completed_at >= requested_at
  )
);

CREATE UNIQUE INDEX payouts_provider_reference_uidx
  ON payouts (provider, provider_reference)
  WHERE provider_reference IS NOT NULL;
CREATE INDEX payouts_trade_idx ON payouts (trade_id, created_at DESC);
CREATE INDEX payouts_status_idx ON payouts (status, requested_at);

CREATE TABLE refunds (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trade_id           uuid NOT NULL REFERENCES trades (id) ON DELETE RESTRICT,
  payment_event_id   uuid REFERENCES payment_events (id) ON DELETE RESTRICT,
  amount_minor       bigint NOT NULL CHECK (amount_minor > 0),
  currency_code      char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  reason_code        text NOT NULL CHECK (reason_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  provider           text CHECK (provider IS NULL
                                 OR provider ~ '^[a-z][a-z0-9_]{1,63}$'),
  provider_reference text,
  status             text NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending', 'submitted', 'paid', 'failed', 'cancelled')),
  requested_at       timestamptz NOT NULL DEFAULT now(),
  completed_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT refund_completed_consistent CHECK (
    (status IN ('paid', 'failed', 'cancelled') AND completed_at IS NOT NULL)
    OR (status IN ('pending', 'submitted') AND completed_at IS NULL)
  ),
  CONSTRAINT refund_completed_after_requested CHECK (
    completed_at IS NULL OR completed_at >= requested_at
  ),
  CONSTRAINT refund_provider_reference_requires_provider CHECK (
    provider_reference IS NULL OR provider IS NOT NULL
  )
);

CREATE UNIQUE INDEX refunds_provider_reference_uidx
  ON refunds (provider, provider_reference)
  WHERE provider_reference IS NOT NULL;
CREATE INDEX refunds_trade_idx ON refunds (trade_id, created_at DESC);
CREATE INDEX refunds_status_idx ON refunds (status, requested_at);

CREATE TABLE p2p_matches (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  buy_trade_id       uuid NOT NULL REFERENCES trades (id) ON DELETE RESTRICT,
  sell_trade_id      uuid NOT NULL REFERENCES trades (id) ON DELETE RESTRICT,
  buy_amount_minor   bigint NOT NULL CHECK (buy_amount_minor > 0),
  sell_amount_minor  bigint NOT NULL CHECK (sell_amount_minor > 0),
  buy_currency       char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  sell_currency      char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  status             text NOT NULL DEFAULT 'proposed'
                       CHECK (status IN ('proposed', 'locked', 'released', 'cancelled', 'failed')),
  matched_at         timestamptz,
  released_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT p2p_distinct_trades CHECK (buy_trade_id <> sell_trade_id),
  CONSTRAINT p2p_times_ordered CHECK (
    released_at IS NULL OR matched_at IS NULL OR released_at >= matched_at
  ),
  CONSTRAINT p2p_status_times CHECK (
    (status = 'proposed' AND matched_at IS NULL)
    OR (status <> 'proposed' AND matched_at IS NOT NULL)
  ),
  CONSTRAINT p2p_unique_pair UNIQUE (buy_trade_id, sell_trade_id)
);

CREATE INDEX p2p_matches_buy_idx ON p2p_matches (buy_trade_id, created_at DESC);
CREATE INDEX p2p_matches_sell_idx ON p2p_matches (sell_trade_id, created_at DESC);
CREATE INDEX p2p_matches_status_idx ON p2p_matches (status, created_at);

CREATE TRIGGER payouts_set_updated_at
  BEFORE UPDATE ON payouts FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER refunds_set_updated_at
  BEFORE UPDATE ON refunds FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER p2p_matches_set_updated_at
  BEFORE UPDATE ON p2p_matches FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE payment_events IS
  'Verified provider callbacks. provider_event_id is unique so a retried webhook cannot be processed twice.';
COMMENT ON COLUMN payment_events.payload IS
  'Minimal, redacted payload. Never store full customer PII or card data.';
COMMENT ON TABLE p2p_matches IS
  'Scaffolding for B3. Queue depth is derived from open trades until the matching engine is approved.';
