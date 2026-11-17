import type { Pool } from 'pg';

export type ActivitySeverity = 'info' | 'warning' | 'critical';

export interface ActivityEvent {
  id: number;
  source: string;
  eventType: string;
  severity: ActivitySeverity;
  tradeId: string | null;
  reference: string | null;
  actorLabel: string | null;
  summary: string;
  payload: Record<string, unknown>;
  createdAt: string;
  href: string | null;
}

interface ActivityRow {
  id: string;
  source: string;
  event_type: string;
  severity: ActivitySeverity;
  trade_id: string | null;
  reference: string | null;
  actor_label: string | null;
  summary: string;
  payload: Record<string, unknown>;
  created_at: Date;
}

function toEvent(row: ActivityRow): ActivityEvent {
  return {
    id: Number(row.id),
    source: row.source,
    eventType: row.event_type,
    severity: row.severity,
    tradeId: row.trade_id,
    reference: row.reference,
    actorLabel: row.actor_label,
    summary: row.summary,
    payload: row.payload ?? {},
    createdAt: new Date(row.created_at).toISOString(),
    href: row.trade_id
      ? `/trades/${row.trade_id}`
      : row.source === 'admin'
        ? '/audit'
        : null,
  };
}

const COLUMNS = `id, source, event_type, severity, trade_id, reference,
                 actor_label, summary, payload, created_at`;

export async function loadRecentActivity(pool: Pool, limit = 60): Promise<ActivityEvent[]> {
  const result = await pool.query<ActivityRow>(
    `SELECT ${COLUMNS}
     FROM admin_activity_events
     ORDER BY created_at DESC, id DESC
     LIMIT $1`,
    [Math.min(Math.max(limit, 1), 200)],
  );
  return result.rows.map(toEvent);
}

export async function loadActivityAfter(
  pool: Pool,
  afterId: number,
  limit = 500,
): Promise<ActivityEvent[]> {
  const result = await pool.query<ActivityRow>(
    `SELECT ${COLUMNS}
     FROM admin_activity_events
     WHERE id > $1
     ORDER BY id
     LIMIT $2`,
    [afterId, Math.min(Math.max(limit, 1), 1000)],
  );
  return result.rows.map(toEvent);
}

export async function loadActivityMaxId(pool: Pool): Promise<number> {
  const result = await pool.query<{ max_id: string | null }>(
    `SELECT max(id)::text AS max_id FROM admin_activity_events`,
  );
  return Number(result.rows[0]?.max_id ?? 0);
}

type Listener = (event: ActivityEvent) => void;

/**
 * One shared poller fans database events out to every connected control-room
 * stream. It advances an identity cursor so a burst cannot starve the reader,
 * and re-reads a short time overlap so a transaction that commits late is not
 * skipped. Duplicates are dropped by id. Two seconds keeps one query per
 * portal, not one per browser.
 */
export class ActivityStream {
  private readonly listeners = new Set<Listener>();
  private timer: NodeJS.Timeout | null = null;
  private polling = false;
  private since: Date | null = null;
  private cursorId = -1;
  private readonly seen = new Map<number, number>();

  constructor(
    private readonly pool: Pool,
    private readonly intervalMs = 2_000,
    private readonly overlapMs = 10_000,
  ) {}

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    if (!this.timer) {
      this.since = new Date(Date.now() - this.overlapMs);
      this.cursorId = -1;
      this.timer = setInterval(() => void this.poll(), this.intervalMs);
      this.timer.unref?.();
    }
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.since = null;
    this.cursorId = -1;
  }

  private async poll(): Promise<void> {
    if (this.polling || !this.since || this.listeners.size === 0) return;
    this.polling = true;
    try {
      if (this.cursorId < 0) {
        // Start from the current end of the outbox, but keep the short overlap
        // window so an event committed around subscription time is not lost.
        // The control room deduplicates by id.
        const current = await this.pool.query<{ max_id: string | null }>(
          `SELECT max(id)::text AS max_id FROM admin_activity_events`,
        );
        this.cursorId = Number(current.rows[0]?.max_id ?? 0);
      }
      const result = await this.pool.query<ActivityRow>(
        `SELECT ${COLUMNS}
         FROM admin_activity_events
         WHERE id > $1
            OR created_at > $2::timestamptz - ($3 * interval '1 millisecond')
         ORDER BY id
         LIMIT 200`,
        [this.cursorId, this.since, this.overlapMs],
      );
      const now = Date.now();
      for (const row of result.rows) {
        const event = toEvent(row);
        this.cursorId = Math.max(this.cursorId, event.id);
        if (event.createdAt > this.since.toISOString()) {
          this.since = new Date(row.created_at);
        }
        if (this.seen.has(event.id)) continue;
        this.seen.set(event.id, now);
        for (const listener of this.listeners) {
          try {
            listener(event);
          } catch {
            // A broken browser must not stop the other streams.
          }
        }
      }
      for (const [id, at] of this.seen) {
        if (now - at > 60_000) this.seen.delete(id);
      }
    } catch {
      // The next tick retries; the control room also has a polling fallback.
      this.since = new Date(Date.now() - this.overlapMs);
    } finally {
      this.polling = false;
    }
  }
}
