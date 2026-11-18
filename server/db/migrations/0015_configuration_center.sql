-- 0015_configuration_center.sql
-- Versioned configuration changes, two-person approval and emergency service
-- controls. Fee bps remain provider-owned; this phase does not add a fee editor
-- that could disagree with the quote the customer already accepted.

ALTER TABLE admin_activity_events
  DROP CONSTRAINT IF EXISTS admin_activity_events_source_check;
ALTER TABLE admin_activity_events
  ADD CONSTRAINT admin_activity_events_source_check
  CHECK (source IN ('trade', 'match', 'payout', 'refund', 'admin',
                    'liquidity', 'ledger', 'support', 'config'));

-- Emergency controls are applied immediately by a superadmin, not proposed:
-- pausing new quotes or trades during an incident must not wait for a second
-- person. Existing payouts, refunds and matches keep running.
CREATE TABLE service_controls (
  id                  smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  quotes_paused       boolean NOT NULL DEFAULT false,
  trades_paused       boolean NOT NULL DEFAULT false,
  message             text CHECK (message IS NULL
                                  OR length(btrim(message)) BETWEEN 1 AND 300),
  updated_by_admin_id uuid REFERENCES admin_users (id) ON DELETE SET NULL,
  updated_at          timestamptz NOT NULL DEFAULT now()
);

INSERT INTO service_controls (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

CREATE TRIGGER service_controls_set_updated_at
  BEFORE UPDATE ON service_controls
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE admin_config_changes (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  config_key          text NOT NULL
                        CHECK (config_key ~ '^(support_contacts|tier_limit:[a-z][a-z0-9_]{1,31}:[A-Z]{3})$'),
  before              jsonb NOT NULL,
  after               jsonb NOT NULL,
  reason              text NOT NULL CHECK (length(btrim(reason)) BETWEEN 10 AND 300),
  status              text NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  proposed_by_admin_id uuid NOT NULL REFERENCES admin_users (id) ON DELETE RESTRICT,
  decided_by_admin_id  uuid REFERENCES admin_users (id) ON DELETE RESTRICT,
  decision_note        text CHECK (decision_note IS NULL
                                   OR length(btrim(decision_note)) BETWEEN 1 AND 300),
  config_version       integer REFERENCES config_versions (version) ON DELETE RESTRICT,
  decided_at           timestamptz,
  applied_at           timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT config_change_decision_consistent CHECK (
    (status = 'pending'
      AND decided_by_admin_id IS NULL AND decided_at IS NULL
      AND applied_at IS NULL AND config_version IS NULL)
    OR (status = 'approved'
      AND decided_by_admin_id IS NOT NULL AND decided_at IS NOT NULL
      AND applied_at IS NOT NULL AND config_version IS NOT NULL)
    OR (status IN ('rejected', 'cancelled')
      AND decided_by_admin_id IS NOT NULL AND decided_at IS NOT NULL
      AND applied_at IS NULL AND config_version IS NULL)
  )
);

CREATE UNIQUE INDEX admin_config_changes_pending_key_uidx
  ON admin_config_changes (config_key)
  WHERE status = 'pending';
CREATE INDEX admin_config_changes_recent_idx
  ON admin_config_changes (created_at DESC, id DESC);
CREATE INDEX admin_config_changes_status_idx
  ON admin_config_changes (status, created_at DESC);

CREATE FUNCTION guard_admin_config_change_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.config_key IS DISTINCT FROM OLD.config_key
     OR NEW.before IS DISTINCT FROM OLD.before
     OR NEW.after IS DISTINCT FROM OLD.after
     OR NEW.reason IS DISTINCT FROM OLD.reason
     OR NEW.proposed_by_admin_id IS DISTINCT FROM OLD.proposed_by_admin_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'config change proposal is immutable';
  END IF;

  IF OLD.status <> 'pending' AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'config change is already decided';
  END IF;

  IF OLD.status = 'pending' AND NEW.status NOT IN ('approved', 'rejected', 'cancelled') THEN
    RAISE EXCEPTION 'config change must be approved, rejected or cancelled';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_config_changes_guard_update
  BEFORE UPDATE ON admin_config_changes
  FOR EACH ROW EXECUTE FUNCTION guard_admin_config_change_update();

CREATE FUNCTION reject_admin_config_change_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'config change history is append-only';
END;
$$;

CREATE TRIGGER admin_config_changes_append_only
  BEFORE DELETE ON admin_config_changes
  FOR EACH ROW EXECUTE FUNCTION reject_admin_config_change_delete();

CREATE FUNCTION admin_activity_from_config_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor_email text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT email INTO actor_email FROM admin_users WHERE id = NEW.proposed_by_admin_id;
    INSERT INTO admin_activity_events
      (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
    VALUES
      ('config', 'config.proposed', 'info', NULL, NULL, actor_email,
       left('Config proposed · ' || NEW.config_key, 300),
       jsonb_build_object('configKey', NEW.config_key, 'status', NEW.status),
       NEW.created_at);
    RETURN NEW;
  END IF;

  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT email INTO actor_email FROM admin_users WHERE id = NEW.decided_by_admin_id;
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('config',
     'config.' || NEW.status,
     CASE WHEN NEW.status = 'rejected' THEN 'warning' ELSE 'info' END,
     NULL, NULL, actor_email,
     left('Config ' || NEW.status || ' · ' || NEW.config_key, 300),
     jsonb_build_object('configKey', NEW.config_key, 'status', NEW.status,
                        'configVersion', NEW.config_version),
     now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_config_change_insert
  AFTER INSERT ON admin_config_changes
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_config_change();
CREATE TRIGGER admin_activity_config_change_update
  AFTER UPDATE OF status ON admin_config_changes
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_config_change();

CREATE FUNCTION admin_activity_from_service_controls()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor_email text;
BEGIN
  IF NEW.quotes_paused IS NOT DISTINCT FROM OLD.quotes_paused
     AND NEW.trades_paused IS NOT DISTINCT FROM OLD.trades_paused
     AND NEW.message IS NOT DISTINCT FROM OLD.message THEN
    RETURN NEW;
  END IF;

  SELECT email INTO actor_email FROM admin_users WHERE id = NEW.updated_by_admin_id;
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('config', 'service.controls', 'warning', NULL, NULL, actor_email,
     left('Service controls · quotes ' ||
          CASE WHEN NEW.quotes_paused THEN 'paused' ELSE 'open' END ||
          ' · trades ' ||
          CASE WHEN NEW.trades_paused THEN 'paused' ELSE 'open' END, 300),
     jsonb_build_object('quotesPaused', NEW.quotes_paused,
                        'tradesPaused', NEW.trades_paused,
                        'hasMessage', NEW.message IS NOT NULL),
     now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_service_controls
  AFTER UPDATE ON service_controls
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_service_controls();

-- Config changes emit their own event; do not duplicate the audit row in the
-- control room. The audit log still records every proposal and decision.
CREATE OR REPLACE FUNCTION admin_activity_from_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF left(NEW.resource_type, 8) = 'support_'
     OR NEW.resource_type IN ('config_change', 'service_control') THEN
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

COMMENT ON TABLE service_controls IS
  'Emergency switches. Superadmin-only, immediate, audited; existing money movement continues.';
COMMENT ON TABLE admin_config_changes IS
  'Versioned configuration proposals. Immutable payload, one pending change per key, two-person approval.';
COMMENT ON COLUMN admin_config_changes.before IS
  'The value at proposal time. Never updated; used for review and rollback.';
COMMENT ON COLUMN admin_config_changes.after IS
  'The proposed value. Applied only when a different admin approves it.';
