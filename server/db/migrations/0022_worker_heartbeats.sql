-- 0022_worker_heartbeats.sql
-- The reconciliation worker records each pass so the admin overview can show a
-- stale or failing worker. Heartbeats are operational metadata only: no user,
-- trade or provider identifiers are stored here.

CREATE TABLE worker_heartbeats (
  worker        text PRIMARY KEY CHECK (worker ~ '^[a-z][a-z0-9_-]{1,31}$'),
  started_at    timestamptz NOT NULL,
  finished_at   timestamptz,
  duration_ms   integer CHECK (duration_ms IS NULL OR duration_ms >= 0),
  errors        integer NOT NULL DEFAULT 0 CHECK (errors >= 0),
  last_error    text CHECK (last_error IS NULL OR length(last_error) <= 300),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE worker_heartbeats IS
  'Last reconciliation-worker pass per worker name. Read by the admin overview.';
