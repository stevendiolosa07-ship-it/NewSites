#!/usr/bin/env node
/**
 * marketing-engine.js — NewSites Marketing Engine ("Clyde")
 * ---------------------------------------------------------
 * Generates ready-to-execute social campaigns for any client industry.
 * Every CTA is wired to the NewSites SMS pipeline: "Text KEYWORD to NUMBER".
 *
 * Deploy (VPS):
 *   1. Place in /root/newsites-sms/marketing-engine.js
 *   2. pm2 start marketing-engine.js --name marketing-engine
 *   3. Caddyfile route (inside your site block — exact path, remember /call* lesson):
 *        handle /marketing* {
 *            reverse_proxy localhost:3005
 *        }
 *      then: systemctl reload caddy
 *
 * Env:
 *   ANTHROPIC_API_KEY     required (already set for your other services)
 *   TWILIO_PUBLIC_NUMBER  display number for CTAs, e.g. "(347) 302-9363"
 *   MARKETING_PORT        default 3005
 *   CLAUDE_MODEL          default claude-sonnet-4-6
 *   CAMPAIGNS_DIR         default ./campaigns
 *   ANTHROPIC_BASE_URL    override for testing only
 *
 * Endpoints:
 *   GET  /health
 *   POST /marketing/generate            { businessName, industry, city?, address?,
 *                                         keyword?, phoneDisplay?, notes?, category? }
 *   GET  /marketing/campaigns           list saved campaigns
 *   GET  /marketing/campaigns/:client   latest campaign for a client
 */
'use strict';

try { require('dotenv').config(); } catch (_) { /* dotenv optional */ }

