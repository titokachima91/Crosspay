-- 0016_settlement_reconciliation.sql
-- Manual settlement statements and a deliberately conservative reconciliation.
--
-- A statement is evidence, never a ledger edit. Lines are append-only, matching
-- is exact reference/amount/currency (or an explicit CrossPay posting key), and
-- a statement cannot close with an open exception. There is no write-off button.

ALTER TABLE admin_activity_events
  DROP CONSTRAINT IF EXISTS admin_activity_events_source_check;
ALTER TABLE admin_activity_events
  ADD CONSTRAINT admin_activity_events_source_check
  CHECK (source IN ('trade', 'match', 'payout', 'refund', 'admin',
                    'liquidity', 'ledger', 'support', 'config', 'reconciliation'));

CREATE TABLE settlement_statements (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_kind          text NOT NULL CHECK (source_kind IN ('provider', 'bank')),
  source_label         text NOT NULL CHECK (length(btrim(source_label)) BETWEEN 1 AND 80),
  provider             text CHECK (provider IS NULL
                                    OR provider ~ '^[a-z][a-z0-9_]{1,63}$'),
  currency_code        char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  period_start         timestamptz NOT NULL,
  period_end           timestamptz NOT NULL,
  file_name            text NOT NULL CHECK (length(btrim(file_name)) BETWEEN 1 AND 200),
  file_sha256          text NOT NULL UNIQUE CHECK (file_sha256 ~ '^[a-f0-9]{64}$'),
  line_count           integer NOT NULL CHECK (line_count >= 0),
  matched_count        integer NOT NULL CHECK (matched_count >= 0),
  exception_count      integer NOT NULL CHECK (exception_count >= 0),
  status               text NOT NULL DEFAULT 'imported'
                         CHECK (status IN ('imported', 'closed')),
  imported_by_admin_id uuid NOT NULL REFERENCES admin_users (id) ON DELETE RESTRICT,
  closed_by_admin_id   uuid REFERENCES admin_users (id) ON DELETE RESTRICT,
  closed_at            timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT settlement_period_order CHECK (period_end >= period_start),
  CONSTRAINT settlement_provider_required CHECK (
    (source_kind = 'provider' AND provider IS NOT NULL)
    OR (source_kind = 'bank' AND provider IS NULL)
  ),
  CONSTRAINT settlement_counts_match CHECK (
    matched_count + exception_count = line_count
  ),
  CONSTRAINT settlement_close_consistent CHECK (
    (status = 'closed' AND closed_by_admin_id IS NOT NULL AND closed_at IS NOT NULL)
    OR (status = 'imported' AND closed_by_admin_id IS NULL AND closed_at IS NULL)
  )
);

CREATE INDEX settlement_statements_recent_idx
  ON settlement_statements (created_at DESC, id DESC);
CREATE INDEX settlement_statements_open_idx
  ON settlement_statements (status, currency_code, created_at DESC);

CREATE TABLE settlement_lines (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  statement_id       uuid NOT NULL REFERENCES settlement_statements (id) ON DELETE RESTRICT,
  line_no            integer NOT NULL CHECK (line_no > 0),
  occurred_at        timestamptz NOT NULL,
  reference          text CHECK (reference IS NULL
                                 OR length(btrim(reference)) BETWEEN 1 AND 120),
  kind               text NOT NULL
                       CHECK (kind IN ('collection', 'payout', 'refund',
                                       'fee', 'transfer', 'adjustment')),
  amount_minor       bigint NOT NULL CHECK (amount_minor > 0),
  currency_code      char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  posting_key        text CHECK (posting_key IS NULL
                                 OR length(btrim(posting_key)) BETWEEN 1 AND 200),
  description        text CHECK (description IS NULL
                                 OR length(btrim(description)) BETWEEN 1 AND 300),
  status             text NOT NULL CHECK (status IN ('matched', 'exception')),
  matched_table      text CHECK (matched_table IS NULL
                                 OR matched_table IN ('payment_attempt', 'payout',
                                                      'refund', 'journal')),
  matched_id         uuid,
  matched_journal_id uuid REFERENCES journal_transactions (id) ON DELETE RESTRICT,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT settlement_lines_unique_no UNIQUE (statement_id, line_no),
  CONSTRAINT settlement_matched_has_journal CHECK (
    status <> 'matched' OR matched_journal_id IS NOT NULL
  ),
  CONSTRAINT settlement_matched_shape CHECK (
    (matched_table IS NULL AND matched_id IS NULL)
    OR (matched_table IS NOT NULL AND matched_id IS NOT NULL)
  )
);

