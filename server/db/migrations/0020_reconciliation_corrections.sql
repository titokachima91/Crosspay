-- 0020_reconciliation_corrections.sql
-- Corrections are new, linked statements. A closed statement is never reopened,
-- mutated or deleted; a correction points back to the closed statement it
-- replaces and records why it exists.

ALTER TABLE settlement_statements
  ADD COLUMN corrects_statement_id uuid
    REFERENCES settlement_statements (id) ON DELETE RESTRICT,
  ADD COLUMN correction_reason text
    CHECK (correction_reason IS NULL
           OR length(btrim(correction_reason)) BETWEEN 10 AND 300);

ALTER TABLE settlement_statements
  ADD CONSTRAINT settlement_correction_shape CHECK (
    (corrects_statement_id IS NULL AND correction_reason IS NULL)
    OR (corrects_statement_id IS NOT NULL AND correction_reason IS NOT NULL)
  ),
  ADD CONSTRAINT settlement_correction_not_self CHECK (
    corrects_statement_id IS NULL OR corrects_statement_id <> id
  );

CREATE INDEX settlement_statements_corrects_idx
  ON settlement_statements (corrects_statement_id)
  WHERE corrects_statement_id IS NOT NULL;

-- The correction link and reason are part of the immutable statement content.
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
     OR NEW.corrects_statement_id IS DISTINCT FROM OLD.corrects_statement_id
     OR NEW.correction_reason IS DISTINCT FROM OLD.correction_reason
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

-- The import activity row carries the correction link so the control room can
-- open both statements without exposing any customer data.
CREATE OR REPLACE FUNCTION admin_activity_from_settlement_statement()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor_email text;
  correction_prefix text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT email INTO actor_email FROM admin_users WHERE id = NEW.imported_by_admin_id;
    correction_prefix := CASE
      WHEN NEW.corrects_statement_id IS NULL THEN 'Statement imported'
      ELSE 'Correction statement imported'
    END;
    INSERT INTO admin_activity_events
      (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
    VALUES
      ('reconciliation',
       CASE
         WHEN NEW.corrects_statement_id IS NULL THEN 'statement.imported'
         ELSE 'statement.corrected'
       END,
       CASE WHEN NEW.exception_count > 0 THEN 'warning' ELSE 'info' END,
       NULL, NULL, actor_email,
       left(correction_prefix || ' · ' || NEW.source_label || ' · ' || NEW.currency_code ||
            ' · matched ' || NEW.matched_count::text || ' · exceptions ' ||
            NEW.exception_count::text, 300),
       jsonb_build_object('sourceKind', NEW.source_kind,
                          'sourceLabel', NEW.source_label,
                          'currency', NEW.currency_code,
                          'lineCount', NEW.line_count,
                          'matchedCount', NEW.matched_count,
                          'exceptionCount', NEW.exception_count,
                          'correctsStatementId', NEW.corrects_statement_id,
                          'correctionReason', NEW.correction_reason),
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
                        'correctsStatementId', NEW.corrects_statement_id),
     now());
  RETURN NEW;
END;
$$;

COMMENT ON COLUMN settlement_statements.corrects_statement_id IS
  'Closed statement this import corrects. The original stays closed and unchanged.';
COMMENT ON COLUMN settlement_statements.correction_reason IS
  'Why the linked correction exists. Required with corrects_statement_id.';
