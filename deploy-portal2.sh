#!/bin/bash
# NewSites Client Portal + Conversation Persistence — one-shot deploy (v2).
# SUPERSEDES deploy-portal.sh — run THIS one. Embedded files, idempotent.
#   bash deploy-portal2.sh   (ON THE DROPLET)
set -uo pipefail
BASE="${NEWSITES_BASE:-/root/newsites-sms}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
STAMP=$(date +%Y%m%d-%H%M%S)
FAIL=0
ok()  { echo "  [OK] $*"; }
bad() { echo "  [FAIL] $*"; FAIL=1; }
die() { echo; echo "XX ABORTED: $*"; exit 1; }
[ -d "$BASE" ] || die "$BASE not found — run ON THE DROPLET"
cd "$BASE" || die "cd failed"
export DATA_ROOT="$BASE"

echo "==> 1/8 Backups"
for f in index.js call-handler.js routes/twilio-status.js; do [ -f "$f" ] && cp "$f" "$f.bak-$STAMP"; done
ok "saved *.bak-$STAMP"

echo "==> 2/8 Write files (embedded)"
mkdir -p routes lib scripts portal
cat > routes/portal-api.js << 'EOF_P2_API'
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

module.exports = router;
EOF_P2_API
cat > routes/twilio-status.js << 'EOF_P2_TWS'
'use strict';

// STEP 3.2 — Missed-call handling.
//
// Mount in index.js:   app.use('/twilio', require('./routes/twilio-status'));
// Endpoint:            POST /twilio/status-callback
//
// Configure in the Twilio console on (347) 302-9363 →
//   Voice & Fax → "CALL STATUS CHANGES" → https://{PERMANENT_DOMAIN}/twilio/status-callback
// and add `/twilio*` to the Caddyfile pointing at :3001. Both are in the README.
// NOTE: this URL lives in Twilio's console — a rotating quick-tunnel URL kills
// the feature every restart. Permanent domain is a hard prerequisite.
//
// Handles BOTH shapes of "missed":
//   - Number-level statusCallback: CallStatus = no-answer | busy | failed | canceled
//     (server down, webhook error, caller bailed)
//   - <Dial> action callback: DialCallStatus = no-answer | busy | failed
//     (forward-to-owner mode rang out)
//
// On a miss: instant text-back (transactional — it's a direct reply to their
// call, so quiet hours don't delay it; the opt-out ledger still applies),
// upsert CRM lead at "New Lead", schedule the +24h follow-up job.
//
// This router parses its own body (urlencoded) — nothing global is touched,
// so Stripe's raw-body webhook is unaffected.

const express = require('express');
const profiles = require('../lib/profiles');
const compliance = require('../compliance');
const crm = require('../crm-adapter');
const jobs = require('../jobs-engine');
const phone = require('../lib/phone');
const tpl = require('../lib/tpl');
const twilioSig = require('../lib/twilio-sig');

const router = express.Router();
router.use(express.urlencoded({ extended: false }));
router.use(twilioSig.middleware());

const MISSED = new Set(['no-answer', 'busy', 'failed', 'canceled']);

// Twilio fires several status events per call; act once per CallSid.
const seen = new Map(); // CallSid -> ts
function alreadyHandled(callSid) {
  const now = Date.now();
  for (const [sid, ts] of seen) {
    if (now - ts > 10 * 60 * 1000) seen.delete(sid);
  }
  if (!callSid) return false;
  if (seen.has(callSid)) return true;
  seen.set(callSid, now);
  return false;
}

router.post('/status-callback', async (req, res) => {
  // Twilio only needs a 2xx; never let our errors cause webhook retry storms.
  res.status(204).end();

  try {
    const b = req.body || {};
    const status = b.DialCallStatus || b.CallStatus;
    if (!MISSED.has(status)) return;

    const caller = phone.toE164(b.From);
    if (!caller) return; // client:/sip: or garbage — nothing to text
    if (alreadyHandled(b.CallSid)) return;

    const slug = await profiles.slugForNumber(b.To);
    const profile = await profiles.loadProfile(slug);
    if (!profile) {
      console.warn(`[missed-call] no profile for slug "${slug}" (To=${b.To}) — skipping`);
      return;
    }
    const triggers = (await profiles.loadTriggers(slug)) || {};
    const mc = triggers.missed_call || {};

    console.log(`[missed-call] ${caller} → ${slug} (${status})`);

    // 1. CRM lead first — even if the SMS fails, the lead exists.
    await crm.upsertLead(slug, {
      phone: caller,
      stage: 'New Lead',
      source: 'missed_call',
      tags: ['missed-call'],
      note: `missed call (${status})`,
    });

    // 2. Instant text-back.
    if (mc.enabled !== false) {
      const id = profile.identity || {};
      const booking = profile.booking || {};
      const body = tpl.render(
        mc.sms_template ||
          'Sorry we missed your call at {business_name}! How can we help? Book here: {calendar_link}',
        { business_name: id.business_name || 'us', calendar_link: booking.calendar_link || '' }
      );
      const sent = await compliance.sendSms({ to: caller, body, profile, mode: 'transactional' });
      if (!sent.ok) console.warn(`[missed-call] text-back not sent to ${caller}: ${sent.blocked || sent.error}`);
    }

    // 3. +24h follow-up, deduped per caller per day.
    await jobs.schedule({
      client_slug: slug,
      action: 'followup_check',
      payload: { phone: caller },
      due_at: Date.now() + 24 * 60 * 60 * 1000,
      dedupe_key: `followup:${slug}:${caller}:${new Date().toISOString().slice(0, 10)}`,
    });
  } catch (err) {
    console.error('[missed-call] handler error:', err);
  }
});


// Twilio posts here when a call recording completes (URL set by
// call-handler's startRecording). Stores the RecordingSid + duration into the
// call's transcript doc so the portal can stream playback.
const transcripts = require('../lib/transcripts');
router.post('/recording-status', async (req, res) => {
  res.status(204).end();
  try {
    const slug = String(req.query.slug || '');
    const doc = String(req.query.doc || '');
    const b = req.body || {};
    if (!/^[a-z0-9-]+$/.test(slug) || !transcripts.isSafeDocRel(doc)) return;
    if (!b.RecordingSid) return;
    await transcripts.setRecording(slug, doc, { sid: b.RecordingSid, duration: b.RecordingDuration });
    console.log(`[recording] ${slug} ${doc} ← ${b.RecordingSid} (${b.RecordingDuration || '?'}s)`);
  } catch (e) {
    console.error('[recording] status handler error:', e);
  }
});

module.exports = router;
EOF_P2_TWS
cat > lib/transcripts.js << 'EOF_P2_TRN'
'use strict';

