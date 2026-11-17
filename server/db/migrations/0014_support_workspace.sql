-- 0014_support_workspace.sql
-- Manual support case management for the admin portal.
--
-- This is deliberately not a fake in-app chat: there is no customer portal yet.
-- Support records what happened, what was asked and what was sent. Message
-- bodies stay in this table, never in the control-room activity payload.
-- Customer PII is revealed only through a permissioned, audited path.

CREATE TABLE support_cases (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reference           text NOT NULL UNIQUE
                        CHECK (reference ~ '^CS-[0-9]{6}-[A-HJ-NP-Z2-9]{6}$'),
  user_id             uuid NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  trade_id            uuid REFERENCES trades (id) ON DELETE RESTRICT,
  subject             text NOT NULL CHECK (length(btrim(subject)) BETWEEN 3 AND 200),
  category            text NOT NULL
                        CHECK (category IN ('payment_not_received', 'payout_delay',
                                            'refund', 'account_access', 'kyc',
                                            'beneficiary', 'other')),
  status              text NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open', 'pending_customer',
                                          'pending_internal', 'resolved', 'closed')),
  priority            text NOT NULL DEFAULT 'normal'
                        CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
  assignee_admin_id   uuid REFERENCES admin_users (id) ON DELETE SET NULL,
  created_by_admin_id uuid NOT NULL REFERENCES admin_users (id) ON DELETE RESTRICT,
  opened_via          text NOT NULL DEFAULT 'admin'
                        CHECK (opened_via IN ('admin', 'phone', 'email', 'whatsapp',
                                              'app', 'other')),
  first_response_at   timestamptz,
  resolved_at         timestamptz,
  closed_at           timestamptz,
  last_activity_at    timestamptz NOT NULL DEFAULT now(),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX support_cases_queue_idx
  ON support_cases (status, priority, last_activity_at DESC);
CREATE INDEX support_cases_assignee_idx
  ON support_cases (assignee_admin_id, status);
CREATE INDEX support_cases_user_idx
  ON support_cases (user_id, created_at DESC);
CREATE INDEX support_cases_trade_idx
  ON support_cases (trade_id, created_at DESC)
  WHERE trade_id IS NOT NULL;

CREATE TRIGGER support_cases_set_updated_at
  BEFORE UPDATE ON support_cases
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE FUNCTION validate_support_case_target()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.trade_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM trades
      WHERE id = NEW.trade_id AND user_id = NEW.user_id
    ) THEN
      RAISE EXCEPTION 'support case trade must belong to the customer';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER support_cases_validate_target
  BEFORE INSERT OR UPDATE OF user_id, trade_id ON support_cases
  FOR EACH ROW EXECUTE FUNCTION validate_support_case_target();

CREATE TABLE support_case_messages (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id            uuid NOT NULL REFERENCES support_cases (id) ON DELETE RESTRICT,
  channel            text NOT NULL
                       CHECK (channel IN ('note', 'sms', 'email', 'phone', 'system')),
  visibility         text NOT NULL CHECK (visibility IN ('internal', 'customer')),
  author_admin_id    uuid REFERENCES admin_users (id) ON DELETE RESTRICT,
  body               text NOT NULL CHECK (length(btrim(body)) BETWEEN 1 AND 4000),
  delivery_status    text NOT NULL DEFAULT 'not_applicable'
                       CHECK (delivery_status IN ('not_applicable', 'pending',
                                                  'sent', 'failed')),
  provider_reference text,
  error_code         text CHECK (error_code IS NULL
                                 OR error_code ~ '^[A-Z][A-Z0-9_]{1,63}$'),
  delivered_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT support_message_delivery_consistent CHECK (
    (channel = 'sms' AND visibility = 'customer'
      AND delivery_status IN ('pending', 'sent', 'failed'))
    OR (channel <> 'sms' AND delivery_status = 'not_applicable')
  ),
  CONSTRAINT support_message_delivered_consistent CHECK (
    (delivery_status = 'sent' AND delivered_at IS NOT NULL)
    OR (delivery_status <> 'sent')
  )
);

CREATE INDEX support_messages_case_idx
  ON support_case_messages (case_id, created_at, id);
CREATE INDEX support_messages_pending_idx
  ON support_case_messages (delivery_status, created_at)
  WHERE delivery_status = 'pending';

