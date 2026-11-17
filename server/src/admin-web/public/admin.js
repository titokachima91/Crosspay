(function () {
  const esc = (value) => String(value == null ? '' : value).replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[ch]));
  const fmt = (value) => Number(value || 0).toLocaleString('en-US');
  const shortDate = (value) => {
    if (!value) return '—';
    const date = new Date(value);
    return date.toISOString().replace('T', ' ').slice(0, 19);
  };
  const relative = (value) => {
    if (!value) return '';
    const seconds = Math.max(0, Math.round((Date.now() - new Date(value).getTime()) / 1000));
    if (seconds < 60) return seconds + 's';
    return Math.floor(seconds / 60) + 'm';
  };
  const pill = (status) => {
    const value = String(status || '').toLowerCase();
    const cls = ['completed', 'paid', 'active', 'released', 'success'].includes(value)
      ? 'ok'
      : ['failed', 'refunded', 'cancelled', 'suspended', 'expired'].includes(value)
        ? 'bad'
        : ['pending', 'submitted', 'matching', 'locked', 'depleted'].includes(value)
          ? 'warn'
          : 'info';
    return '<span class="pill ' + cls + '">' + esc(value) + '</span>';
  };

  const controlFeed = document.getElementById('control-feed');
  const miniFeed = document.getElementById('mini-feed');
  const feed = controlFeed || miniFeed;
  const seen = new Set();
  let paused = false;
  let buffered = 0;
  let filter = 'all';

  function updateStatus(text, cls) {
    const status = document.getElementById('feed-status');
    if (!status) return;
    status.textContent = text;
    status.className = 'pill ' + (cls || '');
  }

  function matchesFilter(event) {
    return filter === 'all' || event.source === filter;
  }

  function eventRow(event) {
    const time = event.createdAt || event.at;
    const source = event.source || 'event';
    const summary = event.summary || event.event || '';
    const reference = event.reference || '';
    const href = event.href || '';
    const severity = event.severity === 'warning' ? 'bad' : event.severity === 'critical' ? 'bad' : 'info';
    return '<div class="feed-row" data-source="' + esc(source) + '" data-severity="' + esc(event.severity || 'info') + '"' +
      (matchesFilter(event) ? '' : ' hidden') + '>'
      + '<div class="time">' + esc(shortDate(time)) + '<div class="tag">' + esc(relative(time)) + ' ago</div></div>'
      + '<div><span class="pill ' + severity + '">' + esc(source) + '</span></div>'
      + '<div>' + esc(summary)
      + (reference ? ' <a class="mono" href="' + esc(href) + '">' + esc(reference) + '</a>' : '')
      + '</div></div>';
  }

  function addEvent(event, position) {
    if (!feed || seen.has(event.id)) return;
    seen.add(event.id);
    if (event.id > latestEventId) latestEventId = event.id;
    const empty = feed.querySelector('.empty');
    if (empty) empty.remove();
    const wrapper = document.createElement('div');
    wrapper.innerHTML = eventRow(event);
    const row = wrapper.firstElementChild;
    if (position === 'append' || !feed.firstElementChild) feed.appendChild(row);
    else feed.insertBefore(row, feed.firstElementChild);
    while (feed.children.length > 200) feed.lastElementChild.remove();
    if (seen.size > 400) {
      const ids = [...seen];
      for (const id of ids.slice(0, 200)) seen.delete(id);
    }
  }

  let latestEventId = 0;

  function renderEvents(events) {
    if (!feed) return;
    feed.innerHTML = '';
    seen.clear();
    if (!events || events.length === 0) {
      feed.innerHTML = '<div class="empty">No activity yet.</div>';
      return;
    }
    for (const event of [...events].sort((a, b) => b.id - a.id)) {
      if (event.id > latestEventId) latestEventId = event.id;
      addEvent(event, 'append');
    }
  }

  function renderOverview(overview) {
    const set = (id, value) => { const el = document.getElementById(id); if (el) el.textContent = value; };
    set('kpi-queue', overview.counts.queue);
    set('kpi-matches', overview.counts.matches);
    set('kpi-payouts', overview.counts.payouts);
    set('kpi-refunds', overview.counts.refunds);
    set('kpi-lp', overview.counts.liquidityOrders);
    set('alert-count', overview.alerts.length);

    const alerts = document.getElementById('control-alerts');
    if (alerts) {
      alerts.innerHTML = overview.alerts.length === 0
        ? '<div class="empty">No alerts.</div>'
        : overview.alerts.map((alert) => '<div class="alert ' + esc(alert.level) + '"><span class="dot"></span>' + esc(alert.message) + '</div>').join('');
    }
    const corridors = document.getElementById('control-corridors');
    if (corridors) {
      corridors.innerHTML = overview.corridors.length === 0
        ? '<div class="empty">No corridors.</div>'
        : '<table><thead><tr><th>Corridor</th><th>Status</th><th class="num">Open</th><th>Use</th></tr></thead><tbody>'
          + overview.corridors.map((c) => '<tr><td>' + esc(c.from) + ' → ' + esc(c.to) + '</td><td>' + pill(c.enabled ? 'active' : 'disabled') + '</td><td class="num">' + c.openTrades + '</td><td>' + (c.utilizationPercent == null ? '—' : c.utilizationPercent + '%') + '</td></tr>').join('')
          + '</tbody></table>';
    }
    const health = document.getElementById('control-health');
    if (health) {
      const age = overview.oldest || {};
      health.innerHTML = '<table><tbody>'
        + '<tr><td>Oldest funded trade</td><td class="num">' + (age.queueSeconds == null ? '—' : fmt(age.queueSeconds) + 's') + '</td></tr>'
        + '<tr><td>Oldest locked match</td><td class="num">' + (age.matchSeconds == null ? '—' : fmt(age.matchSeconds) + 's') + '</td></tr>'
        + '<tr><td>Oldest pending payout</td><td class="num">' + (age.payoutSeconds == null ? '—' : fmt(age.payoutSeconds) + 's') + '</td></tr>'
        + '<tr><td>Oldest pending refund</td><td class="num">' + (age.refundSeconds == null ? '—' : fmt(age.refundSeconds) + 's') + '</td></tr>'
        + '</tbody></table>';
    }
  }

  function renderAudit(rows) {
    const audit = document.getElementById('control-audit');
    if (!audit) return;
    audit.innerHTML = rows.length === 0
      ? '<div class="empty">No admin actions yet.</div>'
      : '<table><thead><tr><th>When</th><th>Actor</th><th>Action</th><th>Resource</th></tr></thead><tbody>'
        + rows.map((row) => '<tr><td>' + esc(shortDate(row.created_at)) + '</td><td>' + esc(row.admin_email || row.actor_label) + '</td><td class="mono">' + esc(row.action) + '</td><td>' + esc(row.resource_type) + ' <span class="tag">' + esc(row.resource_id || '') + '</span></td></tr>').join('')
        + '</tbody></table>';
  }

  async function refreshSnapshot() {
    if (!feed) return;
    const endpoint = feed.dataset.endpoint || '/control-room/data';
    try {
      const response = await fetch(endpoint, { headers: { accept: 'application/json' } });
      if (response.status === 401) {
        window.location.href = '/login';
        return;
      }
      if (!response.ok) throw new Error('HTTP ' + response.status);
      const data = await response.json();
      renderOverview(data.overview);
      if (!paused) {
        if (data.events) renderEvents(data.events);
        else if (data.feed) renderEvents(data.feed);
      }
      if (data.audit) renderAudit(data.audit);
      const updated = document.getElementById('feed-updated');
      if (updated) updated.textContent = 'updated ' + new Date().toLocaleTimeString();
    } catch (error) {
      updateStatus('snapshot error', 'bad');
      const updated = document.getElementById('feed-updated');
      if (updated) updated.textContent = 'error: ' + error.message;
    }
  }

  function startStream() {
    if (!controlFeed || typeof window.EventSource === 'undefined') return;
    let attempts = 0;
    const connect = () => {
      const url = latestEventId > 0
        ? '/control-room/stream?after=' + encodeURIComponent(latestEventId)
        : '/control-room/stream';
      const stream = new EventSource(url);
      stream.addEventListener('open', () => {
        attempts = 0;
        updateStatus(paused ? 'paused' : 'live', paused ? 'warn' : 'ok');
      });
      stream.addEventListener('activity', (message) => {
        let event;
        try { event = JSON.parse(message.data); } catch { return; }
        if (paused) {
          buffered += 1;
          updateStatus('paused · ' + buffered + ' buffered', 'warn');
          return;
        }
        addEvent(event, 'prepend');
      });
      stream.addEventListener('error', () => {
        attempts += 1;
        updateStatus(attempts > 2 ? 'reconnecting…' : 'stream interrupted', 'warn');
      });
    };
    connect();
    setInterval(() => {
      if (!document.hidden) refreshSnapshot();
    }, 5000);
  }

  const pause = document.getElementById('feed-pause');
  if (pause) {
    pause.addEventListener('click', async () => {
      paused = !paused;
      pause.textContent = paused ? 'Resume' : 'Pause';
      updateStatus(paused ? 'paused' : 'live', paused ? 'warn' : 'ok');
      if (!paused) {
        buffered = 0;
        await refreshSnapshot();
      }
    });
  }

  const filterSelect = document.getElementById('feed-filter');
  if (filterSelect) {
    filterSelect.addEventListener('change', () => {
      filter = filterSelect.value;
      if (!feed) return;
      for (const row of feed.querySelectorAll('.feed-row')) {
        row.hidden = filter !== 'all' && row.dataset.source !== filter;
      }
    });
  }

  if (controlFeed) {
    refreshSnapshot().then(startStream);
  } else if (miniFeed) {
    refreshSnapshot();
    setInterval(() => { if (!document.hidden) refreshSnapshot(); }, 15000);
  }

  document.addEventListener('submit', (event) => {
    const form = event.target;
    if (form.matches('form[data-confirm]')) {
      if (!window.confirm(form.dataset.confirm)) event.preventDefault();
    }
  });

  const cannedSelect = document.getElementById('canned');
  const messageBody = document.querySelector('[data-message-body]');
  if (cannedSelect && messageBody) {
    cannedSelect.addEventListener('change', () => {
      const option = cannedSelect.selectedOptions && cannedSelect.selectedOptions[0];
      const body = option && option.dataset ? option.dataset.body : '';
      if (!body) return;
      messageBody.value = body;
      messageBody.focus();
    });
  }

  const messageMode = document.getElementById('mode');
  if (messageMode && messageBody) {
    const syncLimit = () => {
      messageBody.maxLength = messageMode.value === 'sms' ? 480 : 4000;
    };
    messageMode.addEventListener('change', syncLimit);
    syncLimit();
  }
})();