// Conversation persistence — voice + SMS transcripts.
//
// Storage: clients/{slug}/transcripts/{YYYY-MM}/{voice-<CallSid>|sms-<last10>-<YYYYMMDD>}.json
//   { id, channel, phone, started_at, ended_at, status,
//     recording: { sid, duration_sec, source } | null,
//     turns: [{ at, role: 'caller'|'assistant'|'system', text }] }
//
// - All writes go through lib/store (atomic, serialized) — a crashed process
//   never leaves a torn transcript.
// - Voice docs are one per call; SMS docs are one per phone per day.
// - Lives under clients/, so the nightly backup tarball already covers it.
// - Audio itself stays at Twilio; we store only the RecordingSid and proxy
//   playback through the authed portal API. Nothing here makes audio public.

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const store = require('./store');
const phone = require('./phone');

const SAFE_DOC = /^\d{4}-\d{2}\/(voice|sms)-[A-Za-z0-9._+-]+\.json$/;

function monthDir(d = new Date()) {
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
}
function dayStamp(d = new Date()) {
  return `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, '0')}${String(d.getUTCDate()).padStart(2, '0')}`;
}
function docPath(slug, rel) {
  return `clients/${slug}/transcripts/${rel}`;
}
function isSafeDocRel(rel) {
  return typeof rel === 'string' && SAFE_DOC.test(rel);
}

// ---- voice ---------------------------------------------------------------

// Returns the doc's relative name ("YYYY-MM/voice-CAxxx.json").
async function beginVoice(slug, callSid, callerPhone) {
  const rel = `${monthDir()}/voice-${String(callSid).replace(/[^A-Za-z0-9]/g, '')}.json`;
  await store.updateJson(docPath(slug, rel), null, (doc) => {
    if (doc) return doc; // idempotent — Twilio can retry webhooks
    return {
      id: callSid,
      channel: 'voice',
      phone: phone.toE164(callerPhone) || String(callerPhone || ''),
      started_at: new Date().toISOString(),
      ended_at: null,
      status: 'in_progress',
      recording: null,
      turns: [],
    };
  });
  return rel;
}

async function appendTurn(slug, rel, role, text) {
  if (!isSafeDocRel(rel) || !text) return;
  await store.updateJson(docPath(slug, rel), null, (doc) => {
    if (!doc) return doc;
    doc.turns.push({ at: new Date().toISOString(), role, text: String(text).slice(0, 4000) });
    if (doc.turns.length > 200) doc.turns = doc.turns.slice(-200);
  });
}

async function finalize(slug, rel, status) {
  if (!isSafeDocRel(rel)) return;
  await store.updateJson(docPath(slug, rel), null, (doc) => {
    if (!doc || doc.status !== 'in_progress') return doc;
    doc.status = status || 'completed';
    doc.ended_at = new Date().toISOString();
  });
}

async function setRecording(slug, rel, rec) {
  if (!isSafeDocRel(rel)) return;
  await store.updateJson(docPath(slug, rel), null, (doc) => {
    if (!doc) return doc;
    doc.recording = {
      sid: String(rec.sid || ''),
      duration_sec: Number(rec.duration) || null,
      source: 'twilio',
    };
  });
}

// ---- sms -----------------------------------------------------------------

// One doc per phone per UTC day. Creates on first turn.
async function smsTurn(slug, rawPhone, role, text, meta) {
  const e164 = phone.toE164(rawPhone);
  if (!e164 || !text) return null;
  const rel = `${monthDir()}/sms-${phone.last10(e164)}-${dayStamp()}.json`;
  await store.updateJson(docPath(slug, rel), null, (doc) => {
    if (!doc) {
      doc = {
        id: rel,
        channel: 'sms',
        phone: e164,
        started_at: new Date().toISOString(),
        ended_at: null,
        status: 'thread',
        recording: null,
        turns: [],
      };
    }
    const turn = { at: new Date().toISOString(), role, text: String(text).slice(0, 2000) };
    if (meta && meta.kind) turn.kind = meta.kind;
    doc.turns.push(turn);
    if (doc.turns.length > 300) doc.turns = doc.turns.slice(-300);
    return doc;
  });
  return rel;
}

// ---- reading (portal) ----------------------------------------------------

// Recent conversations for a client, newest first. Scans this month and last.
async function listRecent(slug, { phoneFilter, limit = 30 } = {}) {
  const base = store.resolveDataPath(`clients/${slug}/transcripts`);
  const now = new Date();
  const prev = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
  const months = [monthDir(now), monthDir(prev)];
  const key10 = phoneFilter ? phone.last10(phoneFilter) : null;
  const out = [];
  for (const m of months) {
    let names = [];
    try {
      names = await fsp.readdir(path.join(base, m));
    } catch (_) { continue; }
    for (const name of names) {
      if (!name.endsWith('.json')) continue;
      const rel = `${m}/${name}`;
      if (!isSafeDocRel(rel)) continue;
      const doc = await store.readJson(docPath(slug, rel), null);
      if (!doc) continue;
      if (key10 && phone.last10(doc.phone || '') !== key10) continue;
      out.push({
        file: rel,
        channel: doc.channel,
        phone: doc.phone,
        started_at: doc.started_at,
        ended_at: doc.ended_at,
        status: doc.status,
        turn_count: (doc.turns || []).length,
        preview: doc.turns && doc.turns.length ? String(doc.turns[doc.turns.length - 1].text).slice(0, 120) : '',
        recording: doc.recording ? { sid: doc.recording.sid, duration_sec: doc.recording.duration_sec } : null,
      });
    }
  }
  out.sort((a, b) => new Date(b.started_at || 0) - new Date(a.started_at || 0));
  return out.slice(0, Math.min(100, limit));
}

async function readDoc(slug, rel) {
  if (!isSafeDocRel(rel)) return null;
  return store.readJson(docPath(slug, rel), null);
}

// True if this recording sid belongs to one of this client's transcripts.
async function ownsRecording(slug, sid) {
  if (!sid) return false;
  const recent = await listRecent(slug, { limit: 100 });
  return recent.some((t) => t.recording && t.recording.sid === sid);
}

module.exports = {
  beginVoice, appendTurn, finalize, setRecording,
  smsTurn, listRecent, readDoc, ownsRecording, isSafeDocRel,
};
EOF_P2_TRN
cat > lib/expand-prompt.js << 'EOF_P2_EXP'
'use strict';

// expandPrompt(userPrompt, profileData) — MODULE 2.
//
// Turns a one-liner ("I run a local plumbing shop") plus whatever profile
// data exists into a complete, opinionated build brief for the website
// renderer: hero, trust signals, interactive service grid, and a lead-capture
// form wired to THIS backend's /leads endpoint (client slug included, so
// every generated site feeds the right CRM automatically).
//
// Pure function, no I/O — safe to use in index.js, website-generator.js, or
// the builder frontend. Returns { spec, prompt }:
//   spec   — structured object (sections, palette, form wiring) for
//            programmatic renderers
//   prompt — a single expanded prompt string for LLM-driven generation
//
// Integration (website-generator.js or wherever the user's raw prompt enters):
//   const { expandPrompt } = require('./lib/expand-prompt');
//   const { prompt } = expandPrompt(userInput, profile);
//   // ...pass `prompt` to the model instead of userInput

