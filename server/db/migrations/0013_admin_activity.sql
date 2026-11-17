-- 0013_admin_activity.sql
-- Durable admin activity outbox for the real-time control room.
--
-- Rows are written by database triggers, not application code, so every
-- process (API, worker, support tools) feeds the same stream. The admin portal
-- reads the table for catch-up and LISTENs on `admin_activity` for live push.
-- The table is append-only: an operator cannot rewrite history.

CREATE TABLE admin_activity_events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source      text NOT NULL
                CHECK (source IN ('trade', 'match', 'payout', 'refund',
                                  'admin', 'liquidity', 'ledger', 'support')),
  event_type  text NOT NULL CHECK (event_type ~ '^[a-z][a-z0-9_.-]{1,63}$'),
  severity    text NOT NULL DEFAULT 'info'
                CHECK (severity IN ('info', 'warning', 'critical')),
  trade_id    uuid REFERENCES trades (id) ON DELETE SET NULL,
  reference   text,
  actor_label text,
  summary     text NOT NULL CHECK (length(summary) BETWEEN 1 AND 300),
  payload     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX admin_activity_created_idx
  ON admin_activity_events (created_at DESC, id DESC);
CREATE INDEX admin_activity_id_idx ON admin_activity_events (id);
CREATE INDEX admin_activity_source_idx
  ON admin_activity_events (source, created_at DESC);
CREATE INDEX admin_activity_trade_idx
  ON admin_activity_events (trade_id, created_at DESC)
  WHERE trade_id IS NOT NULL;

