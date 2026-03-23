/**
 * NEWSITES.COM — Claude AI Bot Integration
 * ==========================================
 * Powers: AI call responses, lead filtering, SMS follow-ups,
 *         appointment booking, queue messages, social posts, review replies
 *
 * Stack:
 *   - Claude API (Anthropic) — AI brain
 *   - Twilio — phone calls + SMS delivery
 *   - Supabase — database (leads, appointments, queue)
 *
 * Setup:
 *   1. npm install @anthropic-ai/sdk twilio @supabase/supabase-js express dotenv
 *   2. Create .env file with your keys (see bottom of this file)
 *   3. node claude-bot.js
 *   4. Point your Twilio phone number webhook to: http://yourserver.com/call/incoming
 */

require('dotenv').config();
const express = require('express');
const Anthropic = require('@anthropic-ai/sdk');
const twilio = require('twilio');
const { createClient } = require('@supabase/supabase-js');

const app = express();
app.use(express.urlencoded({ extended: true }));
app.use(express.json());

// ─── CLIENTS ────────────────────────────────────────────────────────────────
const claude    = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
const twilioClient = twilio(process.env.TWILIO_ACCOUNT_SID, process.env.TWILIO_AUTH_TOKEN);
const supabase  = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY);
const VoiceResponse = twilio.twiml.VoiceResponse;
const MessagingResponse = twilio.twiml.MessagingResponse;

// ─── BUSINESS CONFIG ─────────────────────────────────────────────────────────
// Edit this to match each client's business
const BUSINESS = {
  name:        process.env.BUSINESS_NAME    || 'Apex HVAC Services',
  phone:       process.env.BUSINESS_PHONE   || '(713) 555-0100',
  industry:    process.env.BUSINESS_INDUSTRY || 'HVAC / Home Services',
  description: process.env.BUSINESS_DESC    || 'Houston\'s top-rated HVAC company. 24/7 repair, installation, and maintenance.',
  offer:       process.env.BUSINESS_OFFER   || 'FREE 20-point inspection — a $149 value — for new customers this week.',
  owner:       process.env.OWNER_PHONE      || process.env.TWILIO_FROM_NUMBER,
};

// ─── HELPERS ─────────────────────────────────────────────────────────────────

/** Ask Claude anything, return text response */
async function askClaude(systemPrompt, userMessage, maxTokens = 300) {
  const response = await claude.messages.create({
    model: 'claude-sonnet-4-20250514',
    max_tokens: maxTokens,
    system: systemPrompt,
    messages: [{ role: 'user', content: userMessage }],
  });
  return response.content[0].text.trim();
}

/** Send an SMS via Twilio */
async function sendSMS(to, message) {
  try {
    await twilioClient.messages.create({
      body: message,
      from: process.env.TWILIO_FROM_NUMBER,
      to,
    });
    console.log(`SMS sent to ${to}`);
  } catch (err) {
    console.error('SMS error:', err.message);
  }
}

/** Save lead to Supabase */
async function saveLead(data) {
  const { error } = await supabase.from('leads').insert([{
    name:        data.name     || 'Unknown',
    phone:       data.phone,
    source:      data.source   || 'phone',
    status:      data.status   || 'new',
    notes:       data.notes    || '',
    score:       data.score    || 'warm',
    created_at:  new Date().toISOString(),
  }]);
  if (error) console.error('Supabase error:', error.message);
}

/** Get current call queue length */
async function getQueueLength() {
  const { count } = await supabase
    .from('call_queue')
    .select('*', { count: 'exact', head: true })
    .eq('status', 'waiting');
  return count || 0;
}

/** Add caller to queue */
async function addToQueue(phone, name) {
  const { data } = await supabase
    .from('call_queue')
    .insert([{ phone, name, status: 'waiting', created_at: new Date().toISOString() }])
    .select();
  return data?.[0]?.id;
}

/** Get position in queue */
async function getQueuePosition(phone) {
  const { data } = await supabase
    .from('call_queue')
    .select('*')
    .eq('status', 'waiting')
    .order('created_at', { ascending: true });
  if (!data) return 1;
  const idx = data.findIndex(r => r.phone === phone);
  return idx === -1 ? data.length + 1 : idx + 1;
}

// ─── LEAD SCORING ────────────────────────────────────────────────────────────

