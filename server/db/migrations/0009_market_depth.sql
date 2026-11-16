-- 0009_market_depth.sql
-- Corridor settlement estimate. Null means the corridor should not be shown in
-- /market/depth; the server never invents an estimate.

ALTER TABLE p2p_corridors
  ADD COLUMN estimated_settle_seconds integer
    CHECK (estimated_settle_seconds IS NULL OR estimated_settle_seconds > 0);

COMMENT ON COLUMN p2p_corridors.estimated_settle_seconds IS
  'Operator-supplied expected settlement time for GET /market/depth. Null omits the corridor.';