const NICHE_HINTS = {
  plumb: { niche: 'home_services', urgency: true, verbs: ['fix', 'unclog', 'repair'] },
  hvac: { niche: 'home_services', urgency: true, verbs: ['repair', 'install', 'tune up'] },
  electric: { niche: 'home_services', urgency: true, verbs: ['repair', 'rewire', 'install'] },
  roof: { niche: 'home_services', urgency: true, verbs: ['repair', 'replace', 'inspect'] },
  clean: { niche: 'home_services', urgency: false, verbs: ['deep clean', 'refresh'] },
  braid: { niche: 'beauty', urgency: false, verbs: ['book', 'style'] },
  salon: { niche: 'beauty', urgency: false, verbs: ['book', 'style'] },
  barber: { niche: 'beauty', urgency: false, verbs: ['book', 'cut'] },
  gym: { niche: 'fitness', urgency: false, verbs: ['train', 'join'] },
  box: { niche: 'fitness', urgency: false, verbs: ['train', 'join'] },
  dent: { niche: 'medical_dental', urgency: false, verbs: ['book', 'schedule'] },
  law: { niche: 'professional', urgency: false, verbs: ['consult', 'protect'] },
  account: { niche: 'professional', urgency: false, verbs: ['file', 'save'] },
  realt: { niche: 'real_estate', urgency: false, verbs: ['tour', 'list'] },
  jewel: { niche: 'luxury_retail', urgency: false, verbs: ['shop', 'customize'] },
  venue: { niche: 'luxury_retail', urgency: false, verbs: ['tour', 'book'] },
};

function detectNiche(text) {
  const t = String(text || '').toLowerCase();
  for (const [k, v] of Object.entries(NICHE_HINTS)) {
    if (t.includes(k)) return v;
  }
  return { niche: 'professional', urgency: false, verbs: ['get started'] };
}

function expandPrompt(userPrompt, profileData) {
  const p = profileData || {};
  const id = p.identity || {};
  const offer = p.offer || {};
  const booking = p.booking || {};
  const raw = String(userPrompt || '').trim();
  const hint = detectNiche(raw + ' ' + (id.niche || ''));

  const businessName = id.business_name || 'the business';
  const area = id.service_area || '';
  const services = (offer.services || []).filter((s) => s && s.name);
  const slug = p._slug || 'newsites';

  const spec = {
    meta: {
      business_name: businessName,
      service_area: area,
      niche: id.niche || hint.niche,
      hours: id.hours || null,
      phone_display: id.public_phone || null,
    },
    theme: {
      mode: 'dark-luxury',
      backdrop: 'deep navy/charcoal with subtle particle or light-streak animation, never busy',
      accent: 'single high-contrast accent (gold or electric blue), used sparingly',
      typography: 'large confident display headings, generous whitespace, high line-height body',
      motion: 'smooth scroll-reveal, card hover lift, respects prefers-reduced-motion',
    },
    sections: [
      {
        key: 'hero',
        headline: `One-sentence value proposition for ${businessName}${area ? ` serving ${area}` : ''} — outcome-first, no jargon`,
        elements: [
          'high-impact H1 + one supporting line',
          hint.urgency ? 'emergency contact badge (tap-to-call) pinned top-right' : 'availability badge (e.g. "Booking this week")',
          'primary CTA button (opens lead form) + secondary tap-to-call',
          'dark animated backdrop per theme',
        ],
      },
      {
        key: 'trust',
        elements: [
          'review counter (renders ONLY if a real review count/URL is provided — never invent numbers)',
          'trust badges: licensed/insured/years-in-business as applicable from profile',
          'recent work gallery grid (placeholder slots if no photos supplied, clearly marked)',
        ],
      },
      {
        key: 'services',
        elements: services.length
          ? services.map((s) => `card: ${s.name}${s.price != null ? ` — from $${s.price}` : ' — pricing on request'}${s.bookable === false ? '' : ' (bookable)'}`)
          : ['3-6 service cards inferred from the business description, each with a one-line benefit'],
        extras: [
          'hover animation on cards',
          services.some((s) => s.price != null)
            ? 'simple estimator widget: pick services -> shows listed prices only, with "owner confirms final quote" line'
            : 'estimator omitted: no listed prices — show "Get a fast quote" CTA instead (never invent prices)',
        ],
      },
      {
        key: 'lead_capture',
        form_fields: ['name', 'phone', 'email', 'message'],
        wiring: {
          method: 'POST',
          url: 'https://164.92.110.116.nip.io/leads',
          content_type: 'application/json',
          body_template: { client: slug, name: '{name}', phone: '{phone}', email: '{email}', message: '{message}', source: 'website' },
          success_behavior: 'inline thank-you state; mention they will get a text confirmation',
        },
        notes: booking.calendar_link
          ? `also surface booking link prominently: ${booking.calendar_link}`
          : 'no calendar link on file — form + phone are the conversion paths',
      },
      {
        key: 'footer',
        elements: ['NAP block (name, area, phone)', 'hours if provided', 'minimal legal links'],
      },
    ],
    hard_rules: [
      'never invent prices, review counts, certifications, or guarantees not present in the profile',
      'single-file HTML+CSS+JS output, mobile-first, loads fast (no heavy frameworks)',
      'all phone numbers tap-to-call; form posts to the wiring URL exactly as specified',
    ],
  };

  const prompt = [
    `Build a complete, single-file, dark-luxury one-page website for ${businessName}${area ? ` (${area})` : ''}.`,
    `Owner's own words: "${raw || 'no description given — infer tastefully from the profile'}"`,
    '',
    `THEME: ${spec.theme.mode}. ${spec.theme.backdrop}. Accent: ${spec.theme.accent}. ${spec.theme.typography}. ${spec.theme.motion}.`,
    '',
    'MANDATORY SECTIONS, in order:',
    `1. HERO — ${spec.sections[0].headline}. Include: ${spec.sections[0].elements.join('; ')}.`,
    `2. TRUST — ${spec.sections[1].elements.join('; ')}.`,
    `3. SERVICES — ${spec.sections[2].elements.join(' | ')}. ${spec.sections[2].extras.join(' ')}`,
    `4. LEAD CAPTURE — fields ${spec.sections[3].form_fields.join(', ')}; on submit, POST JSON ${JSON.stringify(spec.sections[3].wiring.body_template)} to ${spec.sections[3].wiring.url}; ${spec.sections[3].wiring.success_behavior}. ${spec.sections[3].notes}`,
    `5. FOOTER — ${spec.sections[4].elements.join('; ')}.`,
    '',
    'HARD RULES: ' + spec.hard_rules.join(' '),
  ].join('\n');

  return { spec, prompt };
}