/** Use Claude to score and filter a lead */
async function scoreLead(callerInfo) {
  const system = `You are a lead qualification AI for ${BUSINESS.name}, a ${BUSINESS.industry} business.
Your job is to score inbound leads and filter out spam/low-quality callers.

Respond ONLY with valid JSON in this exact format:
{
  "score": "hot|warm|cold|filtered",
  "reason": "one sentence explaining the score",
  "intent": "what the caller likely wants",
  "shouldCallback": true or false
}

Score definitions:
- hot: Ready to buy, specific need, mentions timeline or urgency
- warm: Interested but not urgent, gathering info
- cold: Just browsing, no clear need or budget signals  
- filtered: Spam, solicitors, wrong number, abusive, no real intent`;

  const result = await askClaude(system,
    `Caller info: ${JSON.stringify(callerInfo)}`,
    150
  );

  try {
    return JSON.parse(result);
  } catch {
    return { score: 'warm', reason: 'Could not parse', intent: 'Unknown', shouldCallback: true };
  }
}

// ─── CALL HANDLING ────────────────────────────────────────────────────────────

/**
 * INBOUND CALL WEBHOOK
 * Point your Twilio phone number to: POST /call/incoming
 */
app.post('/call/incoming', async (req, res) => {
  const twiml = new VoiceResponse();
  const callerPhone = req.body.From;
  const callSid = req.body.CallSid;

  console.log(`Incoming call from ${callerPhone}`);

  try {
    // Check queue length
    const queueLen = await getQueueLength();
    const estWait   = queueLen * 3; // rough 3 min per call

    if (queueLen >= 3) {
      // Queue is busy — collect info then send SMS
      twiml.say({ voice: 'Polly.Joanna', language: 'en-US' },
        `Thank you for calling ${BUSINESS.name}! All of our team members are currently with other customers. ` +
        `You are number ${queueLen + 1} in line with an estimated wait of about ${estWait} minutes. ` +
        `I'll send you a text right now with your position. We will call you back as soon as we're free!`
      );

      // Add to queue
      await addToQueue(callerPhone, 'Caller');

      // Send queue position SMS
      await sendSMS(callerPhone,
        `Hi! This is ${BUSINESS.name}. You're #${queueLen + 1} in line — est. wait: ~${estWait} min. ` +
        `We'll call you back automatically. Reply CANCEL to remove yourself from the queue.`
      );

      // Score the lead in background
      const leadScore = await scoreLead({ phone: callerPhone, source: 'inbound_call', queueDrop: true });
      await saveLead({ phone: callerPhone, source: 'call', status: 'queued', score: leadScore.score, notes: leadScore.reason });

    } else {
      // Answer the call with AI gathering
      const gather = twiml.gather({
        input: 'speech',
        timeout: 5,
        action: '/call/respond',
        method: 'POST',
        speechTimeout: 'auto',
      });

      gather.say({ voice: 'Polly.Joanna', language: 'en-US' },
        `Thank you for calling ${BUSINESS.name}! I'm your AI assistant. ` +
        `I can help you schedule a service, get a free quote, or answer questions. ` +
        `How can I help you today?`
      );

      // If no speech input
      twiml.say({ voice: 'Polly.Joanna' },
        `I didn't catch that. Please call back and we'll be happy to help! Goodbye.`
      );
    }

  } catch (err) {
    console.error('Call handler error:', err);
    twiml.say('Thank you for calling. Please hold while we connect you.');
  }

  res.type('text/xml');
  res.send(twiml.toString());
});

/**
 * AI CALL RESPONSE
 * Processes what the caller said and responds intelligently
 */
