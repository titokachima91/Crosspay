-- 0004_idempotency.sql
-- Safe replay and concurrency control for every write endpoint.
-- The business write and the completion of this row commit in one transaction.

CREATE TABLE idempotency_keys (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  scope                  text NOT NULL CHECK (scope ~ '^[a-z][a-z0-9_.]{2,63}$'),
  key                    text NOT NULL CHECK (length(key) BETWEEN 1 AND 255),
  request_hash           text NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
  status                 text NOT NULL DEFAULT 'in_progress'
                           CHECK (status IN ('in_progress', 'succeeded', 'failed')),
  response_status        integer CHECK (response_status BETWEEN 100 AND 599),
  response_body_encrypted bytea CHECK (response_body_encrypted IS NULL
                                        OR octet_length(response_body_encrypted) > 0),
  resource_type          text CHECK (resource_type IS NULL
                                     OR resource_type ~ '^[a-z][a-z0-9_]{1,63}$'),
  resource_id            text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  completed_at           timestamptz,
  expires_at             timestamptz NOT NULL,
  CONSTRAINT idempotency_unique_key UNIQUE (user_id, scope, key),
  CONSTRAINT idempotency_in_progress_shape CHECK (
    (status = 'in_progress'
      AND completed_at IS NULL
      AND response_status IS NULL
      AND response_body_encrypted IS NULL)
    OR (status IN ('succeeded', 'failed')
      AND completed_at IS NOT NULL
      AND response_status IS NOT NULL)
  ),
  CONSTRAINT idempotency_expiry_after_created CHECK (expires_at > created_at),
  CONSTRAINT idempotency_completed_after_created CHECK (
    completed_at IS NULL OR completed_at >= created_at
  )
);

CREATE INDEX idempotency_expiry_idx ON idempotency_keys (expires_at);
CREATE INDEX idempotency_resource_idx
  ON idempotency_keys (resource_type, resource_id)
  WHERE resource_id IS NOT NULL;

COMMENT ON TABLE idempotency_keys IS
  'One row per (user, scope, key). Same body replays the stored result; a different body is rejected.';
COMMENT ON COLUMN idempotency_keys.response_body_encrypted IS
  'Encrypted when the response contains personal data. Retention is short and configurable.';
