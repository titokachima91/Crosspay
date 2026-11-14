-- 0007_guards.sql
-- Cross-table invariants that are safer in the database than in a service:
-- trade status transitions and the append-only timeline.

CREATE TABLE trade_status_transitions (
  from_status text NOT NULL
                CHECK (from_status IN ('pending_deposit', 'escrowed', 'matching', 'matched',
                                       'disbursing', 'completed', 'expired', 'refunded',
                                       'failed', 'cancelled')),
  to_status   text NOT NULL
                CHECK (to_status IN ('pending_deposit', 'escrowed', 'matching', 'matched',
                                     'disbursing', 'completed', 'expired', 'refunded',
                                     'failed', 'cancelled')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (from_status, to_status),
  CONSTRAINT trade_transition_not_self CHECK (from_status <> to_status)
);

CREATE FUNCTION assert_trade_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT EXISTS (
      SELECT 1
      FROM trade_status_transitions
      WHERE from_status = OLD.status AND to_status = NEW.status
    ) THEN
      RAISE EXCEPTION 'illegal trade transition % -> %', OLD.status, NEW.status
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trades_assert_status_transition
  BEFORE UPDATE OF status ON trades
  FOR EACH ROW EXECUTE FUNCTION assert_trade_transition();

CREATE FUNCTION reject_timeline_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'trade_events is append-only; the timeline is never rewritten'
    USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trade_events_append_only
  BEFORE UPDATE OR DELETE ON trade_events
  FOR EACH ROW EXECUTE FUNCTION reject_timeline_mutation();

COMMENT ON TABLE trade_status_transitions IS
  'Configurable allowed trade transitions. Empty or missing rows reject the change; operations can add a transition without a code deploy.';
