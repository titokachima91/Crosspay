-- 0017_reconciliation_missing_lines.sql
-- Reconciliation v1.1: statement-to-ledger matching plus detection of internal
-- provider rows that are absent from the statement for the same period/currency.
--
-- A missing-in-statement exception has no settlement line: it is evidence that
-- our provider record exists but the statement did not include it. It blocks a
-- final close until finance/superadmin records the investigation.

ALTER TABLE settlement_statements
  ADD COLUMN missing_count integer NOT NULL DEFAULT 0
    CHECK (missing_count >= 0);

CREATE OR REPLACE FUNCTION guard_settlement_statement_update()
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
     OR NEW.missing_count IS DISTINCT FROM OLD.missing_count
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

ALTER TABLE reconciliation_exceptions
  ALTER COLUMN line_id DROP NOT NULL;

ALTER TABLE reconciliation_exceptions
  ADD COLUMN internal_table text
    CHECK (internal_table IS NULL
           OR internal_table IN ('payment_attempt', 'payout', 'refund')),
  ADD COLUMN internal_id uuid;

ALTER TABLE reconciliation_exceptions
  DROP CONSTRAINT IF EXISTS reconciliation_exceptions_line_id_key;
CREATE UNIQUE INDEX reconciliation_exceptions_line_uidx
  ON reconciliation_exceptions (line_id)
  WHERE line_id IS NOT NULL;
CREATE UNIQUE INDEX reconciliation_exceptions_internal_uidx
  ON reconciliation_exceptions (statement_id, internal_table, internal_id)
  WHERE internal_id IS NOT NULL;

ALTER TABLE reconciliation_exceptions
  DROP CONSTRAINT IF EXISTS reconciliation_exceptions_kind_check;
ALTER TABLE reconciliation_exceptions
  ADD CONSTRAINT reconciliation_exceptions_kind_check
  CHECK (kind IN ('unmatched_reference', 'amount_mismatch',
                  'currency_mismatch', 'status_mismatch',
                  'missing_journal', 'duplicate_reference',
                  'unmatched_journal', 'unsupported_line',
                  'missing_in_statement'));

ALTER TABLE reconciliation_exceptions
  ADD CONSTRAINT reconciliation_exception_subject CHECK (
    (line_id IS NOT NULL AND internal_table IS NULL AND internal_id IS NULL)
    OR (line_id IS NULL AND internal_table IS NOT NULL AND internal_id IS NOT NULL)
  );

CREATE OR REPLACE FUNCTION guard_reconciliation_exception_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.statement_id IS DISTINCT FROM OLD.statement_id
     OR NEW.line_id IS DISTINCT FROM OLD.line_id
     OR NEW.internal_table IS DISTINCT FROM OLD.internal_table
     OR NEW.internal_id IS DISTINCT FROM OLD.internal_id
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

CREATE OR REPLACE FUNCTION admin_activity_from_settlement_statement()
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
       CASE WHEN NEW.exception_count + NEW.missing_count > 0 THEN 'warning' ELSE 'info' END,
       NULL, NULL, actor_email,
       left('Statement imported · ' || NEW.source_label || ' · ' || NEW.currency_code ||
            ' · matched ' || NEW.matched_count::text || ' · exceptions ' ||
            NEW.exception_count::text || ' · missing ' || NEW.missing_count::text, 300),
       jsonb_build_object('sourceKind', NEW.source_kind,
                          'sourceLabel', NEW.source_label,
                          'currency', NEW.currency_code,
                          'lineCount', NEW.line_count,
                          'matchedCount', NEW.matched_count,
                          'exceptionCount', NEW.exception_count,
                          'missingCount', NEW.missing_count),
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
                        'exceptionCount', NEW.exception_count,
                        'missingCount', NEW.missing_count),
     now());
  RETURN NEW;
END;
$$;

COMMENT ON COLUMN settlement_statements.missing_count IS
  'Internal provider rows in the statement period/currency that the statement did not include.';
COMMENT ON COLUMN reconciliation_exceptions.internal_table IS
  'For missing_in_statement exceptions, the internal provider table that has no statement line.';