module.exports = { expandPrompt };
EOF_P2_EXP
cat > scripts/generate-social-calendar.js << 'EOF_P2_CAL'
#!/usr/bin/env node
'use strict';

// MODULE 3 — Zero-prompt social calendar.
//
//   node scripts/generate-social-calendar.js <slug> [--days 30]
//
// Reads clients/{slug}/profile.json, makes ONE Anthropic call, and writes
// {days} scheduled posts into pending-posts.json across three pillars:
//   trust  — value/expertise posts
//   offer  — direct CTA posts
//   brand  — behind-the-scenes / personality posts
// Posts land as status "pending" with a scheduledFor date; nothing publishes
// until a human approves it in the portal (Social tab) or the email link.
// Re-running SKIPS days that already have a pending calendar post for this
// client, so it tops up instead of duplicating.
//
// Cost: one model call (~2-4k output tokens) per run. Deliberate, not a cron.

require('dotenv').config({ path: '/root/newsites-sms/.env' });
const store = require('../lib/store');
const profiles = require('../lib/profiles');

async function main() {
  const slug = process.argv[2];
  if (!slug) {
    console.error('Usage: node scripts/generate-social-calendar.js <slug> [--days 30]');
    process.exit(2);
  }
  const daysIdx = process.argv.indexOf('--days');
  const days = daysIdx > -1 ? Math.min(60, Math.max(7, parseInt(process.argv[daysIdx + 1], 10) || 30)) : 30;

  const profile = await profiles.loadProfile(slug, { fresh: true });
  if (!profile) {
    console.error(`No profile for "${slug}"`);
    process.exit(1);
  }
  const id = profile.identity || {};
  const services = ((profile.offer || {}).services || [])
    .map((s) => `${s.name}${s.price != null ? ` ($${s.price})` : ''}`)
    .join(', ');

  const sys = 'You write social media posts for small businesses. Return ONLY a JSON array, no markdown fences, no commentary.';
  const user = `Business: ${id.business_name || slug}
Niche: ${id.niche || 'local business'}
Area: ${id.service_area || 'local'}
Services & listed prices: ${services || 'not listed — never invent prices'}
Hours: ${id.hours || 'n/a'}

Write ${days} short social posts (Instagram/Facebook length, 1-4 sentences, tasteful emoji ok, no hashtag spam — max 3 hashtags).
Rotate three pillars roughly evenly: "trust" (tips, expertise, value), "offer" (direct call-to-action using ONLY listed services/prices; if no prices are listed, CTA without numbers), "brand" (behind the scenes, personality, community).
NEVER invent prices, discounts, reviews, or claims not given above.
Return a JSON array of exactly ${days} objects: [{"pillar":"trust|offer|brand","text":"..."}]`;

  console.log(`[calendar] generating ${days} posts for ${slug}...`);
  const resp = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': process.env.ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: 'claude-sonnet-4-6',
      max_tokens: 6000,
      system: sys,
      messages: [{ role: 'user', content: user }],
    }),
    signal: AbortSignal.timeout(90000),
  });
  const data = await resp.json();
  if (!resp.ok) {
    console.error('[calendar] API error:', resp.status, JSON.stringify(data).slice(0, 300));
    process.exit(1);
  }
  let posts;
  try {
    posts = JSON.parse((data.content?.[0]?.text || '[]').replace(/```json|```/g, '').trim());
    if (!Array.isArray(posts) || !posts.length) throw new Error('empty');
  } catch (e) {
    console.error('[calendar] model did not return valid JSON — aborting, nothing written');
    process.exit(1);
  }

  const biz = id.business_name || slug;
  let added = 0;
  await store.updateJson('pending-posts.json', [], (all) => {
    if (!Array.isArray(all)) all = [];
    const existingDays = new Set(
      all.filter((p) => p.clientName === biz && p.source === 'calendar' && p.status === 'pending')
         .map((p) => (p.scheduledFor || '').slice(0, 10))
    );
    const start = new Date();
    for (let i = 0; i < posts.length; i++) {
      const d = new Date(start.getTime() + (i + 1) * 24 * 60 * 60 * 1000);
      d.setHours(10, 0, 0, 0); // 10:00 local server time; portal can reschedule
      const dayKey = d.toISOString().slice(0, 10);
      if (existingDays.has(dayKey)) continue;
      all.push({
        id: `${Date.now()}${String(i).padStart(2, '0')}`,
        clientName: biz,
        clientEmail: '',
        message: String(posts[i].text || '').slice(0, 1500),
        pillar: ['trust', 'offer', 'brand'].includes(posts[i].pillar) ? posts[i].pillar : 'trust',
        source: 'calendar',
        status: 'pending',
        createdAt: new Date().toISOString(),
        scheduledFor: d.toISOString(),
      });
      added += 1;
    }
    return all;
  });

  console.log(`[calendar] ${added} posts queued for ${biz} (skipped ${posts.length - added} already-covered days). Review them in the portal Social tab.`);
}

