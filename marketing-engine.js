// ============================================================
//  NEWSITES MARKETING ENGINE  (port 3005)
//  Claude-powered marketing intelligence for NewSites clients.
//
//  What it does:
//    POST /marketing/strategy   -> live-researched, evidence-labeled
//                                  marketing playbook for a business
//    GET  /marketing/health     -> service heartbeat
//
//  Ground rules baked into the prompt (non-negotiable):
//    * Recommendations are grounded in PUBLIC signals only:
//      views / engagement / documented case studies.
//    * NEVER fabricates conversion stats. Sales-conversion truth
//      comes from the NewSites CRM lead-source attribution, not
//      from guesses about other people's funnels.
//    * Every strategy ships with: hook, pacing, CTA, evidence line
//      (labeled engagement_data | case_study | benchmark), a
//      visual_example spec (for Canva / image gen), and camera
//      directions when the industry is personality-driven.
//
//  Deploy: pm2 start marketing-engine.js --name marketing-engine
//  Caddy:  route /marketing* -> localhost:3005   (EXACT path match)
// ============================================================

"use strict";

try { require("dotenv").config(); } catch (_) { /* env may come from pm2 */ }

const express = require("express");
const app = express();
app.use(express.json({ limit: "1mb" }));

const PORT = process.env.MARKETING_PORT || 3005;
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.MARKETING_MODEL || "claude-sonnet-4-6";
const MAX_WEB_SEARCHES = 4;              // cost control per request
const CACHE_TTL_MS = 6 * 60 * 60 * 1000; // 6h — trends don't move faster

if (!ANTHROPIC_API_KEY) {
  console.warn("[marketing-engine] WARNING: ANTHROPIC_API_KEY is not set. /marketing/strategy will 503.");
}

// ---------- tiny in-memory cache (cost control) ----------
const cache = new Map();
function cacheKey(b) {
  return [b.business, b.industry, b.city, b.platform, b.goal]
    .map(v => String(v || "").toLowerCase().trim()).join("|");
}
function getCached(key) {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.t < CACHE_TTL_MS) return hit.v;
  cache.delete(key);
  return null;
}
function setCached(key, v) {
  cache.set(key, { t: Date.now(), v });
  if (cache.size > 200) cache.delete(cache.keys().next().value);
}

// ---------- Anthropic API (native https, zero new deps) ----------
const https = require("https");
function anthropic(body) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const req = https.request({
      hostname: "api.anthropic.com",
      path: "/v1/messages",
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-length": Buffer.byteLength(payload)
      },
      timeout: 180000
    }, res => {
      let data = "";
      res.on("data", c => (data += c));
      res.on("end", () => {
        try {
          const json = JSON.parse(data);
          if (res.statusCode >= 400) {
            return reject(new Error(`Anthropic ${res.statusCode}: ${json.error?.message || data.slice(0, 300)}`));
          }
          resolve(json);
        } catch (e) { reject(new Error("Bad JSON from Anthropic: " + data.slice(0, 300))); }
      });
    });
    req.on("timeout", () => { req.destroy(new Error("Anthropic request timed out")); });
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