app.post('/call/respond', async (req, res) => {
  const twiml = new VoiceResponse();
  const callerPhone = req.body.From;
  const callerSpeech = req.body.SpeechResult || '';

  console.log(`Caller said: "${callerSpeech}"`);

  try {
    // Score the lead based on what they said
    const leadScore = await scoreLead({
      phone: callerPhone,
      speech: callerSpeech,
      source: 'inbound_call',
    });

    // If filtered (spam/solicitor), end call politely
    if (leadScore.score === 'filtered') {
      twiml.say({ voice: 'Polly.Joanna' },
        `Thank you for calling ${BUSINESS.name}. We're not able to help with that today. Have a great day!`
      );
      await saveLead({
        phone: callerPhone,
        source: 'call',
        status: 'filtered',
        score: 'filtered',
        notes: leadScore.reason,
      });
      res.type('text/xml');
      return res.send(twiml.toString());
    }

    // Generate AI response to what caller said
    const aiReply = await askClaude(
      `You are the AI phone assistant for ${BUSINESS.name}, a ${BUSINESS.industry} business.
${BUSINESS.description}

Your job:
1. Respond helpfully to the caller's request in a friendly, professional tone
2. Try to book an appointment or get their contact info
3. Mention this offer if relevant: ${BUSINESS.offer}
4. Keep your response under 3 sentences — this is a phone call
5. If they want to book, say "Great! I'll send you a text to confirm the details right now."
6. Do NOT use markdown, asterisks, or special characters — this will be spoken aloud`,
      `Caller said: "${callerSpeech}"\nCaller intent detected: ${leadScore.intent}`,
      250
    );

    // Speak the AI response
    const gather = twiml.gather({
      input: 'speech',
      timeout: 5,
      action: '/call/book',
      method: 'POST',
      speechTimeout: 'auto',
    });
    gather.say({ voice: 'Polly.Joanna', language: 'en-US' }, aiReply);

    // Save lead
    await saveLead({
      phone: callerPhone,
      source: 'call',
      status: leadScore.score === 'hot' ? 'hot' : 'new',
      score: leadScore.score,
      notes: `Said: "${callerSpeech}" | Intent: ${leadScore.intent}`,
    });

    // If hot lead, notify owner
    if (leadScore.score === 'hot') {
      await sendSMS(BUSINESS.owner,
        `🔥 HOT LEAD calling right now!\nPhone: ${callerPhone}\nIntent: ${leadScore.intent}\nCall them back ASAP!`
      );
    }

  } catch (err) {
    console.error('Respond error:', err);
    twiml.say({ voice: 'Polly.Joanna' },
      `Thanks for calling ${BUSINESS.name}! I'll have someone call you back shortly. Have a great day!`
    );
  }

  res.type('text/xml');
  res.send(twiml.toString());
});

/**
 * BOOKING HANDLER
 * Triggers when caller responds to booking offer
 */
app.post('/call/book', async (req, res) => {
  const twiml = new VoiceResponse();
  const callerPhone = req.body.From;
  const callerSpeech = req.body.SpeechResult || '';

  try {
    // Check if they agreed to book
    const bookingIntent = await askClaude(
      `You are analyzing a caller's response to a booking offer. Reply ONLY with "yes" or "no".`,
      `The caller said: "${callerSpeech}". Did they agree to book or give their availability?`
    );

    if (bookingIntent.toLowerCase().includes('yes')) {
      twiml.say({ voice: 'Polly.Joanna' },
        `Perfect! I'm sending you a text right now to confirm your appointment details. ` +
        `We look forward to seeing you soon. Have a great day!`
      );

      // Send booking confirmation SMS
      await sendSMS(callerPhone,
        `Hi! This is ${BUSINESS.name}. Thanks for calling! ` +
        `Reply with your preferred day and time and we'll get you booked in. ` +
        `Or call us back at ${BUSINESS.phone}. Talk soon!`
      );

      // Update lead status
      await supabase
        .from('leads')
        .update({ status: 'booking_started' })
        .eq('phone', callerPhone);

    } else {
      twiml.say({ voice: 'Polly.Joanna' },
        `No problem at all! We're here whenever you need us. ` +
        `I'll send you our contact info by text. Have a wonderful day!`
      );

      await sendSMS(callerPhone,
        `Thanks for calling ${BUSINESS.name}! ` +
        `When you're ready to schedule, just reply to this text or call ${BUSINESS.phone}. ` +
        `${BUSINESS.offer}`
      );
    }

  } catch (err) {
    console.error('Booking error:', err);
    twiml.say({ voice: 'Polly.Joanna' }, `Thanks for calling! We\'ll be in touch soon.`);
  }

  res.type('text/xml');
  res.send(twiml.toString());
});

// ─── SMS HANDLING ─────────────────────────────────────────────────────────────

/**
 * INBOUND SMS WEBHOOK
 * Point your Twilio number to: POST /sms/incoming
 */