main().catch((e) => { console.error('[calendar] crashed:', e.message); process.exit(1); });
EOF_P2_CAL
cat > portal/portal.html << 'EOF_P2_HTM'
<!DOCTYPE html>
<html lang="en" class="dark">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NewSites — Client Portal</title>
<script src="https://cdn.tailwindcss.com"></script>
<style>
  :root { color-scheme: dark; }
  body { background: #0a0f1a; }
  .glass { background: rgba(17, 24, 39, .72); backdrop-filter: blur(8px); border: 1px solid rgba(148, 163, 184, .12); }
  .tab-active { color: #38bdf8; border-color: #38bdf8; }
  .badge-hot { background: rgba(239,68,68,.15); color: #f87171; border: 1px solid rgba(239,68,68,.35); }
  .badge-warm { background: rgba(245,158,11,.15); color: #fbbf24; border: 1px solid rgba(245,158,11,.35); }
  .badge-cold { background: rgba(56,189,248,.12); color: #7dd3fc; border: 1px solid rgba(56,189,248,.3); }
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
    <input id="tokenInput" type="password" placeholder="Access key" class="w-full bg-slate-900 border border-slate-700 rounded-lg px-4 py-3 mb-3 focus:outline-none focus:border-sky-500">
    <button onclick="saveToken()" class="w-full bg-sky-500 hover:bg-sky-400 text-slate-950 font-bold rounded-lg py-3">Open my dashboard</button>
    <p id="gateErr" class="text-red-400 text-sm mt-3 hidden">That key didn't work.</p>
  </div>
</div>

<div id="app" class="hidden">
  <header class="sticky top-0 z-30 glass">
    <div class="max-w-6xl mx-auto px-4 py-3 flex items-center gap-4">
      <div class="flex items-center gap-2 font-bold text-white"><span class="w-2.5 h-2.5 rounded-sm bg-sky-400 shadow-[0_0_10px_rgba(56,189,248,.8)]"></span><span id="bizName">NewSites</span></div>
      <div id="aiPill" class="text-xs px-2 py-1 rounded-full border"></div>
      <nav class="ml-auto flex gap-1 overflow-x-auto text-sm">
        <button data-tab="overview" class="tabBtn px-3 py-2 border-b-2 border-transparent hover:text-sky-300">Overview</button>
        <button data-tab="leads" class="tabBtn px-3 py-2 border-b-2 border-transparent hover:text-sky-300">Lead Generation</button>
        <button data-tab="voice" class="tabBtn px-3 py-2 border-b-2 border-transparent hover:text-sky-300">AI Voice &amp; SMS</button>
        <button data-tab="social" class="tabBtn px-3 py-2 border-b-2 border-transparent hover:text-sky-300">Social Engine</button>
        <button data-tab="settings" class="tabBtn px-3 py-2 border-b-2 border-transparent hover:text-sky-300">Settings</button>
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
          <div class="flex items-center justify-between mb-3">
            <h3 class="font-semibold text-white">Live Lead Stream</h3>
            <button onclick="loadLeads()" class="text-xs text-sky-300 hover:text-sky-200">↻ Refresh</button>
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
            <label class="flex items-start gap-3 p-3 rounded-lg border border-slate-700 cursor-pointer hover:border-sky-600">
              <input type="radio" name="routing" value="auto" class="mt-1">
              <span><span class="text-white font-medium">AI Brain Auto-Routing</span><br><span class="text-slate-400">Hot leads (score ≥ your threshold) text you instantly. Everything else lands in the CRM and gets the automated follow-up sequence. Quiet hours respected.</span></span>
            </label>
            <label class="flex items-start gap-3 p-3 rounded-lg border border-slate-700 cursor-pointer hover:border-sky-600">
              <input type="radio" name="routing" value="manual" class="mt-1">
              <span><span class="text-white font-medium">Manual Custom Routing</span><br><span class="text-slate-400">You set the exact cell for alerts; every lead alert goes there regardless of score.</span></span>
            </label>
            <div>
              <label class="text-slate-400 text-xs">Alert cell (SMS)</label>
              <input id="ownerCell" class="w-full bg-slate-900 border border-slate-700 rounded-lg px-3 py-2 mt-1" placeholder="+1 555 555 5555">
            </div>
            <div>
              <label class="text-slate-400 text-xs">Hot-lead threshold (0–10): <span id="thVal" class="text-sky-300 font-semibold"></span></label>
              <input id="threshold" type="range" min="0" max="10" step="1" class="w-full accent-sky-400">
            </div>
            <button onclick="saveRouting()" class="w-full bg-sky-500 hover:bg-sky-400 text-slate-950 font-bold rounded-lg py-2.5">Save routing</button>
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
        <button onclick="loadPosts()" class="text-xs text-sky-300 hover:text-sky-200">↻ Refresh</button>
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
            <button onclick="saveQuiet()" class="bg-sky-500 hover:bg-sky-400 text-slate-950 font-bold rounded-lg px-4 py-2">Save</button>
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
        <a id="loCall" class="flex-1 text-center bg-emerald-500/90 hover:bg-emerald-400 text-slate-950 font-bold rounded-lg py-2">Call Now</a>
        <a id="loSms" class="flex-1 text-center bg-sky-500/90 hover:bg-sky-400 text-slate-950 font-bold rounded-lg py-2">Send SMS</a>
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
     <div class="h-2 bg-slate-800 rounded-full overflow-hidden"><div class="h-full bg-sky-500/80" style="width:${Math.round(n / total * 100)}%"></div></div></div>`).join('') || '<p class="text-slate-500 text-sm">No leads yet — they\'ll appear the moment your AI takes its first call or form fill.</p>';
}

async function loadLeads() {
  const d = await api('/leads');
  const st = SETTINGS || await api('/settings'); SETTINGS = st;
  document.querySelector(`input[name=routing][value=${st.editable.routing_mode}]`).checked = true;
  $('ownerCell').value = st.editable.owner_cell;
  $('threshold').value = st.editable.lead_alert_threshold;
  $('thVal').textContent = st.editable.lead_alert_threshold;
  $('threshold').oninput = () => $('thVal').textContent = $('threshold').value;
  $('leadRows').innerHTML = d.leads.map((l) => `
    <tr class="border-b border-slate-800/60 hover:bg-slate-800/30 cursor-pointer" onclick='openLead(${JSON.stringify(l.key)})'>
      <td class="py-2.5 pr-3 text-slate-400 whitespace-nowrap">${l.created_at ? new Date(l.created_at).toLocaleDateString() : '—'}</td>
      <td class="py-2.5 pr-3"><div class="text-white">${esc(l.name || 'Unknown')}</div><div class="text-slate-500 text-xs">${esc(l.phone || l.email || '')}</div></td>
      <td class="py-2.5 pr-3 text-slate-300">${esc(l.source || '')}</td>
      <td class="py-2.5 pr-3"><span class="badge-${l.badge} text-xs px-2 py-0.5 rounded-full">${l.badge === 'unscored' ? '—' : l.badge.toUpperCase() + (l.score != null ? ' ' + l.score : '')}</span></td>
      <td class="py-2.5 text-slate-400 text-xs max-w-[220px] truncate">${esc(l.summary || '')}</td>
    </tr>`).join('') || '<tr><td colspan="5" class="py-6 text-center text-slate-500">No leads yet.</td></tr>';
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
  t.className = 'px-4 py-2 rounded-lg font-bold ' + (on ? 'bg-emerald-500 text-slate-950 hover:bg-emerald-400' : 'bg-red-500/90 text-white hover:bg-red-400');
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
  const roleCls = { caller: 'bg-slate-800 text-slate-100 self-start', assistant: 'bg-sky-900/50 text-sky-100 self-end', system: 'bg-amber-900/30 text-amber-200 self-center text-xs' };
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
  const pillarColor = { trust: 'text-sky-300', offer: 'text-amber-300', brand: 'text-fuchsia-300' };
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
        ${p.status === 'pending' ? `<button onclick="postAction('${p.id}','approve')" class="bg-emerald-500 hover:bg-emerald-400 text-slate-950 font-bold rounded-lg px-3 py-1.5 text-sm">Approve &amp; Post</button>` : ''}
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
EOF_P2_HTM
cat > call-handler.js << 'EOF_P2_CH'
// NewSites voice AI — call-handler.js (v2, 2026-08-22 overhaul)
// Runs as PM2 process "newsites-calls" on port 3002.
//
// What changed vs v1 (rollback = restore call-handler.js.bak-* and pm2 restart newsites-calls):
//   - Per-client profile loaded from the caller's dialed number (numbers-map).
//   - Kill switch: profile.ai_enabled=false bridges straight to the owner.
//   - AI + recording disclosure prepended to the greeting (CA two-party consent).
//   - All speech uses the Polly.Joanna-Neural voice.
//   - 8-turn limit (AI_TURN_LIMIT) → warm handoff to owner_cell.
//   - System prompt comes from clients/{slug}/compiled/system-prompt.txt
//     (run `node compiler.js <slug>` after profile edits); the hardcoded
//     prompt remains as fallback. A call-completion protocol is appended so
//     the COMPLETE sentinel keeps working with any compiled prompt.
//   - Zero-hallucination pricing: if the AI emits the forced fallback line,
//     an owner_alert job fires immediately.
//   - Completed calls upsert into the CRM (system of record + dashboard).
//   - Sessions are cleaned up on completion and swept hourly (no more
//     unbounded in-memory growth).

require('dotenv').config({ path: '/root/newsites-sms/.env' });
const express = require('express');
const twilio = require('twilio');
const { saveLead } = require('./lead-scorer');

const profiles = require('./lib/profiles');
const guards = require('./guards');
const crm = require('./crm-adapter');
const phone = require('./lib/phone');
const transcripts = require('./lib/transcripts');

// Record the live call via Twilio's REST API (the TwiML Gather/Say flow has
// no verb for whole-call recording). Fire-and-forget: a recording failure
// must never break the call. Gated on the profile's recording_disclosure
// (the greeting must have announced it) and RECORD_CALLS!=0.
async function startRecording(callSid, slug, docRel) {
  try {
    if (process.env.RECORD_CALLS === '0') return;
    const sid = process.env.TWILIO_ACCOUNT_SID, tok = process.env.TWILIO_AUTH_TOKEN;
    const base = process.env.PUBLIC_BASE_URL;
    if (!sid || !tok || !base) return; // no creds or no public callback URL — skip quietly
    const params = new URLSearchParams({
      RecordingStatusCallback: `${base}/twilio/recording-status?slug=${encodeURIComponent(slug)}&doc=${encodeURIComponent(docRel)}`,
      RecordingStatusCallbackEvent: 'completed',
    });
    const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Calls/${callSid}/Recordings.json`, {
      method: 'POST',
      headers: {
        Authorization: 'Basic ' + Buffer.from(`${sid}:${tok}`).toString('base64'),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: params.toString(),
      signal: AbortSignal.timeout(8000),
    });
    if (!r.ok) {
      const t = await r.text().catch(() => '');
      console.warn(`[call] recording start failed ${r.status}: ${t.slice(0, 160)}`);
    }
  } catch (e) {
    console.warn('[call] recording start error:', e.message);
  }
}

const app = express();
app.use(express.urlencoded({ extended: false }));

const VOICE = { voice: 'Polly.Joanna-Neural' };
const SPEECH_HINTS = 'website, websites, pricing, price, plan, Starter, Growth, Empire, appointment, demo, AI, call answering, SMS, text, automation, CRM, leads, social media, cancel, help';
const DISCLOSURE = "Quick note — this call may be recorded, and you're speaking with an A.I. assistant. ";

const FALLBACK_PROMPT =
  'You are a friendly business receptionist on a phone call. Keep responses short and friendly.';

// Appended to WHATEVER system prompt is in play so the completion sentinel
// and lead extraction keep working even as compiled prompts change.
const CALL_PROTOCOL = `

=== CALL HANDLING (system requirement) ===
Lead with help. Answer the caller's actual question immediately using the
business information above — services, prices, next steps — BEFORE asking for
anything. Never open with a request for their name.
While helping, naturally pick up their name and a callback number or email,
one at a time, only after you have been useful. If they volunteer something,
never re-ask for it.
When their needs are handled or they start wrapping up, briefly confirm
whatever contact details you did get, say a warm goodbye, and append the
single word COMPLETE at the very end of that final message. Say COMPLETE only
in that final goodbye message, never earlier — even if you never got their
name.`;

// callSid -> { convo: [], lead: {}, slug, startedAt }
const sessions = {};
setInterval(() => {
  const cutoff = Date.now() - 4 * 60 * 60 * 1000;
  for (const sid of Object.keys(sessions)) {
    if (sessions[sid].startedAt < cutoff) {
      const s = sessions[sid];
      if (s.slug && s.doc) transcripts.finalize(s.slug, s.doc, 'abandoned').catch(() => {});
      delete sessions[sid];
    }
  }
}, 60 * 60 * 1000).unref();

function endSession(callSid) {
  delete sessions[callSid];
  guards.resetTurns(callSid);
}

app.post('/call', async (req, res) => {
  res.type('text/xml');
  const callSid = req.body.CallSid;
  const fromNumber = req.body.From;

  try {
    const slug = await profiles.slugForNumber(req.body.To);
    const profile = await profiles.loadProfile(slug);

    // Per-client kill switch — no AI, straight to a human (or voicemail).
    if (profile && !guards.aiEnabled(profile)) {
      return res.send(guards.killSwitchTwiml(profile));
    }

    sessions[callSid] = { convo: [], lead: { phone: fromNumber }, slug, startedAt: Date.now(), doc: null };
    try {
      sessions[callSid].doc = await transcripts.beginVoice(slug, callSid, fromNumber);
    } catch (e) { console.warn('[call] transcript begin failed:', e.message); }

    const id = (profile && profile.identity) || {};
    const persona = (profile && profile.voice_sms_persona) || {};
    const disclose = persona.recording_disclosure !== false; // default ON — CA two-party consent
    const greeting =
      (disclose ? DISCLOSURE : '') +
      `Hello! Thank you for calling${id.business_name ? ' ' + id.business_name : ''}. How can I help you today?`;

    const twiml = new twilio.twiml.VoiceResponse();
    const gather = twiml.gather({
      input: 'speech', enhanced: true, speechModel: 'phone_call', hints: SPEECH_HINTS,
      action: '/call/respond',
      speechTimeout: 'auto',
      language: 'en-US'
    });
    gather.say(VOICE, greeting);
    twiml.redirect('/call/respond'); // caller stayed silent — give the AI a turn anyway

    if (sessions[callSid].doc) {
      transcripts.appendTurn(slug, sessions[callSid].doc, 'assistant', greeting).catch(() => {});
      if (disclose) startRecording(callSid, slug, sessions[callSid].doc); // disclosure announced — recording allowed
    }

    res.send(twiml.toString());
  } catch (e) {
    console.error('[call] entry error:', e);
    const twiml = new twilio.twiml.VoiceResponse();
    twiml.say(VOICE, 'Sorry, we are having technical trouble. Please try again shortly.');
    twiml.hangup();
    res.send(twiml.toString());
  }
});

app.post('/call/respond', async (req, res) => {
  res.type('text/xml');
  const callSid = req.body.CallSid;
  const userSpeech = (req.body.SpeechResult || '').trim();

  try {
    if (!sessions[callSid]) {
      sessions[callSid] = { convo: [], lead: { phone: req.body.From }, slug: null, startedAt: Date.now() };
    }
    const session = sessions[callSid];
    if (!session.slug) session.slug = await profiles.slugForNumber(req.body.To);
    const profile = await profiles.loadProfile(session.slug);

    // Silence/timeout — reprompt without burning an AI turn.
    if (!userSpeech) {
      const twiml = new twilio.twiml.VoiceResponse();
      const gather = twiml.gather({ input: 'speech', enhanced: true, speechModel: 'phone_call', hints: SPEECH_HINTS, action: '/call/respond', speechTimeout: 'auto', language: 'en-US' });
      gather.say(VOICE, "Sorry, I didn't catch that. How can I help?");
      twiml.say(VOICE, "It seems we got disconnected. Please call back anytime. Goodbye!");
      twiml.hangup();
      return res.send(twiml.toString());
    }

    session.convo.push({ role: 'user', text: userSpeech });
    if (session.doc && session.slug) transcripts.appendTurn(session.slug, session.doc, 'caller', userSpeech).catch(() => {});

    // Turn limit — past it, a human takes over. Warm handoff, no dead air.
    const turnNo = guards.bumpTurn(callSid);
    if (turnNo > guards.TURN_LIMIT) {
      if (session.doc && session.slug) {
        await transcripts.appendTurn(session.slug, session.doc, 'system', 'Turn limit reached — escalated to owner').catch(() => {});
        await transcripts.finalize(session.slug, session.doc, 'escalated').catch(() => {});
      }
      endSession(callSid);
      return res.send(guards.escalationTwiml(profile));
    }

    // Compiled per-client prompt, with the hardcoded one as fallback.
    const compiled = session.slug ? await profiles.loadCompiledPrompt(session.slug) : null;
    const systemPrompt = (compiled || FALLBACK_PROMPT) + CALL_PROTOCOL;

    const claudeMessages = session.convo.map((t) => ({
      role: t.role === 'model' ? 'assistant' : 'user',
      content: t.text
    }));

    const chatResp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': process.env.ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5',
        max_tokens: 200,
        system: systemPrompt,
        messages: claudeMessages
      }),
      signal: AbortSignal.timeout(15000),
    });
    const chatData = await chatResp.json();
    const aiResponse = (chatData.content && chatData.content[0]) ? chatData.content[0].text : "I'm sorry, could you repeat that?";

    session.convo.push({ role: 'model', text: aiResponse });
    if (session.doc && session.slug) transcripts.appendTurn(session.slug, session.doc, 'assistant', aiResponse.replace(/COMPLETE/g, '').trim()).catch(() => {});

    // Deterministic pricing guard: the compiled prompt FORCES an exact fallback
    // sentence for off-menu pricing; if it appears, alert the owner now.
    guards.checkPriceEscalation(aiResponse, profile, { callerPhone: req.body.From, channel: 'voice' })
      .catch((e) => console.warn('[call] price escalation check failed:', e.message));

    // Extract lead info (name/email/need) from the running conversation.
    try {
      const convoText = session.convo.map((t) => t.text).join(' ');
      const exResp = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-api-key': process.env.ANTHROPIC_API_KEY,
          'anthropic-version': '2023-06-01'
        },
        body: JSON.stringify({
          model: 'claude-haiku-4-5',
          max_tokens: 150,
          messages: [{ role: 'user', content:
            'Extract name, email, and need from this conversation. Return ONLY JSON with no markdown: {"name":"","email":"","need":""}\n\n' + convoText }]
        }),
        signal: AbortSignal.timeout(10000),
      });
      const exData = await exResp.json();
      const exText = (exData.content && exData.content[0]) ? exData.content[0].text : '{}';
      const extracted = JSON.parse(exText.replace(/```json|```/g, '').trim());
      session.lead = Object.assign({}, session.lead, extracted);
    } catch (e) { /* extraction is best-effort */ }

    const twiml = new twilio.twiml.VoiceResponse();

    if (aiResponse.includes('COMPLETE')) {
      const lead = session.lead;
      await saveLead(lead); // existing lead-scorer pipeline, unchanged

      // New pipeline: CRM system of record + dashboard mirror.
      try {
        const e164 = phone.toE164(lead.phone || req.body.From);
        if (session.slug && e164) {
          await crm.upsertLead(session.slug, {
            name: lead.name || null,
            email: lead.email || null,
            phone: e164,
            message: lead.need,
            note: lead.need ? String(lead.need).slice(0, 300) : undefined,
            stage: 'New Lead',
            source: 'voice',
            tags: ['voice'],
          });
        }
      } catch (e) {
        console.warn('[call] crm upsert failed:', e.message);
      }

      if (session.doc && session.slug) await transcripts.finalize(session.slug, session.doc, 'completed').catch(() => {});
      endSession(callSid);
      twiml.say(VOICE, 'Thank you for calling. Someone will be in touch with you soon. Goodbye!');
      twiml.hangup();
    } else {
      const gather = twiml.gather({
        input: 'speech', enhanced: true, speechModel: 'phone_call', hints: SPEECH_HINTS,
        action: '/call/respond',
        speechTimeout: 'auto',
        language: 'en-US'
      });
      gather.say(VOICE, aiResponse.replace(/COMPLETE/g, '').trim());
      twiml.say(VOICE, 'Are you still there? Feel free to call back anytime. Goodbye!');
      twiml.hangup();
    }

    res.send(twiml.toString());
  } catch (e) {
    console.error('[call] respond error:', e);
    const twiml = new twilio.twiml.VoiceResponse();
    twiml.say(VOICE, "I'm sorry, we're having trouble on our end. Please call back in a few minutes.");
    twiml.hangup();
    res.send(twiml.toString());
  }
});