// ---------- the brain ----------
const SYSTEM_PROMPT = `You are the NewSites Marketing Engine — a marketing intelligence system for small businesses. You research what is CURRENTLY working on social media and produce concrete, executable strategy.

HARD RULES (violations make the output worthless):
1. EVIDENCE HONESTY. Ground every recommendation in publicly observable signals: view counts, engagement rates, follower velocity, or documented/published case studies. Label every evidence item with exactly one type:
   - "engagement_data"  (public views/likes/shares/comments patterns)
   - "case_study"       (a published, attributable writeup)
   - "benchmark"        (an industry-average figure from a named source)
   NEVER state or imply a sales-conversion rate for content unless it comes from a published case study — per-post conversion data is private and claiming it is fabrication. If evidence is thin, say so in the evidence text.
2. CLASSIFICATION. Classify the business as "personality_driven" (trust is sold through a visible human: salons, realtors, coaches, restaurants) or "system_driven" (the product demos itself: SaaS, automation, e-commerce utility). Personality-driven strategies MUST include camera_directions (framing, angle, movement, lighting) so a real person can film it. System-driven strategies may be fully AI-producible.
3. EXECUTABILITY. Every strategy must contain: name, format (e.g. "9:16 vertical, 20-35s"), hook (the literal first-3-seconds mechanic, written out), pacing (shot rhythm / text-overlay cadence), cta (the literal ask + where it points), posting_cadence, evidence[], visual_example (a precise one-paragraph spec an artist or Canva user could build a reference image from), and camera_directions (personality_driven only, else null).
4. OUTPUT: Respond with ONLY a valid JSON object. No markdown fences, no preamble, no commentary. Schema:
{
  "business": string, "industry": string, "classification": "personality_driven"|"system_driven",
  "classification_reason": string,
  "researched_at": string (ISO date),
  "trend_summary": string (3-5 sentences on what is currently winning in this niche, from your web research),
  "strategies": [ { "name", "platform", "format", "hook", "pacing", "cta", "posting_cadence",
                    "evidence": [{ "type": "engagement_data"|"case_study"|"benchmark", "detail": string, "source": string }],
                    "visual_example": string, "camera_directions": string|null } ],   // exactly 3 strategies
  "measurement": string (how to attribute results through the NewSites CRM lead-source field — the client's OWN conversion data is the only conversion truth),
  "disclaimer": "Evidence reflects public engagement signals and published case studies; sales conversion varies by business and is measured via your NewSites CRM."
}`;

function extractJson(resp) {
  // Collect all text blocks (web-search responses interleave tool blocks)
  const text = (resp.content || [])
    .filter(b => b.type === "text")
    .map(b => b.text)
    .join("\n")
    .trim();
  const clean = text.replace(/^```json/i, "").replace(/^```/, "").replace(/```$/, "").trim();
  // Find outermost JSON object
  const start = clean.indexOf("{");
  const end = clean.lastIndexOf("}");
  if (start === -1 || end === -1) throw new Error("No JSON object in model output");
  return JSON.parse(clean.slice(start, end + 1));
}

// ---------- routes ----------
app.get("/marketing/health", (_req, res) => {
  res.json({
    ok: true,
    service: "newsites-marketing-engine",
    model: MODEL,
    key_loaded: Boolean(ANTHROPIC_API_KEY),
    cache_entries: cache.size,
    uptime_s: Math.round(process.uptime())
  });
});

app.post("/marketing/strategy", async (req, res) => {
  const { business, industry, city, platform, goal, refresh } = req.body || {};
  if (!business || !industry) {
    return res.status(400).json({ ok: false, error: "Required: business, industry. Optional: city, platform, goal, refresh:true" });
  }
  if (!ANTHROPIC_API_KEY) {
    return res.status(503).json({ ok: false, error: "ANTHROPIC_API_KEY not configured on server" });
  }

  const key = cacheKey({ business, industry, city, platform, goal });
  if (!refresh) {
    const hit = getCached(key);
    if (hit) return res.json({ ok: true, cached: true, playbook: hit });
  }

  const userPrompt =
    `Business: ${business}\nIndustry: ${industry}\nCity: ${city || "not specified"}\n` +
    `Priority platform: ${platform || "choose the best fit"}\nPrimary goal: ${goal || "generate inbound leads"}\n\n` +
    `Research what content formats and strategies are CURRENTLY performing in this niche (use web search; today's real trends, not generic advice). Then produce the JSON playbook per the schema.`;

  try {
    const resp = await anthropic({
      model: MODEL,
      max_tokens: 4000,
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: userPrompt }],
      tools: [{ type: "web_search_20250305", name: "web_search", max_uses: MAX_WEB_SEARCHES }]
    });
    const playbook = extractJson(resp);
    playbook.researched_at = playbook.researched_at || new Date().toISOString();
    setCached(key, playbook);
    res.json({ ok: true, cached: false, playbook });
  } catch (err) {
    console.error("[marketing-engine] strategy error:", err.message);
    res.status(502).json({ ok: false, error: "Strategy generation failed", detail: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`[marketing-engine] NewSites Marketing Engine listening on :${PORT}`);
  console.log(`[marketing-engine] model=${MODEL} web_search=on(max ${MAX_WEB_SEARCHES}) cache=${CACHE_TTL_MS / 3600000}h`);
});
