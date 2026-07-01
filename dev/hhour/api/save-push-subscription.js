// Register/refresh a Web Push subscription for the signed-in user.
// Done server-side (service role) so a device that switches accounts correctly
// REASSIGNS its push endpoint to the current user — a client upsert can't, because
// the owner RLS policy blocks updating a row still owned by the previous account,
// which would otherwise leave the new user receiving the old user's notifications.
const { applyCors } = require('./_cors');
const { rateLimit, clientIp } = require('./_ratelimit');
const { createClient } = require('@supabase/supabase-js');

module.exports = async function handler(req, res) {
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const _rl = await rateLimit('save-push-sub:' + clientIp(req), 30, 10 * 60 * 1000);
  if (!_rl.allowed) { res.setHeader('Retry-After', String(_rl.retryAfter)); return res.status(429).json({ error: 'Too many requests' }); }

  const url = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return res.status(500).json({ error: 'Server missing SUPABASE_SERVICE_ROLE_KEY' });

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const { endpoint, p256dh, auth, user_agent } = body || {};
  if (!endpoint || !p256dh || !auth) return res.status(400).json({ error: 'endpoint, p256dh and auth are required' });
  if (String(endpoint).length > 2000) return res.status(400).json({ error: 'endpoint too long' });

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'Not signed in' });

  try {
    const admin = createClient(url, key, { auth: { persistSession: false } });
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

    // Reassign the endpoint to this user (service role bypasses RLS).
    const { error } = await admin.from('push_subscriptions').upsert({
      user_id: callerId,
      endpoint: String(endpoint),
      p256dh: String(p256dh),
      auth: String(auth),
      user_agent: (user_agent || '').slice(0, 200),
      updated_at: new Date().toISOString()
    }, { onConflict: 'endpoint' });
    if (error) return res.status(400).json({ error: error.message });
    return res.json({ ok: true });
  } catch (e) {
    return res.status(500).json({ error: e.message || 'Unknown error' });
  }
};
