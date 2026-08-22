// GDPR DSAR with email-OTP verification.
//   action: 'send'   → email a 6-digit code to the signed-in user's own address
//   action: 'verify' → check the code; on success CREATE the data_requests row
//                      (server-side, so a request can't be filed without the code)
import { Resend } from 'resend';
import { createClient } from '@supabase/supabase-js';
import crypto from 'crypto';
import { applyCors } from './_cors.js';
import { rateLimit, clientIp } from './_ratelimit.js';
import { audit } from './_audit.js';

const resend = new Resend(process.env.RESEND_API_KEY);
const sha = (s) => crypto.createHash('sha256').update(String(s)).digest('hex');
const maskEmail = (e) => { const [u, d] = String(e).split('@'); return d ? (u.slice(0, 1) + '***@' + d) : e; };

export default async function handler(req, res) {
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { action, code } = req.body || {};
  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const sbUrl = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const sbKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!token || !sbKey) return res.status(401).json({ error: 'Not signed in' });

  const sb = createClient(sbUrl, sbKey, { auth: { persistSession: false } });

  // Resolve the caller from their token (mirrors send-email.js).
  let uid = null, email = '', name = '';
  try {
    const { data: who } = await sb.auth.getUser(token);
    if (who && who.user) { uid = who.user.id; email = who.user.email || ''; }
    else {
      const payload = JSON.parse(Buffer.from((token.split('.')[1] || ''), 'base64').toString('utf8'));
      if (payload && payload.sub) {
        const { data: byId } = await sb.auth.admin.getUserById(payload.sub);
        if (byId && byId.user) { uid = byId.user.id; email = byId.user.email || ''; }
      }
    }
  } catch (e) {}
  if (!uid) return res.status(401).json({ error: 'Invalid session' });
  try { const { data: p } = await sb.from('profiles').select('name').eq('id', uid).single(); name = (p && p.name) || ''; } catch (e) {}
  if (!email) return res.status(400).json({ error: 'Your account has no email on file — contact support.' });

  // ── Send a fresh code ──────────────────────────────────────────────────────
  if (action === 'send') {
    const rl = await rateLimit('dsar-otp-send:' + uid, 5, 15 * 60 * 1000);
    if (!rl.allowed) { res.setHeader('Retry-After', String(rl.retryAfter)); return res.status(429).json({ error: 'Too many code requests — please try again later.' }); }
    const c = String(Math.floor(100000 + Math.random() * 900000));
    const expires = new Date(Date.now() + 10 * 60 * 1000).toISOString();
    const up = await sb.from('data_request_otp').upsert(
      { user_id: uid, code_hash: sha(c), expires_at: expires, attempts: 0, created_at: new Date().toISOString() },
      { onConflict: 'user_id' });
    if (up.error) return res.status(500).json({ error: 'Could not start verification — run data_requests.sql first.' });
    const { error } = await resend.emails.send({
      from: 'Appie Hour <noreply@appiehour.com>', to: email,
      subject: 'Your Appie Hour data-request code',
      html: `<div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;">
        <h1>Verify your data request</h1><p>Hi ${name || 'there'},</p>
        <p>Use this code to confirm you're requesting a copy of your own data:</p>
        <p style="font-size:34px;font-weight:bold;letter-spacing:8px;margin:18px 0;">${c}</p>
        <p>This code expires in 10 minutes. If you didn't request this, you can safely ignore this email — no request will be created.</p></div>`,
    });
    if (error) return res.status(502).json({ error: error.message || 'Could not send the code.' });
    audit(req, { type: 'dsar_otp_sent', actor: uid, meta: { ip: clientIp(req) } });
    return res.status(200).json({ success: true, emailMasked: maskEmail(email) });
  }

  // ── Verify the code and create the request ─────────────────────────────────
  if (action === 'verify') {
    const rl = await rateLimit('dsar-otp-verify:' + uid, 12, 15 * 60 * 1000);
    if (!rl.allowed) { res.setHeader('Retry-After', String(rl.retryAfter)); return res.status(429).json({ error: 'Too many attempts — please try again later.' }); }
    if (!code || !/^\d{6}$/.test(String(code))) return res.status(400).json({ error: 'Enter the 6-digit code from your email.' });
    const { data: row } = await sb.from('data_request_otp').select('*').eq('user_id', uid).single();
    if (!row) return res.status(400).json({ error: 'No code found — request a new one.' });
    if (new Date(row.expires_at).getTime() < Date.now()) return res.status(400).json({ error: 'That code expired — request a new one.' });
    if ((row.attempts || 0) >= 5) return res.status(429).json({ error: 'Too many wrong attempts — request a new code.' });
    if (row.code_hash !== sha(String(code))) {
      await sb.from('data_request_otp').update({ attempts: (row.attempts || 0) + 1 }).eq('user_id', uid);
      return res.status(400).json({ error: 'Incorrect code — please try again.' });
    }
    // Correct → consume the code, then create the request (dedup any open one).
    await sb.from('data_request_otp').delete().eq('user_id', uid);
    const { data: open } = await sb.from('data_requests').select('id').eq('user_id', uid).in('status', ['pending', 'verifying', 'ready']).limit(1);
    if (open && open.length) { audit(req, { type: 'dsar_request_dupe', actor: uid }); return res.status(200).json({ success: true, already: true }); }
    const ins = await sb.from('data_requests').insert({ user_id: uid, user_email: email, user_name: name, type: 'export', status: 'pending' });
    if (ins.error) return res.status(500).json({ error: 'Verified, but could not file the request — try again.' });
    try {
      await resend.emails.send({
        from: 'Appie Hour <noreply@appiehour.com>', to: email,
        subject: "We've received your data request",
        html: `<div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;">
          <h1>Your data request 📩</h1><p>Hi ${name || 'there'},</p>
          <p>Thanks — we've verified it's you and received your request for a copy of your personal data. Our team will prepare your export and email you when it's ready (usually within 30 days).</p></div>`,
      });
    } catch (e) {}
    audit(req, { type: 'dsar_request_created', actor: uid });
    return res.status(200).json({ success: true });
  }

  return res.status(400).json({ error: 'Unknown action' });
}
