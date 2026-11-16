-- 0011_admin_audit.sql
-- Phase A admin audit. The final admin identity model will add admin_user_id;
-- this table already gives every write an actor label, resource and before/after.

CREATE TABLE admin_audit_log (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_label   text NOT NULL CHECK (length(btrim(actor_label)) BETWEEN 1 AND 120),
  action        text NOT NULL CHECK (action ~ '^[a-z][a-z0-9_.]{1,63}$'),
  resource_type text NOT NULL CHECK (resource_type ~ '^[a-z][a-z0-9_]{1,63}$'),
  resource_id   text,
  reason        text,
  before        jsonb,
  after         jsonb,
  ip            text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX admin_audit_created_idx ON admin_audit_log (created_at DESC);
CREATE INDEX admin_audit_resource_idx ON admin_audit_log (resource_type, resource_id, created_at DESC);

CREATE FUNCTION reject_admin_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'admin_audit_log is append-only';
END;
$$;

CREATE TRIGGER admin_audit_append_only
  BEFORE UPDATE OR DELETE ON admin_audit_log
  FOR EACH ROW EXECUTE FUNCTION reject_admin_audit_mutation();

COMMENT ON TABLE admin_audit_log IS
  'Append-only Phase A admin audit. Full admin identity/RBAC replaces actor_label later.';