CREATE FUNCTION guard_support_message_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.case_id IS DISTINCT FROM OLD.case_id
     OR NEW.channel IS DISTINCT FROM OLD.channel
     OR NEW.visibility IS DISTINCT FROM OLD.visibility
     OR NEW.author_admin_id IS DISTINCT FROM OLD.author_admin_id
     OR NEW.body IS DISTINCT FROM OLD.body
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'support message content is append-only';
  END IF;

  IF OLD.delivery_status <> 'pending' AND (
       NEW.delivery_status IS DISTINCT FROM OLD.delivery_status
       OR NEW.provider_reference IS DISTINCT FROM OLD.provider_reference
       OR NEW.error_code IS DISTINCT FROM OLD.error_code
       OR NEW.delivered_at IS DISTINCT FROM OLD.delivered_at
     ) THEN
    RAISE EXCEPTION 'support message delivery is already final';
  END IF;

  IF OLD.delivery_status = 'pending' AND NEW.delivery_status = 'pending' THEN
    RETURN NEW;
  END IF;

  IF OLD.delivery_status = 'pending'
     AND NEW.delivery_status NOT IN ('sent', 'failed') THEN
    RAISE EXCEPTION 'support message delivery must finish as sent or failed';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER support_messages_guard_update
  BEFORE UPDATE ON support_case_messages
  FOR EACH ROW EXECUTE FUNCTION guard_support_message_update();

CREATE FUNCTION reject_support_message_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'support messages are append-only';
END;
$$;

CREATE TRIGGER support_messages_append_only
  BEFORE DELETE ON support_case_messages
  FOR EACH ROW EXECUTE FUNCTION reject_support_message_mutation();

CREATE FUNCTION touch_support_case_from_message()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE support_cases
  SET last_activity_at = NEW.created_at
  WHERE id = NEW.case_id;
  RETURN NEW;
END;
$$;

CREATE TRIGGER support_messages_touch_case
  AFTER INSERT ON support_case_messages
  FOR EACH ROW EXECUTE FUNCTION touch_support_case_from_message();

