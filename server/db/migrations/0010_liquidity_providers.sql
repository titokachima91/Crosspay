-- 0010_liquidity_providers.sql
-- Pre-funded liquidity providers, standing orders, corridor amount bounds,
-- exposure read model and LP traceability on journal transactions.

ALTER TABLE p2p_corridors
  ADD COLUMN min_amount_minor bigint
    CHECK (min_amount_minor IS NULL OR min_amount_minor >= 0);
ALTER TABLE p2p_corridors
  ADD COLUMN max_amount_minor bigint
    CHECK (max_amount_minor IS NULL OR max_amount_minor > 0);
ALTER TABLE p2p_corridors
  ADD CONSTRAINT p2p_corridor_amount_bounds CHECK (
    min_amount_minor IS NULL
    OR max_amount_minor IS NULL
    OR min_amount_minor < max_amount_minor
  );

CREATE TABLE liquidity_providers (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL UNIQUE CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  status     text NOT NULL DEFAULT 'active'
               CHECK (status IN ('active', 'suspended')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE liquidity_orders (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id        uuid NOT NULL REFERENCES liquidity_providers (id) ON DELETE RESTRICT,
  provide_currency   char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  receive_currency   char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  capacity_minor     bigint NOT NULL CHECK (capacity_minor > 0),
  remaining_minor    bigint NOT NULL CHECK (remaining_minor >= 0),
  min_amount_minor   bigint NOT NULL DEFAULT 0 CHECK (min_amount_minor >= 0),
  max_amount_minor   bigint NOT NULL CHECK (max_amount_minor > 0),
  -- receive_currency units per one provide_currency unit.
  rate               numeric(20, 10) NOT NULL CHECK (rate > 0),
  status             text NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active', 'depleted', 'expired', 'cancelled')),
  prefund_reference  text CHECK (prefund_reference IS NULL
                                 OR length(btrim(prefund_reference)) BETWEEN 1 AND 200),
  prefunded_at       timestamptz,
  expires_at         timestamptz NOT NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT liquidity_order_distinct_currencies CHECK (provide_currency <> receive_currency),
  CONSTRAINT liquidity_order_remaining_within_capacity CHECK (remaining_minor <= capacity_minor),
  CONSTRAINT liquidity_order_amount_bounds CHECK (
    min_amount_minor < max_amount_minor
    AND max_amount_minor <= capacity_minor
  ),
  CONSTRAINT liquidity_order_expiry_after_creation CHECK (expires_at > created_at),
  CONSTRAINT liquidity_order_prefund_consistent CHECK (
    (prefunded_at IS NULL) = (prefund_reference IS NULL)
  )
);

CREATE INDEX liquidity_orders_lookup_idx
  ON liquidity_orders (provide_currency, receive_currency, status, rate, expires_at);
CREATE INDEX liquidity_orders_provider_idx ON liquidity_orders (provider_id, status);

ALTER TABLE p2p_matches
  ADD COLUMN liquidity_order_id uuid
    REFERENCES liquidity_orders (id) ON DELETE RESTRICT;
ALTER TABLE p2p_matches
  ADD COLUMN liquidity_released_at timestamptz;
ALTER TABLE p2p_matches
  ALTER COLUMN sell_trade_id DROP NOT NULL;
ALTER TABLE p2p_matches
  ADD CONSTRAINT p2p_one_counterparty CHECK (
    (sell_trade_id IS NOT NULL) <> (liquidity_order_id IS NOT NULL)
  );

-- A funded trade can be the buy side of exactly one active match. LP matches
-- have no sell trade; organic matches still enforce one sell trade per match.
CREATE UNIQUE INDEX p2p_matches_active_buy_uidx
  ON p2p_matches (buy_trade_id)
  WHERE status IN ('proposed', 'locked');
CREATE UNIQUE INDEX p2p_matches_active_sell_uidx
  ON p2p_matches (sell_trade_id)
  WHERE sell_trade_id IS NOT NULL AND status IN ('proposed', 'locked');

ALTER TABLE journal_transactions
  ADD COLUMN liquidity_provider_id uuid
    REFERENCES liquidity_providers (id) ON DELETE RESTRICT;
CREATE INDEX journal_transactions_lp_idx
  ON journal_transactions (liquidity_provider_id, occurred_at)
  WHERE liquidity_provider_id IS NOT NULL;

CREATE VIEW p2p_corridor_exposure AS
SELECT c.send_currency,
       c.receive_currency,
       c.enabled,
       c.exposure_cap_minor,
       c.min_amount_minor,
       c.max_amount_minor,
       c.estimated_settle_seconds,
       c.match_deadline_seconds,
       c.spread_bps,
       COALESCE(sum(t.send_amount_minor), 0)::bigint AS open_send_minor,
       count(t.id)::integer AS open_trades,
       CASE
         WHEN c.exposure_cap_minor IS NULL THEN NULL
         ELSE greatest(0, c.exposure_cap_minor - COALESCE(sum(t.send_amount_minor), 0))
       END::bigint AS available_send_minor
FROM p2p_corridors c
LEFT JOIN trades t
  ON t.send_currency = c.send_currency
 AND t.receive_currency = c.receive_currency
 AND t.status IN ('escrowed', 'matching', 'matched', 'disbursing')
GROUP BY c.send_currency, c.receive_currency, c.enabled, c.exposure_cap_minor,
         c.min_amount_minor, c.max_amount_minor, c.estimated_settle_seconds,
         c.match_deadline_seconds, c.spread_bps;

CREATE TRIGGER liquidity_providers_set_updated_at
  BEFORE UPDATE ON liquidity_providers FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER liquidity_orders_set_updated_at
  BEFORE UPDATE ON liquidity_orders FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE liquidity_providers IS
  'Allowlisted, pre-funded P2P liquidity providers. No public onboarding.';
COMMENT ON TABLE liquidity_orders IS
  'Standing orders. remaining_minor is the prefunded provide-currency capacity not yet consumed.';
COMMENT ON COLUMN liquidity_orders.rate IS
  'receive_currency minor units per one provide_currency minor unit. The platform checks the customer send amount covers it.';
COMMENT ON VIEW p2p_corridor_exposure IS
  'Ops read model. Exposure is the sum of the corridor send amounts still capable of moving money.';
COMMENT ON COLUMN journal_transactions.liquidity_provider_id IS
  'Set on journals that settle with an LP, so every LP position is traceable per trade.';