app.listen(3002, () => {
  console.log('Call handler running on port 3002 (v2 overhaul)');
});
EOF_P2_CH
declare -A EXPECT=( [routes/portal-api.js]=17320 [routes/twilio-status.js]=5161 [lib/transcripts.js]=6174 [lib/expand-prompt.js]=7561 [scripts/generate-social-calendar.js]=4954 [portal/portal.html]=26099 [call-handler.js]=13528 )
for f in "${!EXPECT[@]}"; do
  W=$(wc -c < "$f"); [ "$W" -eq "${EXPECT[$f]}" ] && ok "$f $W" || bad "$f $W != ${EXPECT[$f]}"
done
[ "$FAIL" -eq 0 ] || die "embed mismatch"
for f in routes/portal-api.js routes/twilio-status.js lib/transcripts.js lib/expand-prompt.js scripts/generate-social-calendar.js call-handler.js; do node --check "$f" || die "syntax: $f"; done
ok "syntax clean"

echo "==> 3/8 Patch index.js (portal mount + SMS transcript logging)"
if grep -q "portal-api" index.js; then ok "portal already mounted"; else
python3 - << 'PYIN'
s = open('index.js').read()
i = s.index("app.listen(3001")
open('index.js','w').write(s[:i] + "\n// ── CLIENT PORTAL (Module: dashboard) ──\napp.use('/portal-api', require('./routes/portal-api'));\napp.get('/portal', (req, res) => res.sendFile('/root/newsites-sms/portal/portal.html'));\n" + "\n" + s[i:])
PYIN
grep -q "portal-api" index.js && ok "portal mounted" || die "mount failed"; fi
python3 - << 'PYSMS'

