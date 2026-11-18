import type { Pool, PoolClient } from 'pg';
import { serviceUnavailable } from '../http/errors.js';

export interface ServiceControls {
  quotesPaused: boolean;
  tradesPaused: boolean;
  message: string | null;
  updatedAt: string | null;
}

type Queryable = Pool | PoolClient;

const OPEN: ServiceControls = {
  quotesPaused: false,
  tradesPaused: false,
  message: null,
  updatedAt: null,
};

/** Emergency controls are one row. A missing row means everything is open. */
export async function loadServiceControls(db: Queryable): Promise<ServiceControls> {
  const result = await db.query<{
    quotes_paused: boolean;
    trades_paused: boolean;
    message: string | null;
    updated_at: Date;
  }>(
    `SELECT quotes_paused, trades_paused, message, updated_at
     FROM service_controls WHERE id = 1`,
  );
  const row = result.rows[0];
  if (!row) return OPEN;
  return {
    quotesPaused: row.quotes_paused,
    tradesPaused: row.trades_paused,
    message: row.message,
    updatedAt: new Date(row.updated_at).toISOString(),
  };
}

export async function assertQuotesOpen(db: Queryable): Promise<void> {
  const controls = await loadServiceControls(db);
  if (controls.quotesPaused) {
    throw serviceUnavailable(
      'SERVICE_PAUSED',
      controls.message || 'New quotes are paused for a short maintenance window',
    );
  }
}

export async function assertTradesOpen(db: Queryable): Promise<void> {
  const controls = await loadServiceControls(db);
  if (controls.tradesPaused) {
    throw serviceUnavailable(
      'SERVICE_PAUSED',
      controls.message || 'New transfers are paused for a short maintenance window',
    );
  }
}
