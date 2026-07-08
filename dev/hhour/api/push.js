// Unified Web Push endpoint (one serverless function to stay under the Vercel
// Hobby 12-function limit). Two modes, distinguished by how the caller authenticates:
//
//   1. WEBHOOK  (header x-webhook-secret) — called by the Postgres trigger on every
//      INSERT into `notifications`. Body { record: <notification row> }. Looks up the
//      user's push_subscriptions and sends the OS push. This is the single auto-push
//      path (client inserts, admin broadcasts, and server-side RPCs all flow through it).
//
//   2. SUBSCRIBE (Authorization: Bearer <user token>, body { action:'subscribe', ... })
//      — registers/refreshes the caller's push subscription (service role, so a device
//      that switched accounts reassigns its endpoint cleanly).
//
// Requires Vercel env: SUPABASE_SERVICE_ROLE_KEY, VAPID_PRIVATE, PUSH_WEBHOOK_SECRET
//   (VAPID_PUBLIC / VAPID_SUBJECT / SUPABASE_URL have safe defaults)
const { applyCors } = require('./_cors');
const { rateLimit, clientIp } = require('./_ratelimit');
const { createClient } = require('@supabase/supabase-js');
const webpush = require('web-push');

const VAPID_PUBLIC  = process.env.VAPID_PUBLIC  || 'BAHC8ym5QUaY6-5Tv3q0Ckc5F1dZj52hj8tY85lzbEpy0BRPNg6RqiG0ajTwhwLs1PnoL5ztmpxnxfMttjKa66g';
const VAPID_SUBJECT = process.env.VAPID_SUBJECT || 'mailto:business@appiehour.com';

// Where tapping the notification lands. Everything opens the Alerts screen (where the
// sent notification appears in-app); rewards go straight to Credits.
function urlForType(type) {
  switch (type) {
    case 'rewards': return '/credits';
    default:        return '/alerts';
  }
}

module.exports = async function handler(req, res) {
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const supaUrl = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return res.status(500).json({ error: 'Server missing SUPABASE_SERVICE_ROLE_KEY' });

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  body = body || {};

  const admin = createClient(supaUrl, key, { auth: { persistSession: false } });
  const webhookSecret = req.headers['x-webhook-secret'] || '';

  // ── MODE 1: webhook (auto-push from the notifications trigger) ──────────────
  if (webhookSecret) {
    const secret = process.env.PUSH_WEBHOOK_SECRET;
    if (!secret) return res.status(500).json({ error: 'Server missing PUSH_WEBHOOK_SECRET' });
    // Trim both sides — a trailing space/newline on the pasted env var is the #1 cause
    // of a silent "Bad secret" mismatch.
    if (String(webhookSecret).trim() !== String(secret).trim()) {
      console.log('[push] secret mismatch', { envLen: secret.length, envTrimLen: secret.trim().length, hdrLen: String(webhookSecret).length });
      return res.status(401).json({ error: 'Bad secret' });
    }
    const vapidPrivate = process.env.VAPID_PRIVATE;
    if (!vapidPrivate) return res.status(500).json({ error: 'Server missing VAPID_PRIVATE' });

    const rec = (body.record || body.row) || {};
    const userId = rec.user_id;
    const title = rec.title;
    if (!userId || !title) return res.json({ ok: true, skipped: 'no user_id/title' });

    try {
      const { data: subs, error } = await admin
        .from('push_subscriptions').select('id,endpoint,p256dh,auth').eq('user_id', userId);
      if (error) return res.status(400).json({ error: error.message });
      if (!subs || !subs.length) { console.log('[push] webhook: user', String(userId).slice(0, 8), 'has 0 subscriptions'); return res.json({ ok: true, sent: 0 }); }

      webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, vapidPrivate);
      const payload = JSON.stringify({
        title: String(title).slice(0, 120),
        body: String(rec.body || '').slice(0, 300),
        url: urlForType(rec.type),
        tag: 'notif-' + (rec.id || '')
      });

      let sent = 0, failed = 0; const dead = [];
      const results = await Promise.allSettled(subs.map(function (s) {
        return webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600 });
      }));
      results.forEach(function (r, idx) {
        if (r.status === 'fulfilled') sent++;
        else {
          failed++;
          const code = r.reason && r.reason.statusCode;
          if (code === 404 || code === 410) dead.push(subs[idx].id);
          else console.warn('[push webhook] failed for sub', subs[idx].id, '→', code || (r.reason && r.reason.message));
        }
      });
      if (dead.length) { try { await admin.from('push_subscriptions').delete().in('id', dead); } catch (e) {} }
      console.log('[push] webhook: user', String(userId).slice(0, 8), '→ subs', subs.length, 'sent', sent, 'failed', failed);
      return res.json({ ok: true, sent: sent, failed: failed });
    } catch (e) {
      return res.status(500).json({ error: e.message || 'Unknown error' });
    }
  }

  // ── MODE 2: subscribe (register this device for the signed-in user) ─────────
  const _rl = await rateLimit('push-sub:' + clientIp(req), 30, 10 * 60 * 1000);
  if (!_rl.allowed) { res.setHeader('Retry-After', String(_rl.retryAfter)); return res.status(429).json({ error: 'Too many requests' }); }

  const action = body.action;
  if (action !== 'subscribe') return res.status(400).json({ error: 'Unknown action' });
  const { endpoint, p256dh, auth, user_agent } = body;
  if (!endpoint || !p256dh || !auth) return res.status(400).json({ error: 'endpoint, p256dh and auth are required' });
  if (String(endpoint).length > 2000) return res.status(400).json({ error: 'endpoint too long' });

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'Not signed in' });

  try {
    let callerId = null;
    const { data: who } = await admin.auth.getUser(token);
    if (who && who.user) callerId = who.user.id;
    else {
      try {
        const payload = JSON.parse(Buffer.from(token.split('.')[1] || '', 'base64').toString('utf8'));
        if (payload && payload.sub) {
          const { data: byId } = await admin.auth.admin.getUserById(payload.sub);
          if (byId && byId.user) callerId = byId.user.id;
        }
      } catch (e) {}
      if (!callerId) return res.status(401).json({ error: 'Invalid session' });
    }

    // Reassign the endpoint to this user (service role bypasses RLS, so switching
    // accounts on one device doesn't leave the new user getting the old user's pushes).
    const { error } = await admin.from('push_subscriptions').upsert({
      user_id: callerId, endpoint: String(endpoint), p256dh: String(p256dh),
      auth: String(auth), user_agent: (user_agent || '').slice(0, 200), updated_at: new Date().toISOString()
    }, { onConflict: 'endpoint' });
    if (error) return res.status(400).json({ error: error.message });
    return res.json({ ok: true });
  } catch (e) {
    return res.status(500).json({ error: e.message || 'Unknown error' });
  }
};
