/*
 * portal-client.js — API client + realtime sync for /portal-api.  Framework-free ES module.
 *
 * Replaces every localStorage read/write for tasks, automation rules, roles and the audit log.
 * The ONLY thing kept in the browser is the session token (and a "legacy migrated" marker).
 * XSS note: anything in localStorage is readable by injected script. Keep the site's CSP tight and
 * never render server data with innerHTML (portal-ui.js uses textContent throughout).
 */

export class PortalError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.name = 'PortalError';
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

const SSE_EVENTS = [
  'task.upsert', 'task.delete', 'lead.upsert', 'webhook.delivery', 'member.changed', 'access.changed', 'pipeline.changed', 'engine.changed',
];

function safeStorage() {
  try {
    const k = '__portal_probe__';
    localStorage.setItem(k, '1');
    localStorage.removeItem(k);
    return {
      get: (key) => localStorage.getItem(key),
      set: (key, val) => localStorage.setItem(key, val),
      del: (key) => localStorage.removeItem(key),
    };
  } catch {
    const mem = new Map(); // private mode / blocked storage: session lives for this page only
    return { get: (k) => mem.get(k) ?? null, set: (k, v) => mem.set(k, v), del: (k) => mem.delete(k) };
  }
}

export function createPortalClient({ baseUrl, storage = safeStorage(), storageKey = 'portal.session', pollMs = 15000, timeoutMs = 10000 } = {}) {
  if (!baseUrl) throw new Error('createPortalClient: baseUrl is required, e.g. https://api.example.com/portal-api');
  baseUrl = baseUrl.replace(/\/+$/, '');

  /* ---------------------------------------------------------------- tiny event bus */
  const listeners = new Map();
  const on = (type, fn) => {
    if (!listeners.has(type)) listeners.set(type, new Set());
    listeners.get(type).add(fn);
    return () => listeners.get(type)?.delete(fn);
  };
  const emit = (type, data) => { for (const fn of listeners.get(type) ?? []) { try { fn(data); } catch (e) { console.error(e); } } };

  /* ---------------------------------------------------------------- session */
  let session = null;
  try { session = JSON.parse(storage.get(storageKey) || 'null'); } catch { session = null; }
  const setSession = (s) => {
    session = s;
    if (s) storage.set(storageKey, JSON.stringify(s)); else storage.del(storageKey);
    emit('session', s);
  };
  const token = () => session?.token ?? null;

  /* ---------------------------------------------------------------- http */
  async function request(method, path, { body, query, signal, responseType = 'json' } = {}) {
    const qs = query ? `?${new URLSearchParams(Object.entries(query).filter(([, v]) => v !== undefined && v !== null && v !== ''))}` : '';
    // Every call has a deadline. A host that accepts the connection and never answers (suspended, hung, black-holed) must not leave the page
    // waiting for minutes; the caller sees { code: 'timeout' } and treats the server as unavailable.
    const limit = responseType === 'blob' ? Math.max(timeoutMs, 60000) : timeoutMs;
    let timedOut = false, timer = null, sig = signal;
    if (limit > 0 && typeof AbortController === 'function') {
      const ac = new AbortController();
      timer = setTimeout(() => { timedOut = true; ac.abort(); }, limit);
      if (signal) { if (signal.aborted) ac.abort(); else signal.addEventListener('abort', () => ac.abort(), { once: true }); }
      sig = ac.signal;
    }
    const unreachable = (e) => (timedOut ? new PortalError(0, 'timeout', 'The server did not answer in time', { cause: String(e) }) : new PortalError(0, 'network_error', 'Cannot reach the server', { cause: String(e) }));
    try {
      let res;
      try {
        res = await fetch(`${baseUrl}${path}${qs}`, {
          method,
          signal: sig,
          headers: { ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...(token() ? { authorization: `Bearer ${token()}` } : {}) },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        });
      } catch (e) {
        throw unreachable(e);
      }
      if (res.status === 204) return null;
      if (responseType === 'blob' && res.ok) {
        try { return { blob: await res.blob(), filename: /filename="([^"]+)"/.exec(res.headers.get('content-disposition') || '')?.[1] }; } catch (e) { throw unreachable(e); }
      }
      let text;
      try { text = await res.text(); } catch (e) { throw unreachable(e); }
      let json = null;
      try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON error page from a proxy */ }
      if (!res.ok) {
        const err = json?.error ?? {};
        if (res.status === 401 && token()) { setSession(null); emit('unauthorized'); }
        throw new PortalError(res.status, typeof err.code === 'string' ? err.code : 'http_error', typeof err.message === 'string' ? err.message : `Request failed (${res.status})`, err.details);
      }
      if (json === null && text) throw new PortalError(res.status, 'bad_response', 'The server answered with something that is not JSON');
      return json;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
  const get = (p, query) => request('GET', p, { query });
  const post = (p, body) => request('POST', p, { body: body ?? {} });
  const patch = (p, body) => request('PATCH', p, { body });
  const put = (p, body) => request('PUT', p, { body });
  const del = (p, query) => request('DELETE', p, { query });

  /* ---------------------------------------------------------------- API surface */
  const auth = {
    async join({ joinCode, displayName, deviceLabel }) {
      const r = await post('/auth/join', { join_code: joinCode, display_name: displayName, device_label: deviceLabel });
      setSession({ token: r.session.token, userId: r.user.id, companyId: r.company.id });
      return r;
    },
    async redeemDeviceCode(code, deviceLabel) {
      const r = await post('/auth/device-codes/redeem', { code, device_label: deviceLabel });
      setSession({ token: r.session.token, userId: r.user.id, companyId: r.company.id });
      return r;
    },
    /** Sign in with the legacy portal's per-client portal_token (sent in the body, never a URL). Resolves with the session, or rejects with code
     *  not_linked (404) | legacy_token_rejected (401) | legacy_unavailable (503) | bridge_disabled (404). The session is least-privilege and short-lived. */
    async bridge(portalToken, deviceLabel) {
      const r = await post('/auth/bridge', { portal_token: portalToken, device_label: deviceLabel });
      setSession({ token: r.session.token, userId: r.user.id, companyId: r.company.id, kind: 'bridge', expiresAt: r.session.expires_at });
      return r;
    },
    useToken(t) { setSession({ token: t }); },
    me: () => get('/auth/me'),
    createDeviceCode: () => post('/auth/device-codes'),
    async logout() { try { await post('/auth/logout'); } finally { sync.stop(); setSession(null); } },
    isSignedIn: () => !!token(),
  };

  const team = {
    members: () => get('/team/members'),
    updateMember: (id, change) => patch(`/team/members/${id}`, change),
    removeMember: (id) => del(`/team/members/${id}`),
    joinCode: () => get('/team/join-code'),
    rotateJoinCode: () => post('/team/join-code/rotate'),
    setJoinEnabled: (joinEnabled) => patch('/team/join-settings', { join_enabled: joinEnabled }),
    legacyLinks: () => get('/team/legacy-links'),
    /** Owner/admin: connect a legacy portal_token to this workspace (the server verifies it with the legacy backend first). */
    createLegacyLink: (portalToken, label, permissionSetId) => post('/team/legacy-links', { portal_token: portalToken, label, ...(permissionSetId ? { permission_set_id: permissionSetId } : {}) }),
    /** While the server creates hot-lead tasks this is refused (409 engine_owner_server) unless { handBack: true } hands them back in the same step. */
    revokeLegacyLink: (id, { handBack = false } = {}) => del(`/team/legacy-links/${id}`, handBack ? { hand_back: 'true' } : undefined),
    /** Swap a link's token for the one you just rotated in the legacy system. Keeps the member, and the hot-lead switch is untouched. */
    rotateLegacyLink: (id, portalToken) => post(`/team/legacy-links/${id}/rotate`, { portal_token: portalToken }),
    permissionSets: () => get('/permission-sets'),
    createPermissionSet: (s) => post('/permission-sets', s),
    updatePermissionSet: (id, s) => patch(`/permission-sets/${id}`, s),
    deletePermissionSet: (id, reassignTo) => del(`/permission-sets/${id}`, { reassign_to: reassignTo }),
  };

  const leads = {
    list: (query) => get('/leads', query),
    create: (l) => post('/leads', l),
    update: (id, version, changes) => patch(`/leads/${id}`, { version, ...changes }),
    addActivity: (id, a) => post(`/leads/${id}/activities`, a),
    stages: () => get('/pipeline/stages'),
    saveStages: (stages) => put('/pipeline/stages', { stages }),
  };

  const automations = {
    list: () => get('/automations'),
    create: (r) => post('/automations', r),
    update: (id, changes) => patch(`/automations/${id}`, changes),
    remove: (id) => del(`/automations/${id}`),
    runs: (limit = 50) => get('/automations/runs', { limit }),
    /** Who turns "a lead became hot" into a task: { hot_lead_owner: 'server'|'browser', default_rule, last_server_lead_at, lead_feed_stale,
     *  lead_feed_stale_after_ms, last_hot_task_at, server_time }. { hotSince: ISO } also returns hot_tasks_since (server hot-lead rule runs since then). */
    engine: ({ hotSince } = {}) => get('/automations/engine', hotSince ? { hot_since: hotSince } : undefined),
    setEngineOwner: (owner) => put('/automations/engine', { hot_lead_owner: owner }),
  };

  const webhooks = {
    endpoints: () => get('/webhooks/endpoints'),
    createEndpoint: (e) => post('/webhooks/endpoints', e),
    updateEndpoint: (id, e) => patch(`/webhooks/endpoints/${id}`, e),
    deleteEndpoint: (id) => del(`/webhooks/endpoints/${id}`),
    test: (id) => post(`/webhooks/endpoints/${id}/test`),
    deliveries: (query) => get('/webhooks/deliveries', query),
    delivery: (id) => get(`/webhooks/deliveries/${id}`),
    redeliver: (id) => post(`/webhooks/deliveries/${id}/redeliver`),
    triggers: () => get('/triggers'),
    createTrigger: (t) => post('/triggers', t),
    updateTrigger: (id, t) => patch(`/triggers/${id}`, t),
    rotateTriggerSecret: (id) => post(`/triggers/${id}/rotate-secret`),
    deleteTrigger: (id) => del(`/triggers/${id}`),
  };

  const audit = {
    list: (filters) => get('/audit', filters),
    verify: () => post('/audit/verify'),
    certificateKey: () => get('/audit/certificate-key'),
    certificateStatus: () => get('/audit/certificate-status'),
    /** Authenticated download (a plain <a href> can't send the Authorization header). */
    async export({ format = 'csv', ...filters } = {}) {
      const { blob, filename } = await request('GET', '/audit/export', { query: { format, ...filters }, responseType: 'blob' });
      const url = URL.createObjectURL(blob);
      const a = Object.assign(document.createElement('a'), { href: url, download: filename || `audit.${format}` });
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 10_000);
      return filename;
    },
  };

  const forecast = { baseline: () => get('/forecast/baseline'), ai: () => get('/forecast/ai') };

  /* ---------------------------------------------------------------- realtime (SSE → polling fallback) */
  const sync = (() => {
    let es = null;
    let status = 'idle';          // idle | connecting | live | polling | offline
    let stopped = true;
    let retry = 1000;
    let retryTimer = null;
    let pollTimer = null;

    const setStatus = (s) => { if (s !== status) { status = s; emit('sync:status', s); } };

    function startPolling() {
      if (pollTimer) return;
      pollTimer = setInterval(() => { if (!stopped && status !== 'live') emit('sync:resync'); }, pollMs);
    }

    async function connect() {
      if (stopped || es) return;
      if (typeof navigator !== 'undefined' && navigator.onLine === false) { setStatus('offline'); return scheduleRetry(); }
      setStatus('connecting');
      try {
        const { ticket } = await post('/events/ticket');
        if (stopped || es) return; // stop() (or a second connect) won the race while the ticket request was in flight
        es = new EventSource(`${baseUrl}/events?ticket=${encodeURIComponent(ticket)}`);
      } catch (e) {
        if (e instanceof PortalError && e.status === 401) return stop();
        setStatus('polling');
        return scheduleRetry();
      }
      es.addEventListener('ready', () => { retry = 1000; setStatus('live'); emit('sync:resync'); });
      for (const t of SSE_EVENTS) es.addEventListener(t, (ev) => { try { emit(t, JSON.parse(ev.data)); } catch { /* ignore malformed frame */ } });
      es.onerror = () => {
        // EventSource would auto-retry with the SAME (now consumed) ticket. Close and fetch a new one instead.
        es?.close();
        es = null;
        if (stopped) return;
        setStatus(navigator.onLine === false ? 'offline' : 'polling');
        scheduleRetry();
      };
    }

    function scheduleRetry() {
      clearTimeout(retryTimer);
      retryTimer = setTimeout(connect, retry);
      retry = Math.min(retry * 2, 30_000);
    }

    const onVisible = () => { if (!stopped && document.visibilityState === 'visible') { emit('sync:resync'); if (!es) { retry = 1000; connect(); } } };
    const onOnline = () => { if (!stopped) { retry = 1000; clearTimeout(retryTimer); connect(); emit('sync:resync'); } };
    const onOffline = () => { if (!stopped) setStatus('offline'); };

    function start() {
      if (!stopped) return;
      stopped = false;
      startPolling();
      document.addEventListener('visibilitychange', onVisible);
      window.addEventListener('online', onOnline);
      window.addEventListener('offline', onOffline);
      connect();
    }

    function stop() {
      stopped = true;
      clearTimeout(retryTimer);
      clearInterval(pollTimer);
      pollTimer = null;
      es?.close();
      es = null;
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('online', onOnline);
      window.removeEventListener('offline', onOffline);
      setStatus('idle');
    }

    return { start, stop, status: () => status };
  })();

  /* ---------------------------------------------------------------- optimistic task store */
  class TaskStore {
    constructor(scope) {
      this.scope = scope; // 'team' | 'company'
      this.tasks = new Map();
      this.pending = new Set();     // ids with an in-flight optimistic change
      this.since = null;
      this.subs = new Set();
      this.loaded = false;
      this.offs = [
        on('task.upsert', ({ task }) => this.#incoming(task)),
        on('task.delete', (d) => this.#remove(d.id, d.version)),
        on('sync:resync', () => this.refresh().catch(() => {})),
      ];
    }

    subscribe(fn) { this.subs.add(fn); return () => this.subs.delete(fn); }
    destroy() { this.offs.forEach((o) => o()); this.subs.clear(); }
    #notify() { for (const fn of this.subs) fn(this.list()); }

    list() {
      const rank = { urgent: 0, high: 1, normal: 2, low: 3 };
      return [...this.tasks.values()].sort((a, b) =>
        (a.status === 'done') - (b.status === 'done') || rank[a.priority] - rank[b.priority] || b.created_at.localeCompare(a.created_at));
    }

    #incoming(task) {
      if (task.scope !== this.scope) { // moved to the other scope: drop it here
        if (this.tasks.delete(task.id)) this.#notify();
        return;
      }
      const cur = this.tasks.get(task.id);
      if (this.pending.has(task.id)) return;                       // our own in-flight change will reconcile
      if (cur && cur.version > task.version) return;               // stale echo
      this.tasks.set(task.id, task);
      this.#notify();
    }

    #remove(id, version) {
      const cur = this.tasks.get(id);
      if (cur && version !== undefined && cur.version > version) return;
      if (this.tasks.delete(id)) this.#notify();
    }

    async load() {
      const r = await get('/tasks', { scope: this.scope });
      this.tasks = new Map(r.tasks.map((t) => [t.id, t]));
      this.since = r.server_time;
      this.loaded = true;
      this.#notify();
    }

    /** Delta sync: only what changed since last time, including deletions. Safe to call often. */
    async refresh() {
      if (!this.loaded) return this.load();
      const since = new Date(Date.parse(this.since) - 2000).toISOString(); // overlap guards clock/commit skew; versions dedupe
      const r = await get('/tasks', { scope: this.scope, since });
      for (const t of r.tasks) this.#incoming(t);
      for (const d of r.deleted) this.#remove(d.id, d.version);
      this.since = r.server_time;
    }

    async create(input) {
      const id = crypto.randomUUID();
      const now = new Date().toISOString();
      const optimistic = { id, scope: this.scope, title: '', description: '', status: 'open', priority: 'normal', kind: 'manual', queue: null,
        assignee_id: null, assignee_name: null, lead_id: null, due_at: null, external_ref: null, created_by: session?.userId ?? '',
        created_at: now, updated_at: now, completed_at: null, version: 0, deleted: false, ...input, _pending: true };
      this.tasks.set(id, optimistic);
      this.pending.add(id);
      this.#notify();
      try {
        const r = await post('/tasks', { id, scope: this.scope, ...input }); // client id => safe to retry
        this.tasks.set(id, r.task);
        return r.task;
      } catch (e) {
        this.tasks.delete(id);
        throw e;
      } finally {
        this.pending.delete(id);
        this.#notify();
      }
    }

    /**
     * Optimistic update with server reconciliation. On a 409 the server hands back its current
     * row. If nobody else touched the fields we changed, we re-apply our change on top of it
     * (rebase) and retry once; otherwise we keep the server's version and emit 'conflict'.
     */
    async update(id, changes) {
      const base = this.tasks.get(id);
      if (!base) throw new PortalError(404, 'not_found', 'Task not found locally');
      this.tasks.set(id, { ...base, ...changes, _pending: true });
      this.pending.add(id);
      this.#notify();
      const attempt = (version) => patch(`/tasks/${id}`, { version, ...changes });
      try {
        let r;
        try {
          r = await attempt(base.version);
        } catch (e) {
          if (!(e instanceof PortalError) || e.code !== 'version_conflict') throw e;
          const current = e.details.current;
          const untouched = Object.keys(changes).every((k) => current[k] === base[k]);
          if (!untouched) {
            this.tasks.set(id, current);
            emit('conflict', { scope: this.scope, task: current, attempted: changes });
            return current;
          }
          r = await attempt(current.version); // rebase onto the server's version
        }
        this.tasks.set(id, r.task);
        return r.task;
      } catch (e) {
        this.tasks.set(id, base); // roll back
        throw e;
      } finally {
        this.pending.delete(id);
        this.#notify();
      }
    }

    async remove(id) {
      const base = this.tasks.get(id);
      if (!base) return;
      this.tasks.delete(id);
      this.pending.add(id);
      this.#notify();
      try {
        await del(`/tasks/${id}`);
      } catch (e) {
        this.tasks.set(id, base);
        throw e;
      } finally {
        this.pending.delete(id);
        this.#notify();
      }
    }
  }

  /* ---------------------------------------------------------------- legacy localStorage migration */
  /**
   * adapter (YOU supply this: it knows your old localStorage key names):
   *   key():   string identifying the old store (the portal token), used server-side as an idempotency key
   *   read():  { tasks, automation_rules, roles, audit_log } | null   (null/empty => nothing to migrate)
   *   clear(): removes the old keys — called ONLY after the server confirms the import
   * mode: 'auto' migrates silently; 'prompt' calls confirm(summary) first (one-click UX).
   */
  async function migrateLegacy(adapter, { mode = 'prompt', confirm = async () => true } = {}) {
    const data = adapter.read();
    const has = data && ['tasks', 'automation_rules', 'roles', 'audit_log'].some((k) => (Array.isArray(data[k]) ? data[k].length : data[k] && Object.keys(data[k]).length));
    if (!has) return { status: 'none' };
    if (mode === 'prompt') {
      const ok = await confirm({ tasks: data.tasks?.length ?? 0, automation_rules: data.automation_rules?.length ?? 0 });
      if (!ok) return { status: 'declined' };
    }
    const r = await post('/migrate', { legacy_key: adapter.key(), ...data });
    adapter.clear(); // server has it (201) or already had it (200 already_migrated): safe to drop the local copy
    return { status: r.already_migrated ? 'already' : 'done', summary: r.summary };
  }

  return {
    baseUrl, on, request,
    auth, team, leads, automations, webhooks, audit, forecast, sync,
    session: () => session,
    taskStore: (scope) => new TaskStore(scope),
    migrateLegacy,
  };
}