app.post('/sms/incoming', async (req, res) => {
  const twiml = new MessagingResponse();
  const fromPhone  = req.body.From;
  const msgBody    = req.body.Body?.trim() || '';

  console.log(`SMS from ${fromPhone}: "${msgBody}"`);

  try {
    // Handle queue cancellation
    if (msgBody.toUpperCase() === 'CANCEL') {
      await supabase
        .from('call_queue')
        .update({ status: 'cancelled' })
        .eq('phone', fromPhone);
      twiml.message(`No problem! You've been removed from the callback queue. Call us anytime at ${BUSINESS.phone}.`);
      res.type('text/xml');
      return res.send(twiml.toString());
    }

    // Handle STOP/unsubscribe
    if (['STOP', 'UNSUBSCRIBE', 'QUIT'].includes(msgBody.toUpperCase())) {
      twiml.message('You have been unsubscribed from our messages. Reply START to resubscribe anytime.');
      res.type('text/xml');
      return res.send(twiml.toString());
    }

    // Score the SMS lead
    const leadScore = await scoreLead({
      phone: fromPhone,
      message: msgBody,
      source: 'sms',
    });

    if (leadScore.score === 'filtered') {
      // Don't respond to spam
      res.type('text/xml');
      return res.send(twiml.toString());
    }

    // Generate Claude AI SMS reply
    const aiReply = await askClaude(
      `You are the SMS assistant for ${BUSINESS.name}, a ${BUSINESS.industry} business.
${BUSINESS.description}

Rules for SMS replies:
- Keep it under 160 characters if possible, max 2 texts worth
- Be friendly, helpful, and professional
- Try to get them to book or call
- Mention this offer if relevant: ${BUSINESS.offer}
- Do not use markdown or special formatting`,
      `Customer texted: "${msgBody}"\nDetected intent: ${leadScore.intent}`,
      200
    );

    twiml.message(aiReply);

    // Save lead
    await saveLead({
      phone: fromPhone,
      source: 'sms',
      status: leadScore.score,
      score: leadScore.score,
      notes: `SMS: "${msgBody}" | Intent: ${leadScore.intent}`,
    });

    // Alert owner for hot SMS leads
    if (leadScore.score === 'hot') {
      await sendSMS(BUSINESS.owner,
        `🔥 HOT SMS LEAD!\nFrom: ${fromPhone}\nMessage: "${msgBody}"\nFollow up now!`
      );
    }

  } catch (err) {
    console.error('SMS handler error:', err);
    twiml.message(`Thanks for reaching out to ${BUSINESS.name}! We'll get back to you shortly. Call us at ${BUSINESS.phone}.`);
  }

  res.type('text/xml');
  res.send(twiml.toString());
});

// ─── FOLLOW-UP AUTOMATION ─────────────────────────────────────────────────────

/**
 * SEND FOLLOW-UP SEQUENCES
 * Call this on a schedule (cron job) — e.g. every day at 9am
 * Example: node -e "require('./claude-bot').runFollowUps()"
 */
async function runFollowUps() {
  console.log('Running follow-up sequences...');

  // Get leads that need follow-up (new leads from 24h ago, not yet booked)
  const yesterday = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data: leads } = await supabase
    .from('leads')
    .select('*')
    .in('status', ['new', 'warm', 'cold'])
    .lt('created_at', yesterday)
    .is('follow_up_sent', null);

  if (!leads || leads.length === 0) {
    console.log('No follow-ups needed today.');
    return;
  }

  for (const lead of leads) {
    try {
      // Generate personalized follow-up with Claude
      const followUpMsg = await askClaude(
        `You are writing a follow-up SMS for ${BUSINESS.name}, a ${BUSINESS.industry} business.
Write a friendly, non-pushy follow-up text to someone who contacted us but hasn't booked yet.
Keep it under 160 characters. Be warm and personal. Include the offer if relevant.
Current offer: ${BUSINESS.offer}
Do not use markdown or special characters.`,
        `Lead info: Source: ${lead.source}, Notes: ${lead.notes}, Score: ${lead.score}`,
        120
      );

      await sendSMS(lead.phone, followUpMsg);

      // Mark follow-up sent
      await supabase
        .from('leads')
        .update({ follow_up_sent: new Date().toISOString() })
        .eq('id', lead.id);

      console.log(`Follow-up sent to ${lead.phone}`);

      // Small delay between messages
      await new Promise(r => setTimeout(r, 1000));

    } catch (err) {
      console.error(`Follow-up error for ${lead.phone}:`, err.message);
    }
  }

  console.log(`Follow-ups complete. Sent to ${leads.length} leads.`);
}

// ─── AUTO CALLBACK ────────────────────────────────────────────────────────────

/**
 * PROCESS CALLBACK QUEUE
 * Call this on a schedule to auto-call back waiting callers
 * Point the callback to /call/incoming to re-use the same flow
 */