CREATE TABLE support_canned_replies (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title               text NOT NULL CHECK (length(btrim(title)) BETWEEN 3 AND 120),
  body                text NOT NULL CHECK (length(btrim(body)) BETWEEN 3 AND 2000),
  category            text CHECK (category IS NULL
                                  OR category IN ('payment_not_received', 'payout_delay',
                                                  'refund', 'account_access', 'kyc',
                                                  'beneficiary', 'other')),
  active              boolean NOT NULL DEFAULT true,
  created_by_admin_id uuid NOT NULL REFERENCES admin_users (id) ON DELETE RESTRICT,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX support_canned_title_uidx
  ON support_canned_replies (lower(btrim(title)));

CREATE TRIGGER support_canned_set_updated_at
  BEFORE UPDATE ON support_canned_replies
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE support_pii_reveals (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_id       uuid NOT NULL REFERENCES support_cases (id) ON DELETE RESTRICT,
  admin_user_id uuid NOT NULL REFERENCES admin_users (id) ON DELETE RESTRICT,
  reason        text NOT NULL CHECK (length(btrim(reason)) BETWEEN 5 AND 300),
  fields        text[] NOT NULL CHECK (cardinality(fields) BETWEEN 1 AND 10),
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX support_pii_reveals_case_idx
  ON support_pii_reveals (case_id, created_at DESC);

CREATE FUNCTION reject_support_pii_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'support_pii_reveals is append-only';
END;
$$;

CREATE TRIGGER support_pii_reveals_append_only
  BEFORE UPDATE OR DELETE ON support_pii_reveals
  FOR EACH ROW EXECUTE FUNCTION reject_support_pii_mutation();

CREATE FUNCTION reject_support_case_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'support cases are never deleted';
END;
$$;

CREATE TRIGGER support_cases_append_only
  BEFORE DELETE ON support_cases
  FOR EACH ROW EXECUTE FUNCTION reject_support_case_delete();

-- Support activity is written by triggers so every admin process feeds the
-- control room. Summaries and payloads intentionally exclude phone numbers,
-- names, message bodies and account data.
CREATE FUNCTION admin_activity_from_support_case()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor_email text;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.status IS NOT DISTINCT FROM OLD.status
     AND NEW.priority IS NOT DISTINCT FROM OLD.priority
     AND NEW.assignee_admin_id IS NOT DISTINCT FROM OLD.assignee_admin_id THEN
    RETURN NEW;
  END IF;

  SELECT email INTO actor_email FROM admin_users WHERE id = NEW.created_by_admin_id;

  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('support',
     'case.' || NEW.status,
     CASE WHEN NEW.priority IN ('high', 'urgent')
               AND NEW.status IN ('open', 'pending_internal')
          THEN 'warning' ELSE 'info' END,
     NEW.trade_id,
     NEW.reference,
     actor_email,
     left('Support ' || NEW.reference || ' · ' || NEW.category || ' · ' || NEW.status ||
          CASE WHEN NEW.assignee_admin_id IS NULL THEN ' · unassigned' ELSE '' END, 300),
     jsonb_build_object('status', NEW.status, 'priority', NEW.priority,
                        'category', NEW.category,
                        'hasAssignee', NEW.assignee_admin_id IS NOT NULL),
     now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_support_case_insert
  AFTER INSERT ON support_cases
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_support_case();

CREATE TRIGGER admin_activity_support_case_update
  AFTER UPDATE OF status, priority, assignee_admin_id ON support_cases
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_support_case();

CREATE FUNCTION admin_activity_from_support_message()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  case_reference text;
  case_trade_id uuid;
  actor_email text;
BEGIN
  SELECT reference, trade_id INTO case_reference, case_trade_id
  FROM support_cases WHERE id = NEW.case_id;
  SELECT email INTO actor_email FROM admin_users WHERE id = NEW.author_admin_id;

  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('support',
     'message.' || NEW.channel,
     CASE WHEN NEW.delivery_status = 'failed' THEN 'warning' ELSE 'info' END,
     case_trade_id,
     case_reference,
     COALESCE(actor_email, 'system'),
     left('Support ' || COALESCE(case_reference, NEW.case_id::text) || ' · ' ||
          CASE WHEN NEW.visibility = 'customer' THEN 'customer-visible' ELSE 'internal' END ||
          ' ' || NEW.channel ||
          CASE WHEN NEW.delivery_status <> 'not_applicable'
               THEN ' · ' || NEW.delivery_status ELSE '' END, 300),
     jsonb_build_object('channel', NEW.channel, 'visibility', NEW.visibility,
                        'deliveryStatus', NEW.delivery_status,
                        'bodyLength', length(NEW.body)),
     NEW.created_at);
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_support_message
  AFTER INSERT ON support_case_messages
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_support_message();

CREATE FUNCTION admin_activity_from_support_message_delivery()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  case_reference text;
  case_trade_id uuid;
  actor_email text;
BEGIN
  IF NEW.delivery_status IS NOT DISTINCT FROM OLD.delivery_status THEN
    RETURN NEW;
  END IF;
  SELECT reference, trade_id INTO case_reference, case_trade_id
  FROM support_cases WHERE id = NEW.case_id;
  SELECT email INTO actor_email FROM admin_users WHERE id = NEW.author_admin_id;

  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('support',
     'message.' || NEW.channel || '.' || NEW.delivery_status,
     CASE WHEN NEW.delivery_status = 'failed' THEN 'warning' ELSE 'info' END,
     case_trade_id,
     case_reference,
     COALESCE(actor_email, 'system'),
     left('Support ' || COALESCE(case_reference, NEW.case_id::text) || ' · ' ||
          NEW.channel || ' ' || NEW.delivery_status, 300),
     jsonb_build_object('channel', NEW.channel, 'visibility', NEW.visibility,
                        'deliveryStatus', NEW.delivery_status,
                        'errorCode', NEW.error_code),
     now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_support_message_delivery
  AFTER UPDATE OF delivery_status ON support_case_messages
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_support_message_delivery();

CREATE FUNCTION admin_activity_from_support_pii_reveal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  case_reference text;
  case_trade_id uuid;
  actor_email text;
BEGIN
  SELECT reference, trade_id INTO case_reference, case_trade_id
  FROM support_cases WHERE id = NEW.case_id;
  SELECT email INTO actor_email FROM admin_users WHERE id = NEW.admin_user_id;

  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('support',
     'pii.reveal',
     'warning',
     case_trade_id,
     case_reference,
     actor_email,
     left('Customer PII revealed on ' || COALESCE(case_reference, NEW.case_id::text) ||
          ' · ' || array_length(NEW.fields, 1)::text || ' field(s)', 300),
     jsonb_build_object('fields', NEW.fields, 'adminUserId', NEW.admin_user_id),
     NEW.created_at);
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_support_pii_reveal
  AFTER INSERT ON support_pii_reveals
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_support_pii_reveal();

-- Support writes already produce a support activity event. Do not double-log
-- the corresponding admin audit row in the control room. The audit log itself
-- still records every action.
CREATE OR REPLACE FUNCTION admin_activity_from_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF left(NEW.resource_type, 8) = 'support_' THEN
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

COMMENT ON TABLE support_cases IS
  'Manual support cases. One customer, optionally one trade. No in-app chat is implied.';
COMMENT ON TABLE support_case_messages IS
  'Append-only case notes and outbound replies. SMS delivery state is the only mutable field.';
COMMENT ON TABLE support_pii_reveals IS
  'Append-only record of every customer PII reveal, with the operator reason and field names only.';
COMMENT ON TABLE support_canned_replies IS
  'Operator-managed reply templates. Plain text; placeholders are not expanded.';
