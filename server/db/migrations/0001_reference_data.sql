-- 0001_reference_data.sql
-- Server-driven reference data. Every value the app shows comes from these
-- tables; nothing is invented by the client. Ordered lists are sorted by
-- sort_order then a stable identifier.

CREATE TABLE countries (
  code                  char(2) PRIMARY KEY,
  name                  text NOT NULL CHECK (length(btrim(name)) > 0),
  dial_code             text NOT NULL CHECK (dial_code ~ '^[1-9][0-9]{0,3}$'),
  national_number_length smallint NOT NULL
                          CHECK (national_number_length BETWEEN 4 AND 15),
  sort_order            integer NOT NULL DEFAULT 0,
  active                boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT countries_code_iso CHECK (code ~ '^[A-Z]{2}$')
);

CREATE INDEX countries_active_order_idx
  ON countries (sort_order, code) WHERE active;

CREATE TABLE currencies (
  code          char(3) PRIMARY KEY,
  name          text NOT NULL CHECK (length(btrim(name)) > 0),
  country_code  char(2) NOT NULL REFERENCES countries (code) ON DELETE RESTRICT,
  decimals      smallint NOT NULL CHECK (decimals BETWEEN 0 AND 6),
  sort_order    integer NOT NULL DEFAULT 0,
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT currencies_code_iso CHECK (code ~ '^[A-Z]{3}$')
);

CREATE INDEX currencies_active_order_idx
  ON currencies (sort_order, code) WHERE active;

CREATE TABLE carriers (
  id             text PRIMARY KEY CHECK (id ~ '^[a-z0-9][a-z0-9-]{1,63}$'),
  name           text NOT NULL CHECK (length(btrim(name)) > 0),
  country_code   char(2) NOT NULL REFERENCES countries (code) ON DELETE RESTRICT,
  prefix_pattern text NOT NULL CHECK (length(prefix_pattern) BETWEEN 1 AND 64),
  sort_order     integer NOT NULL DEFAULT 0,
  active         boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX carriers_active_order_idx
  ON carriers (country_code, sort_order, id) WHERE active;

CREATE TABLE hubs (
  id           text PRIMARY KEY CHECK (id ~ '^[a-z0-9][a-z0-9-]{1,63}$'),
  name         text NOT NULL CHECK (length(btrim(name)) > 0),
  country_code char(2) NOT NULL REFERENCES countries (code) ON DELETE RESTRICT,
  sort_order   integer NOT NULL DEFAULT 0,
  active       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX hubs_active_order_idx
  ON hubs (sort_order, id) WHERE active;

CREATE TABLE payout_rails (
  id           text PRIMARY KEY CHECK (id ~ '^[a-z0-9][a-z0-9-]{1,63}$'),
  name         text NOT NULL CHECK (length(btrim(name)) > 0),
  country_code char(2) NOT NULL REFERENCES countries (code) ON DELETE RESTRICT,
  kind         text NOT NULL CHECK (kind IN ('mobile_money', 'bank')),
  sort_order   integer NOT NULL DEFAULT 0,
  active       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX payout_rails_active_order_idx
  ON payout_rails (country_code, sort_order, id) WHERE active;

-- One optional support block. No row, or a row with every field null, means
-- the app must say support contact options are not available yet.
CREATE TABLE support_settings (
  id         smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  email      text CHECK (email IS NULL OR email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  phone      text CHECK (phone IS NULL OR length(btrim(phone)) BETWEEN 4 AND 32),
  whatsapp   text CHECK (whatsapp IS NULL OR length(btrim(whatsapp)) BETWEEN 4 AND 32),
  hours      text CHECK (hours IS NULL OR length(btrim(hours)) BETWEEN 1 AND 200),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT support_has_one_value CHECK (
    email IS NOT NULL OR phone IS NOT NULL OR whatsapp IS NOT NULL OR hours IS NOT NULL
  )
);

-- Public corridor metadata. Live rates are supplied by the pricing source and
-- are deliberately not stored here as if they were configuration.
CREATE TABLE corridor_settings (
  send_currency            char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  receive_currency         char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  is_enabled               boolean NOT NULL DEFAULT false,
  estimated_settle_seconds integer CHECK (estimated_settle_seconds IS NULL
                                          OR estimated_settle_seconds > 0),
  status_code              text CHECK (status_code IS NULL
                                      OR status_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  status_level             text CHECK (status_level IS NULL
                                      OR status_level IN ('healthy', 'limited', 'down')),
  sort_order               integer NOT NULL DEFAULT 0,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (send_currency, receive_currency),
  CONSTRAINT corridor_distinct_currencies CHECK (send_currency <> receive_currency)
);

CREATE INDEX corridor_settings_order_idx
  ON corridor_settings (sort_order, send_currency, receive_currency);

-- Published configuration versions. The highest published version is the
-- current one; the table is an audit trail for configuration changes.
CREATE TABLE config_versions (
  version      integer PRIMARY KEY CHECK (version > 0),
  notes        text,
  published_at timestamptz NOT NULL DEFAULT now(),
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tiers (
  code       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{1,31}$'),
  name       text NOT NULL CHECK (length(btrim(name)) > 0),
  active     boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Daily limits are product decisions and are intentionally not seeded. An
-- empty row means the server has no approved limit and must not invent one.
CREATE TABLE tier_limits (
  tier_code         text NOT NULL REFERENCES tiers (code) ON DELETE CASCADE,
  currency_code     char(3) NOT NULL REFERENCES currencies (code) ON DELETE RESTRICT,
  daily_limit_minor bigint NOT NULL CHECK (daily_limit_minor >= 0),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tier_code, currency_code)
);

CREATE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER countries_set_updated_at
  BEFORE UPDATE ON countries FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER currencies_set_updated_at
  BEFORE UPDATE ON currencies FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER carriers_set_updated_at
  BEFORE UPDATE ON carriers FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER hubs_set_updated_at
  BEFORE UPDATE ON hubs FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER payout_rails_set_updated_at
  BEFORE UPDATE ON payout_rails FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER support_settings_set_updated_at
  BEFORE UPDATE ON support_settings FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER corridor_settings_set_updated_at
  BEFORE UPDATE ON corridor_settings FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER tiers_set_updated_at
  BEFORE UPDATE ON tiers FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER tier_limits_set_updated_at
  BEFORE UPDATE ON tier_limits FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE countries IS 'ISO 3166-1 alpha-2 dialling data used by the phone screen.';
COMMENT ON TABLE currencies IS 'ISO 4217 currency metadata; decimals drives every minor-unit amount.';
COMMENT ON COLUMN payout_rails.kind IS 'Required by the Flutter PayoutRail model: mobile_money or bank.';
COMMENT ON TABLE support_settings IS 'Optional, real support block. Never seed placeholder addresses.';
COMMENT ON TABLE tier_limits IS 'Approved daily limits only. Empty means no approved limit exists.';
COMMENT ON TABLE corridor_settings IS 'Public corridor metadata; live FX rates are not stored here.';
