const { applyCors } = require('./_cors');
const { rateLimit, clientIp } = require('./_ratelimit');
const { audit } = require('./_audit');
// Serverless endpoint: a signed-in user deletes THEIR OWN account (GDPR/CCPA
// right to erasure). We soft-delete immediately (set profiles.deleted_at = now),
// which blocks sign-in right away (see handleAuthSession), and start the 30-day
// grace period. The actual hard-delete (which frees the email and cascades to all
// their data) is done by the daily cron in api/purge-deleted.js.
//
// Requires Vercel env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//   (optional) RESEND_API_KEY — to email a deletion confirmation.
const { createClient } = require('@supabase/supabase-js');

module.exports = async function handler(req, res) {
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
  const _rl = rateLimit('delete-my-account:' + clientIp(req), 5, 60 * 60 * 1000);
  if (!_rl.allowed) { audit(req, { type: 'rate_limit', severity: 'warn', meta: { route: 'delete-my-account' } }); res.setHeader('Retry-After', String(_rl.retryAfter)); return res.status(429).json({ error: 'Too many requests — please try again later' }); }

  const url = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return res.status(500).json({ error: 'Server missing SUPABASE_SERVICE_ROLE_KEY' });

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'Not signed in' });

  try {
    const admin = createClient(url, key, { auth: { persistSession: false } });

    // Identify the caller. getUser(token) can reject valid tokens with the new
    // sb_secret_ keys, so fall back to decoding the JWT sub + getUserById.
    let callerId = null, callerEmail = null;
    const { data: who } = await admin.auth.getUser(token);
    if (who && who.user) { callerId = who.user.id; callerEmail = who.user.email; }
    else {
      try {
        const payload = JSON.parse(Buffer.from(token.split('.')[1] || '', 'base64').toString('utf8'));
        if (payload && payload.sub) {
          const { data: byId } = await admin.auth.admin.getUserById(payload.sub);
          if (byId && byId.user) { callerId = byId.user.id; callerEmail = byId.user.email; }
        }
      } catch (e) {}
      if (!callerId) return res.status(401).json({ error: 'Invalid session' });
    }

    // Soft-delete the caller's OWN profile only. Service role => not blocked by RLS.
    const stamp = new Date().toISOString();
    const { data: upd, error: uErr } = await admin
      .from('profiles')
      .update({ deleted_at: stamp })
      .eq('id', callerId)
      .select('id, email');
    if (uErr) return res.status(400).json({ error: uErr.message });
    if (!upd || !upd.length) return res.status(404).json({ error: 'Profile not found' });
    callerEmail = callerEmail || (upd[0] && upd[0].email);

    // Best-effort confirmation email (non-fatal).
    try {
      if (process.env.RESEND_API_KEY && callerEmail) {
        const { Resend } = require('resend');
        const resend = new Resend(process.env.RESEND_API_KEY);
        await resend.emails.send({
          from: 'Appie Hour <noreply@appiehour.com>',
          to: callerEmail,
          subject: 'Your Appie Hour account has been scheduled for deletion',
          html:
            '<div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;">'
            + '<h2>Your account is scheduled for deletion</h2>'
            + '<p>We’ve received your request to delete your Appie Hour account. Your access has been disabled immediately.</p>'
            + '<p>All of your data — including credits, vouchers, reviews and history — will be <strong>permanently removed within 30 days</strong>.</p>'
            + '<p>If this wasn’t you, or you change your mind, please contact support as soon as possible so we can restore your account before it is permanently erased.</p>'
            + '</div>'
        });
      }
    } catch (e) { /* email failure must not block the deletion */ }

    audit(req, { type: 'account_delete_requested', severity: 'info', actor: callerId, target: callerId, meta: { route: 'delete-my-account' } });
    return res.json({ ok: true, deleted_at: stamp });
  } catch (e) {
    return res.status(500).json({ error: e.message || 'Unknown error' });
  }
};