async function processCallbackQueue() {
  const { data: queue } = await supabase
    .from('call_queue')
    .select('*')
    .eq('status', 'waiting')
    .order('created_at', { ascending: true })
    .limit(1);

  if (!queue || queue.length === 0) return;

  const next = queue[0];
  console.log(`Auto-calling back ${next.phone}...`);

  try {
    await twilioClient.calls.create({
      to:   next.phone,
      from: process.env.TWILIO_FROM_NUMBER,
      url:  `${process.env.SERVER_URL}/call/callback-greeting`,
    });

    await supabase
      .from('call_queue')
      .update({ status: 'calling_back' })
      .eq('id', next.id);

  } catch (err) {
    console.error('Callback error:', err.message);
  }
}

/** Greeting for auto-callbacks */
app.post('/call/callback-greeting', async (req, res) => {
  const twiml = new VoiceResponse();
  const gather = twiml.gather({
    input: 'speech',
    action: '/call/respond',
    timeout: 5,
    speechTimeout: 'auto',
  });
  gather.say({ voice: 'Polly.Joanna', language: 'en-US' },
    `Hi! This is ${BUSINESS.name} calling you back as promised. ` +
    `How can we help you today?`
  );
  res.type('text/xml');
  res.send(twiml.toString());
});

// ─── APPOINTMENT REMINDER ─────────────────────────────────────────────────────

/**
 * SEND APPOINTMENT REMINDERS
 * Run this daily — sends reminder 24h before each appointment
 */
async function sendAppointmentReminders() {
  const tomorrow = new Date(Date.now() + 24 * 60 * 60 * 1000);
  const tomorrowStr = tomorrow.toISOString().split('T')[0];

  const { data: appts } = await supabase
    .from('appointments')
    .select('*')
    .eq('date', tomorrowStr)
    .eq('reminder_sent', false);

  if (!appts || appts.length === 0) return;

  for (const appt of appts) {
    const msg =
      `Hi ${appt.customer_name}! Reminder: your ${BUSINESS.name} appointment is tomorrow ` +
      `at ${appt.time} at ${appt.address}. Reply YES to confirm or RESCHEDULE to change it.`;

    await sendSMS(appt.customer_phone, msg);

    await supabase
      .from('appointments')
      .update({ reminder_sent: true })
      .eq('id', appt.id);
  }
}

// ─── SOCIAL MEDIA POST GENERATOR ─────────────────────────────────────────────

/**
 * GENERATE SOCIAL MEDIA POST
 * Returns AI-written posts for Facebook, Instagram, Google Business
 */
async function generateSocialPost(platform, topic) {
  const specs = {
    facebook:  'Facebook business post. 2-3 sentences. Conversational. End with a call to action.',
    instagram: 'Instagram caption. Punchy opener. 1-2 sentences. Relevant hashtags at end.',
    google:    'Google Business update. Professional. 1-2 sentences. Focus on service/offer.',
  };

  const post = await askClaude(
    `You are a social media manager for ${BUSINESS.name}, a ${BUSINESS.industry} business.
Write a ${specs[platform] || specs.facebook}
Business: ${BUSINESS.description}
Current offer: ${BUSINESS.offer}
Do not use markdown formatting.`,
    `Write a post about: ${topic}`,
    200
  );

  return post;
}

// ─── REVIEW RESPONSE GENERATOR ───────────────────────────────────────────────

/**
 * GENERATE REVIEW RESPONSE
 * Pass in the review text and star rating, get a response back
 */
async function generateReviewResponse(reviewText, stars) {
  const tone = stars >= 4 ? 'grateful and warm' : stars === 3 ? 'appreciative and constructive' : 'empathetic and solution-focused';

  return await askClaude(
    `You are responding to a customer review on behalf of ${BUSINESS.name}.
Tone: ${tone}. Keep it 2-3 sentences. Be genuine, not generic.
Do not use markdown or special formatting.`,
    `${stars}-star review: "${reviewText}"`,
    180
  );
}

// ─── API ENDPOINTS FOR YOUR DASHBOARD ────────────────────────────────────────

/** Dashboard: Get all leads */
app.get('/api/leads', async (req, res) => {
  const { data, error } = await supabase
    .from('leads')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(50);
  if (error) return res.status(500).json({ error: error.message });
  res.json(data);
});

/** Dashboard: Get call queue */
app.get('/api/queue', async (req, res) => {
  const { data, error } = await supabase
    .from('call_queue')
    .select('*')
    .eq('status', 'waiting')
    .order('created_at', { ascending: true });
  if (error) return res.status(500).json({ error: error.message });
  res.json(data);
});