const express = require('express');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.MARKETING_PORT || '3005', 10);
const MODEL = process.env.CLAUDE_MODEL || 'claude-sonnet-4-6';
const API_KEY = process.env.ANTHROPIC_API_KEY || '';
const BASE_URL = (process.env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com').replace(/\/+$/, '');
const SMS_NUMBER = process.env.TWILIO_PUBLIC_NUMBER || '(347) 302-9363';
const CAMPAIGNS_DIR = process.env.CAMPAIGNS_DIR || path.join(__dirname, 'campaigns');

fs.mkdirSync(CAMPAIGNS_DIR, { recursive: true });

const app = express();
app.use(express.json({ limit: '1mb' }));

/* ------------------------------------------------------------------ */
/* Clyde system prompt                                                  */
/* ------------------------------------------------------------------ */

function buildSystemPrompt(keyword, phone) {
  return [
    'You are Clyde, an elite AI Social Media Marketing Architect and the growth engine for New Sites — an automated platform with an AI CRM, SMS backend, and instant client onboarding.',
    '',
    'Your job: deconstruct the given business, classify it, and produce ready-to-execute organic content campaigns that route viewers into the NewSites SMS pipeline.',
    '',
    '# CLASSIFICATION',
    'Category A — digital products, software, agencies, automated services, visually abstract brands. Deliver finished AI-video-ready scripts (hook, visual direction for generation tools, voiceover, CTA).',
    'Category B — physical, location-based work: salons, construction, events, real estate, brick-and-mortar. Deliver smartphone shot lists and directing instructions. Never offer AI-generated footage concepts for Category B; physical proof and authenticity win here.',
    '',
    '# THE ONLY ALLOWED CTA',
    'Every campaign CTA must be the SMS loop and nothing else:',
    '  "Text ' + keyword + ' to ' + phone + '"',
    'The NewSites AI answers that text instantly, sends pricing/booking, and captures the lead in the CRM. Do not write comment-to-DM CTAs, do not write link-in-bio as the primary CTA.',
    '',
    '# PLAIN LANGUAGE RULE (hard rule)',
    'Shot instructions must read like a text to a friend who has never filmed anything and only owns an iPhone.',
    '- NEVER use film jargon: no "45 degrees", "tilt-up", "orbit", "wide shot", "low angle".',
    '- Every shot says: where to STAND, how to HOLD the phone, and what should FILL the screen.',
    '- Compare every position to something people already film: "hold it flat over her head like you film a plate of food", "prop it against the mirror like a gym video", "walk around slowly like you are showing off a new car".',
    '- Mention the exact iPhone feature when relevant (Camera app > Time-lapse, 0.5x lens, volume ON for real sound).',
    '',
    '# HONESTY CONSTRAINTS (hard rules)',
    '- Never invent creator handles, view counts, engagement statistics, dollar results, or studies.',
    '- Proof-of-concept sections name real, well-known FORMAT ARCHETYPES (before/after reveal, ASMR process, timelapse compression, reaction reveal, POV, day-in-the-life) and explain the retention/conversion mechanism. No fabricated examples.',
    '',
    '# OUTPUT — STRICT',
    'Respond with ONLY valid JSON. No markdown fences, no preamble, no trailing commentary. Schema:',
    '{',
    '  "category": "A" | "B",',
    '  "classification_reason": string,',
    '  "pattern_recognition": {',
    '    "core_viral_loop": string,',
    '    "funnel_blueprint": [string],',
    '    "platform_matrix": { "tiktok": string, "instagram": string, "facebook": string, "x": string }',
    '  },',
    '  "campaigns": [            // exactly 3',
    '    {',
    '      "title": string,',
    '      "concept": string,',
    '      "primary_platform": string,',
    '      "shot_list": [ { "shot": number, "phone_position": string, "action": string, "duration_seconds": number } ],   // Category B; [] for A. phone_position + action in plain iPhone language per the rule above',
    '      "video_script": { "hook": string, "visual_direction": string, "voiceover": string },                    // Category A; nulls for B',
    '      "text_overlays": [string],',
    '      "voiceover": string,      // "" if native audio only',
    '      "cta_line": string,       // must contain the keyword and number',
    '      "captions": { "tiktok": string, "instagram": string, "facebook": string },',
    '      "hashtags": [string],',
    '      "proof_of_concept": string',
    '    }',
    '  ],',
    '  "posting_cadence": string,',
    '  "sms_flow": { "keyword": string, "number": string, "auto_reply": string }',
    '}'
  ].join('\n');
}

function buildUserMessage(input, keyword, phone) {
  return [
    'Business profile:',
    '- Name: ' + input.businessName,
    '- Industry: ' + input.industry,
    input.city ? '- City: ' + input.city : null,
    input.address ? '- Address: ' + input.address : null,
    input.category && input.category !== 'auto' ? '- Forced category: ' + input.category : null,
    input.notes ? '- Notes: ' + input.notes : null,
    '- SMS keyword: ' + keyword,
    '- SMS number: ' + phone,
    '',
    'Produce the full campaign JSON now.'
  ].filter(Boolean).join('\n');
}

/* ------------------------------------------------------------------ */
/* Anthropic API call (native fetch, one retry)                        */
/* ------------------------------------------------------------------ */

async function callClaude(system, userMsg) {
  const body = JSON.stringify({
    model: MODEL,
    max_tokens: 4000,
    system: system,
    messages: [{ role: 'user', content: userMsg }]
  });

  let lastErr;
  for (let attempt = 1; attempt <= 2; attempt++) {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 90_000);
    try {
      const res = await fetch(BASE_URL + '/v1/messages', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-api-key': API_KEY,
          'anthropic-version': '2023-06-01'
        },
        body,
        signal: ac.signal
      });
      clearTimeout(timer);

      if (res.status === 429 || res.status >= 500) {
        lastErr = new Error('Anthropic API ' + res.status);
        await new Promise(r => setTimeout(r, 2000 * attempt));
        continue;
      }
      const data = await res.json();
      if (!res.ok) {
        const msg = (data && data.error && data.error.message) || ('HTTP ' + res.status);
        throw Object.assign(new Error(msg), { status: res.status });
      }
      const text = (data.content || [])
        .filter(b => b.type === 'text')
        .map(b => b.text)
        .join('\n');
      if (!text) throw new Error('Empty completion from model');
      return text;
    } catch (err) {
      clearTimeout(timer);
      if (err.status && err.status < 500 && err.status !== 429) throw err; // real 4xx: don't retry
      lastErr = err;
      if (attempt === 2) break;
      await new Promise(r => setTimeout(r, 2000));
    }
  }
  throw lastErr || new Error('Anthropic API call failed');
}

/* ------------------------------------------------------------------ */
/* Helpers                                                              */
/* ------------------------------------------------------------------ */

