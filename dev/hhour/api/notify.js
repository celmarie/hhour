const { applyCors } = require('./_cors');
const { rateLimit, clientIp } = require('./_ratelimit');
const { audit } = require('./_audit');
// Serverless endpoint: insert a notification for any user using the Supabase
// service-role key (bypasses RLS). Used by the admin → customer messaging
// feature so admins can message users whose profile role check can't be
// satisfied client-side.
//
// Requires these Vercel environment variables:
//   SUPABASE_URL                — your project URL (https://xxxx.supabase.co)
//   SUPABASE_SERVICE_ROLE_KEY   — service_role key from Supabase → Settings → API
const { createClient } = require('@supabase/supabase-js');

module.exports = async function handler(req, res) {
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
  const _rl = await rateLimit('notify:' + clientIp(req), 30, 10 * 60 * 1000);
  if (!_rl.allowed) { audit(req, { type: 'rate_limit', severity: 'warn', meta: { route: 'notify' } }); res.setHeader('Retry-After', String(_rl.retryAfter)); return res.status(429).json({ error: 'Too many requests — please try again later' }); }

  // URL is public (already shipped in the client), so default it — only the
  // secret service-role key needs to be configured as a Vercel env var.
  const url = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) {
    return res.status(500).json({ error: 'Server missing SUPABASE_SERVICE_ROLE_KEY — add it in Vercel env vars' });
  }

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const { user_id, title, message, type, icon, icon_class } = body || {};

  if (!user_id) return res.status(400).json({ error: 'user_id required' });
  if (!title)   return res.status(400).json({ error: 'title required' });

  // AuthZ — this inserts for ANY user via the service-role key (bypasses RLS),
  // so the caller must prove they are an admin.
  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'Not signed in' });

  try {
    const admin = createClient(url, key, { auth: { persistSession: false } });

    let callerId = null;
    const { data: who } = await admin.auth.getUser(token);
    if (who && who.user) {
      callerId = who.user.id;
    } else {
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
      audit(req, { type: 'permission_denied', severity: 'warn', actor: callerId, meta: { route: 'notify', need: 'admin' } });
      return res.status(403).json({ error: 'Admins only' });
    }

    const { data, error } = await admin.from('notifications').insert({
      user_id: user_id,
      type: ['new', 'ending', 'rewards', 'system'].includes(type) ? type : 'system',
      title: title,
      body: message || '',
      icon: icon || '✉️',
      icon_class: icon_class || 'ai-purple',
      read: false
    }).select('id').single();

    if (error) return res.status(400).json({ error: error.message });
    return res.json({ ok: true, id: data && data.id });
  } catch (e) {
    return res.status(500).json({ error: e.message || 'Unknown error' });
  }
};
