# NEWSITES.COM — Full Setup Guide
## Your complete tech stack, free or near-free

---

## THE FULL PICTURE

  app.html (your website)          claude-bot.js (your AI backend)
  ─────────────────────            ──────────────────────────────
  Hosted on GitHub Pages           Hosted on Railway.app (free)
  Free forever, custom domain      Powered by Claude AI + Twilio
        │                                      │
        └──────────── Supabase DB ─────────────┘
                   (leads, queue, appts)

---

## PART 1 — WEBSITE (GitHub Pages)
See: GITHUB_DEPLOY.md — takes 5 minutes

---

## PART 2 — AI BOT (claude-bot.js)

### A. Get your API keys (all free to start)

1. ANTHROPIC (Claude AI)
   - Go to console.anthropic.com
   - Sign up → API Keys → Create Key
   - Costs: ~$0.003 per call/SMS handled (very cheap)

2. TWILIO (phone calls + SMS)
   - Go to twilio.com → Sign up free
   - Get a phone number (~$1/mo)
   - Find your Account SID and Auth Token on the dashboard
   - Point your number's webhook to your bot URL (step D below)

3. SUPABASE (database — free)
   - Go to supabase.com → New project
   - Copy your Project URL and anon key
   - Run the SQL from the bottom of claude-bot.js to create tables

### B. Set up the bot server on Railway (free)

1. Go to railway.app → Sign up with GitHub
2. New Project → Deploy from GitHub repo
3. Upload claude-bot.js and package.json to a GitHub repo
4. Railway auto-detects Node.js and deploys it
5. Go to Variables tab → add all your .env keys
6. Railway gives you a live URL like: https://newsites-bot.up.railway.app

### C. package.json (create this alongside claude-bot.js)

{
  "name": "newsites-bot",
  "version": "1.0.0",
  "main": "claude-bot.js",
  "scripts": { "start": "node claude-bot.js" },
  "dependencies": {
    "@anthropic-ai/sdk": "^0.24.0",
    "twilio": "^5.0.0",
    "@supabase/supabase-js": "^2.0.0",
    "express": "^4.18.0",
    "dotenv": "^16.0.0"
  }
}

### D. Connect Twilio to your bot

1. Go to twilio.com/console → Phone Numbers → Your number
2. Under "Voice & Fax":
   - "A call comes in" → Webhook → https://yourbot.railway.app/call/incoming
3. Under "Messaging":
   - "A message comes in" → Webhook → https://yourbot.railway.app/sms/incoming
4. Save. Done. Your AI now answers every call and text.

---

## PART 3 — SCHEDULED TASKS (follow-ups + reminders)

Railway lets you run cron jobs free.
Add these in Railway → your service → Settings → Cron:

  Follow-ups daily at 9am:
  0 9 * * * node -e "require('./claude-bot').runFollowUps()"

  Appointment reminders daily at 8am:
  0 8 * * * node -e "require('./claude-bot').sendAppointmentReminders()"

  Process callback queue every 5 min:
  */5 * * * * node -e "require('./claude-bot').processCallbackQueue()"

---

## TOTAL MONTHLY COSTS (at startup scale)

  GitHub Pages hosting:    $0/mo
  Railway bot server:      $0/mo (free credit)
  Supabase database:       $0/mo (free tier)
  Twilio phone number:     $1/mo
  Twilio SMS (100 texts):  ~$0.80/mo
  Twilio calls (50 calls): ~$2.40/mo
  Claude API (50 calls):   ~$0.15/mo
  Domain name:             ~$1/mo (~$12/yr)
                           ─────────────
  TOTAL:                   ~$5–6/mo

Once you're charging clients $97–$597/mo, this pays for itself
on your very first customer.

---

## FOR EACH NEW CLIENT

1. Duplicate your GitHub repo — change the business info in app.html
2. Copy .env file — update BUSINESS_NAME, BUSINESS_DESC, BUSINESS_OFFER etc.
3. Buy them a Twilio number ($1/mo) — point it to the same bot
4. Deploy their version on Railway — takes 10 min
5. Charge them $97–$597/mo — your costs per client are ~$3-5/mo

---

## QUESTIONS?

Everything is documented inside claude-bot.js.
Read the comments — every function explains what it does and why.
