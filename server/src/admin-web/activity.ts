import type { Pool, PoolClient } from 'pg';

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

/** The slice of a pooled client the notification listener needs. */
export type ActivityListenerClient = Pick<
  PoolClient,
  'query' | 'on' | 'release'
>;

export type ActivityListenerFactory = (
  pool: Pool,
) => Promise<ActivityListenerClient>;

/**
 * Borrows one connection from the pool and keeps it checked out for as long
 * as at least one control-room stream is open. The LISTEN session must not be
 * returned to the pool between notifications.
 */
const defaultListenerClient: ActivityListenerFactory = (pool) => pool.connect();

/**
 * One shared feed fans database events out to every connected control-room
 * stream. Delivery has two paths:
 *
 * - `LISTEN admin_activity`: the outbox trigger calls `pg_notify`, so a new
 *   event wakes the poller immediately on a dedicated connection.
 * - The interval poll is the fallback: it also catches notification loss,
 *   reconnects and transactions that commit after their notify was sent. It
 *   advances an identity cursor so a burst cannot starve the reader, and
 *   re-reads a short time overlap so a late commit is not skipped. Duplicates
 *   are dropped by id. It is one query per portal process, not per browser.
 */
export class ActivityStream {
  private readonly listeners = new Set<Listener>();
  private timer: NodeJS.Timeout | null = null;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private notificationClient: ActivityListenerClient | null = null;
  private connecting = false;
  private generation = 0;
  private polling = false;
  private pollAgain = false;
  private since: Date | null = null;
  private cursorId = -1;
  private readonly seen = new Map<number, number>();

  constructor(
    private readonly pool: Pool,
    private readonly intervalMs = 2_000,
    private readonly overlapMs = 10_000,
    private readonly createListener: ActivityListenerFactory = defaultListenerClient,
  ) {}

  /** True while the dedicated LISTEN connection is established. */
  get listening(): boolean {
    return this.notificationClient !== null;
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    if (!this.timer) {
      this.since = new Date(Date.now() - this.overlapMs);
      this.cursorId = -1;
      this.timer = setInterval(() => void this.poll(), this.intervalMs);
      this.timer.unref?.();
      const generation = ++this.generation;
      void this.connectListener(generation);
    }
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  }

  stop(): void {
    this.generation += 1;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    const client = this.notificationClient;
    this.notificationClient = null;
    if (client) {
      try {
        client.release(true);
      } catch {
        // The connection may already be gone.
      }
    }
    this.since = null;
    this.cursorId = -1;
    this.pollAgain = false;
  }

  private async connectListener(generation: number): Promise<void> {
    if (this.connecting || this.notificationClient) return;
    if (generation !== this.generation || this.listeners.size === 0) return;
    this.connecting = true;
    let client: ActivityListenerClient | null = null;
    try {
      client = await this.createListener(this.pool);
      client.on('notification', () => {
        void this.poll();
      });
      client.on('error', () => {
        if (client) this.dropListener(client);
      });
      await client.query('LISTEN admin_activity');
      if (generation !== this.generation || this.listeners.size === 0) {
        client.release(true);
        return;
      }
      this.notificationClient = client;
    } catch {
      client?.release(true);
      this.scheduleReconnect(generation);
    } finally {
      this.connecting = false;
    }
  }

  private dropListener(client: ActivityListenerClient): void {
    if (this.notificationClient !== client) return;
    this.notificationClient = null;
    try {
      client.release(true);
    } catch {
      // The connection may already be gone.
    }
    if (this.listeners.size > 0) this.scheduleReconnect(this.generation);
  }

  private scheduleReconnect(generation: number): void {
    if (this.reconnectTimer || this.listeners.size === 0) return;
    if (generation !== this.generation) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      void this.connectListener(this.generation);
    }, 5_000);
    this.reconnectTimer.unref?.();
  }

  private async poll(): Promise<void> {
    if (this.polling) {
      this.pollAgain = true;
      return;
    }
    if (!this.since || this.listeners.size === 0) return;
    this.polling = true;
    const since = this.since;
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
        [this.cursorId, since, this.overlapMs],
      );
      const now = Date.now();
      for (const row of result.rows) {
        const event = toEvent(row);
        this.cursorId = Math.max(this.cursorId, event.id);
        if (event.createdAt > since.toISOString()) {
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
      if (this.listeners.size > 0) {
        this.since = new Date(Date.now() - this.overlapMs);
      }
    } finally {
      this.polling = false;
      if (this.pollAgain) {
        this.pollAgain = false;
        void this.poll();
      }
    }
  }
}