/** Dashboard: Get appointments */
app.get('/api/appointments', async (req, res) => {
  const { data, error } = await supabase
    .from('appointments')
    .select('*')
    .order('date', { ascending: true })
    .limit(20);
  if (error) return res.status(500).json({ error: error.message });
  res.json(data);
});

/** Dashboard: Generate social post on demand */
app.post('/api/social/generate', async (req, res) => {
  const { platform, topic } = req.body;
  try {
    const post = await generateSocialPost(platform, topic);
    res.json({ post });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/** Dashboard: Generate review response */
app.post('/api/reviews/respond', async (req, res) => {
  const { review, stars } = req.body;
  try {
    const response = await generateReviewResponse(review, stars);
    res.json({ response });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/** Dashboard: Trigger follow-ups manually */
app.post('/api/followups/run', async (req, res) => {
  try {
    await runFollowUps();
    res.json({ success: true, message: 'Follow-ups sent' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

/** Health check */
app.get('/', (req, res) => {
  res.json({
    status: 'running',
    business: BUSINESS.name,
    powered_by: 'Claude AI + Twilio',
    endpoints: {
      inbound_call:  'POST /call/incoming',
      inbound_sms:   'POST /sms/incoming',
      leads:         'GET  /api/leads',
      queue:         'GET  /api/queue',
      appointments:  'GET  /api/appointments',
      social:        'POST /api/social/generate',
      reviews:       'POST /api/reviews/respond',
      followups:     'POST /api/followups/run',
    }
  });
});

// ─── START SERVER ─────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`\n🤖 NEWSITES.COM Claude Bot running on port ${PORT}`);
  console.log(`📞 Inbound call webhook: POST http://localhost:${PORT}/call/incoming`);
  console.log(`💬 Inbound SMS webhook:  POST http://localhost:${PORT}/sms/incoming`);
  console.log(`📊 Dashboard API:        GET  http://localhost:${PORT}/api/leads\n`);
});

module.exports = { runFollowUps, processCallbackQueue, sendAppointmentReminders, generateSocialPost, generateReviewResponse };


/*
=================================================================
  .env FILE — Create this file in the same folder
  NEVER share or commit this file (add it to .gitignore)
=================================================================

# Claude AI
ANTHROPIC_API_KEY=sk-ant-your-key-here

# Twilio (get from twilio.com/console)
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=your-auth-token
TWILIO_FROM_NUMBER=+17135550100

# Supabase (get from supabase.com/dashboard)
SUPABASE_URL=https://yourproject.supabase.co
SUPABASE_ANON_KEY=your-anon-key

# Your business info (one bot per client)
BUSINESS_NAME=Apex HVAC Services
BUSINESS_PHONE=(713) 555-0100
BUSINESS_INDUSTRY=HVAC / Home Services
BUSINESS_DESC=Houston's top-rated HVAC company. 24/7 repair, installation, and maintenance.
BUSINESS_OFFER=FREE 20-point inspection for new customers this week — a $149 value.
OWNER_PHONE=+17135550142

# Your server's public URL (use ngrok for testing)
SERVER_URL=https://yourapp.railway.app
PORT=3000

=================================================================
  SUPABASE TABLES — Run these in your Supabase SQL editor
=================================================================

create table leads (
  id uuid default gen_random_uuid() primary key,
  name text, phone text, source text,
  status text, score text, notes text,
  follow_up_sent timestamptz,
  created_at timestamptz default now()
);

create table call_queue (
  id uuid default gen_random_uuid() primary key,
  phone text, name text, status text,
  created_at timestamptz default now()
);

create table appointments (
  id uuid default gen_random_uuid() primary key,
  customer_name text, customer_phone text,
  date text, time text, address text,
  service text, status text,
  reminder_sent boolean default false,
  created_at timestamptz default now()
);

=================================================================
  FREE HOSTING FOR THE BOT SERVER
  (Your app.html goes on GitHub Pages — this bot needs a server)
=================================================================

Best free options:
1. Railway.app — Free $5/mo credit, deploy in 2 min
   - Sign up at railway.app
   - "New Project" → "Deploy from GitHub repo"
   - Add your .env variables in Railway's dashboard
   - Done — Railway gives you a live URL

2. Render.com — Free tier, spins down after 15min idle
   - Good for testing, upgrade for production

3. Fly.io — Free tier, stays running 24/7

=================================================================
*/
