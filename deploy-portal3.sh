#!/bin/bash
# NewSites Portal v3 — gold theme + built-in CRM tools + provisioning. Run AFTER deploy-portal2.sh.
#   bash deploy-portal3.sh   (ON THE DROPLET)
set -uo pipefail
BASE="${NEWSITES_BASE:-/root/newsites-sms}"
STAMP=$(date +%Y%m%d-%H%M%S)
FAIL=0
ok()  { echo "  [OK] $*"; }
bad() { echo "  [FAIL] $*"; FAIL=1; }
die() { echo; echo "XX ABORTED: $*"; exit 1; }
[ -d "$BASE" ] || die "run ON THE DROPLET"
cd "$BASE" || die "cd failed"
export DATA_ROOT="$BASE"
[ -f lib/transcripts.js ] || die "deploy-portal2.sh has not been run — run it first"

echo "==> 1/4 Write files"
cp routes/portal-api.js "routes/portal-api.js.bak-$STAMP" 2>/dev/null || true
cat > routes/portal-api.js << 'EOF_P3_API'
'use strict';

// Client Portal API — mounted at /portal-api by index.js.
//
// AUTH MODEL (v1, deliberate): every client profile carries a random
// `portal_token` (generated at deploy). Every request must send it as
// `?token=` or `X-Portal-Token`. Token → client slug; a client can only ever
// see and edit their own data. This is bearer-token access, not user
// accounts — fine for a handful of clients, revocable per client by editing
// profile.json. Real login/sessions is a Phase-2 item; do NOT bolt password
// forms onto this.
//
// HONESTY RULES baked in:
//   - No fabricated metrics. Everything on the Overview is computed from
//     files that actually exist (crm.json, jobs.json, pending-posts.json).
//   - Settings writes are whitelisted field-by-field and validated; nothing
//     else in profile.json is reachable from the portal.
//   - Persona/prompt fields are read-only here (changing them requires a
//     recompile; that stays a deliberate operator action).

const express = require('express');
const crypto = require('crypto');
const store = require('../lib/store');
const profiles = require('../lib/profiles');
const phone = require('../lib/phone');

const router = express.Router();
router.use(express.json({ limit: '200kb' }));

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

async function slugForToken(token) {
  if (!token || typeof token !== 'string' || token.length < 16) return null;
  const slugs = await profiles.listClientSlugs();
  for (const slug of slugs) {
    const p = await profiles.loadProfile(slug);
    if (p && p.portal_token && crypto.timingSafeEqual(
      Buffer.from(String(p.portal_token)),
      Buffer.from(token.padEnd(String(p.portal_token).length).slice(0, String(p.portal_token).length))
    ) && String(p.portal_token) === token) {
      return slug;
    }
  }
  return null;
}

