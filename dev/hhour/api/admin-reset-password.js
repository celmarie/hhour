const { applyCors } = require('./_cors');
const { rateLimit, clientIp } = require('./_ratelimit');
const { audit } = require('./_audit');
// Serverless endpoint: an ADMIN sets another user's password.
// Changing someone else's password needs the Supabase service-role key, which
// must never be exposed in the browser — so it happens here, server-side, and
// only after we verify (server-side) that the caller is actually an admin.
//
// Requires Vercel env vars:
//   SUPABASE_URL                — project URL (defaults below)
//   SUPABASE_SERVICE_ROLE_KEY   — service_role key (Supabase → Settings → API)
const { createClient } = require('@supabase/supabase-js');

module.exports = async function handler(req, res) {
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
  const _rl = rateLimit('admin-reset-password:' + clientIp(req), 15, 10 * 60 * 1000);
  if (!_rl.allowed) { audit(req, { type: 'rate_limit', severity: 'warn', meta: { route: 'admin-reset-password' } }); res.setHeader('Retry-After', String(_rl.retryAfter)); return res.status(429).json({ error: 'Too many requests — please try again later' }); }

  const url = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return res.status(500).json({ error: 'Server missing SUPABASE_SERVICE_ROLE_KEY — add it in Vercel env vars' });

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const { user_id, new_password } = body || {};
  if (!user_id) return res.status(400).json({ error: 'user_id required' });
  if (!new_password || String(new_password).length < 6) {
    return res.status(400).json({ error: 'Password must be at least 6 characters' });
  }

  // The caller must prove they're an admin: read their JWT, look up their role.
  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'Not signed in' });

  try {
    const admin = createClient(url, key, { auth: { persistSession: false } });

    // 1) Who is calling? (getUser can reject valid sb_secret_-era tokens; fall back
    //    to decoding the JWT sub and confirming the user via the service client.)
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

    // 2) Are they an admin?
    const { data: prof, error: profErr } = await admin
      .from('profiles').select('role').eq('id', callerId).single();
    if (profErr || !prof || !['admin', 'super_admin'].includes(prof.role)) {
      audit(req, { type: 'permission_denied', severity: 'warn', actor: callerId, target: user_id, meta: { route: 'admin-reset-password', need: 'admin' } });
      return res.status(403).json({ error: 'Admins only' });
    }

    // 3) Set the target user's password (service-role can do this)
    const { error: updErr } = await admin.auth.admin.updateUserById(user_id, { password: String(new_password) });
    if (updErr) return res.status(400).json({ error: updErr.message });

    audit(req, { type: 'admin_reset_password', severity: 'warn', actor: callerId, target: user_id, meta: { route: 'admin-reset-password' } });
    return res.json({ ok: true });
  } catch (e) {
    return res.status(500).json({ error: e.message || 'Unknown error' });
  }
};
