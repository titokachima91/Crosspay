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

  function feedRows(feed) {
    if (!feed || feed.length === 0) return '<div class="empty">No activity yet.</div>';
    return feed.map((event) => {
      const tag = event.source === 'admin' ? 'admin'
        : event.source === 'trade' ? 'trade'
        : event.source === 'payout' ? 'payout'
        : event.source === 'refund' ? 'refund'
        : event.source;
      return '<div class="feed-row">'
        + '<div class="time">' + esc(shortDate(event.at)) + '</div>'
        + '<div><span class="tag">' + esc(tag) + '</span></div>'
        + '<div>' + esc(event.summary) + (event.reference ? ' <a class="mono" href="' + esc(event.href) + '">' + esc(event.reference) + '</a>' : '') + '</div>'
        + '</div>';
    }).join('');
  }

  async function refreshControl() {
    const feedElement = document.getElementById('control-feed') || document.getElementById('mini-feed');
    if (!feedElement) return;
    const endpoint = feedElement.dataset.endpoint || '/control-room/data';
    try {
      const response = await fetch(endpoint, { headers: { accept: 'application/json' } });
      if (response.status === 401) {
        window.location.href = '/login';
        return;
      }
      if (!response.ok) throw new Error('HTTP ' + response.status);
      const data = await response.json();
      const overview = data.overview;
      const set = (id, value) => { const el = document.getElementById(id); if (el) el.textContent = value; };
      set('kpi-queue', overview.counts.queue);
      set('kpi-matches', overview.counts.matches);
      set('kpi-payouts', overview.counts.payouts);
      set('kpi-refunds', overview.counts.refunds);
      set('kpi-lp', overview.counts.liquidityOrders);
      feedElement.innerHTML = feedRows(data.feed);
      const updated = document.getElementById('feed-updated');
      if (updated) updated.textContent = 'updated ' + new Date().toLocaleTimeString();

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
      const audit = document.getElementById('control-audit');
      if (audit) {
        audit.innerHTML = data.audit.length === 0
          ? '<div class="empty">No admin actions yet.</div>'
          : '<table><thead><tr><th>When</th><th>Actor</th><th>Action</th><th>Resource</th></tr></thead><tbody>'
            + data.audit.map((row) => '<tr><td>' + esc(shortDate(row.created_at)) + '</td><td>' + esc(row.admin_email || row.actor_label) + '</td><td class="mono">' + esc(row.action) + '</td><td>' + esc(row.resource_type) + ' <span class="tag">' + esc(row.resource_id || '') + '</span></td></tr>').join('')
            + '</tbody></table>';
      }
    } catch (error) {
      const updated = document.getElementById('feed-updated');
      if (updated) updated.textContent = 'feed error: ' + error.message;
    }
  }

  if (document.getElementById('control-feed') || document.getElementById('mini-feed')) {
    refreshControl();
    setInterval(refreshControl, 5000);
  }

  document.addEventListener('submit', (event) => {
    const form = event.target;
    if (form.matches('form[data-confirm]')) {
      if (!window.confirm(form.dataset.confirm)) event.preventDefault();
    }
  });
})();