CREATE FUNCTION admin_activity_severity(status text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN status IN ('failed', 'cancelled', 'expired') THEN 'warning'
    ELSE 'info'
  END;
$$;

CREATE FUNCTION notify_admin_activity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_notify('admin_activity', NEW.id::text);
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_notify
  AFTER INSERT ON admin_activity_events
  FOR EACH ROW EXECUTE FUNCTION notify_admin_activity();

CREATE FUNCTION reject_admin_activity_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'admin_activity_events is append-only';
END;
$$;

CREATE TRIGGER admin_activity_append_only
  BEFORE UPDATE OR DELETE ON admin_activity_events
  FOR EACH ROW EXECUTE FUNCTION reject_admin_activity_mutation();

-- Trade status changes already have an append-only timeline; mirror it.
CREATE FUNCTION admin_activity_from_trade_event()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  trade_reference text;
BEGIN
  SELECT reference INTO trade_reference FROM trades WHERE id = NEW.trade_id;
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('trade',
     'trade.' || NEW.status,
     admin_activity_severity(NEW.status),
     NEW.trade_id,
     trade_reference,
     NEW.actor,
     left('Trade ' || COALESCE(trade_reference, NEW.trade_id::text) || ' → ' || NEW.status, 300),
     jsonb_build_object('status', NEW.status, 'actor', NEW.actor, 'noteCode', NEW.note_code),
     NEW.created_at);
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_trade_event
  AFTER INSERT ON trade_events
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_trade_event();

CREATE FUNCTION admin_activity_from_payout()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  trade_reference text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;
  SELECT reference INTO trade_reference FROM trades WHERE id = NEW.trade_id;
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('payout',
     'payout.' || NEW.status,
     admin_activity_severity(NEW.status),
     NEW.trade_id,
     trade_reference,
     NEW.provider,
     left('Payout ' || NEW.currency_code || ' ' || NEW.amount_minor::text || ' minor · ' ||
          COALESCE(trade_reference, '') || ' · ' || NEW.status, 300),
     jsonb_build_object('status', NEW.status, 'provider', NEW.provider,
                        'currency', NEW.currency_code, 'amountMinor', NEW.amount_minor,
                        'providerReference', NEW.provider_reference),
     COALESCE(NEW.completed_at, NEW.requested_at));
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_payout_insert
  AFTER INSERT ON payouts
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_payout();
CREATE TRIGGER admin_activity_payout_status
  AFTER UPDATE OF status ON payouts
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_payout();

CREATE FUNCTION admin_activity_from_refund()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  trade_reference text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;
  SELECT reference INTO trade_reference FROM trades WHERE id = NEW.trade_id;
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('refund',
     'refund.' || NEW.status,
     admin_activity_severity(NEW.status),
     NEW.trade_id,
     trade_reference,
     NEW.reason_code,
     left('Refund ' || NEW.currency_code || ' ' || NEW.amount_minor::text || ' minor · ' ||
          COALESCE(trade_reference, '') || ' · ' || NEW.status, 300),
     jsonb_build_object('status', NEW.status, 'reasonCode', NEW.reason_code,
                        'currency', NEW.currency_code, 'amountMinor', NEW.amount_minor,
                        'provider', NEW.provider),
     COALESCE(NEW.completed_at, NEW.requested_at));
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_refund_insert
  AFTER INSERT ON refunds
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_refund();
CREATE TRIGGER admin_activity_refund_status
  AFTER UPDATE OF status ON refunds
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_refund();

CREATE FUNCTION admin_activity_from_match()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('match',
     'match.' || NEW.status,
     admin_activity_severity(NEW.status),
     NEW.buy_trade_id,
     NULL,
     CASE WHEN NEW.liquidity_order_id IS NULL THEN 'p2p' ELSE 'liquidity_provider' END,
     left('Match ' || NEW.buy_currency || '→' || NEW.sell_currency || ' ' || NEW.status ||
          ' · buy ' || NEW.buy_amount_minor::text || ' / sell ' ||
          NEW.sell_amount_minor::text || ' minor', 300),
     jsonb_build_object('status', NEW.status,
                        'buyCurrency', NEW.buy_currency, 'sellCurrency', NEW.sell_currency,
                        'buyAmountMinor', NEW.buy_amount_minor,
                        'sellAmountMinor', NEW.sell_amount_minor,
                        'liquidityOrderId', NEW.liquidity_order_id),
     COALESCE(NEW.released_at, NEW.matched_at, NEW.created_at));
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_match_insert
  AFTER INSERT ON p2p_matches
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_match();
CREATE TRIGGER admin_activity_match_status
  AFTER UPDATE OF status ON p2p_matches
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_match();

CREATE FUNCTION admin_activity_from_liquidity_order()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('liquidity',
     'liquidity.' || NEW.status,
     admin_activity_severity(NEW.status),
     NULL,
     NEW.prefund_reference,
     NEW.provider_id::text,
     left('LP order ' || NEW.provide_currency || '→' || NEW.receive_currency || ' ' ||
          NEW.status || ' · remaining ' || NEW.remaining_minor::text || ' minor', 300),
     jsonb_build_object('status', NEW.status,
                        'provideCurrency', NEW.provide_currency,
                        'receiveCurrency', NEW.receive_currency,
                        'capacityMinor', NEW.capacity_minor,
                        'remainingMinor', NEW.remaining_minor),
     NEW.created_at);
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_liquidity_order_insert
  AFTER INSERT ON liquidity_orders
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_liquidity_order();
CREATE TRIGGER admin_activity_liquidity_order_status
  AFTER UPDATE OF status ON liquidity_orders
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_liquidity_order();

CREATE FUNCTION admin_activity_from_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('admin',
     left(NEW.action, 64),
     'info',
     NULL,
     NEW.resource_id,
     NEW.actor_label,
     left('Admin ' || NEW.actor_label || ' · ' || NEW.action || ' · ' ||
          NEW.resource_type || COALESCE(' ' || NEW.resource_id, ''), 300),
     jsonb_build_object('action', NEW.action, 'resourceType', NEW.resource_type,
                        'resourceId', NEW.resource_id),
     NEW.created_at);
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_audit
  AFTER INSERT ON admin_audit_log
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_audit();

-- Backfill a short window so the control room is not empty straight after the
-- migration. Older history remains in the source tables and trade timeline.
INSERT INTO admin_activity_events
  (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
SELECT 'trade', 'trade.' || s.status, admin_activity_severity(s.status),
       s.trade_id, s.reference, s.actor,
       left('Trade ' || COALESCE(s.reference, s.trade_id::text) || ' → ' || s.status, 300),
       jsonb_build_object('status', s.status, 'actor', s.actor, 'noteCode', s.note_code),
       s.created_at
FROM (
  SELECT te.status, te.trade_id, t.reference, te.actor, te.note_code, te.created_at
  FROM trade_events te JOIN trades t ON t.id = te.trade_id
  WHERE te.created_at > now() - interval '7 days'
  ORDER BY te.created_at DESC, te.id DESC
  LIMIT 500
) s;

INSERT INTO admin_activity_events
  (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
SELECT 'payout', 'payout.' || s.status, admin_activity_severity(s.status),
       s.trade_id, s.reference, s.provider,
       left('Payout ' || s.currency_code || ' ' || s.amount_minor::text || ' minor · ' ||
            COALESCE(s.reference, '') || ' · ' || s.status, 300),
       jsonb_build_object('status', s.status, 'provider', s.provider,
                          'currency', s.currency_code, 'amountMinor', s.amount_minor),
       COALESCE(s.completed_at, s.requested_at)
FROM (
  SELECT p.*, t.reference FROM payouts p JOIN trades t ON t.id = p.trade_id
  WHERE p.requested_at > now() - interval '7 days'
  ORDER BY p.requested_at DESC LIMIT 300
) s;

INSERT INTO admin_activity_events
  (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
SELECT 'refund', 'refund.' || s.status, admin_activity_severity(s.status),
       s.trade_id, s.reference, s.reason_code,
       left('Refund ' || s.currency_code || ' ' || s.amount_minor::text || ' minor · ' ||
            COALESCE(s.reference, '') || ' · ' || s.status, 300),
       jsonb_build_object('status', s.status, 'reasonCode', s.reason_code,
                          'currency', s.currency_code, 'amountMinor', s.amount_minor),
       COALESCE(s.completed_at, s.requested_at)
FROM (
  SELECT r.*, t.reference FROM refunds r JOIN trades t ON t.id = r.trade_id
  WHERE r.requested_at > now() - interval '7 days'
  ORDER BY r.requested_at DESC LIMIT 300
) s;

INSERT INTO admin_activity_events
  (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
SELECT 'match', 'match.' || s.status, admin_activity_severity(s.status),
       s.buy_trade_id, NULL,
       CASE WHEN s.liquidity_order_id IS NULL THEN 'p2p' ELSE 'liquidity_provider' END,
       left('Match ' || s.buy_currency || '→' || s.sell_currency || ' ' || s.status ||
            ' · buy ' || s.buy_amount_minor::text || ' / sell ' ||
            s.sell_amount_minor::text || ' minor', 300),
       jsonb_build_object('status', s.status, 'buyCurrency', s.buy_currency,
                          'sellCurrency', s.sell_currency,
                          'buyAmountMinor', s.buy_amount_minor,
                          'sellAmountMinor', s.sell_amount_minor),
       COALESCE(s.released_at, s.matched_at, s.created_at)
FROM (
  SELECT * FROM p2p_matches
  WHERE created_at > now() - interval '7 days'
  ORDER BY created_at DESC LIMIT 300
) s;

INSERT INTO admin_activity_events
  (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
SELECT 'liquidity', 'liquidity.' || s.status, admin_activity_severity(s.status),
       NULL, s.prefund_reference, s.provider_id::text,
       left('LP order ' || s.provide_currency || '→' || s.receive_currency || ' ' ||
            s.status || ' · remaining ' || s.remaining_minor::text || ' minor', 300),
       jsonb_build_object('status', s.status, 'provideCurrency', s.provide_currency,
                          'receiveCurrency', s.receive_currency,
                          'capacityMinor', s.capacity_minor,
                          'remainingMinor', s.remaining_minor),
       s.created_at
FROM (
  SELECT * FROM liquidity_orders
  WHERE created_at > now() - interval '7 days'
  ORDER BY created_at DESC LIMIT 300
) s;

INSERT INTO admin_activity_events
  (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
SELECT 'admin', left(s.action, 64), 'info', NULL, s.resource_id, s.actor_label,
       left('Admin ' || s.actor_label || ' · ' || s.action || ' · ' ||
            s.resource_type || COALESCE(' ' || s.resource_id, ''), 300),
       jsonb_build_object('action', s.action, 'resourceType', s.resource_type,
                          'resourceId', s.resource_id),
       s.created_at
FROM (
  SELECT * FROM admin_audit_log
  ORDER BY created_at DESC LIMIT 300
) s;

COMMENT ON TABLE admin_activity_events IS
  'Append-only admin activity outbox. Triggers mirror trade, match, payout, refund, liquidity and audit changes. The admin portal streams it over SSE.';
COMMENT ON COLUMN admin_activity_events.payload IS
  'Structured non-PII operational details only. Recipient and account data stay in their encrypted columns.';
