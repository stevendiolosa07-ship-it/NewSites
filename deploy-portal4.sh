#!/bin/bash
# Portal v4: access key required each visit unless "Remember" is ticked. Run ON THE DROPLET.
set -uo pipefail
BASE="${NEWSITES_BASE:-/root/newsites-sms}"
cd "$BASE" || { echo "XX run on the droplet"; exit 1; }
cp portal/portal.html "portal/portal.html.bak-$(date +%Y%m%d-%H%M%S)"
cat > portal/portal.html << 'EOF_P4'
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
    <label class="flex items-center gap-2 text-sm text-slate-400 mb-4 cursor-pointer select-none justify-center">
      <input id="rememberKey" type="checkbox" class="accent-[#C9A84C] w-4 h-4"> Remember access key on this device
    </label>
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
// Key handling: session-only by default (closing the tab forgets it); the
// "Remember" checkbox opts a device into localStorage. Invite links (?token=)
// grant this session only — they never silently imprint on a shared device.
let TOKEN = new URLSearchParams(location.search).get('token') || sessionStorage.getItem('ns_portal_token') || localStorage.getItem('ns_portal_token') || '';
if (new URLSearchParams(location.search).get('token')) { try { sessionStorage.setItem('ns_portal_token', TOKEN); } catch (e) {} }
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
function showGate(err) {
  if (err) { try { sessionStorage.removeItem('ns_portal_token'); localStorage.removeItem('ns_portal_token'); } catch (e) {} } // stale key — clear it
  $('gate').classList.remove('hidden'); $('app').classList.add('hidden'); $('gateErr').classList.toggle('hidden', !err);
}
function saveToken() {
  TOKEN = $('tokenInput').value.trim();
  try {
    sessionStorage.setItem('ns_portal_token', TOKEN);
    if ($('rememberKey').checked) localStorage.setItem('ns_portal_token', TOKEN);
    else localStorage.removeItem('ns_portal_token');
  } catch (e) {}
  boot();
}

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
EOF_P4
W=$(wc -c < portal/portal.html)
[ "$W" -eq 29484 ] && echo "[OK] portal.html $W" || { echo "XX size $W != 29484"; exit 1; }
grep -q "Remember access key" portal/portal.html && echo "[OK] remember-key gate in place" || echo "XX marker missing"
echo "PORTAL v4 DONE — no restart needed. Open the portal in a fresh tab to see the gate."