CREATE INDEX settlement_lines_statement_idx
  ON settlement_lines (statement_id, line_no);
CREATE INDEX settlement_lines_exception_idx
  ON settlement_lines (statement_id, status);
CREATE INDEX settlement_lines_reference_idx
  ON settlement_lines (reference)
  WHERE reference IS NOT NULL;

CREATE TABLE reconciliation_exceptions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  statement_id        uuid NOT NULL REFERENCES settlement_statements (id) ON DELETE RESTRICT,
  line_id             uuid NOT NULL UNIQUE REFERENCES settlement_lines (id) ON DELETE RESTRICT,
  kind                text NOT NULL
                        CHECK (kind IN ('unmatched_reference', 'amount_mismatch',
                                        'currency_mismatch', 'status_mismatch',
                                        'missing_journal', 'duplicate_reference',
                                        'unmatched_journal', 'unsupported_line')),
  reference           text,
  amount_minor        bigint,
  currency_code       char(3) REFERENCES currencies (code) ON DELETE RESTRICT,
  status              text NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open', 'resolved')),
  note                text CHECK (note IS NULL
                                 OR length(btrim(note)) BETWEEN 5 AND 300),
  resolved_by_admin_id uuid REFERENCES admin_users (id) ON DELETE RESTRICT,
  resolved_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reconciliation_exception_resolution CHECK (
    (status = 'open' AND resolved_by_admin_id IS NULL AND resolved_at IS NULL)
    OR (status = 'resolved' AND resolved_by_admin_id IS NOT NULL
        AND resolved_at IS NOT NULL)
  )
);

CREATE INDEX reconciliation_exceptions_statement_idx
  ON reconciliation_exceptions (statement_id, status, created_at);
CREATE INDEX reconciliation_exceptions_open_idx
  ON reconciliation_exceptions (status, created_at)
  WHERE status = 'open';

CREATE FUNCTION guard_settlement_statement_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.source_kind IS DISTINCT FROM OLD.source_kind
     OR NEW.source_label IS DISTINCT FROM OLD.source_label
     OR NEW.provider IS DISTINCT FROM OLD.provider
     OR NEW.currency_code IS DISTINCT FROM OLD.currency_code
     OR NEW.period_start IS DISTINCT FROM OLD.period_start
     OR NEW.period_end IS DISTINCT FROM OLD.period_end
     OR NEW.file_name IS DISTINCT FROM OLD.file_name
     OR NEW.file_sha256 IS DISTINCT FROM OLD.file_sha256
     OR NEW.line_count IS DISTINCT FROM OLD.line_count
     OR NEW.matched_count IS DISTINCT FROM OLD.matched_count
     OR NEW.exception_count IS DISTINCT FROM OLD.exception_count
     OR NEW.imported_by_admin_id IS DISTINCT FROM OLD.imported_by_admin_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement statement content is immutable';
  END IF;

  IF OLD.status = 'closed' AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'settlement statement is already closed';
  END IF;

  IF OLD.status = 'closed' AND (
       NEW.closed_by_admin_id IS DISTINCT FROM OLD.closed_by_admin_id
       OR NEW.closed_at IS DISTINCT FROM OLD.closed_at
     ) THEN
    RAISE EXCEPTION 'closed settlement statement decision is immutable';
  END IF;

  IF OLD.status = 'imported' AND NEW.status NOT IN ('imported', 'closed') THEN
    RAISE EXCEPTION 'settlement statement status must be imported or closed';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER settlement_statements_guard_update
  BEFORE UPDATE ON settlement_statements
  FOR EACH ROW EXECUTE FUNCTION guard_settlement_statement_update();

CREATE FUNCTION reject_settlement_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'settlement evidence is append-only';
END;
$$;

CREATE TRIGGER settlement_statements_append_only
  BEFORE DELETE ON settlement_statements
  FOR EACH ROW EXECUTE FUNCTION reject_settlement_mutation();
CREATE TRIGGER settlement_lines_append_only
  BEFORE UPDATE OR DELETE ON settlement_lines
  FOR EACH ROW EXECUTE FUNCTION reject_settlement_mutation();
CREATE TRIGGER reconciliation_exceptions_append_only
  BEFORE DELETE ON reconciliation_exceptions
  FOR EACH ROW EXECUTE FUNCTION reject_settlement_mutation();