function parseCampaignJson(text) {
  let t = text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  const first = t.indexOf('{');
  const last = t.lastIndexOf('}');
  if (first === -1 || last === -1) throw new Error('No JSON object in model output');
  return JSON.parse(t.slice(first, last + 1));
}

function slugify(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'client';
}

function sanitizeKeyword(s) {
  return String(s || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 15);
}

/** Guarantee CTA integrity regardless of model drift. */
function enforceCta(campaign, keyword, phone) {
  const standard = 'Text ' + keyword + ' to ' + phone + ' — our AI answers in seconds with prices & open slots.';
  if (!campaign.sms_flow || typeof campaign.sms_flow !== 'object') campaign.sms_flow = {};
  campaign.sms_flow.keyword = keyword;
  campaign.sms_flow.number = phone;
  if (!campaign.sms_flow.auto_reply) {
    campaign.sms_flow.auto_reply =
      'Thanks for texting ' + keyword + '! Tap to see prices & book instantly: {BOOKING_LINK}. ' +
      'Reply with what you want + your day, and we will lock you in.';
  }
  if (Array.isArray(campaign.campaigns)) {
    for (const c of campaign.campaigns) {
      if (!c.cta_line || c.cta_line.indexOf(keyword) === -1 || c.cta_line.indexOf(phone) === -1) {
        c.cta_line = standard;
      }
    }
  }
  return campaign;
}

/* ------------------------------------------------------------------ */
/* Routes                                                               */
/* ------------------------------------------------------------------ */

app.get('/health', (_req, res) => {
  res.json({ ok: true, service: 'marketing-engine', model: MODEL, keyConfigured: Boolean(API_KEY) });
});

app.post('/marketing/generate', async (req, res) => {
  const input = req.body || {};
  if (!input.businessName || !input.industry) {
    return res.status(400).json({ ok: false, error: 'businessName and industry are required' });
  }
  if (!API_KEY) {
    return res.status(500).json({ ok: false, error: 'ANTHROPIC_API_KEY not set for marketing-engine process' });
  }

  const keyword = sanitizeKeyword(input.keyword) || sanitizeKeyword(input.businessName.split(/\s+/)[0]);
  const phone = input.phoneDisplay || SMS_NUMBER;
  const clientKey = slugify(input.clientKey || input.businessName);

  try {
    const raw = await callClaude(buildSystemPrompt(keyword, phone), buildUserMessage(input, keyword, phone));
    const campaign = enforceCta(parseCampaignJson(raw), keyword, phone);

    const record = {
      clientKey,
      input: { ...input, keyword, phoneDisplay: phone },
      model: MODEL,
      generatedAt: new Date().toISOString(),
      campaign
    };
    const file = path.join(CAMPAIGNS_DIR, clientKey + '-' + Date.now() + '.json');
    fs.writeFileSync(file, JSON.stringify(record, null, 2));

    res.json({ ok: true, clientKey, file: path.basename(file), campaign });
  } catch (err) {
    const status = err.status && err.status >= 400 && err.status < 500 ? 502 : 500;
    res.status(status).json({ ok: false, error: String(err.message || err).slice(0, 400) });
  }
});

app.get('/marketing/campaigns', (_req, res) => {
  const files = fs.readdirSync(CAMPAIGNS_DIR).filter(f => f.endsWith('.json')).sort().reverse();
  res.json({ ok: true, count: files.length, files });
});

app.get('/marketing/campaigns/:clientKey', (req, res) => {
  const key = slugify(req.params.clientKey);
  const files = fs.readdirSync(CAMPAIGNS_DIR)
    .filter(f => f.startsWith(key + '-') && f.endsWith('.json'))
    .sort()
    .reverse();
  if (!files.length) return res.status(404).json({ ok: false, error: 'No campaigns for ' + key });
  const latest = JSON.parse(fs.readFileSync(path.join(CAMPAIGNS_DIR, files[0]), 'utf8'));
  res.json({ ok: true, clientKey: key, file: files[0], history: files, latest });
});

app.listen(PORT, () => {
  console.log('[marketing-engine] listening on :' + PORT + ' model=' + MODEL + ' keyConfigured=' + Boolean(API_KEY));
});