router.use(async (req, res, next) => {
  try {
    const token = req.query.token || req.get('X-Portal-Token');
    const slug = await slugForToken(token);
    if (!slug) return res.status(401).json({ error: 'invalid or missing portal token' });
    req.clientSlug = slug;
    req.clientProfile = await profiles.loadProfile(slug);
    next();
  } catch (e) {
    console.error('[portal] auth error:', e);
    res.status(500).json({ error: 'internal error' });
  }
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function leadArray(crm) {
  const out = [];
  for (const [key, l] of Object.entries((crm && crm.leads) || {})) {
    out.push({ key, ...l });
  }
  out.sort((a, b) => new Date(b.updated_at || 0) - new Date(a.updated_at || 0));
  return out;
}

function scoreBadge(score, threshold) {
  if (!Number.isFinite(score)) return 'unscored';
  if (score >= threshold) return 'hot';
  if (score >= Math.max(2, threshold - 2)) return 'warm';
  return 'cold';
}

// Pull stored scores for this client's leads from the legacy dashboard file
// (the only place scores persist today), matched by last-10 phone digits.
async function scoreMap() {
  const legacy = await store.readJson('crm.json', []);
  const map = new Map();
  if (Array.isArray(legacy)) {
    for (const c of legacy) {
      if (c && c.phone && Number.isFinite(c.score)) map.set(phone.last10(c.phone), c.score);
    }
  }
  return map;
}

// ---------------------------------------------------------------------------
// GET /portal-api/summary — Overview metrics (real data only)
// ---------------------------------------------------------------------------

router.get('/summary', async (req, res) => {
  try {
    const slug = req.clientSlug;
    const p = req.clientProfile || {};
    const crm = await store.readJson(`clients/${slug}/crm.json`, { leads: {} });
    const leads = leadArray(crm);
    const weekAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
    const threshold = Number.isFinite(p.lead_alert_threshold) ? p.lead_alert_threshold : 5;
    const scores = await scoreMap();

    const byStage = {};
    let hot = 0;
    for (const l of leads) {
      byStage[l.stage || 'Unstaged'] = (byStage[l.stage || 'Unstaged'] || 0) + 1;
      const s = l.phone ? scores.get(phone.last10(l.phone)) : undefined;
      if (Number.isFinite(s) && s >= threshold) hot += 1;
    }

    const jobsDb = await store.readJson('jobs/jobs.json', { jobs: [] });
    const upcoming = (jobsDb.jobs || []).filter(
      (j) => j.client_slug === slug && j.status === 'pending'
    ).length;

    res.json({
      business_name: (p.identity && p.identity.business_name) || slug,
      ai_enabled: p.ai_enabled !== false,
      totals: {
        leads: leads.length,
        new_this_week: leads.filter((l) => new Date(l.created_at || 0).getTime() > weekAgo).length,
        hot_leads: hot,
        scheduled_followups: upcoming,
      },
      pipeline: byStage,
      // Deliberately absent: revenue, conversion %, response-time — the
      // backend does not record those yet. The portal must not invent them.
    });
  } catch (e) {
    console.error('[portal] summary:', e);
    res.status(500).json({ error: 'internal error' });
  }
});

// ---------------------------------------------------------------------------
// GET /portal-api/leads — Live lead stream
// GET /portal-api/leads/:key — one lead + full history
// ---------------------------------------------------------------------------

router.get('/leads', async (req, res) => {
  try {
    const slug = req.clientSlug;
    const p = req.clientProfile || {};
    const threshold = Number.isFinite(p.lead_alert_threshold) ? p.lead_alert_threshold : 5;
    const crm = await store.readJson(`clients/${slug}/crm.json`, { leads: {} });
    const scores = await scoreMap();
    const rows = leadArray(crm).slice(0, 200).map((l) => {
      const s = l.phone ? scores.get(phone.last10(l.phone)) : undefined;
      const lastNote = (l.history || []).slice().reverse().find((h) => h.note);
      return {
        key: l.key,
        name: l.name || null,
        phone: l.phone || null,
        email: l.email || null,
        stage: l.stage,
        source: l.source,
        tags: l.tags || [],
        created_at: l.created_at,
        last_activity_at: l.last_activity_at,
        score: Number.isFinite(s) ? s : null,
        badge: scoreBadge(s, threshold),
        summary: lastNote ? lastNote.note : null,
      };
    });
    res.json({ leads: rows });
  } catch (e) {
    console.error('[portal] leads:', e);
    res.status(500).json({ error: 'internal error' });
  }
});

router.get('/leads/:key', async (req, res) => {
  try {
    const crm = await store.readJson(`clients/${req.clientSlug}/crm.json`, { leads: {} });
    const lead = crm.leads && crm.leads[req.params.key];
    if (!lead) return res.status(404).json({ error: 'lead not found' });
    res.json({ key: req.params.key, ...lead });
  } catch (e) {
    res.status(500).json({ error: 'internal error' });
  }
});

// POST /portal-api/leads/:key/stage  { stage }
const crmAdapter = require('../crm-adapter');
router.post('/leads/:key/stage', async (req, res) => {
  try {
    const stage = String((req.body && req.body.stage) || '').slice(0, 60);
    if (!stage) return res.status(400).json({ error: 'stage required' });
    const lead = await crmAdapter.moveStage(req.clientSlug, req.params.key, stage, { via: 'portal' });
    if (!lead) return res.status(404).json({ error: 'lead not found (email-keyed leads move via dashboard for now)' });
    res.json({ ok: true, stage: lead.stage });
  } catch (e) {
    console.error('[portal] stage:', e);
    res.status(500).json({ error: 'internal error' });
  }
});

// ---------------------------------------------------------------------------
// Settings — read + whitelisted writes
// ---------------------------------------------------------------------------

router.get('/settings', async (req, res) => {
  const p = req.clientProfile || {};
  res.json({
    editable: {
      ai_enabled: p.ai_enabled !== false,
      routing_mode: p.routing_mode === 'manual' ? 'manual' : 'auto',
      owner_cell: (p.identity && p.identity.owner_cell) || '',
      escalation_cell: (p.voice_sms_persona && p.voice_sms_persona.escalation_cell) || '',
      lead_alert_threshold: Number.isFinite(p.lead_alert_threshold) ? p.lead_alert_threshold : 5,
      quiet_hours: (p.compliance && p.compliance.quiet_hours) || { start: '21:00', end: '08:00' },
    },
    readonly: {
      business_name: (p.identity && p.identity.business_name) || '',
      timezone: (p.identity && p.identity.timezone) || '',
      tone: (p.voice_sms_persona && p.voice_sms_persona.tone) || {},
      services: ((p.offer && p.offer.services) || []).map((s) => ({ name: s.name, price: s.price })),
      note: 'Persona, services, and prices are set with your NewSites manager — changing them re-trains the AI.',
    },
  });
});

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

router.post('/settings', async (req, res) => {
  try {
    const b = req.body || {};
    const errors = [];
    const patch = {};

    if ('ai_enabled' in b) patch.ai_enabled = Boolean(b.ai_enabled);
    if ('routing_mode' in b) {
      if (!['auto', 'manual'].includes(b.routing_mode)) errors.push('routing_mode must be auto|manual');
      else patch.routing_mode = b.routing_mode;
    }
    if ('lead_alert_threshold' in b) {
      const t = Number(b.lead_alert_threshold);
      if (!Number.isFinite(t) || t < 0 || t > 10) errors.push('lead_alert_threshold must be 0-10');
      else patch.lead_alert_threshold = Math.round(t);
    }
    if ('owner_cell' in b) {
      const e164 = phone.toE164(b.owner_cell);
      if (!e164) errors.push('owner_cell is not a valid US phone number');
      else patch.owner_cell = e164;
    }
    if ('escalation_cell' in b) {
      const e164 = b.escalation_cell === '' ? '' : phone.toE164(b.escalation_cell);
      if (e164 === null) errors.push('escalation_cell is not a valid US phone number');
      else patch.escalation_cell = e164;
    }
    if ('quiet_hours' in b) {
      const q = b.quiet_hours || {};
      if (!HHMM.test(q.start || '') || !HHMM.test(q.end || '')) errors.push('quiet_hours must be HH:MM 24h');
      else patch.quiet_hours = { start: q.start, end: q.end };
    }
    if (errors.length) return res.status(400).json({ ok: false, errors });
    if (!Object.keys(patch).length) return res.status(400).json({ ok: false, errors: ['nothing to update'] });

    await store.updateJson(`clients/${req.clientSlug}/profile.json`, null, (p) => {
      if (!p) throw new Error('profile missing');
      if ('ai_enabled' in patch) p.ai_enabled = patch.ai_enabled;
      if ('routing_mode' in patch) p.routing_mode = patch.routing_mode;
      if ('lead_alert_threshold' in patch) p.lead_alert_threshold = patch.lead_alert_threshold;
      if ('owner_cell' in patch) { p.identity = p.identity || {}; p.identity.owner_cell = patch.owner_cell; }
      if ('escalation_cell' in patch) { p.voice_sms_persona = p.voice_sms_persona || {}; p.voice_sms_persona.escalation_cell = patch.escalation_cell; }
      if ('quiet_hours' in patch) { p.compliance = p.compliance || {}; p.compliance.quiet_hours = patch.quiet_hours; }
    });
    profiles.bustCache();
    res.json({ ok: true, applied: Object.keys(patch), live_within_seconds: 30 });
  } catch (e) {
    console.error('[portal] settings write:', e);
    res.status(500).json({ error: 'internal error' });
  }
});

// ---------------------------------------------------------------------------
// Social queue — read + approve/reject/reschedule
// ---------------------------------------------------------------------------

function postVisibleTo(post, profile, slug) {
  if (slug === 'newsites') return true; // operator sees everything
  const biz = profile && profile.identity && profile.identity.business_name;
  return Boolean(biz && post.clientName && post.clientName.toLowerCase() === biz.toLowerCase());
}

router.get('/posts', async (req, res) => {
  try {
    const posts = await store.readJson('pending-posts.json', []);
    const mine = (Array.isArray(posts) ? posts : [])
      .filter((p) => postVisibleTo(p, req.clientProfile, req.clientSlug))
      .sort((a, b) => new Date(a.scheduledFor || a.createdAt || 0) - new Date(b.scheduledFor || b.createdAt || 0));
    res.json({ posts: mine });
  } catch (e) {
    res.status(500).json({ error: 'internal error' });
  }
});

router.post('/posts/:id', async (req, res) => {
  try {
    const { action, message, scheduledFor } = req.body || {};
    if (!['approve', 'reject', 'edit', 'reschedule'].includes(action)) {
      return res.status(400).json({ error: 'action must be approve|reject|edit|reschedule' });
    }
    let target = null;
    await store.updateJson('pending-posts.json', [], (posts) => {
      const p = (Array.isArray(posts) ? posts : []).find((x) => x.id === req.params.id);
      if (!p || !postVisibleTo(p, req.clientProfile, req.clientSlug)) return;
      target = p;
      if (action === 'reject') p.status = 'rejected';
      if (action === 'edit' && typeof message === 'string' && message.trim()) p.message = message.trim().slice(0, 2000);
      if (action === 'reschedule' && scheduledFor && !Number.isNaN(Date.parse(scheduledFor))) p.scheduledFor = new Date(scheduledFor).toISOString();
      if (action === 'approve') p.status = 'approved';
    });
    if (!target) return res.status(404).json({ error: 'post not found' });

    // Approval fires the existing Make.com hook — same payload the email link used.
    if (action === 'approve') {
      try {
        const https = require('https');
        const payload = target.imageUrl
          ? JSON.stringify({ message: target.message, imageUrl: target.imageUrl })
          : JSON.stringify({ message: target.message });
        await new Promise((resolve, reject) => {
          const r = https.request({
            hostname: 'hook.us2.make.com',
            path: '/dzmqe5zvxx8t8ew4vtpsvzb9d7d5cz5h',
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
          }, resolve);
          r.on('error', reject);
          r.write(payload);
          r.end();
        });
      } catch (e) {
        console.warn('[portal] make.com hook failed:', e.message);
        return res.json({ ok: true, action, warning: 'approved locally but publish hook failed — it will not post' });
      }
    }
    res.json({ ok: true, action });
  } catch (e) {
    console.error('[portal] post action:', e);
    res.status(500).json({ error: 'internal error' });
  }
});


// ---------------------------------------------------------------------------
// Conversations — transcripts + recording playback
// ---------------------------------------------------------------------------
const transcriptsLib = require('../lib/transcripts');
const { Readable } = require('stream');

// GET /portal-api/transcripts?phone=+1...&limit=30
router.get('/transcripts', async (req, res) => {
  try {
    const list = await transcriptsLib.listRecent(req.clientSlug, {
      phoneFilter: req.query.phone || null,
      limit: Math.min(100, parseInt(req.query.limit, 10) || 30),
    });
    res.json({ transcripts: list });
  } catch (e) {
    console.error('[portal] transcripts list:', e);
    res.status(500).json({ error: 'internal error' });
  }
});

// GET /portal-api/transcripts/one?file=YYYY-MM/voice-CAxxx.json
router.get('/transcripts/one', async (req, res) => {
  try {
    const doc = await transcriptsLib.readDoc(req.clientSlug, String(req.query.file || ''));
    if (!doc) return res.status(404).json({ error: 'transcript not found' });
    res.json(doc);
  } catch (e) {
    res.status(500).json({ error: 'internal error' });
  }
});

// GET /portal-api/recordings/:sid — streams the mp3 from Twilio with account
// auth, but ONLY after proving this recording belongs to one of THIS client's
// transcripts. Audio never becomes a public URL.
router.get('/recordings/:sid', async (req, res) => {
  try {
    const sid = String(req.params.sid || '');
    if (!/^RE[a-f0-9]{32}$/i.test(sid)) return res.status(400).json({ error: 'bad recording id' });
    const owns = await transcriptsLib.ownsRecording(req.clientSlug, sid);
    if (!owns) return res.status(404).json({ error: 'recording not found' });
    const acct = process.env.TWILIO_ACCOUNT_SID, tok = process.env.TWILIO_AUTH_TOKEN;
    if (!acct || !tok) return res.status(503).json({ error: 'recordings unavailable' });
    const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${acct}/Recordings/${sid}.mp3`, {
      headers: { Authorization: 'Basic ' + Buffer.from(`${acct}:${tok}`).toString('base64') },
      signal: AbortSignal.timeout(20000),
    });
    if (!r.ok || !r.body) return res.status(502).json({ error: `upstream ${r.status}` });
    res.set('Content-Type', 'audio/mpeg');
    res.set('Cache-Control', 'private, max-age=300');
    Readable.fromWeb(r.body).pipe(res);
  } catch (e) {
    console.error('[portal] recording proxy:', e);
    if (!res.headersSent) res.status(500).json({ error: 'internal error' });
  }
});


// POST /portal-api/leads/add — manual contact entry from the portal.
router.post('/leads/add', async (req, res) => {
  try {
    const b = req.body || {};
    const e164 = b.phone ? phone.toE164(b.phone) : null;
    const email = b.email ? String(b.email).trim() : '';
    if (!e164 && !email) return res.status(400).json({ ok: false, errors: ['phone or email required'] });
    if (b.phone && !e164) return res.status(400).json({ ok: false, errors: ['phone is not a valid US number'] });
    const lead = await crmAdapter.upsertLead(req.clientSlug, {
      name: b.name ? String(b.name).trim().slice(0, 80) : null,
      phone: e164,
      email: email || null,
      note: b.note ? String(b.note).trim().slice(0, 300) : undefined,
      stage: 'New Lead',
      source: 'manual',
      tags: ['manual'],
    });
    res.json({ ok: true, key: lead && (lead.phone || ('email:' + email.toLowerCase())) });
  } catch (e) {
    console.error('[portal] leads/add:', e);
    res.status(500).json({ ok: false, errors: ['internal error'] });
  }
});

module.exports = router;
EOF_P3_API
cat > portal/portal.html << 'EOF_P3_HTM'
<!DOCTYPE html>
<html lang="en" class="dark">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NewSites — Client Portal</title>
<script src="https://cdn.tailwindcss.com"></script>
<style>
  :root { color-scheme: dark; }
  body { background: #060608; }
  .glass { background: rgba(14, 14, 18, .82); backdrop-filter: blur(8px); border: 1px solid rgba(201, 168, 76, .22); }
  .tab-active { color: #E8C97A; border-color: #C9A84C; }
  .badge-hot { background: rgba(239,68,68,.15); color: #f87171; border: 1px solid rgba(239,68,68,.35); }
  .badge-warm { background: rgba(245,158,11,.15); color: #fbbf24; border: 1px solid rgba(245,158,11,.35); }
  .badge-cold { background: rgba(201,168,76,.10); color: #C9A84C; border: 1px solid rgba(201,168,76,.3); }
  .badge-unscored { background: rgba(148,163,184,.12); color: #94a3b8; border: 1px solid rgba(148,163,184,.25); }
  ::-webkit-scrollbar { width: 8px; height: 8px; } ::-webkit-scrollbar-thumb { background: #1e293b; border-radius: 4px; }
  .fade-in { animation: fi .18s ease-out; } @keyframes fi { from { opacity:0; transform: translateY(4px);} to {opacity:1; transform:none;} }
</style>
</head>
<body class="text-slate-200 min-h-screen">

<div id="gate" class="hidden min-h-screen flex items-center justify-center p-6">
  <div class="glass rounded-2xl p-8 max-w-md w-full text-center">
    <div class="text-2xl font-bold text-white mb-2">NewSites Portal</div>
    <p class="text-slate-400 text-sm mb-6">Enter your access key. It's in your welcome text/email — or ask your NewSites manager.</p>
    <input id="tokenInput" type="password" placeholder="Access key" class="w-full bg-slate-900 border border-slate-700 rounded-lg px-4 py-3 mb-3 focus:outline-none focus:border-[#C9A84C]">
    <button onclick="saveToken()" class="w-full bg-[#C9A84C] hover:bg-[#E8C97A] text-black font-bold rounded-lg py-3">Open my dashboard</button>
    <p id="gateErr" class="text-red-400 text-sm mt-3 hidden">That key didn't work.</p>
  </div>
</div>

<div id="app" class="hidden">
  <header class="sticky top-0 z-30 glass">
    <div class="max-w-6xl mx-auto px-4 py-3 flex items-center gap-4">
      <div class="flex items-center gap-2 font-bold text-white"><span class="w-2.5 h-2.5 rounded-sm bg-[#C9A84C] shadow-[0_0_10px_rgba(201,168,76,.8)]"></span><span id="bizName">NewSites</span></div>
      <div id="aiPill" class="text-xs px-2 py-1 rounded-full border"></div>
      <nav class="ml-auto flex gap-1 overflow-x-auto text-sm">
        <button data-tab="overview" class="tabBtn px-3 py-2 border-b-2 border-transparent hover:text-[#E8C97A]">Overview</button>
        <button data-tab="leads" class="tabBtn px-3 py-2 border-b-2 border-transparent hover:text-[#E8C97A]">Lead Generation</button>
        <button data-tab="voice" class="tabBtn px-3 py-2 border-b-2 border-transparent hover:text-[#E8C97A]">AI Voice &amp; SMS</button>
        <button data-tab="social" class="tabBtn px-3 py-2 border-b-2 border-transparent hover:text-[#E8C97A]">Social Engine</button>
        <button data-tab="settings" class="tabBtn px-3 py-2 border-b-2 border-transparent hover:text-[#E8C97A]">Settings</button>
      </nav>
    </div>
  </header>

  <main class="max-w-6xl mx-auto px-4 py-6">

    <section id="tab-overview" class="tabPane hidden fade-in">
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6" id="metricCards"></div>
      <div class="glass rounded-2xl p-5">
        <h3 class="font-semibold text-white mb-3">Pipeline</h3>
        <div id="pipeline" class="space-y-2"></div>
      </div>
    </section>

    <section id="tab-leads" class="tabPane hidden fade-in">
      <div class="grid lg:grid-cols-3 gap-5">
        <div class="lg:col-span-2 glass rounded-2xl p-5">
          <div class="flex items-center justify-between mb-3 gap-3 flex-wrap">
            <h3 class="font-semibold text-white">Live Lead Stream</h3>
            <div class="flex items-center gap-2 ml-auto">
              <input id="leadSearch" oninput="renderLeads()" placeholder="Search name, phone, email…" class="bg-slate-900 border border-slate-700 rounded-lg px-3 py-1.5 text-sm w-52 focus:outline-none focus:border-[#C9A84C]">
              <button onclick="toggleAdd()" class="bg-[#C9A84C] hover:bg-[#E8C97A] text-black font-bold rounded-lg px-3 py-1.5 text-sm">+ Add Contact</button>
              <button onclick="loadLeads()" class="text-xs text-[#E8C97A] hover:text-[#F0DCA0]">↻</button>
            </div>
          </div>
          <div id="addBox" class="hidden mb-4 p-3 rounded-xl border border-[#C9A84C]/40 bg-slate-900/40">
            <div class="grid grid-cols-2 gap-2 mb-2">
              <input id="acName" placeholder="Name" class="bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-sm">
              <input id="acPhone" placeholder="Phone" class="bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-sm">
              <input id="acEmail" placeholder="Email (optional)" class="bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-sm">
              <input id="acNote" placeholder="Note (optional)" class="bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-sm">
            </div>
            <div class="flex items-center gap-3">
              <button onclick="addContact()" class="bg-[#C9A84C] hover:bg-[#E8C97A] text-black font-bold rounded-lg px-4 py-2 text-sm">Save contact</button>
              <span id="acMsg" class="text-xs"></span>
            </div>
          </div>
          <div class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead><tr class="text-slate-400 text-left border-b border-slate-800">
                <th class="py-2 pr-3">When</th><th class="py-2 pr-3">Contact</th><th class="py-2 pr-3">Source</th><th class="py-2 pr-3">Score</th><th class="py-2">Latest</th>
              </tr></thead>
              <tbody id="leadRows"></tbody>
            </table>
          </div>
        </div>
        <div class="glass rounded-2xl p-5 h-fit">
          <h3 class="font-semibold text-white mb-1">Lead Routing</h3>
          <p class="text-xs text-slate-400 mb-4">How inbound leads reach you.</p>
          <div class="space-y-3 text-sm">
            <label class="flex items-start gap-3 p-3 rounded-lg border border-slate-700 cursor-pointer hover:border-[#C9A84C]">
              <input type="radio" name="routing" value="auto" class="mt-1">
              <span><span class="text-white font-medium">AI Brain Auto-Routing</span><br><span class="text-slate-400">Hot leads (score ≥ your threshold) text you instantly. Everything else lands in the CRM and gets the automated follow-up sequence. Quiet hours respected.</span></span>
            </label>
            <label class="flex items-start gap-3 p-3 rounded-lg border border-slate-700 cursor-pointer hover:border-[#C9A84C]">
              <input type="radio" name="routing" value="manual" class="mt-1">
              <span><span class="text-white font-medium">Manual Custom Routing</span><br><span class="text-slate-400">You set the exact cell for alerts; every lead alert goes there regardless of score.</span></span>
            </label>
            <div>
              <label class="text-slate-400 text-xs">Alert cell (SMS)</label>
              <input id="ownerCell" class="w-full bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 mt-1" placeholder="+1 555 555 5555">
            </div>
            <div>
              <label class="text-slate-400 text-xs">Hot-lead threshold (0–10): <span id="thVal" class="text-[#E8C97A] font-semibold"></span></label>
              <input id="threshold" type="range" min="0" max="10" step="1" class="w-full accent-[#C9A84C]">
            </div>
            <button onclick="saveRouting()" class="w-full bg-[#C9A84C] hover:bg-[#E8C97A] text-black font-bold rounded-lg py-2.5">Save routing</button>
            <p id="routingMsg" class="text-xs text-center h-4"></p>
          </div>
        </div>
      </div>
    </section>

    <section id="tab-voice" class="tabPane hidden fade-in">
      <div class="glass rounded-2xl p-5 mb-5">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <div>
            <h3 class="font-semibold text-white">AI Agent</h3>
            <p class="text-xs text-slate-400">Answers your calls and texts 24/7. Flip it off and calls bridge straight to your cell.</p>
          </div>
          <button id="aiToggle" onclick="toggleAi()" class="px-4 py-2 rounded-lg font-bold"></button>
        </div>
        <div id="personaBox" class="mt-4 grid md:grid-cols-3 gap-3 text-sm"></div>
      </div>
      <div class="glass rounded-2xl p-5">
        <h3 class="font-semibold text-white mb-3">Conversations</h3>
        <div id="convoList" class="space-y-2 text-sm"></div>
        <div id="convoDetail" class="hidden mt-4 border-t border-slate-800 pt-4"></div>
        <p class="text-xs text-slate-500 mt-4">Calls are recorded and transcribed when the AI's recording notice is on; callers hear the notice at the start of every call.</p>
      </div>
      <div class="glass rounded-2xl p-5 mt-5">
        <h3 class="font-semibold text-white mb-3">Recent Lead Activity</h3>
        <div id="voiceFeed" class="space-y-2 text-sm"></div>
      </div>
    </section>

    <section id="tab-social" class="tabPane hidden fade-in">
      <div class="flex items-center justify-between mb-4 flex-wrap gap-2">
        <div>
          <h3 class="font-semibold text-white">Post Pipeline</h3>
          <p class="text-xs text-slate-400">Nothing publishes without your approval.</p>
        </div>
        <button onclick="loadPosts()" class="text-xs text-[#E8C97A] hover:text-[#F0DCA0]">↻ Refresh</button>
      </div>
      <div id="postList" class="space-y-3"></div>
    </section>

    <section id="tab-settings" class="tabPane hidden fade-in">
      <div class="grid md:grid-cols-2 gap-5">
        <div class="glass rounded-2xl p-5">
          <h3 class="font-semibold text-white mb-3">Quiet Hours</h3>
          <p class="text-xs text-slate-400 mb-3">Automated follow-up texts pause during these hours and send after — required by texting law, good manners anyway.</p>
          <div class="flex gap-3 items-center text-sm">
            <input id="qStart" class="bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 w-28" placeholder="21:00">
            <span class="text-slate-500">to</span>
            <input id="qEnd" class="bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 w-28" placeholder="08:00">
            <button onclick="saveQuiet()" class="bg-[#C9A84C] hover:bg-[#E8C97A] text-black font-bold rounded-lg px-4 py-2">Save</button>
          </div>
          <p id="quietMsg" class="text-xs mt-2 h-4"></p>
        </div>
        <div class="glass rounded-2xl p-5">
          <h3 class="font-semibold text-white mb-3">Your AI's Setup</h3>
          <div id="settingsReadonly" class="text-sm space-y-2"></div>
        </div>
      </div>
    </section>
  </main>

  <div id="slideOver" class="fixed inset-0 z-40 hidden">
    <div class="absolute inset-0 bg-black/60" onclick="closeLead()"></div>
    <div class="absolute right-0 top-0 h-full w-full max-w-md glass p-6 overflow-y-auto fade-in">
      <div class="flex items-start justify-between mb-4">
        <div>
          <div id="loName" class="text-xl font-bold text-white"></div>
          <div id="loContact" class="text-sm text-slate-400"></div>
        </div>
        <button onclick="closeLead()" class="text-slate-400 hover:text-white text-xl leading-none">✕</button>
      </div>
      <div class="flex gap-2 mb-4">
        <a id="loCall" class="flex-1 text-center bg-emerald-500/90 hover:bg-emerald-400 text-black font-bold rounded-lg py-2">Call Now</a>
        <a id="loSms" class="flex-1 text-center bg-[#C9A84C] hover:bg-[#E8C97A] text-black font-bold rounded-lg py-2">Send SMS</a>
      </div>
      <label class="text-xs text-slate-400">Pipeline stage</label>
      <div class="flex gap-2 mt-1 mb-5">
        <input id="loStage" class="flex-1 bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 text-sm">
        <button onclick="saveStage()" class="bg-slate-700 hover:bg-slate-600 rounded-lg px-3 text-sm">Update</button>
      </div>
      <h4 class="font-semibold text-white mb-2 text-sm">Conversations</h4>
      <div id="loConvos" class="space-y-2 text-sm mb-5"></div>
      <h4 class="font-semibold text-white mb-2 text-sm">History</h4>
      <div id="loHistory" class="space-y-2 text-sm"></div>
    </div>
  </div>
</div>

<script>
const API = '/portal-api';
let TOKEN = new URLSearchParams(location.search).get('token') || localStorage.getItem('ns_portal_token') || '';
let SETTINGS = null, CURRENT_LEAD = null;

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function api(path, opts = {}) {
  const r = await fetch(API + path + (path.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(TOKEN), {
    headers: { 'Content-Type': 'application/json' }, ...opts,
  });
  if (r.status === 401) { showGate(true); throw new Error('unauthorized'); }
  return r.json();
}
function showGate(err) { $('gate').classList.remove('hidden'); $('app').classList.add('hidden'); $('gateErr').classList.toggle('hidden', !err); }
function saveToken() { TOKEN = $('tokenInput').value.trim(); localStorage.setItem('ns_portal_token', TOKEN); boot(); }

function setTab(name) {
  document.querySelectorAll('.tabPane').forEach((p) => p.classList.add('hidden'));
  document.querySelectorAll('.tabBtn').forEach((b) => b.classList.remove('tab-active'));
  $('tab-' + name).classList.remove('hidden');
  document.querySelector(`[data-tab="${name}"]`).classList.add('tab-active');
  if (name === 'overview') loadOverview();
  if (name === 'leads') loadLeads();
  if (name === 'voice') loadVoice();
  if (name === 'social') loadPosts();
  if (name === 'settings') loadSettings();
}
document.addEventListener('click', (e) => { const t = e.target.closest('.tabBtn'); if (t) setTab(t.dataset.tab); });

async function boot() {
  try {
    const s = await api('/summary');
    $('gate').classList.add('hidden'); $('app').classList.remove('hidden');
    $('bizName').textContent = s.business_name;
    paintAiPill(s.ai_enabled);
    setTab('overview');
  } catch (e) { /* gate shown */ }
}
function paintAiPill(on) {
  const el = $('aiPill');
  el.textContent = on ? 'AI ON' : 'AI OFF';
  el.className = 'text-xs px-2 py-1 rounded-full border ' + (on ? 'border-emerald-500 text-emerald-400' : 'border-red-500 text-red-400');
}

async function loadOverview() {
  const s = await api('/summary');
  paintAiPill(s.ai_enabled);
  const cards = [
    ['Total Leads', s.totals.leads],
    ['New This Week', s.totals.new_this_week],
    ['Hot Leads', s.totals.hot_leads],
    ['Scheduled Follow-ups', s.totals.scheduled_followups],
  ];
  $('metricCards').innerHTML = cards.map(([k, v]) =>
    `<div class="glass rounded-2xl p-4"><div class="text-3xl font-bold text-white">${v}</div><div class="text-xs text-slate-400 mt-1">${k}</div></div>`).join('');
  const total = Math.max(1, s.totals.leads);
  $('pipeline').innerHTML = Object.entries(s.pipeline).map(([stage, n]) =>
    `<div><div class="flex justify-between text-sm mb-1"><span>${esc(stage)}</span><span class="text-slate-400">${n}</span></div>
     <div class="h-2 bg-slate-800 rounded-full overflow-hidden"><div class="h-full bg-[#C9A84C]/80" style="width:${Math.round(n / total * 100)}%"></div></div></div>`).join('') || '<p class="text-slate-500 text-sm">No leads yet — they\'ll appear the moment your AI takes its first call or form fill.</p>';
}

let LEADS = [];
function toggleAdd() { $('addBox').classList.toggle('hidden'); }
async function addContact() {
  const m = $('acMsg');
  const r = await api('/leads/add', { method: 'POST', body: JSON.stringify({ name: $('acName').value.trim(), phone: $('acPhone').value.trim(), email: $('acEmail').value.trim(), note: $('acNote').value.trim() }) });
  if (r.ok) { m.textContent = 'Added.'; m.className = 'text-xs text-emerald-400'; $('acName').value = $('acPhone').value = $('acEmail').value = $('acNote').value = ''; loadLeads(); }
  else { m.textContent = (r.errors || [r.error || 'Failed']).join(' '); m.className = 'text-xs text-red-400'; }
}
function renderLeads() {
  const q = ($('leadSearch').value || '').toLowerCase();
  const rows = LEADS.filter((l) => !q || [l.name, l.phone, l.email, l.summary].some((v) => v && String(v).toLowerCase().includes(q)));
  $('leadRows').innerHTML = rows.map((l) => `
    <tr class="border-b border-slate-800/60 hover:bg-slate-800/30 cursor-pointer" onclick='openLead(${JSON.stringify(l.key)})'>
      <td class="py-2.5 pr-3 text-slate-400 whitespace-nowrap">${l.created_at ? new Date(l.created_at).toLocaleDateString() : '—'}</td>
      <td class="py-2.5 pr-3"><div class="text-white">${esc(l.name || 'Unknown')}</div><div class="text-slate-500 text-xs">${esc(l.phone || l.email || '')}</div></td>
      <td class="py-2.5 pr-3 text-slate-300">${esc(l.source || '')}</td>
      <td class="py-2.5 pr-3"><span class="badge-${l.badge} text-xs px-2 py-0.5 rounded-full">${l.badge === 'unscored' ? '—' : l.badge.toUpperCase() + (l.score != null ? ' ' + l.score : '')}</span></td>
      <td class="py-2.5 text-slate-400 text-xs max-w-[220px] truncate">${esc(l.summary || '')}</td>
    </tr>`).join('') || '<tr><td colspan="5" class="py-6 text-center text-slate-500">No matching leads.</td></tr>';
}
async function loadLeads() {
  const d = await api('/leads');
  const st = SETTINGS || await api('/settings'); SETTINGS = st;
  document.querySelector(`input[name=routing][value=${st.editable.routing_mode}]`).checked = true;
  $('ownerCell').value = st.editable.owner_cell;
  $('threshold').value = st.editable.lead_alert_threshold;
  $('thVal').textContent = st.editable.lead_alert_threshold;
  $('threshold').oninput = () => $('thVal').textContent = $('threshold').value;
  LEADS = d.leads;
  renderLeads();
}

async function openLead(key) {
  const l = await api('/leads/' + encodeURIComponent(key));
  CURRENT_LEAD = key;
  $('loName').textContent = l.name || 'Unknown';
  $('loContact').textContent = [l.phone, l.email].filter(Boolean).join(' · ');
  $('loCall').href = l.phone ? 'tel:' + l.phone : '#'; $('loCall').classList.toggle('opacity-40', !l.phone);
  $('loSms').href = l.phone ? 'sms:' + l.phone : '#'; $('loSms').classList.toggle('opacity-40', !l.phone);
  $('loStage').value = l.stage || '';
  if (l.phone) {
    api('/transcripts?phone=' + encodeURIComponent(l.phone)).then((d) => {
      $('loConvos').innerHTML = d.transcripts.slice(0, 8).map((t) => convoRow(t, `openConvo('${t.file}','loConvos')`)).join('') || '<p class="text-slate-500">No conversations yet.</p>';
    }).catch(() => { $('loConvos').innerHTML = ''; });
  } else { $('loConvos').innerHTML = '<p class="text-slate-500">No phone on file.</p>'; }
  $('loHistory').innerHTML = (l.history || []).slice().reverse().map((h) => `
    <div class="border-l-2 border-slate-700 pl-3">
      <div class="text-slate-500 text-xs">${h.at ? new Date(h.at).toLocaleString() : ''} · ${esc(h.type || '')}${h.channel ? ' · ' + esc(h.channel) : ''}${h.to ? ' → ' + esc(h.to) : ''}</div>
      ${h.note ? `<div class="text-slate-300">${esc(h.note)}</div>` : ''}
    </div>`).join('') || '<p class="text-slate-500">No history yet.</p>';
  $('slideOver').classList.remove('hidden');
}
function closeLead() { $('slideOver').classList.add('hidden'); }
async function saveStage() {
  const r = await api('/leads/' + encodeURIComponent(CURRENT_LEAD) + '/stage', { method: 'POST', body: JSON.stringify({ stage: $('loStage').value.trim() }) });
  if (r.ok) { closeLead(); loadLeads(); }
}

async function saveRouting() {
  const body = {
    routing_mode: document.querySelector('input[name=routing]:checked')?.value || 'auto',
    owner_cell: $('ownerCell').value.trim(),
    lead_alert_threshold: Number($('threshold').value),
  };
  const r = await api('/settings', { method: 'POST', body: JSON.stringify(body) });
  const m = $('routingMsg');
  if (r.ok) { m.textContent = 'Saved — live within 30 seconds.'; m.className = 'text-xs text-center h-4 text-emerald-400'; SETTINGS = null; }
  else { m.textContent = (r.errors || ['Save failed']).join(' '); m.className = 'text-xs text-center h-4 text-red-400'; }
}

async function loadVoice() {
  const st = SETTINGS || await api('/settings'); SETTINGS = st;
  const on = st.editable.ai_enabled;
  const t = $('aiToggle');
  t.textContent = on ? 'AI is ON — tap to turn OFF' : 'AI is OFF — tap to turn ON';
  t.className = 'px-4 py-2 rounded-lg font-bold ' + (on ? 'bg-emerald-500 text-black hover:bg-emerald-400' : 'bg-red-500/90 text-white hover:bg-red-400');
  $('personaBox').innerHTML = [
    ['Tone', Object.values(st.readonly.tone || {}).join(' · ') || '—'],
    ['Services on file', (st.readonly.services || []).map((s) => s.name).join(', ') || '—'],
    ['Timezone', st.readonly.timezone || '—'],
  ].map(([k, v]) => `<div class="bg-slate-900/60 rounded-lg p-3"><div class="text-xs text-slate-500">${k}</div><div class="text-slate-200 mt-0.5">${esc(v)}</div></div>`).join('');
  api('/transcripts?limit=30').then((td) => {
    $('convoList').innerHTML = td.transcripts.map((t) => convoRow(t, `openConvo('${t.file}','convoDetail')`)).join('') || '<p class="text-slate-500">No conversations yet — they appear the moment your AI takes a call or text.</p>';
  }).catch(() => { $('convoList').innerHTML = ''; });
  const d = await api('/leads');
  const events = [];
  for (const l of d.leads) {
    if (['voice', 'sms', 'missed_call'].includes(l.source) || (l.tags || []).some((t) => ['voice', 'sms', 'missed-call'].includes(t))) {
      events.push(l);
    }
  }
  $('voiceFeed').innerHTML = events.slice(0, 30).map((l) => `
    <div class="flex items-center gap-3 bg-slate-900/50 rounded-lg px-3 py-2 cursor-pointer hover:bg-slate-800/60" onclick='openLead(${JSON.stringify(l.key)})'>
      <span class="text-lg">${l.source === 'voice' ? '📞' : l.source === 'missed_call' ? '📵' : '💬'}</span>
      <div class="flex-1"><div class="text-white">${esc(l.name || l.phone || 'Unknown')}</div><div class="text-xs text-slate-500">${esc(l.summary || l.source)}</div></div>
      <div class="text-xs text-slate-500">${l.last_activity_at ? new Date(l.last_activity_at).toLocaleDateString() : ''}</div>
    </div>`).join('') || '<p class="text-slate-500">No call or text activity yet.</p>';
}
function convoRow(t, onclickExpr) {
  const icon = t.channel === 'voice' ? '📞' : '💬';
  const dur = t.recording && t.recording.duration_sec ? ` · ${t.recording.duration_sec}s audio` : '';
  const when = t.started_at ? new Date(t.started_at).toLocaleString() : '';
  return `<div class="flex items-center gap-3 bg-slate-900/50 rounded-lg px-3 py-2 cursor-pointer hover:bg-slate-800/60" onclick="${onclickExpr}">
    <span class="text-lg">${icon}</span>
    <div class="flex-1 min-w-0"><div class="text-white truncate">${esc(t.phone || '')} <span class="text-slate-500 text-xs">${esc(t.status)}${dur}</span></div>
    <div class="text-xs text-slate-500 truncate">${esc(t.preview || '')}</div></div>
    <div class="text-xs text-slate-500 whitespace-nowrap">${when}</div></div>`;
}
function turnsHtml(doc) {
  const roleCls = { caller: 'bg-slate-800 text-slate-100 self-start', assistant: 'bg-[#C9A84C]/15 text-[#F5F0E8] self-end', system: 'bg-amber-900/30 text-amber-200 self-center text-xs' };
  const audio = doc.recording && doc.recording.sid
    ? `<audio controls preload="none" class="w-full mb-3" src="${API}/recordings/${doc.recording.sid}?token=${encodeURIComponent(TOKEN)}"></audio>` : '';
  return audio + '<div class="flex flex-col gap-2">' + (doc.turns || []).map((t) =>
    `<div class="max-w-[85%] rounded-xl px-3 py-2 ${roleCls[t.role] || 'bg-slate-800'}"><div class="text-[10px] text-slate-500">${t.at ? new Date(t.at).toLocaleTimeString() : ''} · ${esc(t.role)}</div>${esc(t.text)}</div>`
  ).join('') + '</div>';
}
async function openConvo(file, mountId) {
  const doc = await api('/transcripts/one?file=' + encodeURIComponent(file));
  const el = $(mountId);
  el.classList.remove('hidden');
  el.innerHTML = `<div class="flex items-center justify-between mb-2"><span class="text-sm text-slate-400">${esc(doc.channel)} · ${esc(doc.phone || '')} · ${doc.started_at ? new Date(doc.started_at).toLocaleString() : ''}</span><button class="text-slate-500 hover:text-white" onclick="$('${mountId}').classList.add('hidden')">✕</button></div>` + turnsHtml(doc);
}
async function toggleAi() {
  const st = SETTINGS || await api('/settings');
  const r = await api('/settings', { method: 'POST', body: JSON.stringify({ ai_enabled: !st.editable.ai_enabled }) });
  if (r.ok) { SETTINGS = null; loadVoice(); const s = await api('/summary'); paintAiPill(s.ai_enabled); }
}

async function loadPosts() {
  const d = await api('/posts');
  const pillarColor = { trust: 'text-[#E8C97A]', offer: 'text-amber-300', brand: 'text-fuchsia-300' };
  $('postList').innerHTML = d.posts.filter((p) => p.status !== 'rejected').map((p) => `
    <div class="glass rounded-xl p-4">
      <div class="flex items-center gap-2 text-xs mb-2">
        <span class="${pillarColor[p.pillar] || 'text-slate-400'} font-semibold uppercase">${esc(p.pillar || p.status)}</span>
        <span class="text-slate-500">·</span>
        <span class="text-slate-400">${p.scheduledFor ? new Date(p.scheduledFor).toLocaleDateString() : 'unscheduled'}</span>
        <span class="ml-auto text-slate-500">${esc(p.status)}</span>
      </div>
      <textarea id="msg-${p.id}" class="w-full bg-slate-900/70 border border-slate-800 rounded-lg p-3 text-sm text-slate-200" rows="3">${esc(p.message)}</textarea>
      <div class="flex gap-2 mt-2">
        ${p.status === 'pending' ? `<button onclick="postAction('${p.id}','approve')" class="bg-emerald-500 hover:bg-emerald-400 text-black font-bold rounded-lg px-3 py-1.5 text-sm">Approve &amp; Post</button>` : ''}
        <button onclick="postEdit('${p.id}')" class="bg-slate-700 hover:bg-slate-600 rounded-lg px-3 py-1.5 text-sm">Save edit</button>
        <input type="date" id="date-${p.id}" class="bg-slate-900 border border-slate-700 rounded-lg px-2 text-sm">
        <button onclick="postReschedule('${p.id}')" class="bg-slate-700 hover:bg-slate-600 rounded-lg px-3 py-1.5 text-sm">Reschedule</button>
        ${p.status === 'pending' ? `<button onclick="postAction('${p.id}','reject')" class="ml-auto text-red-400 hover:text-red-300 text-sm">Reject</button>` : ''}
      </div>
    </div>`).join('') || '<p class="text-slate-500 text-sm">No posts queued. Ask your NewSites manager to generate your 30-day calendar.</p>';
}
async function postAction(id, action) { await api('/posts/' + id, { method: 'POST', body: JSON.stringify({ action }) }); loadPosts(); }
async function postEdit(id) { await api('/posts/' + id, { method: 'POST', body: JSON.stringify({ action: 'edit', message: $('msg-' + id).value }) }); loadPosts(); }
async function postReschedule(id) { const v = $('date-' + id).value; if (v) { await api('/posts/' + id, { method: 'POST', body: JSON.stringify({ action: 'reschedule', scheduledFor: v }) }); loadPosts(); } }

async function loadSettings() {
  const st = await api('/settings'); SETTINGS = st;
  $('qStart').value = st.editable.quiet_hours.start;
  $('qEnd').value = st.editable.quiet_hours.end;
  $('settingsReadonly').innerHTML = [
    ['Business', st.readonly.business_name],
    ['Services', (st.readonly.services || []).map((s) => `${s.name}${s.price != null ? ' — $' + s.price : ''}`).join('<br>') || '—'],
  ].map(([k, v]) => `<div><div class="text-xs text-slate-500">${k}</div><div class="text-slate-200">${v}</div></div>`).join('')
  + `<p class="text-xs text-slate-500 pt-2 border-t border-slate-800">${esc(st.readonly.note)}</p>`;
}
async function saveQuiet() {
  const r = await api('/settings', { method: 'POST', body: JSON.stringify({ quiet_hours: { start: $('qStart').value.trim(), end: $('qEnd').value.trim() } }) });
  const m = $('quietMsg');
  if (r.ok) { m.textContent = 'Saved.'; m.className = 'text-xs mt-2 h-4 text-emerald-400'; }
  else { m.textContent = (r.errors || ['Failed']).join(' '); m.className = 'text-xs mt-2 h-4 text-red-400'; }
}

TOKEN ? boot() : showGate(false);
</script>
</body>
</html>
EOF_P3_HTM
cat > scripts/new-client.js << 'EOF_P3_NC'
#!/usr/bin/env node
'use strict';

// New-client provisioning — the manual bridge between "they paid" and "they're live".
//
//   node scripts/new-client.js <slug> "Business Name" <owner_cell> [--niche fitness] [--sms]
//
//   node scripts/new-client.js joes-plumbing "Joe's Plumbing" 3235551234 --niche home_services --sms
//
// Does, in order: creates clients/<slug>/profile.json from the example
// template (business name, owner cell, escalation cell filled in), mints a
// portal token, runs the compiler, prints the portal link — and with --sms,
// texts that link to the owner's cell from the NewSites number.
//
// Until a Stripe webhook automates this (operator's lane), this is the
// 60-second post-payment ritual.

require('dotenv').config({ path: '/root/newsites-sms/.env' });
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const BASE = process.env.DATA_ROOT || '/root/newsites-sms';

function arg(flag) {
  const i = process.argv.indexOf(flag);
  return i > -1 ? process.argv[i + 1] : null;
}

async function main() {
  const [slug, bizName, cellRaw] = process.argv.slice(2);
  if (!slug || !bizName || !cellRaw || slug.startsWith('--')) {
    console.error('Usage: node scripts/new-client.js <slug> "Business Name" <owner_cell> [--niche X] [--sms]');
    process.exit(2);
  }
  if (!/^[a-z0-9-]{2,40}$/.test(slug)) {
    console.error('slug must be lowercase letters/numbers/dashes, e.g. joes-plumbing');
    process.exit(2);
  }
  const phone = require(path.join(BASE, 'lib/phone'));
  const ownerCell = phone.toE164(cellRaw);
  if (!ownerCell) {
    console.error(`"${cellRaw}" is not a valid US phone number`);
    process.exit(2);
  }

  const dir = path.join(BASE, 'clients', slug);
  const profPath = path.join(dir, 'profile.json');
  if (fs.existsSync(profPath)) {
    console.error(`${slug} already exists — edit clients/${slug}/profile.json instead.`);
    process.exit(1);
  }

  let template;
  try {
    template = JSON.parse(fs.readFileSync(path.join(BASE, 'clients/example-fitness/profile.json')));
  } catch (_) {
    template = { // built-in fallback if the example profile is ever missing
      ai_enabled: true, lead_alert_threshold: 5,
      identity: { business_name: '', niche: 'professional', service_area: '', timezone: 'America/Los_Angeles', hours: '', owner_cell: '', website_url: '' },
      offer: { services: [], payment_methods: [], stripe_account_id: null },
      voice_sms_persona: { greeting_name: '', tone: { formal_casual: 'casual', brief_chatty: 'brief', salesy_consultative: 'consultative' }, banned_topics: [], escalation_triggers: ['refund request', 'asks for the owner'], escalation_cell: '', recording_disclosure: true },
      booking: { calendar_provider: '', calendar_link: '', min_lead_time_hours: 2, buffer_min: 0, can_ai_commit_times: false },
      reputation: { google_review_url: '', trigger_stage: 'Job Done', delay_hours: 4, reactivation_days: 90 },
      compliance: { quiet_hours: { start: '21:00', end: '08:00' }, opt_out_list_path: 'compliance/opt-out-ledger.json' },
    };
  }
  template.identity.business_name = bizName;
  template.identity.niche = arg('--niche') || template.identity.niche;
  template.identity.service_area = '';
  template.identity.hours = 'call for availability';
  template.identity.owner_cell = ownerCell;
  template.identity.website_url = '';
  template.voice_sms_persona.greeting_name = `the ${bizName} assistant`;
  template.voice_sms_persona.escalation_cell = ownerCell;
  template.offer.services = [{ name: 'General Service', price: null, bookable: true }]; // placeholder — real menu before go-live
  template.booking.calendar_link = '';
  template.reputation.google_review_url = '';
  template.portal_token = crypto.randomBytes(24).toString('hex');

  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(profPath, JSON.stringify(template, null, 2));
  console.log(`[new-client] created clients/${slug}/profile.json`);

  execFileSync('node', [path.join(BASE, 'compiler.js'), slug], { stdio: 'inherit', cwd: BASE });

  const link = `https://164.92.110.116.nip.io/portal?token=${template.portal_token}`;
  console.log(`\n[new-client] PORTAL LINK for ${bizName}:\n  ${link}\n`);
  console.log('[new-client] NEXT: edit their real services/prices in profile.json, then `node compiler.js ' + slug + '` again.');

  if (process.argv.includes('--sms')) {
    const compliance = require(path.join(BASE, 'compliance'));
    const profile = JSON.parse(fs.readFileSync(profPath));
    profile._slug = slug;
    const r = await compliance.sendSms({
      to: ownerCell,
      body: `Welcome to NewSites! Your private dashboard for ${bizName} is live — leads, calls, texts, everything: ${link}  (Keep this link private; it's your key.)`,
      profile,
      mode: 'transactional',
    });
    console.log(r.ok ? `[new-client] invite texted to ${ownerCell}` : `[new-client] invite SMS failed: ${r.blocked || r.error}`);
  }
}

main().catch((e) => { console.error('[new-client] crashed:', e.message); process.exit(1); });
EOF_P3_NC
W1=$(wc -c < routes/portal-api.js); W2=$(wc -c < portal/portal.html); W3=$(wc -c < scripts/new-client.js)
[ "$W1" -eq 18368 ] && ok "portal-api.js $W1" || bad "portal-api $W1 != 18368"
[ "$W2" -eq 28510 ] && ok "portal.html $W2" || bad "portal.html $W2 != 28510"
[ "$W3" -eq 5123 ] && ok "new-client.js $W3" || bad "new-client $W3 != 5123"
[ "$FAIL" -eq 0 ] || die "embed mismatch"
node --check routes/portal-api.js && node --check scripts/new-client.js && ok "syntax clean" || die "syntax"

echo "==> 2/4 Point paid-checkout back at the NewSites success page"
cp index.js "index.js.bak-$STAMP"
python3 - << 'PYSU'
s = open('index.js').read()
n = s.count("social-media-creator.html?paid=true")
if n:
    s = s.replace("https://stevendiolosa07-ship-it.github.io/NewSites/social-media-creator.html?paid=true",
                  "https://stevendiolosa07-ship-it.github.io/NewSites/success.html")
    open('index.js','w').write(s)
    print(f"  [OK] {n} success_url(s) now land on success.html")
else:
    print("  [OK] success_url already points at success.html")
PYSU
node --check index.js || { cp "index.js.bak-$STAMP" index.js; die "index.js broke — restored"; }

echo "==> 3/4 Restart"
command -v pm2 >/dev/null 2>&1 && pm2 restart newsites-sms --update-env >/dev/null && ok "newsites-sms restarted" || echo "  [WARN] pm2 skipped"

echo "==> 4/4 Verify"
if [ "${NEWSITES_TEST:-0}" = "1" ]; then echo "  [test mode] skip curls"; else
  sleep 2
  C=$(curl -s "https://164.92.110.116.nip.io/portal" | grep -c "C9A84C" || echo 0)
  [ "$C" -ge 1 ] && ok "gold theme live" || bad "gold theme not detected"
fi
echo
[ "$FAIL" -eq 0 ] && echo "PORTAL v3 COMPLETE — reload your portal link for the gold theme. New client setup: node scripts/new-client.js <slug> \"Biz Name\" <cell> --sms" || echo "XX FAILURES — screenshot everything."