s = open('index.js').read()
if 'transcriptsLib.smsTurn' in s:
    print('  [OK] /sms transcript logging already present')
else:
    s = s.replace("const { xmlEscape } = require('./lib/tpl');",
                  "const { xmlEscape } = require('./lib/tpl');\nconst transcriptsLib = require('./lib/transcripts');")
    old_kw = """    if (profile) {
      const kw = await compliance.processInboundSms(from, body, profile);
      if (kw.handled) return res.send(smsTwiml(kw.reply));
    }"""
    new_kw = """    transcriptsLib.smsTurn(slug || DEFAULT_CLIENT_SLUG, from, 'caller', body).catch(() => {});

    if (profile) {
      const kw = await compliance.processInboundSms(from, body, profile);
      if (kw.handled) {
        transcriptsLib.smsTurn(slug || DEFAULT_CLIENT_SLUG, from, 'assistant', kw.reply || ('(' + kw.kind + ')'), { kind: kw.kind }).catch(() => {});
        return res.send(smsTwiml(kw.reply));
      }
    }"""
    assert old_kw in s, 'kw anchor missing'
    s = s.replace(old_kw, new_kw)
    old_reply = """    // 3. Same friendly auto-reply as before.
    return res.send(smsTwiml('Thanks for contacting us!'));"""
    new_reply = """    // 3. Same friendly auto-reply as before.
    transcriptsLib.smsTurn(slug || DEFAULT_CLIENT_SLUG, from, 'assistant', 'Thanks for contacting us!').catch(() => {});
    return res.send(smsTwiml('Thanks for contacting us!'));"""
    assert old_reply in s, 'reply anchor missing'
    s = s.replace(old_reply, new_reply)
    open('index.js','w').write(s)
    print('  [OK] /sms transcript logging inserted')

