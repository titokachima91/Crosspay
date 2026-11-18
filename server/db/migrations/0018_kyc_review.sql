-- 0018_kyc_review.sql
-- Manual compliance review of submitted KYC verifications.
--
-- There is no document image or provider result in this repository, so the
-- review screen shows submitted metadata only (legal name, ID type and last4).
-- It never decrypts the full identity number and never bypasses the pending
-- state: only a pending verification can be approved or rejected.

ALTER TABLE admin_activity_events
  DROP CONSTRAINT IF EXISTS admin_activity_events_source_check;
ALTER TABLE admin_activity_events
  ADD CONSTRAINT admin_activity_events_source_check
  CHECK (source IN ('trade', 'match', 'payout', 'refund', 'admin',
                    'liquidity', 'ledger', 'support', 'config',
                    'reconciliation', 'compliance'));

ALTER TABLE kyc_verifications
  ADD COLUMN reviewed_by_admin_id uuid REFERENCES admin_users (id) ON DELETE RESTRICT,
  ADD COLUMN reviewed_at timestamptz,
  ADD COLUMN review_note text CHECK (review_note IS NULL
                                    OR length(btrim(review_note)) BETWEEN 5 AND 300),
  ADD CONSTRAINT kyc_review_pair CHECK (
    (reviewed_by_admin_id IS NULL AND reviewed_at IS NULL)
    OR (reviewed_by_admin_id IS NOT NULL AND reviewed_at IS NOT NULL)
  );

CREATE INDEX kyc_reviewed_idx
  ON kyc_verifications (reviewed_at DESC, id DESC)
  WHERE reviewed_at IS NOT NULL;

CREATE FUNCTION guard_kyc_verification_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.user_id IS DISTINCT FROM OLD.user_id
     OR NEW.account_type IS DISTINCT FROM OLD.account_type
     OR NEW.legal_name IS DISTINCT FROM OLD.legal_name
     OR NEW.hub_id IS DISTINCT FROM OLD.hub_id
     OR NEW.id_type IS DISTINCT FROM OLD.id_type
     OR NEW.id_number_encrypted IS DISTINCT FROM OLD.id_number_encrypted
     OR NEW.id_number_hash IS DISTINCT FROM OLD.id_number_hash
     OR NEW.id_last4 IS DISTINCT FROM OLD.id_last4
     OR NEW.submitted_at IS DISTINCT FROM OLD.submitted_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'KYC verification evidence is immutable';
  END IF;

  IF OLD.status <> 'pending' AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'KYC verification is already decided';
  END IF;

  IF OLD.status = 'pending' AND NEW.status NOT IN ('pending', 'verified', 'rejected') THEN
    RAISE EXCEPTION 'KYC verification must be verified or rejected';
  END IF;

  IF OLD.status IN ('verified', 'rejected') AND (
       NEW.reviewed_by_admin_id IS DISTINCT FROM OLD.reviewed_by_admin_id
       OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
       OR NEW.review_note IS DISTINCT FROM OLD.review_note
       OR NEW.rejection_code IS DISTINCT FROM OLD.rejection_code
       OR NEW.verified_at IS DISTINCT FROM OLD.verified_at
     ) THEN
    RAISE EXCEPTION 'decided KYC review is immutable';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER kyc_verifications_guard_update
  BEFORE UPDATE ON kyc_verifications
  FOR EACH ROW EXECUTE FUNCTION guard_kyc_verification_update();

CREATE FUNCTION reject_kyc_verification_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'KYC verification history is append-only';
END;
$$;

CREATE TRIGGER kyc_verifications_append_only
  BEFORE DELETE ON kyc_verifications
  FOR EACH ROW EXECUTE FUNCTION reject_kyc_verification_delete();

CREATE FUNCTION admin_activity_from_kyc_review()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor_email text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;
  SELECT email INTO actor_email FROM admin_users WHERE id = NEW.reviewed_by_admin_id;
  INSERT INTO admin_activity_events
    (source, event_type, severity, trade_id, reference, actor_label, summary, payload, created_at)
  VALUES
    ('compliance',
     'kyc.' || NEW.status,
     CASE WHEN NEW.status = 'rejected' THEN 'warning' ELSE 'info' END,
     NULL, NULL, actor_email,
     left('KYC ' || NEW.status || ' · ' || NEW.account_type || ' · ' ||
          NEW.id_type || ' …' || NEW.id_last4, 300),
     jsonb_build_object('status', NEW.status,
                        'accountType', NEW.account_type,
                        'idType', NEW.id_type,
                        'rejectionCode', NEW.rejection_code),
     now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER admin_activity_kyc_review
  AFTER UPDATE OF status ON kyc_verifications
  FOR EACH ROW EXECUTE FUNCTION admin_activity_from_kyc_review();

CREATE OR REPLACE FUNCTION admin_activity_from_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF left(NEW.resource_type, 8) = 'support_'
     OR NEW.resource_type IN ('config_change', 'service_control',
                              'settlement_statement', 'reconciliation_exception',
                              'kyc_verification') THEN
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

COMMENT ON COLUMN kyc_verifications.reviewed_by_admin_id IS
  'Named compliance/superadmin who decided this verification.';
COMMENT ON COLUMN kyc_verifications.review_note IS
  'Short investigation note. Never contains the full identity number.';
