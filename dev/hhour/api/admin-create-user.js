const { applyCors } = require('./_cors');
const { rateLimit, clientIp } = require('./_ratelimit');
const { audit } = require('./_audit');
// Serverless endpoint: an ADMIN creates a new user. Creating an account requires
// an auth.users record (service-role only) — the profiles row is created by the
// handle_new_user trigger, and we upsert role/status/name to be sure.
//
// Requires Vercel env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
const { createClient } = require('@supabase/supabase-js');
const crypto = require('crypto');

module.exports = async function handler(req, res) {
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
  const _rl = rateLimit('admin-create-user:' + clientIp(req), 30, 10 * 60 * 1000);
  if (!_rl.allowed) { audit(req, { type: 'rate_limit', severity: 'warn', meta: { route: 'admin-create-user' } }); res.setHeader('Retry-After', String(_rl.retryAfter)); return res.status(429).json({ error: 'Too many requests — please try again later' }); }

  const url = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return res.status(500).json({ error: 'Server missing SUPABASE_SERVICE_ROLE_KEY' });

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  let { email, name, role, status, password } = body || {};
  email = (email || '').trim().toLowerCase();
  name = (name || '').trim();
  role = ['customer', 'merchant', 'admin', 'super_admin'].includes(role) ? role : 'customer';
  status = status || 'active';
  if (!email || !name) return res.status(400).json({ error: 'name and email required' });

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'Not signed in' });

  try {
    const admin = createClient(url, key, { auth: { persistSession: false } });

    // 1) Caller must be an admin. getUser(token) can reject valid tokens with the
    //    new sb_secret_ keys, so fall back to decoding the JWT's sub and confirming
    //    the user exists via the service client.
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
      { audit(req, { type: 'permission_denied', severity: 'warn', actor: callerId, meta: { route: 'admin-create-user', need: 'admin' } }); return res.status(403).json({ error: 'Admins only' }); }
    }

    // 2) Create the auth user (generate a temp password if none supplied).
    const tempPassword = (password && String(password).length >= 6)
      ? String(password)
      : (crypto.randomBytes(9).toString('base64').replace(/[^a-zA-Z0-9]/g, '') + 'A1!');
    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email: email,
      password: tempPassword,
      email_confirm: true,
      user_metadata: { name: name, role: role }
    });
    if (cErr) {
      if (/already|exist|registered/i.test(cErr.message || '')) {
        return res.status(409).json({ error: 'A user with that email already exists' });
      }
      return res.status(400).json({ error: cErr.message });
    }
    const newUser = created && created.user;
    if (!newUser) return res.status(500).json({ error: 'User not created' });

    // 3) Ensure the profile reflects the chosen role/status/name, and (for staff
    //    accounts) require a password change on first login.
    const mustChange = (role === 'admin' || role === 'super_admin' || role === 'merchant');
    let _prow = { id: newUser.id, email: email, name: name, role: role, status: status, credits: 0, must_change_password: mustChange };
    let up = await admin.from('profiles').upsert(_prow, { onConflict: 'id' });
    if (up && up.error) { // must_change_password column may not exist yet — retry without it
      delete _prow.must_change_password;
      await admin.from('profiles').upsert(_prow, { onConflict: 'id' });
    }

    // 4) Email the new user their login + temporary password (best-effort).
    let emailed = false, emailError = null;
    try {
      if (!process.env.RESEND_API_KEY) {
        emailError = 'RESEND_API_KEY not set';
      } else {
        const { Resend } = require('resend');
        const resend = new Resend(process.env.RESEND_API_KEY);
        const roleLabel = (role === 'merchant') ? 'Merchant' : (role === 'customer' ? 'Member' : 'Admin');
        // Deep link straight to the correct login URL with the email pre-filled.
        const loginPath = (role === 'merchant') ? '/merchant' : (role === 'customer' ? '/' : '/fireclay');
        const signInUrl = 'https://www.appiehour.com' + loginPath + '?email=' + encodeURIComponent(email);
        const { error: mailErr } = await resend.emails.send({
          from: 'Appie Hour <noreply@appiehour.com>',
          to: email,
          subject: 'Your Appie Hour ' + roleLabel + ' account',
          html:
            '<div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;">'
            + '<h2>Welcome to Appie Hour, ' + (name || '') + ' 🍻</h2>'
            + '<p>An ' + roleLabel.toLowerCase() + ' account has been created for you. Sign in with:</p>'
            + '<div style="background:#f5f5f7;border-radius:10px;padding:14px 16px;margin:16px 0;">'
            +   '<p style="margin:4px 0;"><strong>Email:</strong> ' + email + '</p>'
            +   '<p style="margin:4px 0;"><strong>Temporary password:</strong> ' + tempPassword + '</p>'
            + '</div>'
            + '<p><strong>For your security, you’ll be asked to set a new password the first time you sign in.</strong></p>'
            + '<p><a href="' + signInUrl + '" style="background:#E8192C;color:#fff;padding:11px 20px;text-decoration:none;border-radius:8px;display:inline-block;font-weight:bold;">Sign in</a></p>'
            + '</div>'
        });
        emailed = !mailErr;
        if (mailErr) emailError = mailErr.message || 'send failed';
      }
    } catch (e) { emailError = e.message || 'send exception'; }

    audit(req, { type: 'admin_create_user', severity: 'info', actor: callerId, target: newUser.id, meta: { route: 'admin-create-user', emailed: emailed } });
    return res.json({ ok: true, id: newUser.id, temp_password: tempPassword, emailed: emailed, email_error: emailError });
  } catch (e) {
    return res.status(500).json({ error: e.message || 'Unknown error' });
  }
};