CREATE FUNCTION guard_reconciliation_exception_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.statement_id IS DISTINCT FROM OLD.statement_id
     OR NEW.line_id IS DISTINCT FROM OLD.line_id
     OR NEW.kind IS DISTINCT FROM OLD.kind
     OR NEW.reference IS DISTINCT FROM OLD.reference
     OR NEW.amount_minor IS DISTINCT FROM OLD.amount_minor
     OR NEW.currency_code IS DISTINCT FROM OLD.currency_code
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'reconciliation exception evidence is append-only';
  END IF;

  IF OLD.status = 'resolved' AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'reconciliation exception is already resolved';
  END IF;

  IF OLD.status = 'resolved' AND (
       NEW.note IS DISTINCT FROM OLD.note
       OR NEW.resolved_by_admin_id IS DISTINCT FROM OLD.resolved_by_admin_id
       OR NEW.resolved_at IS DISTINCT FROM OLD.resolved_at
     ) THEN
    RAISE EXCEPTION 'resolved reconciliation exception is immutable';
  END IF;

  IF OLD.status = 'open' AND NEW.status NOT IN ('open', 'resolved') THEN
    RAISE EXCEPTION 'reconciliation exception status must be open or resolved';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER reconciliation_exceptions_guard_update
  BEFORE UPDATE ON reconciliation_exceptions
  FOR EACH ROW EXECUTE FUNCTION guard_reconciliation_exception_update();

CREATE FUNCTION admin_activity_from_settlement_statement()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor_email text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT email INTO actor_email FROM admin_users WHERE id = NEW.imported_by_admin_id;
    INSERT INTO admin_activity_events
      (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
    VALUES
      ('reconciliation',
       'statement.imported',
       CASE WHEN NEW.exception_count > 0 THEN 'warning' ELSE 'info' END,
       NULL, NULL, actor_email,
       left('Statement imported · ' || NEW.source_label || ' · ' || NEW.currency_code ||
            ' · matched ' || NEW.matched_count::text || ' · exceptions ' ||
            NEW.exception_count::text, 300),
       jsonb_build_object('sourceKind', NEW.source_kind,
                          'sourceLabel', NEW.source_label,
                          'currency', NEW.currency_code,
                          'lineCount', NEW.line_count,
                          'matchedCount', NEW.matched_count,
                          'exceptionCount', NEW.exception_count),
       NEW.created_at);
    RETURN NEW;
  END IF;

  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT email INTO actor_email FROM admin_users WHERE id = NEW.closed_by_admin_id;
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('reconciliation',
     'statement.closed',
     'info',
     NULL, NULL, actor_email,
     left('Statement closed · ' || NEW.source_label || ' · ' || NEW.currency_code ||
          ' · ' || NEW.line_count::text || ' lines', 300),
     jsonb_build_object('currency', NEW.currency_code,
                        'lineCount', NEW.line_count,
                        'matchedCount', NEW.matched_count,
                        'exceptionCount', NEW.exception_count),
     now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_settlement_statement_insert
  AFTER INSERT ON settlement_statements
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_settlement_statement();
CREATE TRIGGER admin_activity_settlement_statement_update
  AFTER UPDATE OF status ON settlement_statements
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_settlement_statement();

CREATE FUNCTION admin_activity_from_reconciliation_exception()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor_email text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;
  SELECT email INTO actor_email FROM admin_users WHERE id = NEW.resolved_by_admin_id;
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('reconciliation',
     'exception.resolved',
     'info',
     NULL, NEW.reference, actor_email,
     left('Exception resolved · ' || NEW.kind || COALESCE(' · ' || NEW.reference, ''), 300),
     jsonb_build_object('kind', NEW.kind, 'currency', NEW.currency_code),
     now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_reconciliation_exception
  AFTER UPDATE OF status ON reconciliation_exceptions
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_reconciliation_exception();

-- Reconciliation writes emit their own activity; do not duplicate the audit row
-- in the control room. The audit log still records every action.
CREATE OR REPLACE FUNCTION admin_activity_from_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF left(NEW.resource_type, 8) = 'support_'
     OR NEW.resource_type IN ('config_change', 'service_control',
                              'settlement_statement', 'reconciliation_exception') THEN
    RETURN NEW;
  END IF;

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

COMMENT ON TABLE settlement_statements IS
  'One manual provider or bank statement import. Immutable content; only close state changes.';
COMMENT ON TABLE settlement_lines IS
  'Append-only statement lines. Matching is exact reference/amount/currency or an explicit posting key.';
COMMENT ON TABLE reconciliation_exceptions IS
  'One open/resolved exception per statement line. Resolving records a note; it never writes off money.';
