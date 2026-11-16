-- 0008_p2p_matching.sql
-- Funded-trade P2P matching: corridor policy, match audit events, settlement
-- and compensation journal kinds, and the queue index.

ALTER TABLE p2p_matches
  ADD COLUMN match_rate numeric(20, 10)
    CHECK (match_rate IS NULL OR match_rate > 0);

ALTER TABLE trades
  ADD COLUMN match_deadline_at timestamptz;

CREATE INDEX trades_match_queue_idx
  ON trades (send_currency, receive_currency, created_at)
  WHERE status = 'escrowed';

CREATE TABLE p2p_corridors (
  send_currency          char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  receive_currency       char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  enabled                boolean NOT NULL DEFAULT false,
  exposure_cap_minor     bigint CHECK (exposure_cap_minor IS NULL OR exposure_cap_minor > 0),
  match_deadline_seconds integer NOT NULL DEFAULT 600
                           CHECK (match_deadline_seconds BETWEEN 30 AND 86400),
  spread_bps             integer NOT NULL DEFAULT 0
                           CHECK (spread_bps BETWEEN 0 AND 10000),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (send_currency, receive_currency),
  CONSTRAINT p2p_corridor_distinct_currencies CHECK (send_currency <> receive_currency),
  CONSTRAINT p2p_corridor_enabled_needs_cap CHECK (
    NOT enabled OR exposure_cap_minor IS NOT NULL
  )
);

CREATE TABLE p2p_match_events (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  match_id   uuid NOT NULL REFERENCES p2p_matches (id) ON DELETE RESTRICT,
  event      text NOT NULL CHECK (event ~ '^[a-z][a-z0-9_]{1,63}$'),
  note_code  text CHECK (note_code IS NULL OR note_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  actor      text NOT NULL DEFAULT 'system'
               CHECK (actor IN ('server', 'provider', 'user', 'system')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX p2p_match_events_match_idx ON p2p_match_events (match_id, created_at, id);

CREATE TRIGGER p2p_corridors_set_updated_at
  BEFORE UPDATE ON p2p_corridors FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE journal_transactions
  DROP CONSTRAINT journal_transactions_kind_check;
ALTER TABLE journal_transactions
  ADD CONSTRAINT journal_transactions_kind_check
  CHECK (kind IN ('deposit_received', 'fee_earned', 'payout_sent',
                  'refund_paid', 'fx_conversion', 'p2p_settlement',
                  'p2p_compensation', 'adjustment', 'opening_balance'));

COMMENT ON TABLE p2p_corridors IS
  'Corridor policy. Matching is off unless a row is enabled with an exposure cap.';
COMMENT ON COLUMN p2p_corridors.spread_bps IS
  'Provisional policy value, not a production price. The customer quote owns the rate.';
COMMENT ON TABLE p2p_match_events IS
  'Append-only match audit trail. Counterparty identity is never exposed by the API.';
COMMENT ON COLUMN trades.match_deadline_at IS
  'When an unmatched escrowed trade expires. Set from the corridor policy at escrow.';