PYSMS
node --check index.js || { cp "index.js.bak-$STAMP" index.js; die "index.js broke — restored"; }
ok "index.js clean"

echo "==> 4/8 Portal tokens"
node -e "
const fs=require('fs'),crypto=require('crypto');
for(const d of fs.readdirSync('clients',{withFileTypes:true})){
  if(!d.isDirectory())continue;
  const p='clients/'+d.name+'/profile.json';
  if(!fs.existsSync(p))continue;
  const j=JSON.parse(fs.readFileSync(p));
  if(!j.portal_token){j.portal_token=crypto.randomBytes(24).toString('hex');fs.writeFileSync(p,JSON.stringify(j,null,2));console.log('  [OK] token created:',d.name);}
  else console.log('  [OK] token exists:',d.name);
}"

echo "==> 5/8 Caddy /portal*"
if [ -f "$CADDYFILE" ] && command -v caddy >/dev/null 2>&1; then
  cp "$CADDYFILE" "$BASE/Caddyfile.bak-$STAMP"
  grep -q 'reverse_proxy /portal\*' "$CADDYFILE" || sed -i 's|\(reverse_proxy /leads\* localhost:3001\)|\1\n\t\treverse_proxy /portal* localhost:3001|' "$CADDYFILE"
  if caddy validate --config "$CADDYFILE" >/dev/null 2>&1; then systemctl reload caddy && ok "Caddy ok"
  else cp "$BASE/Caddyfile.bak-$STAMP" "$CADDYFILE"; bad "Caddy validate failed — restored"; fi
else echo "  [WARN] caddy skipped"; fi

echo "==> 6/8 Restart (index + call handler)"
if command -v pm2 >/dev/null 2>&1; then
  pm2 restart newsites-sms newsites-calls --update-env >/dev/null && ok "restarted newsites-sms + newsites-calls"
else echo "  [WARN] pm2 skipped"; fi

echo "==> 7/8 Verify"
if [ "${NEWSITES_TEST:-0}" = "1" ]; then echo "  [test mode] skip curls"; else
  sleep 2
  C=$(curl -s -o /dev/null -w '%{http_code}' "https://164.92.110.116.nip.io/portal" || echo ERR)
  [ "$C" = "200" ] && ok "portal serves ($C)" || bad "portal returned $C"
  C2=$(curl -s -o /dev/null -w '%{http_code}' "https://164.92.110.116.nip.io/portal-api/summary" || echo ERR)
  [ "$C2" = "401" ] && ok "API locked without key (401)" || bad "API returned $C2 (want 401)"
  curl -s -o /dev/null -X POST localhost:3001/sms -d 'From=+13235550177' -d 'To=+12295924933' -d 'Body=transcript smoke test'
  sleep 1
  T=$(ls clients/newsites/transcripts/*/sms-* 2>/dev/null | wc -l)
  [ "$T" -ge 1 ] && ok "SMS transcript written ($T doc)" || bad "no SMS transcript created"
fi

echo "==> 8/8 Portal links"
node -e "
const fs=require('fs');
console.log('PORTAL LINKS (one per client — treat like passwords):');
for(const d of fs.readdirSync('clients',{withFileTypes:true})){
  if(!d.isDirectory())continue;
  const p='clients/'+d.name+'/profile.json';
  if(!fs.existsSync(p))continue;
  const j=JSON.parse(fs.readFileSync(p));
  if(j.portal_token)console.log('  '+d.name+': https://164.92.110.116.nip.io/portal?token='+j.portal_token);
}"
echo
[ "$FAIL" -eq 0 ] && echo "PORTAL + PERSISTENCE DEPLOY COMPLETE. Call the (229) number, then open your portal link — the conversation appears in AI Voice & SMS, audio ~1 min later." || echo "XX FINISHED WITH FAILURES — screenshot everything above."
