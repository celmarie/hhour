// Fan out an OS-level Web Push notification to subscribed devices (VAPID/web-push).
// Admin-only (mirrors notify.js auth). Targets: explicit user_ids, or all users of
// a role, or everyone. Dead subscriptions (404/410) are pruned automatically.
//
// Requires these Vercel environment variables:
//   SUPABASE_URL                — project URL (defaulted below; safe to omit)
//   SUPABASE_SERVICE_ROLE_KEY   — service_role key (Supabase → Settings → API)
//   VAPID_PRIVATE               — VAPID private key (keep secret)
//   VAPID_PUBLIC                — VAPID public key (defaulted below; not secret)
//   VAPID_SUBJECT               — "mailto:you@domain" (defaulted below)
const { applyCors } = require('./_cors');
const { rateLimit, clientIp } = require('./_ratelimit');
const { audit } = require('./_audit');
const { createClient } = require('@supabase/supabase-js');
const webpush = require('web-push');

const VAPID_PUBLIC  = process.env.VAPID_PUBLIC  || 'BAHC8ym5QUaY6-5Tv3q0Ckc5F1dZj52hj8tY85lzbEpy0BRPNg6RqiG0ajTwhwLs1PnoL5ztmpxnxfMttjKa66g';
const VAPID_SUBJECT = process.env.VAPID_SUBJECT || 'mailto:business@appiehour.com';

module.exports = async function handler(req, res) {
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const _rl = await rateLimit('send-push:' + clientIp(req), 30, 10 * 60 * 1000);
  if (!_rl.allowed) { audit(req, { type: 'rate_limit', severity: 'warn', meta: { route: 'send-push' } }); res.setHeader('Retry-After', String(_rl.retryAfter)); return res.status(429).json({ error: 'Too many requests — please try again later' }); }

  const url = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const vapidPrivate = process.env.VAPID_PRIVATE;
  if (!key) return res.status(500).json({ error: 'Server missing SUPABASE_SERVICE_ROLE_KEY' });
  if (!vapidPrivate) return res.status(500).json({ error: 'Server missing VAPID_PRIVATE — add it in Vercel env vars' });

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const { title, body: message, role, user_ids, url: clickUrl, icon, tag } = body || {};
  if (!title) return res.status(400).json({ error: 'title required' });

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'Not signed in' });

  try {
    const admin = createClient(url, key, { auth: { persistSession: false } });

    // AuthZ — service role bypasses RLS, so the caller must prove they're an admin.
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
    const { data: prof } = await admin.from('profiles').select('role').eq('id', callerId).single();
    if (!prof || !['admin', 'super_admin'].includes(prof.role)) {
      audit(req, { type: 'permission_denied', severity: 'warn', actor: callerId, meta: { route: 'send-push', need: 'admin' } });
      return res.status(403).json({ error: 'Admins only' });
    }

    // Resolve target user IDs.
    let targetIds = null; // null = everyone with a subscription
    if (Array.isArray(user_ids) && user_ids.length) {
      targetIds = user_ids.slice(0, 5000);
    } else if (role && ['customer', 'merchant', 'admin', 'super_admin'].includes(role)) {
      const { data: profs } = await admin.from('profiles').select('id').eq('role', role);
      targetIds = (profs || []).map(function (p) { return p.id; });
      if (!targetIds.length) return res.json({ ok: true, sent: 0, failed: 0, removed: 0, note: 'no users match role' });
    }

    // Pull the matching subscriptions.
    let q = admin.from('push_subscriptions').select('id,endpoint,p256dh,auth');
    if (targetIds) q = q.in('user_id', targetIds);
    const { data: subs, error: subErr } = await q;
    if (subErr) return res.status(400).json({ error: subErr.message });
    if (!subs || !subs.length) return res.json({ ok: true, sent: 0, failed: 0, removed: 0, note: 'no subscriptions' });

    webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, vapidPrivate);
    // Click target: only a relative path or an appiehour.com URL — never an arbitrary
    // (possibly phishing) origin, since it opens when the user taps the notification.
    function safeUrl(u){
      if (typeof u !== 'string' || !u) return '/';
      if (u.charAt(0) === '/' && u.charAt(1) !== '/') return u.slice(0, 300);   // relative (not protocol-relative)
      try { const p = new URL(u); if (/(^|\.)appiehour\.com$/i.test(p.hostname) && (p.protocol === 'https:' || p.protocol === 'http:')) return u.slice(0, 300); } catch (e) {}
      return '/';
    }
    const payload = JSON.stringify({
      title: String(title).slice(0, 120),
      body: String(message || '').slice(0, 300),
      url: safeUrl(clickUrl),
      icon: icon ? String(icon).slice(0, 300) : undefined,
      tag: tag ? String(tag).slice(0, 80) : undefined
    });

    let sent = 0, failed = 0;
    const dead = [];
    // Send in bounded batches so a big audience can't exhaust sockets at once.
    for (let i = 0; i < subs.length; i += 100) {
      const batch = subs.slice(i, i + 100);
      const results = await Promise.allSettled(batch.map(function (s) {
        return webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          payload,
          { TTL: 3600 }
        );
      }));
      results.forEach(function (r, idx) {
        if (r.status === 'fulfilled') { sent++; }
        else {
          failed++;
          const code = r.reason && r.reason.statusCode;
          if (code === 404 || code === 410) dead.push(batch[idx].id); // subscription gone → prune
          else console.warn('[send-push] send failed for sub', batch[idx].id, '→', code || (r.reason && r.reason.message) || 'unknown');
        }
      });
    }

    // Prune expired/invalid subscriptions.
    let removed = 0;
    if (dead.length) {
      const del = await admin.from('push_subscriptions').delete().in('id', dead);
      if (!del.error) removed = dead.length;
    }

    audit(req, { type: 'push_sent', actor: callerId, meta: { sent: sent, failed: failed, removed: removed } });
    return res.json({ ok: true, sent: sent, failed: failed, removed: removed });
  } catch (e) {
    return res.status(500).json({ error: e.message || 'Unknown error' });
  }
};
