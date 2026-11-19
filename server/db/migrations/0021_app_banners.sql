-- 0021_app_banners.sql
-- Localized, scheduled app banners. They use the same versioned, two-person
-- configuration approval as support contacts and tier limits. Emergency
-- service controls remain immediate and separate.
--
-- `app_banners` is the current published state. Every change to it comes from
-- an approved admin_config_changes row; the change history stays append-only.

ALTER TABLE admin_config_changes
  DROP CONSTRAINT admin_config_changes_config_key_check;
ALTER TABLE admin_config_changes
  ADD CONSTRAINT admin_config_changes_config_key_check
  CHECK (config_key ~ '^(support_contacts|tier_limit:[a-z][a-z0-9_]{1,31}:[A-Z]{3}|app_banner:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$');

CREATE TABLE app_banners (
  id                  uuid PRIMARY KEY,
  message_en          text NOT NULL
                        CHECK (length(btrim(message_en)) BETWEEN 5 AND 200),
  message_sw          text NOT NULL
                        CHECK (length(btrim(message_sw)) BETWEEN 5 AND 200),
  severity            text NOT NULL DEFAULT 'info'
                        CHECK (severity IN ('info', 'warning', 'critical')),
  starts_at           timestamptz NOT NULL,
  ends_at             timestamptz NOT NULL,
  updated_by_admin_id uuid REFERENCES admin_users (id) ON DELETE SET NULL,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT app_banner_window CHECK (ends_at > starts_at)
);

CREATE INDEX app_banners_active_idx ON app_banners (starts_at, ends_at);
CREATE INDEX app_banners_recent_idx ON app_banners (created_at DESC, id DESC);

COMMENT ON TABLE app_banners IS
  'Published localized banners. Mutated only by an approved app_banner config change.';
COMMENT ON COLUMN app_banners.starts_at IS
  'First instant the banner may be shown, inclusive.';
COMMENT ON COLUMN app_banners.ends_at IS
  'Instant the banner stops being shown, exclusive.';
